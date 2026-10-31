# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""
Log the CPU's clock, temperatures and load to CSV while a USB meter watches.

    unoq-powerlog runs.csv --label idle-schedutil --count 60
    python -m unoq.powerlog runs.csv --label load-performance --interval 5

The meter reads current; this records what the board was doing at the same
time, so that the two can be lined up afterwards by timestamp. One row per
interval: the time, a free-text label for the run, each policy's governor and
current frequency, every thermal zone, and the busy percentage per core.

It only reads. Switching the governor is a separate, deliberate step - the
procedure is in docs/reference/mpu.md, "CPU frequency and the governor" - and
the only file this writes is the CSV it is given.
"""

from __future__ import annotations

import argparse
import csv
import os
import sys
from collections.abc import Callable, Sequence
from pathlib import Path
from time import sleep as _sleep
from time import time as _time
from typing import Protocol

from .cpu import PROC_STAT, CpuSampler
from .cpufreq import SYS_CPUFREQ, Policy, read_policies
from .thermal import SYS_THERMAL, read_temps

# Fine enough to see a governor ramp under a build, coarse enough that the
# sampling itself is not a load worth mentioning. A USB meter that logs
# typically does so once a second or slower, so finer buys nothing to line up.
DEFAULT_INTERVAL = 5.0


class Load(Protocol):
    def sample(self) -> list[int]: ...


def row(
    when: float,
    label: str,
    policies: Sequence[Policy],
    temps: Sequence[tuple[str, float]],
    load: Sequence[int],
) -> dict[str, str]:
    """One sample as a CSV row, column name to value.

    Zone types are not unique (see thermal.read_temps), so a repeated one gets
    a #2, #3... suffix rather than overwriting the first.
    """
    out = {"time": f"{when:.3f}", "label": label}
    for policy in policies:
        out[f"{policy.name}_governor"] = policy.governor or ""
        out[f"{policy.name}_khz"] = "" if policy.cur_khz is None else str(policy.cur_khz)
    seen: dict[str, int] = {}
    for name, celsius in temps:
        seen[name] = seen.get(name, 0) + 1
        suffix = "" if seen[name] == 1 else f"#{seen[name]}"
        out[f"temp_{name}{suffix}"] = f"{celsius:.1f}"
    for core, pct in enumerate(load):
        out[f"cpu{core}_pct"] = str(pct)
    return out


def _existing_header(path: Path) -> list[str] | None:
    """The header of a CSV that already has one, so a second run appends to it."""
    try:
        with path.open(newline="") as f:
            return next(csv.reader(f), None)
    except FileNotFoundError:
        return None


def run(
    path: str,
    sampler: Load,
    label: str = "",
    interval: float = DEFAULT_INTERVAL,
    count: int | None = None,
    policies: Callable[[], list[Policy]] = read_policies,
    temps: Callable[[], list[tuple[str, float]]] = read_temps,
    clock: Callable[[], float] = _time,
    sleep: Callable[[float], None] = _sleep,
) -> int:
    """Append `count` rows to the CSV at path, or forever if count is None.

    The header comes from the first row of a new file. Appending to a file
    that already has one keeps its columns - so one file can hold a run per
    governor - and a column the new run lacks is left blank, while one the
    file never had is dropped rather than shifting every column after it.

    Each row is flushed and fsynced as it is written. A brownout is one of the
    things being measured for, and it should cost the last row, not the run.

    Sleeps before the first sample for the reason cpubars.run() does: the load
    is a difference between two readings, and the first one needs an interval
    behind it.
    """
    target = Path(path)
    header = _existing_header(target)
    written = 0
    with target.open("a", newline="") as f:
        writer: csv.DictWriter[str] | None = None
        if header:
            writer = csv.DictWriter(f, header, restval="", extrasaction="ignore")
        while count is None or written < count:
            sleep(interval)
            values = row(clock(), label, policies(), temps(), sampler.sample())
            if writer is None:
                writer = csv.DictWriter(f, list(values), restval="", extrasaction="ignore")
                writer.writeheader()
            writer.writerow(values)
            f.flush()
            os.fsync(f.fileno())
            written += 1
    return written


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="unoq-powerlog",
        description="Append CPU frequency, temperature and load samples to a CSV file.",
    )
    parser.add_argument("csv", help="file to append to (created with a header if new)")
    parser.add_argument(
        "--label", default="", help="free text stored in every row, e.g. idle-schedutil"
    )
    parser.add_argument(
        "--interval", type=float, default=DEFAULT_INTERVAL, help="seconds between rows"
    )
    parser.add_argument("--count", type=int, default=None, help="stop after N rows")
    parser.add_argument("--stat", default=PROC_STAT, help="where to read CPU counters")
    parser.add_argument("--cpufreq", default=SYS_CPUFREQ, help="where to read cpufreq policies")
    parser.add_argument("--thermal", default=SYS_THERMAL, help="where to read thermal zones")
    args = parser.parse_args(argv)

    sampler = CpuSampler(args.stat)
    try:
        written = run(
            args.csv,
            sampler,
            label=args.label,
            interval=args.interval,
            count=args.count,
            policies=lambda: read_policies(args.cpufreq),
            temps=lambda: read_temps(args.thermal),
        )
    except KeyboardInterrupt:
        # Ctrl-C is how an open-ended run ends, not a failure. Every row
        # already written is on disk.
        return 0
    except OSError as err:
        print(f"unoq-powerlog: {err}", file=sys.stderr)
        return 1
    print(f"{written} rows appended to {args.csv}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
