# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""
MCU interface: the Zephyr shell over /dev/ttyHS1.

The shell is a line protocol - send a command, read until the prompt comes
back. SMP/MCUmgr frames share the same UART (the shell detects them in the byte
stream, so there is no `mcumgr` shell command), but that half lives in fota.py.

This wraps only the `app` command group the firmware defines. Everything else
the shell offers - `gpio`, `i2c`, `device`, `kernel`, `devmem` - is reachable
through cmd() or by typing it at `tio /dev/ttyHS1`, and needs no wrapper here.
"""

from __future__ import annotations

import contextlib
import errno
import fcntl
import os
import re
import termios
import time
from collections.abc import Sequence
from dataclasses import dataclass
from typing import NamedTuple

import serial

from .link import link_up

PORT = "/dev/ttyHS1"

# Kernel-enforced exclusive access to a tty. Set it on our fd and any later
# open() by a process without CAP_SYS_ADMIN fails with EBUSY.
#
# Python's termios does not export these on every platform, hence the fallback
# to the numeric values from <asm-generic/ioctls.h>. They are stable ABI.
TIOCEXCL = getattr(termios, "TIOCEXCL", 0x540C)
TIOCNXCL = getattr(termios, "TIOCNXCL", 0x540D)

# The panel's limits, mirroring APP_BARS_* / APP_MATRIX_* in
# mcu/app/include/app_proto.h. They cannot be imported from C, so
# tests/test_contract.py reads that header and fails if these drift.
BARS_MAX = 7
BARS_PCT_MAX = 100
MATRIX_ROWS = 8
MATRIX_COLS = 13
MATRIX_MAX_LEVEL = 7
BAUD = 115200
# What the firmware puts in front of a command it refuses: APP_ERR in
# app_proto.h. test_contract.py holds the two together.
ERROR_PREFIX = "Error:"
# What the Zephyr shell itself says when it will not run a line at all - before
# any handler of ours is reached, so without our prefix. The second was found
# on the board: `app matrix px 1 1`, one argument short, came back as two lines
# of usage text and was returned as though it were the reply.
_SHELL_REFUSALS = ("command not found", "wrong parameter count")

# The two lines `app temp` can answer with: APP_TEMP_FMT and APP_TEMP_ERR_FMT in
# app_proto.h, with each %d turned into a signed-integer group. Anchored at both
# ends because a reading is the whole line or it is not a reading.
# tests/test_contract.py rebuilds both from the header and fails if they drift.
_TEMP = re.compile(r"^temp_mc=(-?\d+)$")
_TEMP_ERR = re.compile(r"^temp_err=(-?\d+)$")
# The lines `app temp log` and `app temp log stat` answer with: APP_TEMPLOG_* in
# app_proto.h, %u as an unsigned group and %d and %lld as signed ones.
# tests/test_contract.py rebuilds each from the header and fails if they drift.
_TEMPLOG = re.compile(r"^seq=(\d+) ms=(-?\d+) temp_mc=(-?\d+)$")
_TEMPLOG_ERR = re.compile(r"^seq=(\d+) ms=(-?\d+) temp_err=(-?\d+)$")
# The reply to `app matrix frame`: APP_MATRIX_FRAME_FMT, pinned the same way.
_MATRIX_FRAME = re.compile(r"^ok frame lit=(-?\d+)$")
# One row of a frame as the firmware's app_matrix_row_valid() takes it: exactly
# MATRIX_COLS level digits. ASCII only, as the C check is: str.isdigit() would
# let through digits from other scripts that the MCU has never heard of.
_MATRIX_ROW = re.compile(rf"[0-{MATRIX_MAX_LEVEL}]{{{MATRIX_COLS}}}")
_TEMPLOG_GAP = re.compile(r"^gap first=(\d+) last=(\d+)$")
_TEMPLOG_END = re.compile(r"^end head=(\d+) more=(\d+)$")
_TEMPLOG_STAT = re.compile(r"^head=(\d+) count=(\d+) size=(\d+) dropped=(\d+) period_ms=(\d+)$")
# APP_RESET_FMT: one value, the reset causes comma-separated. The names are
# guard_reset_table in mcu/app/include/guard.h, in the order it prints them;
# test_contract.py fails if this list and that table part ways.
_RESET = re.compile(r"^reset=([a-z_]+(?:,[a-z_]+)*)$")
RESET_CAUSES = (
    "watchdog",
    "lockup",
    "software",
    "security",
    "brownout",
    "power_on",
    "low_power_wake",
    "debug",
    "parity",
    "pll",
    "clock",
    "hardware",
    "user",
    "temperature",
    "bootloader",
    "flash",
    "pin",
)
RESET_NONE = "none"
RESET_UNKNOWN = "unknown"
# `app jitter`: APP_JITTER_* in app_proto.h. The bin edges and the limits are
# numbers test_contract.py reads out of the header; the reply regexes are
# rebuilt there from the formats, as the others are.
JITTER_EDGES_US = (50, 100, 200, 500, 1000, 2000, 5000)
JITTER_BINS = 2 * len(JITTER_EDGES_US) + 1
JITTER_PERIOD_US_MIN = 100
JITTER_PERIOD_US_MAX = 10_000_000
JITTER_PWM_HZ_MIN = 16
JITTER_PWM_HZ_MAX = 10_000
JITTER_SOURCES = ("tick", "pwm")
_JITTER = re.compile(
    r"^jitter src=([a-z]+) period_us=(\d+) n=(\d+) min_ns=(-?\d+) max_ns=(-?\d+)"
    r" mean_ns=(-?\d+) bins=(\d+(?:,\d+)*)$"
)
_JITTER_ARM = re.compile(r"^ok jitter arm period_us=(\d+)$")
_JITTER_PWM = re.compile(r"^ok jitter pwm hz=(\d+) period_us=(\d+)$")
_JITTER_OFF = re.compile(r"^ok jitter off$")
# `app scope`: APP_SCOPE_* in app_proto.h, checked by tests/test_contract.py.
SCOPE_POINTS = 64
SCOPE_DAC_MID = 2048
SCOPE_DAC_AMPLITUDE = 1638
SCOPE_DAC_MAX = 4095
SCOPE_ADC_MAX = 16383
SCOPE_WAVE_HZ_MIN = 1
SCOPE_WAVE_HZ_MAX = 10_000
SCOPE_N_MIN = 16
SCOPE_N_MAX = 4096
SCOPE_RATE_HZ_MIN = 100
SCOPE_RATE_HZ_MAX = 250_000
SCOPE_BURST_MS_MAX = 500
SCOPE_WAVE_OFF = "off"
SCOPE_WAVES = ("sine", "triangle")
_SCOPE_GEN = re.compile(r"^ok scope gen wave=([a-z]+) hz=(\d+) actual_hz=(\d+)\.(\d{3})$")
_SCOPE_CAPTURE = re.compile(
    r"^ok scope capture id=(\d+) n=(\d+) rate_hz=(\d+)\.(\d{3}) min=(\d+) max=(\d+) mean=(\d+)$"
)
_SCOPE_STAT = re.compile(
    r"^scope wave=([a-z]+) hz=(\d+)\.(\d{3}) id=(\d+) n=(\d+) rate_hz=(\d+)\.(\d{3})"
    r" busy=(\d+) failed=(\d+)$"
)
_SCOPE_OFF = re.compile(r"^ok scope off$")
_ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
_PROMPT = re.compile(r"^\s*\S*:~\$\s*$")
# A prompt with something typed after it on the same line: how a command's
# echo arrives when the prompt before it was not swallowed by the input flush.
_PROMPT_PREFIX = re.compile(r"^\S*:~\$\s*")


class MCUError(RuntimeError):
    """The MCU reported an error, or returned something unparsable."""


class PortBusy(MCUError):
    """Someone else has the port - or a process that exited left it flagged.

    Separate from MCUError because it is the one failure here that is about
    this machine rather than about the MCU, and the fix is a different shape:
    stop something, or restart something.
    """


def port_holders(port: str = PORT) -> list[tuple[int, str]]:
    """Which processes have `port` open, as (pid, command).

    Reads /proc rather than shelling out to lsof, which is not installed
    everywhere and needs root here to see other users' processes.

    INCOMPLETE BY CONSTRUCTION, and callers must treat it that way: without
    root this can only see processes owned by the same user. An empty list
    means "nothing I am allowed to see", never "nothing".
    """
    found: list[tuple[int, str]] = []
    try:
        pids = os.listdir("/proc")
    except OSError:
        # No /proc, or no permission to read it. This function only ever runs
        # while building the message for an ALREADY failed open, so raising
        # here would replace a precise "the port is busy, here is who has it"
        # with an unrelated errno about /proc - losing the diagnosis to the
        # code that exists to provide it. An empty list is what the docstring
        # already promises callers to expect.
        return found
    for entry in pids:
        if not entry.isdigit():
            continue
        pid = int(entry)
        try:
            fds = os.listdir(f"/proc/{pid}/fd")
        except OSError:
            continue  # exited, or not ours to look at
        for fd in fds:
            try:
                if os.readlink(f"/proc/{pid}/fd/{fd}") != port:
                    continue
            except OSError:
                continue
            try:
                with open(f"/proc/{pid}/comm") as fh:
                    comm = fh.read().strip()
            except OSError:
                comm = "?"
            found.append((pid, comm))
            break
    return found


def _busy_message(port: str, holders: list[tuple[int, str]]) -> str:
    """Explain an EBUSY in terms of what to actually do about it."""
    if holders:
        who = ", ".join(f"{comm} (pid {pid})" for pid, comm in holders)
        return (
            f"{port} is flagged exclusive. Open right now: {who}.\n"
            f"  Stop it first - for the demo that is:  systemctl stop unoq-cpu-bars\n"
            f"  (Deliberately not claiming that process SET the flag. It may be an\n"
            f"  innocent bystander that merely keeps the tty open while a TIOCEXCL\n"
            f"  set by something already gone outlives it. The remedy is the same\n"
            f"  either way: get every opener to close.)"
        )
    # Nothing visible has it open, yet the kernel says busy. Two ways that
    # happens, and the second one is the trap this whole function exists for.
    return (
        f"{port} is flagged exclusive, but no process this user can see has it open.\n"
        f"  Either another user holds it (try: sudo lsof {port}), or - much more\n"
        f"  likely - a program that sets TIOCEXCL (tio, screen) exited while a\n"
        f"  long-lived reader still had the port open. The flag is per-tty and is\n"
        f"  only cleared on the LAST close, so it outlives the process that set it\n"
        f"  and lsof shows nothing to explain it.\n"
        f"  Fix:  systemctl restart unoq-cpu-bars"
    )


def open_port(port: str = PORT, baud: int = BAUD, timeout: float = 0.3) -> serial.Serial:
    """Open the port so that nothing else can, and fail legibly when it cannot.

    TWO LOCKS, because they catch different intruders and neither is enough:

      flock (pyserial's exclusive=True) is ADVISORY. It stops another pyserial
      caller that also asks for it, and nothing else - tio, screen, cat and
      arduino-app-cli all walk straight through it.

      TIOCEXCL is enforced by the kernel at open(). It stops all of those.

    The comment that used to be here claimed TIOCEXCL was what exclusive=True
    did. It is not - pyserial 3.5 never mentions TIOCEXCL, it calls
    flock(LOCK_EX|LOCK_NB) - so the guarantee documented for this port had
    never actually been in force. Measured on this board: with the service
    running, two further plain serial.Serial() opens both succeeded.
    """
    try:
        s = serial.Serial(port, baud, timeout=timeout, exclusive=True)
    except serial.SerialException as exc:
        if exc.errno == errno.EBUSY:
            raise PortBusy(_busy_message(port, port_holders(port))) from exc
        if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
            # flock refused: another pyserial caller that also asked for it.
            raise PortBusy(_busy_message(port, port_holders(port))) from exc
        raise
    # Now make it stick for everyone else. There is a small race between the
    # open above and this - another process could get in during it - which is
    # unavoidable without opening the fd ourselves and handing it to pyserial.
    # It is microseconds, against a failure mode that lasts until reboot.
    #
    # Tolerate ONLY "this device does not do TIOCEXCL" - a tty that will not
    # take it still works, we just do not get to exclude tio, and refusing to
    # talk to the MCU over that would be a bad trade.
    #
    # Everything else is re-raised deliberately. Suppressing all OSError here
    # would mean an EBADF or EPERM silently downgraded us to advisory-only
    # locking, which is EXACTLY the failure this function exists to end: a lock
    # that does not lock, with nothing to say so.
    set_exclusive(s)
    return s


def set_exclusive(s: serial.Serial) -> None:
    """Set TIOCEXCL on an open port, closing it and raising if that fails for
    any reason but "this device does not do TIOCEXCL". See open_port().

    Its own function because fota opens the port through smpclient, not
    through open_port(), and has to apply the same rule to that fd.
    """
    try:
        fcntl.ioctl(s.fileno(), TIOCEXCL)
    except OSError as exc:
        if exc.errno not in (errno.ENOTTY, errno.EINVAL, errno.ENOSYS):
            s.close()
            raise


class ShellTimeout(MCUError):
    """No prompt came back before the deadline."""


class TempSample(NamedTuple):
    """One sample from the MCU's temperature log.

    `seq` counts up by one per sample from 1 at the MCU's boot, so a reader
    that sees 41 and then 45 knows 42 to 44 are gone. `ms` is the MCU's own
    uptime when it was taken - its clock, not Linux's. `temp_c` is None when
    the sensor read failed, and `err` is then the negative Zephyr errno; the
    sample keeps its number either way, so a failed read is never mistaken
    for a lost one.
    """

    seq: int
    ms: int
    temp_c: float | None
    err: int = 0


@dataclass(frozen=True)
class TempLogStat:
    """`app temp log stat`: where the MCU's temperature log stands.

    `head` is the newest sequence number, 0 before the first sample. A
    `head` lower than one seen before means the MCU has restarted.
    `dropped` is how many samples have been overwritten, read or not.
    """

    head: int
    count: int
    size: int
    dropped: int
    period_ms: int


def _jitter_labels() -> tuple[str, ...]:
    """A name for each bin, earliest first: "<-5000", "-5000..-2000", ...,
    "-50..50", ..., "2000..5000", ">5000", in microseconds."""
    e = JITTER_EDGES_US
    early = [f"<-{e[-1]}"] + [f"-{e[i]}..-{e[i - 1]}" for i in range(len(e) - 1, 0, -1)]
    late = [f"{e[i - 1]}..{e[i]}" for i in range(1, len(e))] + [f">{e[-1]}"]
    return (*early, f"-{e[0]}..{e[0]}", *late)


JITTER_BIN_LABELS = _jitter_labels()


@dataclass(frozen=True)
class JitterHist:
    """One of the two histograms `app jitter stat` prints.

    `src` is "tick" (Linux's `app jitter tick` arrivals, timestamped on the
    MCU's 1 MHz TIM5) or "pwm" (the period of the square wave on D3, captured
    on D2 by TIM2 through a jumper). Each interval is compared with
    `period_us`, which is 0 if there has never been one to compare with.

    `n` counts intervals. `min_ns`, `max_ns` and `mean_ns` are deviations
    from the period in nanoseconds, negative early and positive late, all 0
    when `n` is 0. `bins` is JITTER_BINS counts, earliest first; their edges
    are JITTER_EDGES_US, and JITTER_BIN_LABELS names them.
    """

    src: str
    period_us: int
    n: int
    min_ns: int
    max_ns: int
    mean_ns: int
    bins: tuple[int, ...]


class JitterStat(NamedTuple):
    """`app jitter stat`: Linux's schedule, and the MCU's hardware, side by side."""

    tick: JitterHist
    pwm: JitterHist


_NO_JITTER = (
    "this firmware has no `app jitter` command - it predates it. "
    "Rebuild and update it (mcu/zbuild.sh, then unoq.fota)"
)


_NO_SCOPE = (
    "this firmware has no `app scope` command - it predates it. "
    "Rebuild and update it (mcu/zbuild.sh, then unoq.fota)"
)


def scope_capture_valid(n: int, rate_hz: int) -> bool:
    """app_scope_capture_valid(): each in range, and no longer than
    SCOPE_BURST_MS_MAX, which is how long a capture may keep adc1 from the
    die temperature."""
    return (
        SCOPE_N_MIN <= n <= SCOPE_N_MAX
        and SCOPE_RATE_HZ_MIN <= rate_hz <= SCOPE_RATE_HZ_MAX
        and n * 1000 <= SCOPE_BURST_MS_MAX * rate_hz
    )


def _hz3(whole: str, frac: str) -> float:
    """A %u.%03u rate, back to hertz."""
    return int(whole) + int(frac) / 1000


@dataclass(frozen=True)
class ScopeCapture:
    """`app scope capture`: what the MCU took, summarized by the MCU itself.

    The samples are not here: they go up the SPI link (unoq.spilink,
    SpiLink.scope_read). `rate_hz` is the rate TIM6 really ran at. `min`,
    `max` and `mean` are 14-bit ADC codes, so the burst read over SPI can be
    checked against them.
    """

    id: int
    n: int
    rate_hz: float
    min: int
    max: int
    mean: int


@dataclass(frozen=True)
class ScopeStat:
    """`app scope stat`: the wave playing (`wave` "off" and `hz` 0 if none),
    the capture that can be read (`id` 0 if none), whether one is running,
    and how many have failed since boot."""

    wave: str
    hz: float
    id: int
    n: int
    rate_hz: float
    busy: bool
    failed: int


_NO_TEMP_LOG = (
    "this firmware has no temperature log (`app temp log`) - it predates it. "
    "Rebuild and update it (mcu/zbuild.sh, then unoq.fota)"
)


def _predates_temp_log(line: str) -> bool:
    """Is this what a firmware without `app temp log` says to it?

    One of two things: the help for `app`, from a firmware without `app temp`
    at all, or a plain reading, from one whose `app temp` has no subcommands
    and takes the words after it as arguments it ignores.
    """
    return line == "Subcommands:" or bool(_TEMP.match(line))


def _echo_span(lines: list[str], start: int, command: str) -> int | None:
    """How many lines from `start` the echo of `command` takes, or None.

    The shell wraps its echo at the terminal width (80 columns), so a long
    command such as `app matrix frame` comes back over two lines. A wrap that
    falls on a space loses it when the lines are stripped, so the pieces are
    compared with all whitespace removed.
    """
    want = re.sub(r"\s+", "", command)
    got = ""
    for n, line in enumerate(lines[start:], 1):
        got += re.sub(r"\s+", "", _PROMPT_PREFIX.sub("", line) if n == 1 else line)
        if got == want:
            return n
        if not want.startswith(got):
            return None
    return None


def _after_echo(lines: list[str], command: str) -> list[str] | None:
    """The lines after the last echo of `command`, or None if it is not there."""
    for i in range(len(lines) - 1, -1, -1):
        if (n := _echo_span(lines, i, command)) is not None:
            return lines[i + n :]
    return None


def _clean(text: str) -> list[str]:
    """Strip ANSI, drop echoed input and prompts, return meaningful lines."""
    lines = []
    for raw in _ANSI.sub("", text).replace("\r", "\n").splitlines():
        line = raw.strip()
        if not line or _PROMPT.match(line):
            continue
        lines.append(line)
    return lines


class MCU:
    """Synchronous handle on the MCU's Zephyr shell.

    Use as a context manager so the port is always released - the UART is a
    single shared resource and a stale handle blocks `tio`, `mcucon` and SMP.
    """

    def __init__(
        self, port: str = PORT, baud: int = BAUD, timeout: float = 0.3, ensure_link: bool = True
    ):
        if ensure_link:
            # Cheap, idempotent; without it every read silently returns b"".
            # Not fatal - the link may already be up, or permissions may differ.
            with contextlib.suppress(Exception):
                link_up()
        # Exclusive, because the alternative is not "the second opener fails" -
        # it is "both succeed and interleave".
        #
        # Measured on this board with unoq-cpu-bars.service running and eight
        # status reads attempted alongside it: six returned correctly and two
        # failed with
        #
        #   device reports readiness to read but returned no data
        #   (device disconnected or multiple access on port?)
        #
        # which is a confusing way to be told you are sharing a serial port -
        # it reads like the cable fell out. Mostly-working with occasional
        # corruption is worse than a clean refusal, because it survives
        # testing.
        #
        # See open_port for which lock does what, and why one is not
        # enough. The documentation has always said to stop the service before
        # using the shell; this is what finally makes that true rather than
        # merely advisable.
        self._s = open_port(port, baud, timeout)
        self._port = port
        # Set by send(): replies to lines nobody read may still be arriving.
        self._unread = False
        time.sleep(0.15)
        self._s.reset_input_buffer()

    # -- lifecycle ---------------------------------------------------------

    def close(self) -> None:
        if self._s.is_open:
            self._s.close()

    def __enter__(self) -> MCU:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    # -- raw shell ---------------------------------------------------------

    def cmd(self, command: str, timeout: float = 2.0) -> list[str]:
        """Run any shell command, return its output lines (prompt/echo removed).

        Reads until the prompt reappears rather than sleeping a fixed time, so
        slow commands (`device list`) and fast ones cost what they should.

        After send(), the echo and prompt of a line sent blind can still be on
        their way when this starts, and that prompt would end the wait before
        this command's reply had begun. So until one cmd() has completed after
        a send(), the prompt only counts once this command's own echo has been
        seen, and only what follows the echo is the reply.
        """
        unread = self._unread
        self._s.reset_input_buffer()
        self._s.write((command + "\r\n").encode())
        self._s.flush()

        # monotonic, not time(): the board has no battery-backed clock, and an
        # NTP step after boot would end this wait at once or stretch it out.
        buf, deadline = "", time.monotonic() + timeout
        while time.monotonic() < deadline:
            chunk = self._s.read(4096)
            if chunk:
                buf += chunk.decode("utf-8", "replace")
                # The prompt is the reliable end-of-response marker.
                if re.search(r":~\$\s*$", _ANSI.sub("", buf).replace("\r", "\n")) and (
                    not unread or _after_echo(_clean(buf), command) is not None
                ):
                    break
        else:
            raise ShellTimeout(f"no prompt after {timeout}s for {command!r}")

        lines = _clean(buf)
        if unread:
            lines = _after_echo(lines, command) or []
            self._unread = False
        # Drop the echoed command itself, however many lines it was wrapped over.
        elif lines and (n := _echo_span(lines, 0, command)) is not None:
            lines = lines[n:]
        for line in lines:
            if line.startswith(ERROR_PREFIX) or any(said in line for said in _SHELL_REFUSALS):
                raise MCUError(f"{command!r}: {line}")
        return lines

    def send(self, command: str) -> None:
        """Send a shell command and do not wait for, or read, its reply.

        For a command whose only point is when it arrives: `app jitter tick`.
        Waiting for the prompt would put the MCU's reply time into the
        schedule being measured. Whatever is waiting to be read - the replies
        to earlier sends - is thrown away first, so the input never fills: if
        it did, the kernel would hold the MCU off with RTS, the shell would
        block on its output, and the ticks behind it would arrive late for a
        reason that has nothing to do with Linux's scheduling.

        The write is not drained (no flush): it returns once the line is in
        the kernel's buffer, which starts sending it at once.

        The next cmd() knows replies may still be on their way, and reads
        past them to its own.
        """
        self._s.reset_input_buffer()
        self._s.write((command + "\r\n").encode())
        self._unread = True

    # -- the `app` command group -------------------------------------------

    def status(self) -> dict[str, int | str]:
        """Parse `app status` into a dict, values converted to int where possible.

        Values are ints in practice - the firmware emits counters - but a field
        it cannot parse is kept as the raw string rather than dropped, so a
        firmware change surfaces as an odd value instead of a missing key.
        """
        out = self.cmd("app status")
        if not out:
            raise MCUError("app status returned nothing")
        fields: dict[str, int | str] = {}
        for token in out[0].split():
            if "=" in token:
                k, _, v = token.partition("=")
                try:
                    fields[k] = int(v)
                except ValueError:
                    fields[k] = v
        if not fields:
            raise MCUError(f"could not parse: {out[0]!r}")
        return fields

    def die_temp(self) -> float:
        """The microcontroller's die temperature in degrees Celsius.

        This is the one temperature on the board Linux cannot read for itself:
        /sys/class/thermal is all QRB2210, and says nothing about the STM32.
        The firmware sends integer millidegrees - the unit sysfs uses - and
        this divides by a thousand.

        The number is the chip's internal sensor converted with ST's factory
        calibration, which is good for a few degrees and no better. It is
        junction temperature, so it sits above the air around the board.

        Raises MCUError in three cases that need telling apart, because the
        fixes differ: the firmware tried and could not read the sensor; the
        firmware predates `app temp`; or the reply was something else.
        """
        out = self.cmd("app temp")
        for line in out:
            failed = _TEMP_ERR.match(line)
            if failed:
                raise MCUError(
                    f"the MCU could not read its die temperature sensor ({line}). "
                    f"The number is a negative Zephyr errno: -19 (ENODEV) means the "
                    f"sensor or its ADC did not come up at boot, anything else came "
                    f"from the conversion itself"
                )
            if line == "Subcommands:":
                # What the Zephyr shell does with an `app` subcommand it does
                # not have: no error, just the help for `app`. Said plainly
                # here, since "could not parse" would send someone looking for
                # a protocol bug when the firmware is merely older than this.
                raise MCUError(
                    "this firmware has no `app temp` command - it predates the die "
                    "temperature sensor. Rebuild and update it (mcu/zbuild.sh, then unoq.fota)"
                )
        m = _TEMP.match(out[0]) if out else None
        if not m:
            raise MCUError(f"could not parse app temp: {out!r}")
        return int(m.group(1)) / 1000

    def reset_cause(self) -> list[str]:
        """Why the MCU last reset, as the names the firmware gives the causes.

        Most telling first: ["watchdog", "pin"] after the MCU's watchdog fired,
        ["software", "pin"] after an update or `kernel reboot`. "pin" is on
        nearly every reset, because the STM32 pulls its own reset pin whatever
        started it; on its own it means the pin really was pulled from
        outside. An empty list means no cause was recorded. ["unknown"] means
        the firmware could not read the flags, or found one it has no name
        for; a name this module has never heard of is passed through rather
        than dropped (see RESET_CAUSES for the known ones).

        The firmware reads the cause once at boot, so this describes the
        reset that started the MCU's current run, and says the same thing
        every time it is asked until the next one.
        """
        out = self.cmd("app reset")
        if "Subcommands:" in out:
            raise MCUError(
                "this firmware has no `app reset` command - it predates the watchdog. "
                "Rebuild and update it (mcu/zbuild.sh, then unoq.fota)"
            )
        m = _RESET.match(out[0]) if out else None
        if not m:
            raise MCUError(f"could not parse app reset: {out!r}")
        names = m[1].split(",")
        return [] if names == [RESET_NONE] else names

    # -- the temperature log -------------------------------------------------

    def temp_log(self, since: int | None = None) -> list[TempSample]:
        """Every sample in the MCU's temperature log newer than `since`.

        The MCU samples its die temperature once a second on its own timer and
        keeps the last ten minutes. This collects them, oldest first: the
        firmware sends at most 32 per reply, so this asks again from the last
        one it got until nothing is left.

        With no `since` it starts from the oldest sample still held. With one
        - the last `seq` the caller stored - it starts after it, and anything
        overwritten in between shows up as a jump in `seq` between that
        number and the first sample returned. `since=0` means from boot.

        Raises MCUError if `since` is beyond the newest sample, which means
        the MCU has restarted since that number was read and its sequence has
        started again: start over with temp_log_stat() or no `since`. Raises
        too on a firmware that predates the log, and on a reply that does not
        parse.
        """
        samples: list[TempSample] = []
        cursor = since
        while True:
            command = "app temp log" if cursor is None else f"app temp log {int(cursor)}"
            batch, more = self._temp_log_batch(command, cursor)
            samples += batch
            if not more or not batch:
                return samples
            cursor = batch[-1].seq

    def _temp_log_batch(self, command: str, since: int | None) -> tuple[list[TempSample], int]:
        """One `app temp log` reply: its samples, and how many are still waiting."""
        out = self.cmd(command)
        if any(_predates_temp_log(line) for line in out):
            raise MCUError(_NO_TEMP_LOG)
        batch: list[TempSample] = []
        gap: tuple[int, int] | None = None
        for line in out:
            if m := _TEMPLOG.match(line):
                batch.append(TempSample(int(m[1]), int(m[2]), int(m[3]) / 1000))
            elif m := _TEMPLOG_ERR.match(line):
                batch.append(TempSample(int(m[1]), int(m[2]), None, int(m[3])))
            elif m := _TEMPLOG_GAP.match(line):
                gap = (int(m[1]), int(m[2]))
            elif m := _TEMPLOG_END.match(line):
                # The firmware's promise is that a batch starts right after
                # `since`, or right after the gap it reported. One that does
                # not would put a hole in the record nobody was told about.
                if gap:
                    expected: int | None = gap[1] + 1
                elif since is not None:
                    expected = since + 1
                else:
                    expected = None
                if batch and expected is not None and batch[0].seq != expected:
                    raise MCUError(f"{command!r}: the first sample does not follow on: {out!r}")
                return batch, int(m[2])
            else:
                raise MCUError(f"could not parse {command!r}: {line!r}")
        raise MCUError(f"{command!r} ended without its end line: {out!r}")

    def temp_log_stat(self) -> TempLogStat:
        """The temperature log's counters: newest seq, count, size, dropped, period."""
        out = self.cmd("app temp log stat")
        if any(_predates_temp_log(line) for line in out):
            raise MCUError(_NO_TEMP_LOG)
        m = _TEMPLOG_STAT.match(out[0]) if out else None
        if not m:
            raise MCUError(f"could not parse app temp log stat: {out!r}")
        return TempLogStat(*(int(g) for g in m.groups()))

    # -- jitter ------------------------------------------------------------

    def _jitter_cmd(self, command: str) -> list[str]:
        out = self.cmd(command)
        if "Subcommands:" in out:
            # What a firmware without `app jitter` says: the help for `app`.
            raise MCUError(_NO_JITTER)
        return out

    def jitter_arm(self, period_us: int) -> int:
        """Tell the MCU to expect a tick every `period_us`, and clear both
        histograms. Returns the period the MCU took."""
        period_us = int(period_us)
        if not JITTER_PERIOD_US_MIN <= period_us <= JITTER_PERIOD_US_MAX:
            raise ValueError(
                f"period_us {period_us} outside {JITTER_PERIOD_US_MIN}..{JITTER_PERIOD_US_MAX}"
            )
        out = self._jitter_cmd(f"app jitter arm {period_us}")
        m = _JITTER_ARM.match(out[0]) if out else None
        if not m:
            raise MCUError(f"could not parse app jitter arm: {out!r}")
        return int(m[1])

    def jitter_tick(self) -> None:
        """One tick: the MCU timestamps its arrival on TIM5.

        Fire-and-forget (see send()): nothing is read back, so nothing is
        known here about whether it was armed. jitter_stat() says what
        arrived. Call it on the schedule jitter_arm() was given.
        """
        self.send("app jitter tick")

    def jitter_pwm(self, hz: int) -> int:
        """Start a square wave of `hz` on D3 and capture its period on D2, and
        clear the pwm histogram. Needs a jumper from D3 to D2; without one the
        pwm histogram stays empty. Returns the period the timer really runs
        at, in whole microseconds: 1_000_000 // hz."""
        hz = int(hz)
        if not JITTER_PWM_HZ_MIN <= hz <= JITTER_PWM_HZ_MAX:
            raise ValueError(f"hz {hz} outside {JITTER_PWM_HZ_MIN}..{JITTER_PWM_HZ_MAX}")
        out = self._jitter_cmd(f"app jitter pwm {hz}")
        m = _JITTER_PWM.match(out[0]) if out else None
        if not m or int(m[1]) != hz:
            raise MCUError(f"could not parse app jitter pwm: {out!r}")
        return int(m[2])

    def jitter_stat(self) -> JitterStat:
        """Both histograms, as the MCU holds them now.

        Raises MCUError if either is missing, if a line does not parse, or if
        its bins do not add up to its count: a histogram that disagrees with
        itself is not one to put in a course.
        """
        out = self._jitter_cmd("app jitter stat")
        found: dict[str, JitterHist] = {}
        for line in out:
            m = _JITTER.match(line)
            if not m:
                raise MCUError(f"could not parse app jitter stat: {line!r}")
            bins = tuple(int(b) for b in m[7].split(","))
            period_us, n, min_ns, max_ns, mean_ns = (int(g) for g in m.groups()[1:6])
            hist = JitterHist(m[1], period_us, n, min_ns, max_ns, mean_ns, bins)
            if len(bins) != JITTER_BINS or sum(bins) != hist.n:
                raise MCUError(f"app jitter stat: bins do not add up to n: {line!r}")
            found[hist.src] = hist
        if set(found) != set(JITTER_SOURCES):
            raise MCUError(f"app jitter stat: expected {JITTER_SOURCES}, got {out!r}")
        return JitterStat(found["tick"], found["pwm"])

    def jitter_off(self) -> None:
        """Stop the ticks, the PWM on D3 and the capture on D2. The
        histograms stay, for jitter_stat()."""
        out = self._jitter_cmd("app jitter off")
        if not out or not _JITTER_OFF.match(out[0]):
            raise MCUError(f"could not parse app jitter off: {out!r}")

    # -- scope -------------------------------------------------------------

    def _scope_cmd(self, command: str, timeout: float = 2.0) -> list[str]:
        out = self.cmd(command, timeout=timeout)
        if "Subcommands:" in out:
            raise MCUError(_NO_SCOPE)
        return out

    def scope_gen(self, wave: str, hz: int) -> float:
        """Play `wave` ("sine" or "triangle") at `hz` out of A0 (PA4), from
        the DAC, until scope_off(). Returns the frequency TIM7 really gives."""
        hz = int(hz)
        if wave not in SCOPE_WAVES:
            raise ValueError(f"wave {wave!r} is not one of {SCOPE_WAVES}")
        if not SCOPE_WAVE_HZ_MIN <= hz <= SCOPE_WAVE_HZ_MAX:
            raise ValueError(f"hz {hz} outside {SCOPE_WAVE_HZ_MIN}..{SCOPE_WAVE_HZ_MAX}")
        out = self._scope_cmd(f"app scope gen {wave} {hz}")
        m = _SCOPE_GEN.match(out[0]) if out else None
        if not m or m[1] != wave or int(m[2]) != hz:
            raise MCUError(f"could not parse app scope gen: {out!r}")
        return _hz3(m[3], m[4])

    def scope_capture(self, n: int, rate_hz: int) -> ScopeCapture:
        """Sample A0 `n` times at `rate_hz` into the MCU's RAM, and wait for
        it. Read the samples with unoq.spilink.SpiLink.scope_read(id)."""
        n, rate_hz = int(n), int(rate_hz)
        if not scope_capture_valid(n, rate_hz):
            raise ValueError(
                f"{n} samples at {rate_hz} Hz: n is {SCOPE_N_MIN}..{SCOPE_N_MAX}, the rate "
                f"{SCOPE_RATE_HZ_MIN}..{SCOPE_RATE_HZ_MAX} Hz, and at most {SCOPE_BURST_MS_MAX} ms"
            )
        out = self._scope_cmd(f"app scope capture {n} {rate_hz}", timeout=2.0 + n / rate_hz)
        m = _SCOPE_CAPTURE.match(out[0]) if out else None
        if not m or int(m[2]) != n:
            raise MCUError(f"could not parse app scope capture: {out!r}")
        return ScopeCapture(int(m[1]), n, _hz3(m[3], m[4]), int(m[5]), int(m[6]), int(m[7]))

    def scope_stat(self) -> ScopeStat:
        out = self._scope_cmd("app scope stat")
        m = _SCOPE_STAT.match(out[0]) if out else None
        if not m:
            raise MCUError(f"could not parse app scope stat: {out!r}")
        return ScopeStat(
            m[1],
            _hz3(m[2], m[3]),
            int(m[4]),
            int(m[5]),
            _hz3(m[6], m[7]),
            m[8] != "0",
            int(m[9]),
        )

    def scope_off(self) -> None:
        """Stop the wave. The last capture stays, to be read."""
        out = self._scope_cmd("app scope off")
        if not out or not _SCOPE_OFF.match(out[0]):
            raise MCUError(f"could not parse app scope off: {out!r}")

    # -- LED matrix --------------------------------------------------------

    def bars(self, pct: Sequence[float]) -> None:
        """Draw one vertical bar per value on the 8x13 LED matrix.

        Values are percentages, one per bar, left to right. They are rounded
        and clamped rather than validated: the caller is normally a live
        measurement, and a reading that arrives as 100.4 should light a full
        bar, not raise. A wrong *number* of bars is a different matter - that
        is a programming error, so it raises.
        """
        if not 1 <= len(pct) <= BARS_MAX:
            raise ValueError(f"need 1..{BARS_MAX} values, got {len(pct)}")
        values = " ".join(str(max(0, min(BARS_PCT_MAX, round(v)))) for v in pct)
        self.cmd(f"app bars {values}")

    def matrix_px(self, row: int, col: int, level: int = MATRIX_MAX_LEVEL) -> None:
        """Light a single LED and blank the rest. Use it to find out which
        corner row 0, column 0 is on a board in front of you."""
        self.cmd(f"app matrix px {int(row)} {int(col)} {int(level)}")

    def matrix_frame(self, rows: Sequence[str]) -> None:
        """Draw a whole picture on the panel in one command.

        ``rows`` is MATRIX_ROWS strings, row 0 first, each MATRIX_COLS
        characters long, each character a level from "0" (off) to "7" (full).
        Row 0 / column 0 is the same corner `matrix_px` lights, and the panel's
        flip setting applies to the frame as it does to a pixel. A heart::

            mcu.matrix_frame([
                "0000000000000",
                "0007700077000",
                "0077770777700",
                "0077777777700",
                "0007777777000",
                "0000777770000",
                "0000077700000",
                "0000007000000",
            ])

        The rows are checked here before anything is sent, with the rule the
        firmware applies, so a bad frame raises ValueError without a round
        trip. The MCU's reply says how many LEDs it lit, and that is checked
        against the frame: a reply that disagrees raises MCUError.
        """
        if isinstance(rows, str):
            # A str is a Sequence[str] too, of one-character rows.
            raise ValueError("rows is one string; pass a list of rows")
        if len(rows) != MATRIX_ROWS:
            raise ValueError(f"need {MATRIX_ROWS} rows, got {len(rows)}")
        for i, row in enumerate(rows):
            if not isinstance(row, str) or not _MATRIX_ROW.fullmatch(row):
                raise ValueError(
                    f"row {i}: {row!r} is not {MATRIX_COLS} digits 0..{MATRIX_MAX_LEVEL}"
                )
        out = self.cmd("app matrix frame " + " ".join(rows))
        m = _MATRIX_FRAME.match(out[0]) if out else None
        if not m:
            raise MCUError(f"could not parse matrix frame: {out!r}")
        lit = sum(c != "0" for row in rows for c in row)
        if int(m.group(1)) != lit:
            raise MCUError(f"sent a frame lighting {lit} LEDs and the MCU lit {m.group(1)}")

    def matrix_flip(self) -> bool:
        """Rotate the panel 180 degrees and persist that. Returns the new state.

        This is how you correct a display that reads upside down because of
        how the board is mounted; the MCU remembers it across reboots.
        """
        out = self.cmd("app matrix flip")
        m = re.search(r"flip=(\d+)", out[0] if out else "")
        if not m:
            raise MCUError(f"could not parse matrix flip: {out!r}")
        return m.group(1) != "0"

    def matrix_off(self) -> None:
        """Blank the panel and stop its refresh timer."""
        self.cmd("app matrix off")
