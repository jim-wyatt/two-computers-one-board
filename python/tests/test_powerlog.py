# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""Tests for the CSV sampler used alongside a USB power meter.

The clock, the sleep and every source are injected, so a run of a hundred
rows takes no time and reads nothing from the machine running the suite.
"""

from __future__ import annotations

import csv
from collections.abc import Callable
from pathlib import Path

import pytest

from unoq import powerlog
from unoq.cpufreq import Policy
from unoq.powerlog import Load, row, run


def policy(
    name: str = "policy0", governor: str | None = "schedutil", khz: int | None = 864000
) -> Policy:
    return Policy(
        name=name,
        cpus=(0, 1, 2, 3),
        driver="qcom-cpufreq-hw",
        governor=governor,
        governors=("ondemand", "userspace", "performance", "schedutil"),
        min_khz=300000,
        max_khz=2016000,
        cur_khz=khz,
        frequencies=(300000, 864000, 2016000),
        time_in_state=(),
    )


TEMPS = [("cpuss0-thermal", 35.8), ("cpuss1-thermal", 36.1)]


class FakeLoad:
    def __init__(self, values: list[int]) -> None:
        self.values = values

    def sample(self) -> list[int]:
        return self.values


class Clock:
    """Starts at 1000.0 and advances by whatever is slept."""

    def __init__(self) -> None:
        self.now = 1000.0
        self.slept: list[float] = []

    def time(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.slept.append(seconds)
        self.now += seconds


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="") as f:
        return list(csv.DictReader(f))


def drive(
    path: Path,
    clock: Clock,
    *,
    sampler: Load | None = None,
    label: str = "",
    interval: float = 5.0,
    count: int | None = None,
    policies: Callable[[], list[Policy]] = lambda: [policy()],
    temps: Callable[[], list[tuple[str, float]]] = lambda: TEMPS,
    sleep: Callable[[float], None] | None = None,
) -> int:
    return run(
        str(path),
        sampler or FakeLoad([12, 3, 0, 47]),
        label=label,
        interval=interval,
        count=count,
        policies=policies,
        temps=temps,
        clock=clock.time,
        sleep=sleep or clock.sleep,
    )


# -- row --------------------------------------------------------------------


def test_row_has_every_source_in_order() -> None:
    assert row(1000.5, "idle", [policy()], TEMPS, [12, 3]) == {
        "time": "1000.500",
        "label": "idle",
        "policy0_governor": "schedutil",
        "policy0_khz": "864000",
        "temp_cpuss0-thermal": "35.8",
        "temp_cpuss1-thermal": "36.1",
        "cpu0_pct": "12",
        "cpu1_pct": "3",
    }


def test_row_leaves_unknown_values_blank_not_zero() -> None:
    """0 kHz would read as a stopped clock."""
    values = row(0.0, "", [policy(governor=None, khz=None)], [], [])
    assert values["policy0_governor"] == ""
    assert values["policy0_khz"] == ""


def test_row_keeps_zones_that_share_a_type() -> None:
    temps = [("pm-thermal", 30.0), ("pm-thermal", 41.0), ("pm-thermal", 42.0)]
    values = row(0.0, "", [], temps, [])
    assert values["temp_pm-thermal"] == "30.0"
    assert values["temp_pm-thermal#2"] == "41.0"
    assert values["temp_pm-thermal#3"] == "42.0"


def test_row_has_a_pair_of_columns_per_policy() -> None:
    values = row(0.0, "", [policy("policy0"), policy("policy4", "performance", 2016000)], [], [])
    assert values["policy4_governor"] == "performance"
    assert values["policy4_khz"] == "2016000"


# -- run --------------------------------------------------------------------


def test_run_writes_a_header_then_one_row_per_interval(tmp_path: Path) -> None:
    out = tmp_path / "runs.csv"
    assert drive(out, Clock(), label="idle-schedutil", count=3) == 3
    rows = read_csv(out)
    assert [r["time"] for r in rows] == ["1005.000", "1010.000", "1015.000"]
    assert {r["label"] for r in rows} == {"idle-schedutil"}
    assert rows[0]["cpu3_pct"] == "47"
    assert out.read_text().count("time,label") == 1


def test_run_sleeps_before_the_first_sample(tmp_path: Path) -> None:
    """The load is a difference between readings; the first needs an
    interval behind it, as in cpubars.run()."""
    clock = Clock()
    seen: list[float] = []

    class Watching(FakeLoad):
        def sample(self) -> list[int]:
            seen.append(clock.now)
            return super().sample()

    drive(tmp_path / "runs.csv", clock, sampler=Watching([1]), interval=2.0, count=1)
    assert clock.slept == [2.0]
    assert seen == [1002.0]


def test_a_second_run_appends_under_the_same_header(tmp_path: Path) -> None:
    """One file can hold a run per governor."""
    out = tmp_path / "runs.csv"
    drive(out, Clock(), label="idle-schedutil", count=2)
    drive(
        out,
        Clock(),
        label="idle-performance",
        count=2,
        policies=lambda: [policy("policy0", "performance", 2016000)],
    )
    rows = read_csv(out)
    assert [r["label"] for r in rows] == ["idle-schedutil"] * 2 + ["idle-performance"] * 2
    assert rows[-1]["policy0_governor"] == "performance"
    assert out.read_text().count("time,label") == 1


def test_appending_keeps_the_files_columns(tmp_path: Path) -> None:
    """A column the new run lacks is blank; one the file never had is dropped
    rather than shifting every column after it."""
    out = tmp_path / "runs.csv"
    drive(out, Clock(), count=1)
    drive(out, Clock(), count=1, temps=lambda: [("cpuss0-thermal", 40.0), ("new-thermal", 1.0)])
    rows = read_csv(out)
    assert rows[1]["temp_cpuss0-thermal"] == "40.0"
    assert rows[1]["temp_cpuss1-thermal"] == ""
    assert "temp_new-thermal" not in rows[1]


def test_an_empty_existing_file_gets_a_header(tmp_path: Path) -> None:
    out = tmp_path / "runs.csv"
    out.write_text("")
    drive(out, Clock(), count=1)
    assert out.read_text().startswith("time,label,")


def test_count_zero_writes_nothing_but_creates_the_file(tmp_path: Path) -> None:
    out = tmp_path / "runs.csv"
    assert drive(out, Clock(), count=0) == 0
    assert out.read_text() == ""


def test_with_no_count_it_runs_until_interrupted(tmp_path: Path) -> None:
    """Ctrl-C ends an open-ended run, and the rows before it are on disk."""
    out = tmp_path / "runs.csv"
    clock = Clock()

    def sleep(seconds: float) -> None:
        if len(clock.slept) == 4:
            raise KeyboardInterrupt
        clock.sleep(seconds)

    with pytest.raises(KeyboardInterrupt):
        drive(out, clock, sleep=sleep)
    assert len(read_csv(out)) == 4


def test_run_writes_only_the_file_it_is_given(tmp_path: Path) -> None:
    drive(tmp_path / "runs.csv", Clock(), count=2)
    assert [p.name for p in tmp_path.iterdir()] == ["runs.csv"]


# -- main -------------------------------------------------------------------


STAT = "cpu  10 0 10 80 0 0 0 0 0 0\ncpu0 10 0 10 80 0 0 0 0 0 0\n"


def fake_roots(tmp_path: Path) -> list[str]:
    stat = tmp_path / "stat"
    stat.write_text(STAT)
    zone = tmp_path / "thermal" / "thermal_zone0"
    zone.mkdir(parents=True)
    (zone / "type").write_text("cpuss0-thermal\n")
    (zone / "temp").write_text("35800\n")
    policy0 = tmp_path / "cpufreq" / "policy0"
    policy0.mkdir(parents=True)
    (policy0 / "scaling_governor").write_text("schedutil\n")
    (policy0 / "scaling_cur_freq").write_text("864000\n")
    return [
        "--stat",
        str(stat),
        "--thermal",
        str(tmp_path / "thermal"),
        "--cpufreq",
        str(tmp_path / "cpufreq"),
    ]


def test_main_logs_from_the_roots_it_is_given(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    out = tmp_path / "runs.csv"
    argv = [str(out), "--label", "idle", "--interval", "0", "--count", "2", *fake_roots(tmp_path)]
    assert powerlog.main(argv) == 0
    rows = read_csv(out)
    assert len(rows) == 2
    assert rows[0]["policy0_governor"] == "schedutil"
    assert rows[0]["policy0_khz"] == "864000"
    assert rows[0]["temp_cpuss0-thermal"] == "35.8"
    assert rows[0]["cpu0_pct"] == "0"
    assert "2 rows appended" in capsys.readouterr().err


def test_main_treats_ctrl_c_as_the_end_of_the_run(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    def interrupt(*args: object, **kwargs: object) -> int:
        raise KeyboardInterrupt

    monkeypatch.setattr(powerlog, "run", interrupt)
    assert powerlog.main([str(tmp_path / "runs.csv"), *fake_roots(tmp_path)]) == 0


def test_main_reports_a_file_it_cannot_write(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    argv = [str(tmp_path / "missing" / "runs.csv"), "--count", "1", *fake_roots(tmp_path)]
    assert powerlog.main(argv) == 1
    assert "unoq-powerlog:" in capsys.readouterr().err
