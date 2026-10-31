# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""
CPU frequency policies, read from /sys/devices/system/cpu/cpufreq.

The same split as thermal.py: a pure function of a directory, so it can be
tested against a written-out sysfs tree instead of against whatever the
governor on the machine running the suite happens to have chosen this second.

Nothing here writes to sysfs. Choosing a governor is a decision to be made
from measurements (docs/reference/mpu.md, "CPU frequency and the governor"),
and a reader that could also change the answer would be one stray call away
from changing it on a board that is powered by a laptop port.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import NamedTuple

SYS_CPUFREQ = "/sys/devices/system/cpu/cpufreq"

# The directory also holds `boost` and, on some drivers, a per-governor
# directory such as `schedutil`. Matching the whole name, digits included,
# keeps them out and gives the policy number to sort on.
_POLICY = re.compile(r"policy(\d+)")

# stats/time_in_state counts in units of 10 ms (the kernel's cpufreq stats
# documentation), whatever HZ the kernel was built with.
_TICKS_PER_SECOND = 100


class Policy(NamedTuple):
    """One cpufreq policy: a group of CPUs that share a clock.

    Frequencies are in kHz, as the kernel reports them. A field the kernel did
    not provide reads as None (for one value) or as an empty tuple (for a
    list), never as a made-up 0 that would look like a measurement.
    """

    name: str
    """The directory name, e.g. `policy0`."""
    cpus: tuple[int, ...]
    """related_cpus: every CPU this policy clocks, online or not."""
    driver: str | None
    governor: str | None
    governors: tuple[str, ...]
    """scaling_available_governors, in the kernel's order."""
    min_khz: int | None
    """scaling_min_freq: the floor the governor is held to."""
    max_khz: int | None
    """scaling_max_freq: the ceiling the governor is held to."""
    cur_khz: int | None
    """scaling_cur_freq: what the policy is running at now."""
    frequencies: tuple[int, ...]
    """scaling_available_frequencies, lowest first."""
    time_in_state: tuple[tuple[int, float], ...]
    """(kHz, seconds spent there since boot or the last stats reset), lowest
    first. Empty when the kernel was built without cpufreq stats."""


def _text(path: Path) -> str | None:
    try:
        return path.read_text().strip()
    except OSError:
        return None


def _int(path: Path) -> int | None:
    text = _text(path)
    if text is None:
        return None
    try:
        return int(text)
    except ValueError:
        return None


def _ints(path: Path) -> tuple[int, ...]:
    """A space-separated list of integers, or () if any of it is not one.

    All or nothing: a list with a hole in it would read as a complete list of
    fewer frequencies, which is a quieter and worse error than an empty one.
    """
    text = _text(path)
    if text is None:
        return ()
    try:
        return tuple(int(word) for word in text.split())
    except ValueError:
        return ()


def _time_in_state(path: Path) -> tuple[tuple[int, float], ...]:
    """Parse `<kHz> <ticks>` lines. Like _ints, all or nothing."""
    text = _text(path)
    if text is None:
        return ()
    rows: list[tuple[int, float]] = []
    for line in text.splitlines():
        try:
            khz, ticks = (int(word) for word in line.split())
        except ValueError:
            # Not two integers - covers too many words and too few as well.
            return ()
        rows.append((khz, ticks / _TICKS_PER_SECOND))
    return tuple(sorted(rows))


def read_policy(path: Path) -> Policy:
    """Read one policy directory. Every field is read independently."""
    governor = _text(path / "scaling_governor")
    governors = _text(path / "scaling_available_governors")
    return Policy(
        name=path.name,
        cpus=_ints(path / "related_cpus"),
        driver=_text(path / "scaling_driver"),
        governor=governor or None,
        governors=tuple(governors.split()) if governors else (),
        min_khz=_int(path / "scaling_min_freq"),
        max_khz=_int(path / "scaling_max_freq"),
        cur_khz=_int(path / "scaling_cur_freq"),
        frequencies=tuple(sorted(_ints(path / "scaling_available_frequencies"))),
        time_in_state=_time_in_state(path / "stats" / "time_in_state"),
    )


def read_policies(root: str = SYS_CPUFREQ) -> list[Policy]:
    """Return every cpufreq policy under root, in policy-number order.

    This board has one policy, policy0, clocking all four cores together, so
    there is one governor to choose rather than one per cluster. A big.LITTLE
    part would show two or more; nothing here assumes a count.

    A missing root reads as no policies: a virtual machine, or a kernel
    without cpufreq, has nothing to report, which is an answer and not an
    error. A file the kernel does not provide - drivers differ in which they
    offer - reads as None or () in that field alone.
    """
    policies: list[tuple[int, Path]] = []
    # iterdir() on a missing directory raises only once iterated, hence the
    # try around the whole loop rather than around the call.
    try:
        for entry in Path(root).iterdir():
            match = _POLICY.fullmatch(entry.name)
            if match and entry.is_dir():
                policies.append((int(match.group(1)), entry))
    except OSError:
        return []
    # Sorted on the number, not the name, for the same reason as thermal.py.
    return [read_policy(path) for _, path in sorted(policies)]
