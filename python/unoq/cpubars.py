# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""
Host CPU load on the LED matrix - the whole hybrid loop in one command.

    unoq-cpu-bars                 # one bar per core, until Ctrl-C
    python -m unoq.cpubars --interval 0.25

The MPU samples /proc/stat (cpu.py), sends whole percentages over the serial
link (mcu.py), and the MCU rasterizes them onto the panel from a timer ISR
(mcu/app/src/bars.c). Nothing here knows how a bar is drawn, and nothing on the
MCU knows what a core is.
"""

from __future__ import annotations

import argparse
import sys
from collections.abc import Callable, Sequence
from time import sleep as _sleep
from typing import Protocol

from .cpu import PROC_STAT, CpuSampler
from .mcu import BARS_MAX, MCU, PORT

# Fast enough to feel live, slow enough that the shell round-trip is a rounding
# error next to it. Below ~0.1s the sampling window gets short enough that
# scheduler noise dominates the reading.
DEFAULT_INTERVAL = 0.5


# run() needs one method from each end, not the two concrete classes. Saying so
# is what lets the tests drive it with fakes, and keeps the loop honest about
# the fact that it neither opens a port nor reads /proc.
class Panel(Protocol):
    def bars(self, pct: Sequence[float]) -> None: ...


class Load(Protocol):
    def sample(self) -> list[int]: ...


def run(
    mcu: Panel,
    sampler: Load,
    interval: float = DEFAULT_INTERVAL,
    count: int | None = None,
    sleep: Callable[[float], None] = _sleep,
) -> int:
    """Sample and draw `count` frames, or forever if count is None.

    Sleeps before the first sample so that it covers a real interval; sampling
    immediately would measure the sliver of time since the sampler was built
    and report a meaningless number as the opening frame.
    """
    sent = 0
    while count is None or sent < count:
        sleep(interval)
        values = sampler.sample()
        if values:
            mcu.bars(values[:BARS_MAX])
        sent += 1
    return sent


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="unoq-cpu-bars",
        description="Show host CPU load as bars on the UNO Q's LED matrix.",
    )
    parser.add_argument(
        "--interval", type=float, default=DEFAULT_INTERVAL, help="seconds between frames"
    )
    parser.add_argument("--count", type=int, default=None, help="stop after N frames")
    parser.add_argument("--port", default=PORT, help="serial port to the MCU")
    parser.add_argument("--stat", default=PROC_STAT, help="where to read CPU counters")
    args = parser.parse_args(argv)

    sampler = CpuSampler(args.stat)
    if sampler.cores == 0:
        print(f"no per-core lines in {args.stat}", file=sys.stderr)
        return 1
    if sampler.cores > BARS_MAX:
        # Say so rather than quietly dropping cores off the end.
        print(
            f"{sampler.cores} cores but the panel fits {BARS_MAX} bars - "
            f"showing cpu0..cpu{BARS_MAX - 1}",
            file=sys.stderr,
        )

    with MCU(port=args.port) as mcu:
        try:
            run(mcu, sampler, args.interval, args.count)
        except KeyboardInterrupt:
            pass  # Ctrl-C is how you stop this, not a failure.
        finally:
            # Leave the panel dark. A frozen last frame looks like a live
            # reading of a machine that is somehow perfectly steady.
            mcu.matrix_off()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
