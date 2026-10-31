# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""Tests for the temperature-log daemon.

The MCU is a fake that keeps a ring the way mcu/app/src/templog.c does: a
sequence number from 1, the oldest overwritten once it is full, `since` past
the newest refused. What is under test is what the daemon makes of that - the
rows, the notes, and where it carries on from - not the wire format, which
test_mcu.py and test_contract.py hold to the firmware's header.
"""

from __future__ import annotations

import csv
import os
from pathlib import Path
from typing import Any

import pytest

from unoq import templog
from unoq.mcu import MCUError, TempLogStat, TempSample


class FakeRing:
    """The MCU's temperature log: `size` samples, one per `tick()`."""

    def __init__(self, size: int = 600, start_ms: int = 1000, temp: float = 40.0) -> None:
        self.size = size
        self.samples: list[TempSample] = []
        self.head = 0
        self.ms = start_ms
        self.temp = temp
        self.calls: list[int | None] = []
        self.fail_next = False

    def tick(self, n: int = 1, err: int = 0) -> None:
        for _ in range(n):
            self.head += 1
            self.ms += 1000
            self.temp += 0.125
            self.samples.append(
                TempSample(self.head, self.ms, None if err else round(self.temp, 3), err)
            )
            del self.samples[: -self.size]

    def reboot(self, start_ms: int = 1000, temp: float = 40.0) -> None:
        self.samples = []
        self.head = 0
        self.ms = start_ms
        self.temp = temp

    def temp_log_stat(self) -> TempLogStat:
        return TempLogStat(self.head, len(self.samples), self.size, 0, 1000)

    def temp_log(self, since: int | None = None) -> list[TempSample]:
        self.calls.append(since)
        if since is not None and since > self.head:
            raise MCUError("since is past the newest sample")
        return [s for s in self.samples if since is None or s.seq > since]


class Clock:
    def __init__(self, now: float = 1_800_000_000.0) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now


ZONES = [("cpuss0-thermal", 41.5), ("cpuss0-thermal", 42.0), ("pm4125-tz", 35.25)]


def read(path: Path) -> list[dict[str, str]]:
    with path.open(newline="") as f:
        return list(csv.DictReader(f))


def go(ring: FakeRing, tmp_path: Path, count: int = 1, **kw: Any) -> int:
    kw.setdefault("temps", lambda: ZONES)
    kw.setdefault("clock", Clock())
    kw.setdefault("sleep", lambda _s: None)
    return templog.run(ring, tmp_path, count=count, **kw)


def seqs(rows: list[dict[str, str]]) -> list[int]:
    return [int(r["seq"]) for r in rows if r["seq"]]


def notes(rows: list[dict[str, str]]) -> list[str]:
    return [r["note"] for r in rows if r["note"]]


# -- a first pull -------------------------------------------------------------


def test_first_pull_stores_everything_the_mcu_holds(tmp_path: Path) -> None:
    ring = FakeRing()
    ring.tick(5)
    assert go(ring, tmp_path) == 5
    rows = read(tmp_path / "temps.csv")
    assert seqs(rows) == [1, 2, 3, 4, 5]
    assert ring.calls == [None]
    assert rows[0]["mcu_ms"] == "2000"
    assert rows[0]["mcu_temp_c"] == "40.125"
    assert rows[0]["mcu_err"] == ""
    # A fresh file starts where the MCU's memory does: nothing before it is a gap.
    assert notes(rows) == []


def test_header_is_the_mcu_columns_then_one_per_zone(tmp_path: Path) -> None:
    ring = FakeRing()
    ring.tick()
    go(ring, tmp_path)
    with (tmp_path / "temps.csv").open() as f:
        header = f.readline().strip().split(",")
    assert header == [
        *templog.BASE_COLUMNS,
        "linux_cpuss0-thermal",
        "linux_cpuss0-thermal#2",
        "linux_pm4125-tz",
    ]


def test_times_come_from_the_mcu_clock_backwards_from_the_pull(tmp_path: Path) -> None:
    # The newest sample is "now"; each older one is as much older as the
    # MCU's own uptime says, whatever Linux was doing in between.
    ring = FakeRing()
    ring.tick(3)
    go(ring, tmp_path, clock=Clock(5000.0))
    times = [float(r["time"]) for r in read(tmp_path / "temps.csv")]
    assert times == [4998.0, 4999.0, 5000.0]


def test_host_zones_go_on_the_newest_row_only(tmp_path: Path) -> None:
    ring = FakeRing()
    ring.tick(3)
    go(ring, tmp_path)
    rows = read(tmp_path / "temps.csv")
    assert [r["linux_cpuss0-thermal"] for r in rows] == ["", "", "41.5"]
    assert rows[-1]["linux_cpuss0-thermal#2"] == "42.0"
    assert rows[-1]["linux_pm4125-tz"] == "35.2"


def test_a_failed_read_keeps_its_number_and_its_errno(tmp_path: Path) -> None:
    ring = FakeRing()
    ring.tick()
    ring.tick(err=-5)
    go(ring, tmp_path)
    rows = read(tmp_path / "temps.csv")
    assert seqs(rows) == [1, 2]
    assert rows[1]["mcu_temp_c"] == ""
    assert rows[1]["mcu_err"] == "-5"


def test_an_empty_log_writes_nothing_not_even_a_header(tmp_path: Path) -> None:
    ring = FakeRing()
    assert go(ring, tmp_path) == 0
    assert (tmp_path / "temps.csv").read_text() == ""
    # ...and the next pull, with samples, still gets a header.
    ring.tick()
    go(ring, tmp_path)
    assert seqs(read(tmp_path / "temps.csv")) == [1]


# -- carrying on ---------------------------------------------------------------


def test_each_pull_asks_again_for_the_last_sample_it_stored(tmp_path: Path) -> None:
    ring = FakeRing()
    ring.tick(3)
    clock = Clock()

    def sleep(_s: float) -> None:
        ring.tick(2)

    go(ring, tmp_path, count=3, clock=clock, sleep=sleep)
    assert ring.calls == [None, 2, 4]
    # ...and stores it once.
    assert seqs(read(tmp_path / "temps.csv")) == [1, 2, 3, 4, 5, 6, 7]


def test_a_pull_with_nothing_new_writes_nothing(tmp_path: Path) -> None:
    ring = FakeRing()
    ring.tick(2)
    assert go(ring, tmp_path, count=2) == 2
    assert seqs(read(tmp_path / "temps.csv")) == [1, 2]


def test_sleeps_the_interval_between_pulls_and_not_after_the_last(tmp_path: Path) -> None:
    ring = FakeRing()
    slept: list[float] = []
    go(ring, tmp_path, count=3, interval=7.5, sleep=slept.append)
    assert slept == [7.5, 7.5]


def test_a_restarted_daemon_resumes_from_the_file(tmp_path: Path) -> None:
    ring = FakeRing()
    ring.tick(4)
    go(ring, tmp_path)
    ring.tick(3)
    ring.calls.clear()
    go(ring, tmp_path)
    assert ring.calls == [3]
    rows = read(tmp_path / "temps.csv")
    assert seqs(rows) == [1, 2, 3, 4, 5, 6, 7]
    assert notes(rows) == []
    # One header, kept from the first run.
    assert (tmp_path / "temps.csv").read_text().count("time,seq") == 1


def test_a_stopped_daemon_that_missed_samples_writes_a_gap(tmp_path: Path) -> None:
    ring = FakeRing(size=5)
    ring.tick(3)
    go(ring, tmp_path)
    ring.tick(10)  # 4..13; the ring holds 9..13
    go(ring, tmp_path)
    rows = read(tmp_path / "temps.csv")
    assert seqs(rows) == [1, 2, 3, 9, 10, 11, 12, 13]
    assert notes(rows) == ["gap 4-8"]
    gap = next(r for r in rows if r["note"])
    # In its place in the record, timed like the sample after it.
    assert rows.index(gap) == 3
    assert gap["time"] == rows[4]["time"]


def test_no_gap_when_only_the_sample_already_stored_was_overwritten(tmp_path: Path) -> None:
    ring = FakeRing(size=5)
    ring.tick(3)
    go(ring, tmp_path)
    ring.tick(5)  # 4..8; 3 is gone but was stored
    go(ring, tmp_path)
    rows = read(tmp_path / "temps.csv")
    assert seqs(rows) == list(range(1, 9))
    assert notes(rows) == []


def test_a_gap_in_the_middle_of_a_reply_is_noted_too(tmp_path: Path) -> None:
    # Overwritten while it was being paged out: temp_log() hands back a jump.
    class Jumpy(FakeRing):
        def temp_log(self, since: int | None = None) -> list[TempSample]:
            out = super().temp_log(since)
            return [s for s in out if s.seq != 3]

    ring = Jumpy()
    ring.tick(5)
    go(ring, tmp_path)
    rows = read(tmp_path / "temps.csv")
    assert notes(rows) == ["gap 3-3"]


# -- the MCU restarting --------------------------------------------------------


def test_a_head_below_the_last_seq_is_a_restart(tmp_path: Path) -> None:
    ring = FakeRing()
    ring.tick(50)
    go(ring, tmp_path)
    ring.reboot()
    ring.tick(3)
    ring.calls.clear()
    go(ring, tmp_path)
    rows = read(tmp_path / "temps.csv")
    assert notes(rows) == ["mcu-restart"]
    assert seqs(rows)[-4:] == [50, 1, 2, 3]
    # Started again from nothing, not from a number the MCU has never reached.
    assert ring.calls == [None]


def test_a_restart_that_has_counted_past_the_old_number_is_caught_too(tmp_path: Path) -> None:
    # The case the head alone misses: stopped, the MCU reflashed, and started
    # again only after the new boot has counted beyond the old last seq. The
    # sample under that number is not the one stored.
    ring = FakeRing()
    ring.tick(5)
    go(ring, tmp_path)
    ring.reboot(start_ms=1300, temp=30.0)
    ring.tick(8)
    go(ring, tmp_path)
    rows = read(tmp_path / "temps.csv")
    assert notes(rows) == ["mcu-restart"]
    assert seqs(rows) == [1, 2, 3, 4, 5, 1, 2, 3, 4, 5, 6, 7, 8]


def test_a_restart_the_ring_has_wrapped_since_is_a_restart_then_a_gap(tmp_path: Path) -> None:
    ring = FakeRing(size=5)
    ring.tick(40)
    go(ring, tmp_path)
    ring.reboot()
    ring.tick(12)  # the new boot holds 8..12
    go(ring, tmp_path)
    rows = read(tmp_path / "temps.csv")
    assert notes(rows) == ["mcu-restart", "gap 1-7"]
    assert seqs(rows)[-5:] == [8, 9, 10, 11, 12]


def test_a_restart_note_at_the_end_of_the_file_is_resumed_from(tmp_path: Path) -> None:
    # Stopped right after writing the note, before any sample of the new boot.
    ring = FakeRing()
    ring.tick(20)
    go(ring, tmp_path)
    ring.reboot()
    go(ring, tmp_path)
    assert notes(read(tmp_path / "temps.csv")) == ["mcu-restart"]
    ring.tick(3)
    ring.calls.clear()
    go(ring, tmp_path)
    rows = read(tmp_path / "temps.csv")
    assert ring.calls == [None]
    assert notes(rows) == ["mcu-restart"]
    assert seqs(rows)[-3:] == [1, 2, 3]


def test_a_failed_sample_is_matched_on_its_errno(tmp_path: Path) -> None:
    ring = FakeRing()
    ring.tick(err=-5)
    go(ring, tmp_path)
    ring.tick()
    go(ring, tmp_path)
    rows = read(tmp_path / "temps.csv")
    assert notes(rows) == []
    assert seqs(rows) == [1, 2]


def test_same() -> None:
    a = TempSample(1, 100, 40.125)
    assert templog._same(a, TempSample(1, 100, 40.1251))
    assert not templog._same(a, TempSample(1, 100, 40.2))
    assert not templog._same(a, TempSample(1, 101, 40.125))
    assert not templog._same(a, TempSample(1, 100, None, -5))
    assert templog._same(TempSample(1, 100, None, -5), TempSample(1, 100, None, -5))


# -- the file ------------------------------------------------------------------


def test_each_pull_is_flushed_and_fsynced(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    synced: list[int] = []
    real = os.fsync

    def fsync(fd: int) -> None:
        synced.append(fd)
        real(fd)

    monkeypatch.setattr("unoq.templog.os.fsync", fsync)
    ring = FakeRing()
    ring.tick()

    def sleep(_s: float) -> None:
        # By now the first pull is on disk, before the second is made.
        assert seqs(read(tmp_path / "temps.csv")) == [1]
        ring.tick()

    go(ring, tmp_path, count=2, sleep=sleep)
    assert len(synced) == 2


def test_a_line_cut_short_by_a_power_cut_does_not_swallow_the_next(tmp_path: Path) -> None:
    ring = FakeRing()
    ring.tick(2)
    go(ring, tmp_path)
    path = tmp_path / "temps.csv"
    path.write_text(path.read_text() + "1800000000.5,3")  # no newline
    ring.tick(2)
    go(ring, tmp_path)
    lines = path.read_text().splitlines()
    assert lines[-3] == "1800000000.5,3"
    assert lines[-2].split(",")[1] == "3"
    # The torn row did not parse, so it was carried on from seq 2.
    assert seqs(read(path))[-2:] == [3, 4]


def test_an_existing_header_is_kept_and_a_new_zone_dropped(tmp_path: Path) -> None:
    ring = FakeRing()
    ring.tick()
    go(ring, tmp_path, temps=lambda: [("a", 1.0)])
    ring.tick()
    go(ring, tmp_path, temps=lambda: [("a", 2.0), ("b", 3.0)])
    rows = read(tmp_path / "temps.csv")
    assert list(rows[-1]) == [*templog.BASE_COLUMNS, "linux_a"]
    assert rows[-1]["linux_a"] == "2.0"


def test_resume_of_a_missing_or_empty_file(tmp_path: Path) -> None:
    assert templog.resume(tmp_path / "nope.csv") == templog.Resume()
    (tmp_path / "empty.csv").write_text("")
    assert templog.resume(tmp_path / "empty.csv") == templog.Resume()


def test_resume_passes_over_gap_notes_and_junk(tmp_path: Path) -> None:
    path = tmp_path / "t.csv"
    path.write_text(
        "time,seq,mcu_ms,mcu_temp_c,mcu_err,note\n"
        "1.0,7,7000,40.500,,\n"
        "2.0,,,,,gap 8-9\n"
        "3.0,x,y,z,,\n"
    )
    state = templog.resume(path)
    assert state.last == TempSample(7, 7000, 40.5, 0)
    assert state.expected == 8
    assert not state.torn


def test_resume_of_a_header_alone(tmp_path: Path) -> None:
    path = tmp_path / "t.csv"
    path.write_text("time,seq,mcu_ms,mcu_temp_c,mcu_err,note\n")
    state = templog.resume(path)
    assert state.header == templog.BASE_COLUMNS
    assert state.last is None
    assert state.expected is None


def test_resume_reads_only_the_end_of_a_long_file(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(templog, "_TAIL_BYTES", 100)
    path = tmp_path / "t.csv"
    lines = ["time,seq,mcu_ms,mcu_temp_c,mcu_err,note"]
    lines += [f"{i}.0,{i},{i * 1000},40.000,," for i in range(1, 200)]
    path.write_text("\n".join(lines) + "\n")
    state = templog.resume(path)
    assert state.header == templog.BASE_COLUMNS
    assert state.last is not None
    assert state.last.seq == 199


# -- the page ------------------------------------------------------------------


def test_the_page_is_written_once_and_rewritten_only_when_it_changed(tmp_path: Path) -> None:
    assert templog.write_page(tmp_path)
    page = tmp_path / "index.html"
    assert "temps.csv" in page.read_text()
    assert not templog.write_page(tmp_path)
    page.write_text("old")
    assert templog.write_page(tmp_path)
    assert page.read_text() != "old"
    assert not list(tmp_path.glob(".*"))


def test_the_page_fetches_nothing_from_anywhere_else() -> None:
    # The board is often on a cable to a laptop with no internet.
    page = (Path(templog.__file__).parent / "templog.html").read_text()
    for needle in ("http://", "https://", "//cdn", "src="):
        if needle == "http://":
            # The SVG namespace is a name, not a fetch.
            page = page.replace("http://www.w3.org/2000/svg", "")
        assert needle not in page, needle


# -- main ----------------------------------------------------------------------


class FakeMCU(FakeRing):
    def __init__(self, port: str = "", **_k: Any) -> None:
        super().__init__()
        self.port = port
        self.tick(3)
        self.closed = False

    def __enter__(self) -> FakeMCU:
        return self

    def __exit__(self, *exc: object) -> None:
        self.closed = True


def test_main_logs_and_writes_the_page(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    made: list[FakeMCU] = []

    def fake(port: str) -> FakeMCU:
        made.append(FakeMCU(port))
        return made[-1]

    monkeypatch.setattr(templog, "MCU", fake)
    thermal = tmp_path / "thermal"
    thermal.mkdir()
    rc = templog.main(
        ["--dir", str(tmp_path), "--count", "1", "--port", "/dev/fake", "--thermal", str(thermal)]
    )
    assert rc == 0
    assert made[0].port == "/dev/fake"
    assert made[0].closed
    assert seqs(read(tmp_path / "temps.csv")) == [1, 2, 3]
    assert (tmp_path / "index.html").exists()
    captured = capsys.readouterr()
    assert "wrote" in captured.out
    assert "3 rows appended" in captured.err
    # The second start finds the page already there and says nothing about it.
    assert templog.main(["--dir", str(tmp_path), "--count", "1"]) == 0
    assert "wrote" not in capsys.readouterr().out


def test_main_reads_the_directory_and_interval_from_the_environment(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    seen: dict[str, Any] = {}

    def fake_run(mcu: Any, directory: Any, interval: float, **_k: Any) -> int:
        seen.update(directory=directory, interval=interval)
        return 0

    monkeypatch.setattr(templog, "MCU", FakeMCU)
    monkeypatch.setattr(templog, "run", fake_run)
    monkeypatch.setenv("UNOQ_TEMPLOG_DIR", str(tmp_path))
    monkeypatch.setenv("UNOQ_TEMPLOG_INTERVAL", "2.5")
    assert templog.main([]) == 0
    assert seen == {"directory": tmp_path, "interval": 2.5}


def test_the_defaults(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("UNOQ_TEMPLOG_INTERVAL", raising=False)
    assert templog._env_float("UNOQ_TEMPLOG_INTERVAL", 10.0) == 10.0
    assert templog.DEFAULT_DIR == "/var/lib/unoq/templog"


@pytest.mark.parametrize(("raw", "says"), [("ten", "not a number"), ("0", "more than 0")])
def test_a_bad_interval_in_the_environment_is_refused(
    monkeypatch: pytest.MonkeyPatch, raw: str, says: str
) -> None:
    monkeypatch.setenv("UNOQ_TEMPLOG_INTERVAL", raw)
    with pytest.raises(SystemExit, match=says):
        templog.main([])


def test_a_bad_interval_on_the_command_line_is_refused(
    capsys: pytest.CaptureFixture[str],
) -> None:
    with pytest.raises(SystemExit):
        templog.main(["--interval", "-1"])
    assert "more than 0" in capsys.readouterr().err


def test_main_reports_a_missing_directory(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    assert templog.main(["--dir", str(tmp_path / "nope")]) == 1
    assert "unoq-temp-log:" in capsys.readouterr().err


def test_main_reports_an_mcu_error(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    class Old(FakeMCU):
        def temp_log_stat(self) -> TempLogStat:
            raise MCUError("this firmware has no temperature log")

    monkeypatch.setattr(templog, "MCU", Old)
    assert templog.main(["--dir", str(tmp_path)]) == 1
    assert "no temperature log" in capsys.readouterr().err


def test_main_stops_cleanly_on_interrupt(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    def interrupted(*_a: Any, **_k: Any) -> int:
        raise KeyboardInterrupt

    monkeypatch.setattr(templog, "MCU", FakeMCU)
    monkeypatch.setattr(templog, "run", interrupted)
    assert templog.main(["--dir", str(tmp_path)]) == 0


def test_the_unit_file_agrees_with_the_defaults() -> None:
    unit = Path(__file__).resolve().parents[1] / "unoq-temp-log.service"
    execstart = next(x for x in unit.read_text().splitlines() if x.startswith("ExecStart="))
    assert f"--dir {templog.DEFAULT_DIR}" in execstart
    assert f"--interval {templog.DEFAULT_INTERVAL:g}" in execstart
    assert "Conflicts=unoq-cpu-bars.service" in unit.read_text().splitlines()
