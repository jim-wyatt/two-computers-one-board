# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""
Host temperatures, read from /sys/class/thermal.

The same split as cpu.py: this is the measuring half only, kept as a pure
function of a directory so it can be tested against a written-out sysfs tree
instead of against however warm the machine running the suite happens to be.

Nothing here writes to sysfs. Trip points, cooling devices and the cpufreq
governor all live next door and are deliberately left alone.
"""

from __future__ import annotations

import re
from pathlib import Path

SYS_THERMAL = "/sys/class/thermal"

# The directory also holds cooling_device0..N, which have no temperature at
# all. Matching the whole name, digits included, keeps them out and gives the
# zone number to sort on.
_ZONE = re.compile(r"thermal_zone(\d+)")


def read_temps(root: str = SYS_THERMAL) -> list[tuple[str, float]]:
    """Return (type, degrees Celsius) per thermal zone, in zone-number order.

    A list of pairs rather than a dict because nothing makes `type` unique:
    two zones may carry the same name, and a dict would quietly keep whichever
    was read last. Call dict() on the result if you know your names are
    distinct.

    How many zones there are, and what they are called, is the kernel's
    business and changes between releases - this board showed six on one
    kernel and ten on the next - so nothing here assumes a count or a name.

    A zone that cannot be read is left out rather than raised. On real
    hardware a sensor that is not ready yet answers EINVAL or ENODATA, and one
    sulking sensor should not cost you the other nine readings. For the same
    reason a missing root reads as no zones: a virtual machine with no thermal
    subsystem has nothing to report, which is an answer and not an error.
    """
    zones: list[tuple[int, Path]] = []
    # iterdir() on a missing directory raises only once iterated, hence the
    # try around the whole loop rather than around the call.
    try:
        for entry in Path(root).iterdir():
            match = _ZONE.fullmatch(entry.name)
            if match:
                zones.append((int(match.group(1)), entry))
    except OSError:
        return []

    temps: list[tuple[str, float]] = []
    # Sorted on the number, not the name: as text, thermal_zone10 comes before
    # thermal_zone2, and the order would shuffle the day an eleventh appears.
    for _, zone in sorted(zones):
        try:
            name = (zone / "type").read_text().strip()
            # The kernel reports millidegrees as a signed integer. Signed
            # matters: a board left in a cold shed reads below zero.
            millidegrees = int((zone / "temp").read_text())
        except (OSError, ValueError):
            # OSError is the sensor refusing; ValueError is it answering with
            # something that is not a number. Neither is a temperature.
            continue
        temps.append((name, millidegrees / 1000))
    return temps


def hottest(temps: list[tuple[str, float]], prefix: str = "") -> tuple[str, float] | None:
    """The warmest (type, degrees Celsius) among zones whose type starts with prefix.

    One number is what fits on a small display, and the warmest zone is the
    one that will throttle first. `prefix="cpu"` narrows it to the CPU
    clusters, which on this board are `cpuss0-thermal` and `cpuss1-thermal`.

    Returns None when nothing matches, rather than a made-up 0.0 that would
    read as a board at freezing point.
    """
    matching = [pair for pair in temps if pair[0].startswith(prefix)]
    if not matching:
        return None
    # On a tie max() keeps the first, which is the lower-numbered zone.
    return max(matching, key=lambda pair: pair[1])
