# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""
Jitter, measured: the MCU times what Linux schedules.

    unoq-jitter                                # 30 s of ticks every 20 ms, idle
    unoq-jitter --seconds 30 --load spin       # the same with every core busy
    unoq-jitter --pwm 1000                     # and a 1 kHz square wave, D3 -> D2

It arms the MCU's `app jitter` with the period, then writes `app jitter tick`
on a fixed schedule of deadlines on Linux's monotonic clock, without waiting
for the shell's prompt (MCU.jitter_tick, through MCU.send). At the end it
prints three histograms side by side, labeled with the load:

- **Linux**: how late each write was against its own deadline, by Linux's
  clock, read just before the write.
- **MCU tick**: how far each interval between two ticks' arrivals, timed on
  the MCU's TIM5, was from the period.
- **MCU pwm**: the same for a square wave the MCU makes on D3 and captures on
  D2 through a jumper, with no software in the path. Only with `--pwm`.

The deadlines are absolute: tick k is due at start + k * period, computed
from k rather than added up, and each wait is to that deadline, so a late
wake-up delays one tick and not every tick after it. On Linux, time.sleep()
is clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME) to a deadline it computes
the moment it is called. A deadline missed by a whole period or more is
skipped and counted, never sent late in a burst; the MCU sees it as one
interval a period long, as docs/reference/mcu.md says it should.

`--load spin` is heat.py's workload: one busy process per core, stopped
however the run ends. The procedure, the jumper and what the columns mean are
in docs/reference/mpu.md, "Jitter".
"""

from __future__ import annotations

import argparse
import contextlib
import os
import signal
import sys
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from typing import Protocol

from .heat import Spinners, Stopped, Worker, _spawn, raise_on_signals, signals_held
from .mcu import (
    JITTER_BIN_LABELS,
    JITTER_EDGES_US,
    JITTER_PERIOD_US_MAX,
    JITTER_PERIOD_US_MIN,
    JITTER_PWM_HZ_MAX,
    JITTER_PWM_HZ_MIN,
    MCU,
    JitterHist,
    JitterStat,
    MCUError,
)

DEFAULT_PERIOD = 0.02
DEFAULT_SECONDS = 30.0
LOADS = ("none", "spin")
SETTLE = 1.0
"""Seconds between starting the load and the first tick, so the scheduler and
the governor have reacted to it before anything is measured."""
SPIN_SLACK = 10.0
"""How much longer than the run a spinner is told to last. They are stopped as
soon as the ticks end; this only has to outlast the settle and the run."""


class Ticker(Protocol):
    """The parts of MCU this uses."""

    def jitter_arm(self, period_us: int) -> int: ...
    def jitter_tick(self) -> None: ...
    def jitter_pwm(self, hz: int) -> int: ...
    def jitter_stat(self) -> JitterStat: ...
    def jitter_off(self) -> None: ...


@dataclass
class Timing:
    """The clock, the wait and the load, so a test can replace each one."""

    clock: Callable[[], float] = time.monotonic
    sleep: Callable[[float], None] = time.sleep
    spawn: Callable[[float], Worker] = _spawn
    cores: int | None = None
    settle: float = SETTLE


@dataclass(frozen=True)
class Result:
    """One run: the three histograms and how it was made."""

    load: str
    cores: int
    """Spinners running, 0 for no load."""
    pwm_hz: int | None
    ticks: int
    """Ticks written."""
    missed: int
    """Deadlines skipped, each a whole period or more late."""
    linux: JitterHist
    stat: JitterStat


def jitter_bin(dev_ns: int) -> int:
    """The bin a deviation falls in, by the firmware's rule (jitter_bin in
    mcu/app/src/jitter.c): the middle bin holds |d| <= the first edge, each
    one out holds up to the next edge, and the outermost hold the rest."""
    middle = len(JITTER_EDGES_US)
    k = next((i for i, edge in enumerate(JITTER_EDGES_US) if abs(dev_ns) <= edge * 1000), middle)
    return middle - k if dev_ns < 0 else middle + k


def histogram(src: str, period_us: int, deviations_ns: Sequence[int]) -> JitterHist:
    """A JitterHist of Linux's own numbers, binned and summed the MCU's way."""
    bins = [0] * len(JITTER_BIN_LABELS)
    for d in deviations_ns:
        bins[jitter_bin(d)] += 1
    n = len(deviations_ns)
    if n == 0:
        return JitterHist(src, period_us, 0, 0, 0, 0, tuple(bins))
    total = sum(deviations_ns)
    # C's division truncates toward zero; Python's // floors.
    mean = abs(total) // n * (1 if total >= 0 else -1)
    return JitterHist(src, period_us, n, min(deviations_ns), max(deviations_ns), mean, tuple(bins))


def tick(mcu: Ticker, period: float, count: int, timing: Timing) -> tuple[list[int], int]:
    """Write `count` deadlines' worth of ticks, `period` seconds apart.

    Returns how late each tick written was against its deadline, in ns, and
    how many deadlines were skipped for being a whole period or more late.
    """
    clock = timing.clock
    start = clock() + timing.settle
    late_ns: list[int] = []
    missed = 0
    k = 0
    while k < count:
        # From k, not by adding periods up: no rounding builds up over a run.
        deadline = start + k * period
        remaining = deadline - clock()
        if remaining > 0:
            timing.sleep(remaining)
        now = clock()
        while now - deadline >= period:
            k += 1
            missed += 1
            deadline = start + k * period
        if k >= count:
            break
        mcu.jitter_tick()
        late_ns.append(round((now - deadline) * 1e9))
        k += 1
    return late_ns, missed


def run(
    mcu: Ticker,
    period: float = DEFAULT_PERIOD,
    seconds: float = DEFAULT_SECONDS,
    load: str = "none",
    pwm_hz: int | None = None,
    timing: Timing | None = None,
) -> Result:
    """Arm, tick for `seconds` under `load`, stop, and read the histograms.

    However it ends, the MCU's ticks and PWM are stopped and the load is gone.
    """
    timing = timing or Timing()
    period_us = mcu.jitter_arm(round(period * 1e6))
    period_s = period_us / 1e6
    count = round(seconds / period_s) + 1
    cores = (timing.cores or os.cpu_count() or 1) if load == "spin" else 0
    try:
        if pwm_hz is not None:
            mcu.jitter_pwm(pwm_hz)
        load_cm: contextlib.AbstractContextManager[object] = (
            Spinners(cores, timing.settle + seconds + SPIN_SLACK, timing.spawn)
            if cores
            else contextlib.nullcontext()
        )
        with load_cm:
            late_ns, missed = tick(mcu, period_s, count, timing)
    except BaseException:
        # Best effort, and with the stop signals held: the error on its way
        # out is the one worth reporting, and the PWM should not outlive it.
        with signals_held(), contextlib.suppress(MCUError, OSError):
            mcu.jitter_off()
        raise
    mcu.jitter_off()
    stat = mcu.jitter_stat()
    linux = histogram("linux", period_us, late_ns)
    return Result(load, cores, pwm_hz, len(late_ns), missed, linux, stat)


def _us(ns: int) -> str:
    return f"{ns / 1000:.1f}"


def table(result: Result) -> str:
    """The three histograms side by side, with a heading that says what made them."""
    hists = (result.linux, result.stat.tick, result.stat.pwm)
    load = "none" if result.load == "none" else f"{result.load} on {result.cores} cores"
    pwm = "off" if result.pwm_hz is None else f"{result.pwm_hz} Hz on D3, captured on D2"
    lines = [
        f"period {result.linux.period_us} us, load {load}, pwm {pwm}",
        f"{result.ticks} ticks written, {result.missed} deadlines missed",
        "",
        f"{'bin (us)':<14}{'Linux':>10}{'MCU tick':>10}{'MCU pwm':>10}",
        f"{'':<14}{'late':>10}{'interval':>10}{'period':>10}",
    ]
    for i, label in enumerate(JITTER_BIN_LABELS):
        lines.append(f"{label:<14}" + "".join(f"{h.bins[i]:>10}" for h in hists))
    lines.append(f"{'n':<14}" + "".join(f"{h.n:>10}" for h in hists))
    for name, field in (("min us", "min_ns"), ("max us", "max_ns"), ("mean us", "mean_ns")):
        lines.append(f"{name:<14}" + "".join(f"{_us(getattr(h, field)):>10}" for h in hists))
    if result.pwm_hz is not None and result.stat.pwm.n == 0:
        lines += ["", "No PWM periods were captured: is the jumper on D3 to D2?"]
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="unoq-jitter",
        description=(
            "Write `app jitter tick` to the MCU on a fixed schedule and print how late "
            "Linux was, what the MCU timed, and the MCU's own PWM, side by side."
        ),
    )
    parser.add_argument(
        "--period",
        type=float,
        default=DEFAULT_PERIOD,
        help="seconds between ticks (default %(default)s)",
    )
    parser.add_argument(
        "--seconds",
        type=float,
        default=DEFAULT_SECONDS,
        help="how long to tick for (default %(default)s)",
    )
    parser.add_argument(
        "--load", choices=LOADS, default="none", help="what else runs: nothing, or every core busy"
    )
    parser.add_argument(
        "--pwm",
        type=int,
        metavar="HZ",
        default=None,
        help="also measure a square wave of HZ on D3, captured on D2 (needs the jumper)",
    )
    args = parser.parse_args(argv)

    period_us = round(args.period * 1e6)
    if not JITTER_PERIOD_US_MIN <= period_us <= JITTER_PERIOD_US_MAX:
        parser.error(
            f"--period {args.period} is outside "
            f"{JITTER_PERIOD_US_MIN / 1e6}..{JITTER_PERIOD_US_MAX / 1e6} s"
        )
    if args.seconds <= 0:
        parser.error("--seconds has to be more than 0")
    if args.pwm is not None and not JITTER_PWM_HZ_MIN <= args.pwm <= JITTER_PWM_HZ_MAX:
        parser.error(f"--pwm {args.pwm} is outside {JITTER_PWM_HZ_MIN}..{JITTER_PWM_HZ_MAX} Hz")

    with contextlib.ExitStack() as stack:
        try:
            mcu = stack.enter_context(MCU())
        except (MCUError, OSError) as err:
            print(
                f"unoq-jitter: {err}\n"
                "Stop the demo first (sudo systemctl stop unoq-cpu-bars): it holds /dev/ttyHS1.",
                file=sys.stderr,
            )
            return 1
        try:
            with raise_on_signals():
                result = run(mcu, args.period, args.seconds, args.load, args.pwm)
        except (MCUError, OSError) as err:
            print(f"unoq-jitter: {err}", file=sys.stderr)
            return 1
        except KeyboardInterrupt:
            print("unoq-jitter: interrupted; ticks and PWM stopped", file=sys.stderr)
            return 128 + signal.SIGINT
        except Stopped as stop:
            print(f"unoq-jitter: {stop}; ticks and PWM stopped", file=sys.stderr)
            return 128 + stop.signum
    print(table(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
