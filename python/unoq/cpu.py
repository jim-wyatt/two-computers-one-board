# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""
Host CPU load, read from /proc/stat.

The MPU measures and the MCU draws - this is the measuring half. It is kept
apart from the drawing half so it can be tested against captured /proc/stat
text instead of against a busy machine, which is not a reproducible input.
"""

from __future__ import annotations

from pathlib import Path

PROC_STAT = "/proc/stat"

# proc(5) gives each cpu line ten counters, but only the first eight are
# independent: `guest` and `guest_nice` are already included in `user` and
# `nice`, so summing all ten double-counts virtualized time. Taking eight
# sidesteps that entirely.
_COUNTERS = 8
# Of those eight, `idle` and `iowait` are the not-working ones. iowait counts as
# idle here on purpose: a core waiting on disk is a core doing nothing, and a
# CPU meter that showed it as load would read as busy on a machine at rest.
_IDLE = (3, 4)


def read_cpu_times(path: str = PROC_STAT) -> list[tuple[int, int]]:
    """Return (busy, total) jiffies per core, in cpu0..cpuN order.

    These are counters since boot, not a rate. A single reading tells you the
    average load since power-on and is almost never what you want - take two
    and use the difference, which is what CpuSampler exists to do.
    """
    cores: list[tuple[int, int]] = []
    for line in Path(path).read_text().splitlines():
        fields = line.split()
        # "cpu" with no digits is the machine-wide aggregate - the same
        # numbers again, summed. Counting it would add a phantom core.
        if not fields or not fields[0].startswith("cpu") or fields[0] == "cpu":
            continue
        counters = [int(v) for v in fields[1 : 1 + _COUNTERS]]
        # Kernels older than 2.6.33 stop short of `steal`. Pad rather than
        # index off the end, so a short line reads as zero for what it omits.
        counters += [0] * (_COUNTERS - len(counters))
        total = sum(counters)
        cores.append((total - counters[_IDLE[0]] - counters[_IDLE[1]], total))
    return cores


class CpuSampler:
    """Per-core busy percentage between successive calls to sample().

    Constructing it takes the first reading, so the first sample() covers the
    time since construction - keep the instance alive across the whole run
    rather than making a new one per frame, or every reading will be the
    average since boot.
    """

    def __init__(self, path: str = PROC_STAT) -> None:
        self._path = path
        self._prev = read_cpu_times(path)

    @property
    def cores(self) -> int:
        """How many cores the last reading saw."""
        return len(self._prev)

    def sample(self) -> list[int]:
        """Busy percentage per core since the previous call, 0..100."""
        now = read_cpu_times(self._path)
        # strict=False on purpose: if a core was hotplugged out between the two
        # readings, report the ones that still line up rather than raising. A
        # CPU meter that dies because the machine changed shape is worse than
        # one that shows fewer bars for a moment.
        out = []
        for (prev_busy, prev_total), (busy, total) in zip(self._prev, now, strict=False):
            elapsed = total - prev_total
            worked = busy - prev_busy
            # No elapsed jiffies means two readings inside one tick - there is
            # no measurement to report, and 0 is closer than a division error.
            pct = round(100 * worked / elapsed) if elapsed > 0 else 0
            # Counters only go up, but a suspend/resume can rewind them.
            out.append(max(0, min(100, pct)))
        self._prev = now
        return out
