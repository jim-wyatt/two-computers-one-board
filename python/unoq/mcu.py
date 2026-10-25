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
_ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
_PROMPT = re.compile(r"^\s*\S*:~\$\s*$")


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
    try:
        fcntl.ioctl(s.fileno(), TIOCEXCL)
    except OSError as exc:
        if exc.errno not in (errno.ENOTTY, errno.EINVAL, errno.ENOSYS):
            s.close()
            raise
    return s


class ShellTimeout(MCUError):
    """No prompt came back before the deadline."""


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
        """
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
                if re.search(r":~\$\s*$", _ANSI.sub("", buf).replace("\r", "\n")):
                    break
        else:
            raise ShellTimeout(f"no prompt after {timeout}s for {command!r}")

        lines = _clean(buf)
        # Drop the echoed command itself.
        if lines and lines[0] == command:
            lines = lines[1:]
        for line in lines:
            if line.startswith(ERROR_PREFIX) or any(said in line for said in _SHELL_REFUSALS):
                raise MCUError(f"{command!r}: {line}")
        return lines

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
