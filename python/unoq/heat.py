# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""
Heat under load, read from both chips, once per cpufreq governor.

    sudo .venv/bin/python -m unoq.heat ~/heat.csv
    sudo .venv/bin/python -m unoq.heat ~/heat.csv --governors performance --seconds 60 --no-mcu

For each governor in turn: switch to it, let the board sit idle for `--rest`
seconds, then keep every core busy for `--seconds`. Every `--interval` seconds
(default 5) a row goes into the CSV: the time, the governor and phase, each
policy's clock and its time_in_state since the phase began, every thermal
zone, the GPU's devfreq clock and, unless `--no-mcu`, the microcontroller's die
temperature and uptime. The MCU is a second chip the workload does not run on,
so its temperature is the board warming rather than the cores, and its uptime
is a stopwatch Linux's clock and frequency cannot touch.

At the end it prints a line per governor: the load's length by the MCU's clock,
the hottest zone seen, and the MCU's mean temperature.

This is the one module in the package that writes to sysfs, and it writes one
file: scaling_governor. It needs root for that, and puts the original governor
back on every way out - a normal end, an exception, Ctrl-C, SIGTERM or SIGHUP.
cpufreq.py, thermal.py and powerlog.py stay read-only; this reuses them.
"""

from __future__ import annotations

import argparse
import contextlib
import csv
import multiprocessing
import os
import re
import signal
import sys
import time
from collections.abc import Callable, Iterator, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from types import FrameType, TracebackType
from typing import Protocol

from .cpufreq import SYS_CPUFREQ, Policy, read_policies, read_policy
from .mcu import MCU, MCUError
from .powerlog import _existing_header, row
from .thermal import SYS_THERMAL, hottest, read_temps

SYS_DEVFREQ = "/sys/class/devfreq"

DEFAULT_GOVERNORS = ("ondemand", "performance", "schedutil")
DEFAULT_SECONDS = 120.0
DEFAULT_REST = 60.0
DEFAULT_INTERVAL = 5.0
WORKLOADS = ("spin",)

# What ends a run early. SIGINT already raises KeyboardInterrupt; the other two
# would kill the process outright, skipping every `finally`, so they are turned
# into an exception for as long as a governor might need putting back.
_STOP_SIGNALS = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)

_POLICY = re.compile(r"policy(\d+)")


class Stopped(BaseException):
    """SIGTERM or SIGHUP arrived. A BaseException, like KeyboardInterrupt, so
    that no `except Exception` on the way out mistakes it for an error."""

    def __init__(self, signum: int) -> None:
        super().__init__(signal.Signals(signum).name)
        self.signum = signum


def _raise_stopped(signum: int, _frame: FrameType | None) -> None:
    raise Stopped(signum)


@contextlib.contextmanager
def raise_on_signals() -> Iterator[None]:
    """Turn SIGTERM and SIGHUP into Stopped while inside, then put back the
    handlers that were there before."""
    previous = {sig: signal.signal(sig, _raise_stopped) for sig in _STOP_SIGNALS[1:]}
    try:
        yield
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


@contextlib.contextmanager
def signals_held() -> Iterator[None]:
    """Hold the stop signals while cleaning up, and deliver them afterwards.

    Without this a second Ctrl-C, pressed because the first seemed slow, would
    raise in the middle of putting the governor back and leave it half done.
    A signal held here is not lost: it arrives the moment this ends.
    """
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, _STOP_SIGNALS)
    try:
        yield
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


# -- the governor ----------------------------------------------------------


def _write_sysfs(path: Path, text: str) -> None:
    path.write_text(text)


def _policy_dirs(root: str) -> list[Path]:
    """The policyN directories under root, in number order, as cpufreq.py finds them."""
    try:
        found = [
            (int(m.group(1)), entry)
            for entry in Path(root).iterdir()
            if (m := _POLICY.fullmatch(entry.name)) and entry.is_dir()
        ]
    except OSError:
        return []
    return [path for _, path in sorted(found)]


class Governor:
    """Switch every cpufreq policy under root to `name`; put each one's
    original governor back on exit, however the block ends.

    Raises ValueError on entry, before writing anything, when there is no
    policy, a policy's governor cannot be read (and so could not be restored),
    or a policy does not offer `name`.
    """

    def __init__(
        self,
        name: str,
        root: str = SYS_CPUFREQ,
        write: Callable[[Path, str], None] = _write_sysfs,
    ) -> None:
        self.name = name
        self.root = root
        self._write = write
        self.original: dict[Path, str] = {}

    def __enter__(self) -> Governor:
        dirs = _policy_dirs(self.root)
        if not dirs:
            raise ValueError(f"no cpufreq policies under {self.root}")
        original: dict[Path, str] = {}
        for path in dirs:
            # cpufreq.py's reader: an unreadable file is None or (), not a raise.
            policy = read_policy(path)
            if policy.governor is None:
                raise ValueError(f"{path.name}: no governor to restore afterwards")
            if self.name not in policy.governors:
                offers = " ".join(policy.governors) or "nothing"
                raise ValueError(f"{path.name} does not offer {self.name!r} (it offers {offers})")
            original[path] = policy.governor
        # Recorded in full before the first write, so __exit__ knows every
        # original even if a write below fails part of the way through.
        self.original = original
        try:
            for path in original:
                self._write(path / "scaling_governor", self.name)
        except BaseException:
            self.restore()
            raise
        return self

    def restore(self) -> None:
        """Write every original governor back, with the stop signals held.

        Each policy is tried even if an earlier one fails; the first failure
        is raised once all have been tried.
        """
        failure: OSError | None = None
        with signals_held():
            for path, governor in self.original.items():
                try:
                    self._write(path / "scaling_governor", governor)
                except OSError as err:
                    failure = failure or err
        if failure is not None:
            raise failure

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> None:
        self.restore()


# -- the workload ----------------------------------------------------------


class Worker(Protocol):
    """The parts of multiprocessing.Process that Spinners uses."""

    def start(self) -> None: ...
    def join(self, timeout: float | None = None) -> None: ...
    def is_alive(self) -> bool: ...
    def terminate(self) -> None: ...
    def kill(self) -> None: ...


def _spin(seconds: float) -> None:
    """Keep one core busy for `seconds`. Runs in a child process.

    Ctrl-C at a terminal goes to the whole process group. The parent handles
    it and stops the children itself, so here it is ignored rather than
    printed as a traceback per core; SIGTERM, which is how the parent stops
    them, goes back to simply ending the process.
    """
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    signal.signal(signal.SIGHUP, signal.SIG_DFL)
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        pass


def _spawn(seconds: float) -> Worker:
    # daemon: should this process die some way no `finally` survives (SIGKILL),
    # multiprocessing still takes its daemonic children down with it.
    return multiprocessing.Process(target=_spin, args=(seconds,), daemon=True)


class Spinners:
    """`count` busy processes for `seconds`, stopped on exit however it comes."""

    def __init__(
        self,
        count: int,
        seconds: float,
        spawn: Callable[[float], Worker] = _spawn,
        grace: float = 2.0,
    ) -> None:
        self.count = count
        self.seconds = seconds
        self._spawn = spawn
        self._grace = grace
        self.workers: list[Worker] = []

    def __enter__(self) -> Spinners:
        try:
            for _ in range(self.count):
                worker = self._spawn(self.seconds)
                worker.start()
                # Only a started process can be joined, so only one is kept.
                self.workers.append(worker)
        except BaseException:
            self.stop()
            raise
        return self

    def stop(self) -> None:
        """Terminate any still running and wait for every one to be gone."""
        with signals_held():
            for worker in self.workers:
                if worker.is_alive():
                    worker.terminate()
            for worker in self.workers:
                worker.join(self._grace)
                if worker.is_alive():
                    worker.kill()
                    worker.join()

    def __exit__(self, *exc: object) -> None:
        self.stop()


# -- the readings ----------------------------------------------------------


def gpu_hz(root: str = SYS_DEVFREQ) -> int | None:
    """The GPU's current clock in Hz, from its devfreq node, or None.

    On this board the node is `5900000.gpu` (the Adreno's register address),
    governed by simple_ondemand. Matched on the `.gpu` suffix rather than the
    address so another SoC's GPU is found too; the first in name order wins.
    """
    try:
        nodes = sorted(entry for entry in Path(root).iterdir() if entry.name.endswith(".gpu"))
        return int((nodes[0] / "cur_freq").read_text())
    except (OSError, ValueError, IndexError):
        return None


class Chip(Protocol):
    """The parts of MCU this uses."""

    def die_temp(self) -> float: ...
    def status(self) -> dict[str, int | str]: ...


def mcu_temp(mcu: Chip | None) -> float | None:
    """The MCU's die temperature in degrees Celsius, or None if unread.

    A reply that fails is a blank in that row, not the end of the run: the
    governor is switched, and a run cut short is the worse outcome.
    """
    if mcu is None:
        return None
    try:
        return mcu.die_temp()
    except (MCUError, OSError):
        return None


def mcu_uptime(mcu: Chip | None) -> int | None:
    """The MCU's uptime in ms - its own clock, not Linux's - or None if unread."""
    if mcu is None:
        return None
    try:
        uptime = mcu.status().get("uptime_ms")
    except (MCUError, OSError):
        return None
    return uptime if isinstance(uptime, int) else None


def time_in_state_delta(before: Sequence[Policy], after: Sequence[Policy]) -> dict[str, float]:
    """Seconds at each frequency between two readings, as `<policy>_tis_<kHz>` columns."""
    start = {(p.name, khz): s for p in before for khz, s in p.time_in_state}
    return {
        f"{p.name}_tis_{khz}": round(s - start.get((p.name, khz), 0.0), 2)
        for p in after
        for khz, s in p.time_in_state
    }


# -- the run ---------------------------------------------------------------


@dataclass
class Summary:
    """One governor's load phase."""

    governor: str
    seconds: float = 0.0
    """By Linux's monotonic clock."""
    mcu_seconds: float | None = None
    """By the MCU's uptime, from the phase's start to its last row."""
    peak: tuple[str, float] | None = None
    """The hottest (zone, degrees Celsius) of any row in the phase."""
    mcu_temps: list[float] = field(default_factory=list)

    @property
    def mcu_mean(self) -> float | None:
        return sum(self.mcu_temps) / len(self.mcu_temps) if self.mcu_temps else None

    def line(self) -> str:
        mcu_s = "-" if self.mcu_seconds is None else f"{self.mcu_seconds:.1f} s"
        peak = "-" if self.peak is None else f"{self.peak[0]} {self.peak[1]:.1f} C"
        mean = "-" if self.mcu_mean is None else f"{self.mcu_mean:.1f} C"
        return (
            f"{self.governor:<12} load {self.seconds:.1f} s (MCU clock {mcu_s}), "
            f"peak {peak}, MCU mean {mean}"
        )


@dataclass
class Sources:
    """Everything the run reads or starts, so a test can replace each one."""

    cpufreq: str = SYS_CPUFREQ
    thermal: str = SYS_THERMAL
    devfreq: str = SYS_DEVFREQ
    mcu: Chip | None = None
    spawn: Callable[[float], Worker] = _spawn
    write: Callable[[Path, str], None] = _write_sysfs
    clock: Callable[[], float] = time.monotonic
    wallclock: Callable[[], float] = time.time
    sleep: Callable[[float], None] = time.sleep


class _Recorder:
    """Rows to one CSV, the header from the first row, each flushed and fsynced."""

    def __init__(self, path: str, src: Sources) -> None:
        self.path = Path(path)
        self.src = src
        header = _existing_header(self.path)
        self.f = self.path.open("a", newline="")
        self.writer: csv.DictWriter[str] | None = None
        if header:
            self.writer = csv.DictWriter(self.f, header, restval="", extrasaction="ignore")

    def close(self) -> None:
        self.f.close()

    def phase(self, governor: str, phase: str, seconds: float, interval: float) -> Summary:
        """Record one row per interval for `seconds`, and summarize it."""
        src = self.src
        summary = Summary(governor)
        start_policies = read_policies(src.cpufreq)
        start = src.clock()
        # Read before the first interval, so the MCU's stopwatch spans the
        # whole phase rather than the phase less one interval.
        first_uptime = mcu_uptime(src.mcu)
        elapsed = 0.0
        while elapsed < seconds:
            src.sleep(min(interval, seconds - elapsed))
            elapsed = src.clock() - start
            policies = read_policies(src.cpufreq)
            temps = read_temps(src.thermal)
            celsius, uptime = mcu_temp(src.mcu), mcu_uptime(src.mcu)
            values = row(src.wallclock(), governor, policies, temps, [])
            out = {
                "time": values.pop("time"),
                "governor": values.pop("label"),
                "phase": phase,
                "elapsed": f"{elapsed:.1f}",
            }
            out.update(values)
            hz = gpu_hz(src.devfreq)
            out["gpu_hz"] = "" if hz is None else str(hz)
            out["mcu_temp"] = "" if celsius is None else f"{celsius:.1f}"
            out["mcu_uptime_ms"] = "" if uptime is None else str(uptime)
            for name, secs in time_in_state_delta(start_policies, policies).items():
                out[name] = f"{secs:.2f}"
            self._write(out)

            summary.seconds = elapsed
            peak = hottest(temps)
            if peak is not None and (summary.peak is None or peak[1] > summary.peak[1]):
                summary.peak = peak
            if celsius is not None:
                summary.mcu_temps.append(celsius)
            if uptime is not None:
                first_uptime = uptime if first_uptime is None else first_uptime
                summary.mcu_seconds = (uptime - first_uptime) / 1000
        return summary

    def _write(self, values: dict[str, str]) -> None:
        if self.writer is None:
            self.writer = csv.DictWriter(self.f, list(values), restval="", extrasaction="ignore")
            self.writer.writeheader()
        self.writer.writerow(values)
        self.f.flush()
        os.fsync(self.f.fileno())


def run(
    path: str,
    governors: Sequence[str] = DEFAULT_GOVERNORS,
    seconds: float = DEFAULT_SECONDS,
    rest: float = DEFAULT_REST,
    interval: float = DEFAULT_INTERVAL,
    cores: int | None = None,
    src: Sources | None = None,
) -> list[Summary]:
    """Rest, then load, under each governor in turn. Returns the load phases.

    Every governor is checked against what the kernel offers before the first
    is switched to, so a typo in the last one does not cost the runs before it.
    """
    src = src or Sources()
    for policy in read_policies(src.cpufreq):
        missing = [g for g in governors if g not in policy.governors]
        if missing:
            raise ValueError(
                f"{policy.name} does not offer {' '.join(missing)} "
                f"(it offers {' '.join(policy.governors) or 'nothing'})"
            )
    count = cores or os.cpu_count() or 1
    summaries: list[Summary] = []
    recorder = _Recorder(path, src)
    try:
        with raise_on_signals():
            for governor in governors:
                with Governor(governor, src.cpufreq, src.write):
                    recorder.phase(governor, "rest", rest, interval)
                    with Spinners(count, seconds, src.spawn):
                        summaries.append(recorder.phase(governor, "load", seconds, interval))
    finally:
        recorder.close()
    return summaries


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="python -m unoq.heat",
        description=(
            "Load every core under each cpufreq governor in turn and record the heat, "
            "from Linux's thermal zones and the MCU's own sensor. Needs root; puts the "
            "original governor back when it ends."
        ),
    )
    parser.add_argument("csv", help="file to append to (created with a header if new)")
    parser.add_argument(
        "--governors",
        nargs="+",
        default=list(DEFAULT_GOVERNORS),
        help="governors to run, in order (default: %(default)s)",
    )
    parser.add_argument("--workload", choices=WORKLOADS, default="spin", help="what keeps it busy")
    parser.add_argument(
        "--seconds", type=float, default=DEFAULT_SECONDS, help="load per governor (default 120)"
    )
    parser.add_argument(
        "--rest", type=float, default=DEFAULT_REST, help="idle before each load (default 60)"
    )
    parser.add_argument(
        "--interval", type=float, default=DEFAULT_INTERVAL, help="seconds between rows"
    )
    parser.add_argument(
        "--no-mcu",
        action="store_true",
        help="leave /dev/ttyHS1 alone (the CPU-bars demo may hold it)",
    )
    parser.add_argument("--cpufreq", default=SYS_CPUFREQ, help=argparse.SUPPRESS)
    parser.add_argument("--thermal", default=SYS_THERMAL, help=argparse.SUPPRESS)
    parser.add_argument("--devfreq", default=SYS_DEVFREQ, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    if os.geteuid() != 0:
        print(
            "unoq.heat: switching the cpufreq governor needs root; run it with sudo",
            file=sys.stderr,
        )
        return 2

    src = Sources(cpufreq=args.cpufreq, thermal=args.thermal, devfreq=args.devfreq)
    with contextlib.ExitStack() as stack:
        if not args.no_mcu:
            try:
                src.mcu = stack.enter_context(MCU())
            except (MCUError, OSError) as err:
                print(
                    f"unoq.heat: {err}\n"
                    "Stop the demo (sudo systemctl stop unoq-cpu-bars) or pass --no-mcu.",
                    file=sys.stderr,
                )
                return 1
        try:
            summaries = run(
                args.csv, args.governors, args.seconds, args.rest, args.interval, src=src
            )
        except ValueError as err:
            print(f"unoq.heat: {err}", file=sys.stderr)
            return 2
        except OSError as err:
            print(f"unoq.heat: {err}", file=sys.stderr)
            return 1
        except KeyboardInterrupt:
            print("unoq.heat: interrupted; governor restored", file=sys.stderr)
            return 128 + signal.SIGINT
        except Stopped as stop:
            print(f"unoq.heat: {stop}; governor restored", file=sys.stderr)
            return 128 + stop.signum
    for summary in summaries:
        print(summary.line())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
