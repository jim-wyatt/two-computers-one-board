# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""Tests for the /sys/class/thermal reader.

Every input here is a sysfs tree written out under tmp_path, never the real
one: how warm the machine running the suite is, and how many sensors it has,
is not a reproducible fixture. On a virtual machine there are none at all.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from unoq.thermal import hottest, read_temps

# The ten zones the board reported under kernel 7.0.0, in zone order, in the
# millidegrees the kernel really prints. Ten rather than a tidy three because
# ten is the first count at which sorting names as text goes wrong.
BOARD = [
    ("mapss-thermal", 34200),
    ("video-thermal", 34800),
    ("wlan-thermal", 32600),
    ("cpuss0-thermal", 35800),
    ("cpuss1-thermal", 36100),
    ("mdm0-thermal", 34200),
    ("mdm1-thermal", 33600),
    ("gpu-thermal", 33900),
    ("hm-center-thermal", 35800),
    ("camera-thermal", 33300),
]


def add_zone(root: Path, number: int, name: str | None, temp: str | None) -> Path:
    """Write one thermal_zoneN. None leaves that file out altogether."""
    zone = root / f"thermal_zone{number}"
    zone.mkdir(parents=True)
    # sysfs ends every value with a newline, so the fake does too.
    if name is not None:
        (zone / "type").write_text(f"{name}\n")
    if temp is not None:
        (zone / "temp").write_text(f"{temp}\n")
    return zone


def board(tmp_path: Path) -> str:
    for number, (name, millidegrees) in enumerate(BOARD):
        add_zone(tmp_path, number, name, str(millidegrees))
    return str(tmp_path)


# -- read_temps -------------------------------------------------------------


def test_reads_every_zone_in_degrees_celsius(tmp_path: Path) -> None:
    assert read_temps(board(tmp_path)) == [
        ("mapss-thermal", 34.2),
        ("video-thermal", 34.8),
        ("wlan-thermal", 32.6),
        ("cpuss0-thermal", 35.8),
        ("cpuss1-thermal", 36.1),
        ("mdm0-thermal", 34.2),
        ("mdm1-thermal", 33.6),
        ("gpu-thermal", 33.9),
        ("hm-center-thermal", 35.8),
        ("camera-thermal", 33.3),
    ]


def test_zones_sort_by_number_not_by_name(tmp_path: Path) -> None:
    """As text, thermal_zone10 comes before thermal_zone9. Created out of
    order as well, so the test does not pass on directory order by luck."""
    for number in (10, 9, 2, 11, 1):
        add_zone(tmp_path, number, f"zone{number}", str(number * 1000))
    names = [name for name, _ in read_temps(str(tmp_path))]
    assert names == ["zone1", "zone2", "zone9", "zone10", "zone11"]


def test_a_missing_root_reads_as_no_zones(tmp_path: Path) -> None:
    """A machine with no thermal subsystem has nothing to report. That is an
    answer, not an error."""
    assert read_temps(str(tmp_path / "nope")) == []


def test_an_empty_root_reads_as_no_zones(tmp_path: Path) -> None:
    assert read_temps(str(tmp_path)) == []


def test_a_root_that_is_not_a_directory_reads_as_no_zones(tmp_path: Path) -> None:
    path = tmp_path / "thermal"
    path.write_text("not a directory\n")
    assert read_temps(str(path)) == []


def test_a_sensor_that_refuses_to_read_costs_only_itself(tmp_path: Path) -> None:
    """A sensor that is not ready answers EINVAL or ENODATA on the read. A
    directory where `temp` should be fails the read the same way, with an
    OSError, without needing a kernel to provoke it."""
    add_zone(tmp_path, 0, "cpuss0-thermal", "35800")
    (add_zone(tmp_path, 1, "wlan-thermal", None) / "temp").mkdir()
    add_zone(tmp_path, 2, "gpu-thermal", "33900")
    assert read_temps(str(tmp_path)) == [("cpuss0-thermal", 35.8), ("gpu-thermal", 33.9)]


def test_a_zone_with_no_temp_file_is_left_out(tmp_path: Path) -> None:
    add_zone(tmp_path, 0, "cpuss0-thermal", "35800")
    add_zone(tmp_path, 1, "wlan-thermal", None)
    assert read_temps(str(tmp_path)) == [("cpuss0-thermal", 35.8)]


@pytest.mark.parametrize("garbage", ["", "warm", "35.8", "0x8bd8"])
def test_a_temp_that_is_not_an_integer_is_left_out(tmp_path: Path, garbage: str) -> None:
    """Whatever this is, it is not millidegrees. Guessing at it would put a
    wrong number on a display, which is worse than a missing one."""
    add_zone(tmp_path, 0, "wlan-thermal", garbage)
    add_zone(tmp_path, 1, "gpu-thermal", "33900")
    assert read_temps(str(tmp_path)) == [("gpu-thermal", 33.9)]


def test_a_zone_with_no_type_is_left_out(tmp_path: Path) -> None:
    """A temperature with no name cannot be told apart from its neighbours,
    and inventing one from the directory would make it look like a real zone."""
    add_zone(tmp_path, 0, None, "35800")
    add_zone(tmp_path, 1, "gpu-thermal", "33900")
    assert read_temps(str(tmp_path)) == [("gpu-thermal", 33.9)]


def test_zones_sharing_a_type_are_both_kept(tmp_path: Path) -> None:
    """Nothing makes `type` unique. A dict would keep whichever came last and
    say nothing about the other, which is why this returns pairs."""
    add_zone(tmp_path, 0, "pm8150-thermal", "30000")
    add_zone(tmp_path, 1, "pm8150-thermal", "41000")
    assert read_temps(str(tmp_path)) == [("pm8150-thermal", 30.0), ("pm8150-thermal", 41.0)]


def test_temperatures_below_zero_keep_their_sign(tmp_path: Path) -> None:
    add_zone(tmp_path, 0, "cpuss0-thermal", "-5500")
    add_zone(tmp_path, 1, "gpu-thermal", "0")
    assert read_temps(str(tmp_path)) == [("cpuss0-thermal", -5.5), ("gpu-thermal", 0.0)]


def test_everything_that_is_not_a_zone_is_ignored(tmp_path: Path) -> None:
    """The real directory also holds cooling_device0..N, and they have a
    `type` too. Each of these is given a readable type and temp, so only the
    name is keeping it out."""
    add_zone(tmp_path, 0, "cpuss0-thermal", "35800")
    for stray in ("cooling_device0", "thermal_zone", "thermal_zone1.bak", "old_thermal_zone2"):
        (tmp_path / stray).mkdir()
        (tmp_path / stray / "type").write_text("stray\n")
        (tmp_path / stray / "temp").write_text("99000\n")
    assert read_temps(str(tmp_path)) == [("cpuss0-thermal", 35.8)]


def test_the_default_root_is_the_real_sysfs_path() -> None:
    """Called with no argument it reads the live machine. The values are not
    reproducible, so this only checks that it answers in the promised shape -
    including on a machine with no zones at all."""
    for name, celsius in read_temps():
        assert isinstance(name, str)
        assert isinstance(celsius, float)


# -- hottest ----------------------------------------------------------------


def test_hottest_picks_the_warmest_zone(tmp_path: Path) -> None:
    assert hottest(read_temps(board(tmp_path))) == ("cpuss1-thermal", 36.1)


def test_hottest_can_be_narrowed_by_prefix(tmp_path: Path) -> None:
    temps = read_temps(board(tmp_path))
    assert hottest(temps, "cpu") == ("cpuss1-thermal", 36.1)
    assert hottest(temps, "mdm") == ("mdm0-thermal", 34.2)


def test_hottest_of_nothing_is_none_not_zero() -> None:
    """0.0 would read as a board at freezing point."""
    assert hottest([]) is None


def test_hottest_with_no_matching_zone_is_none(tmp_path: Path) -> None:
    assert hottest(read_temps(board(tmp_path)), "battery") is None


def test_hottest_on_a_tie_keeps_the_lower_numbered_zone() -> None:
    temps = [("cpuss0-thermal", 35.8), ("cpuss1-thermal", 35.8)]
    assert hottest(temps) == ("cpuss0-thermal", 35.8)


def test_hottest_works_below_zero() -> None:
    assert hottest([("a", -10.0), ("b", -2.5)]) == ("b", -2.5)
