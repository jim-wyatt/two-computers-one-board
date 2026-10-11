# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""Tests for the /proc/stat reader.

Every input here is a written-out /proc/stat, never the real one: load on the
machine running the suite is not a reproducible fixture, and a test that
asserted anything about it would be a coin toss.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from unoq.cpu import CpuSampler, read_cpu_times

# A real /proc/stat opens with the machine-wide aggregate and closes with
# counters that have nothing to do with CPUs. Both are here so the parser is
# tested against the shape it actually meets.
STAT = """\
cpu  100 0 100 800 0 0 0 0 0 0
cpu0 100 0 100 800 0 0 0 0 0 0
cpu1 200 0 200 600 0 0 0 0 0 0
intr 12345 0 0
ctxt 98765
btime 1700000000
processes 4242
"""


def write(tmp_path: Path, text: str) -> str:
    path = tmp_path / "stat"
    path.write_text(text)
    return str(path)


# -- read_cpu_times ---------------------------------------------------------


def test_reads_one_entry_per_core(tmp_path: Path) -> None:
    assert read_cpu_times(write(tmp_path, STAT)) == [(200, 1000), (400, 1000)]


def test_skips_the_machine_wide_aggregate(tmp_path: Path) -> None:
    """The bare `cpu` line repeats every core's time summed. Counting it would
    add a phantom core that always reads as the average of the real ones."""
    cores = read_cpu_times(write(tmp_path, STAT))
    assert len(cores) == 2


def test_iowait_counts_as_idle(tmp_path: Path) -> None:
    """A core blocked on disk is not doing work. Were iowait counted as busy,
    a machine sitting at rest under I/O would peg every bar."""
    stat = "cpu0 100 0 100 500 300 0 0 0 0 0\n"
    busy, total = read_cpu_times(write(tmp_path, stat))[0]
    assert (busy, total) == (200, 1000)


def test_guest_columns_are_not_double_counted(tmp_path: Path) -> None:
    """proc(5) already includes guest time inside user, and guest_nice inside
    nice. Summing all ten columns would count virtualized time twice and
    inflate the total, quietly shrinking every reading."""
    stat = "cpu0 100 0 100 800 0 0 0 0 70 30\n"
    assert read_cpu_times(write(tmp_path, stat))[0] == (200, 1000)


def test_short_lines_from_old_kernels_are_padded(tmp_path: Path) -> None:
    """Kernels before 2.6.33 stop before `steal`. The missing columns should
    read as zero rather than raising an IndexError."""
    stat = "cpu0 100 0 100 800\n"
    assert read_cpu_times(write(tmp_path, stat)) == [(200, 1000)]


def test_a_file_with_no_cores_reads_as_empty(tmp_path: Path) -> None:
    assert read_cpu_times(write(tmp_path, "intr 1\nctxt 2\n")) == []


def test_blank_lines_are_ignored(tmp_path: Path) -> None:
    assert read_cpu_times(write(tmp_path, "\ncpu0 100 0 100 800 0 0 0 0\n\n")) == [(200, 1000)]


# -- CpuSampler -------------------------------------------------------------


def test_sample_reports_the_delta_not_the_total(tmp_path: Path) -> None:
    """The counters are cumulative since boot. A sampler that reported them
    raw would show the average since power-on and barely move afterwards."""
    path = write(tmp_path, "cpu0 100 0 100 800 0 0 0 0\n")
    sampler = CpuSampler(path)

    # 500 more jiffies, 250 of them busy: the reading is 50%, even though the
    # cumulative figure is only 45/1500.
    Path(path).write_text("cpu0 350 0 100 1050 0 0 0 0\n")
    assert sampler.sample() == [50]


def test_successive_samples_each_cover_their_own_window(tmp_path: Path) -> None:
    path = write(tmp_path, "cpu0 0 0 0 0 0 0 0 0\n")
    sampler = CpuSampler(path)

    Path(path).write_text("cpu0 100 0 0 0 0 0 0 0\n")
    assert sampler.sample() == [100]

    # A fully idle window after a fully busy one must read as 0, not as the
    # running average.
    Path(path).write_text("cpu0 100 0 0 100 0 0 0 0\n")
    assert sampler.sample() == [0]


def test_idle_and_pegged_cores_read_as_the_extremes(tmp_path: Path) -> None:
    path = write(tmp_path, "cpu0 0 0 0 0 0 0 0 0\ncpu1 0 0 0 0 0 0 0 0\n")
    sampler = CpuSampler(path)

    Path(path).write_text("cpu0 0 0 0 100 0 0 0 0\ncpu1 100 0 0 0 0 0 0 0\n")
    assert sampler.sample() == [0, 100]


def test_no_elapsed_time_reads_as_zero_rather_than_dividing_by_zero(tmp_path: Path) -> None:
    """Two reads inside one kernel tick. There is no measurement to report."""
    path = write(tmp_path, "cpu0 100 0 100 800 0 0 0 0\n")
    sampler = CpuSampler(path)
    assert sampler.sample() == [0]


def test_rewound_counters_clamp_instead_of_going_negative(tmp_path: Path) -> None:
    """Suspend/resume can move these counters backwards. A negative percentage
    would be rejected by the firmware and freeze the panel on its last frame."""
    path = write(tmp_path, "cpu0 500 0 500 500 0 0 0 0\n")
    sampler = CpuSampler(path)

    Path(path).write_text("cpu0 0 0 0 900 0 0 0 0\n")
    assert sampler.sample() == [0]


def test_a_core_disappearing_does_not_raise(tmp_path: Path) -> None:
    """CPU hotplug. Report the cores that still line up rather than failing."""
    path = write(tmp_path, "cpu0 0 0 0 0 0 0 0 0\ncpu1 0 0 0 0 0 0 0 0\n")
    sampler = CpuSampler(path)

    Path(path).write_text("cpu0 100 0 0 0 0 0 0 0\n")
    assert sampler.sample() == [100]


def test_cores_reports_what_the_last_reading_saw(tmp_path: Path) -> None:
    assert CpuSampler(write(tmp_path, STAT)).cores == 2
    assert CpuSampler(write(tmp_path, "intr 1\n")).cores == 0


def test_a_missing_stat_file_raises(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError, match="nope"):
        read_cpu_times(str(tmp_path / "nope"))
