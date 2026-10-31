# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""Tests for the CPU-bars runner.

The runner's job is glue: sample, clamp, send, and leave the panel dark on the
way out. The MCU and the sampler are both faked, so what is under test is the
sequencing rather than either end.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest

from unoq import cpubars
from unoq.mcu import BARS_MAX, MCUError


class FakeMCU:
    """Records what the runner sent, in order."""

    def __init__(self, reset: list[str] | Exception | None = None) -> None:
        self.frames: list[list[int]] = []
        self.off = 0
        self.closed = False
        self.reset: list[str] | Exception = ["watchdog", "pin"] if reset is None else reset
        self.reset_asked = 0

    def reset_cause(self) -> list[str]:
        self.reset_asked += 1
        if isinstance(self.reset, Exception):
            raise self.reset
        return self.reset

    def bars(self, pct: Any) -> None:
        self.frames.append(list(pct))

    def matrix_off(self) -> None:
        self.off += 1

    def __enter__(self) -> FakeMCU:
        return self

    def __exit__(self, *exc: object) -> None:
        self.closed = True


class FakeSampler:
    """Hands out a fixed script of readings, then repeats the last one."""

    def __init__(self, readings: list[list[int]]) -> None:
        self.readings = readings
        self.calls = 0

    @property
    def cores(self) -> int:
        return len(self.readings[0])

    def sample(self) -> list[int]:
        reading = self.readings[min(self.calls, len(self.readings) - 1)]
        self.calls += 1
        return reading


# -- run() ------------------------------------------------------------------


def test_sends_one_frame_per_interval() -> None:
    mcu, sampler = FakeMCU(), FakeSampler([[10, 20, 30, 40]])
    sent = cpubars.run(mcu, sampler, interval=0.1, count=3, sleep=lambda _s: None)

    assert sent == 3
    assert mcu.frames == [[10, 20, 30, 40]] * 3


def test_sleeps_before_the_first_sample() -> None:
    """Sampling immediately would measure the sliver of time since the sampler
    was constructed and open with a meaningless frame."""
    order: list[str] = []
    mcu = FakeMCU()

    class Watcher(FakeSampler):
        def sample(self) -> list[int]:
            order.append("sample")
            return super().sample()

    def sleep(_s: float) -> None:
        order.append("sleep")

    cpubars.run(mcu, Watcher([[0]]), interval=0.1, count=2, sleep=sleep)
    assert order == ["sleep", "sample", "sleep", "sample"]


def test_sleeps_for_the_requested_interval() -> None:
    slept: list[float] = []
    cpubars.run(FakeMCU(), FakeSampler([[0]]), interval=0.25, count=2, sleep=slept.append)
    assert slept == [0.25, 0.25]


def test_more_cores_than_bars_are_truncated_not_rejected() -> None:
    """MCU.bars() raises above BARS_MAX, so the runner has to cut the list
    down itself or a big host would crash on the first frame."""
    mcu = FakeMCU()
    reading = list(range(BARS_MAX + 3))
    cpubars.run(mcu, FakeSampler([reading]), count=1, sleep=lambda _s: None)

    assert mcu.frames == [reading[:BARS_MAX]]


def test_a_reading_with_no_cores_sends_nothing() -> None:
    """Sending an empty bar list would be a usage error, not a blank display."""
    mcu = FakeMCU()
    sent = cpubars.run(mcu, FakeSampler([[]]), count=2, sleep=lambda _s: None)

    assert sent == 2
    assert mcu.frames == []


# -- main() -----------------------------------------------------------------


@pytest.fixture
def wired(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> dict[str, Any]:
    """Patch main()'s two collaborators and hand back what it built."""
    mcu = FakeMCU()
    state: dict[str, Any] = {"mcu": mcu, "port": None}

    def make_mcu(port: str) -> FakeMCU:
        state["port"] = port
        return mcu

    monkeypatch.setattr(cpubars, "MCU", make_mcu)
    stat = tmp_path / "stat"
    stat.write_text("cpu0 0 0 0 0 0 0 0 0\ncpu1 0 0 0 0 0 0 0 0\n")
    state["stat"] = str(stat)
    return state


def test_main_draws_then_blanks_the_panel(wired: dict[str, Any]) -> None:
    rc = main_with(wired, ["--count", "2", "--interval", "0"])

    assert rc == 0
    assert len(wired["mcu"].frames) == 2
    assert wired["mcu"].off == 1, "the panel must not be left showing a stale frame"
    assert wired["mcu"].closed, "the port must be released"


def test_main_blanks_the_panel_on_ctrl_c(
    wired: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    def interrupt(*_a: Any, **_k: Any) -> int:
        raise KeyboardInterrupt

    monkeypatch.setattr(cpubars, "run", interrupt)
    rc = main_with(wired, [])

    assert rc == 0, "Ctrl-C is how you stop this, not a failure"
    assert wired["mcu"].off == 1


def test_main_blanks_the_panel_even_when_the_link_fails(
    wired: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    def boom(*_a: Any, **_k: Any) -> int:
        raise OSError("serial gone")

    monkeypatch.setattr(cpubars, "run", boom)
    with pytest.raises(OSError, match="serial gone"):
        main_with(wired, [])

    assert wired["mcu"].off == 1


def test_main_uses_the_requested_port(wired: dict[str, Any]) -> None:
    main_with(wired, ["--count", "1", "--interval", "0", "--port", "/dev/ttyFAKE"])
    assert wired["port"] == "/dev/ttyFAKE"


def test_main_refuses_a_stat_file_with_no_cores(
    wired: dict[str, Any], tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    empty = tmp_path / "empty"
    empty.write_text("intr 1\n")
    rc = cpubars.main(["--stat", str(empty)])

    assert rc == 1
    assert "no per-core lines" in capsys.readouterr().err
    assert wired["mcu"].frames == [], "it must not open the link at all"


def test_main_says_so_when_there_are_more_cores_than_bars(
    wired: dict[str, Any], tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Dropping cores silently would make the panel look like a full picture
    of a machine it is only showing part of."""
    big = tmp_path / "big"
    big.write_text("".join(f"cpu{i} 0 0 0 0 0 0 0 0\n" for i in range(BARS_MAX + 1)))
    cpubars.main(["--stat", str(big), "--count", "1", "--interval", "0"])

    err = capsys.readouterr().err
    assert f"panel fits {BARS_MAX} bars" in err


def test_main_logs_the_reset_cause_once_before_drawing(
    wired: dict[str, Any], capsys: pytest.CaptureFixture[str]
) -> None:
    main_with(wired, ["--count", "3", "--interval", "0"])

    assert wired["mcu"].reset_asked == 1
    assert "MCU last reset: watchdog,pin" in capsys.readouterr().err


def test_log_reset_cause_with_nothing_recorded(capsys: pytest.CaptureFixture[str]) -> None:
    cpubars.log_reset_cause(FakeMCU(reset=[]))
    assert "MCU last reset: no cause recorded" in capsys.readouterr().err


def test_an_old_firmware_costs_the_line_not_the_demo(
    wired: dict[str, Any], capsys: pytest.CaptureFixture[str]
) -> None:
    wired["mcu"].reset = MCUError("this firmware has no `app reset` command")
    rc = main_with(wired, ["--count", "2", "--interval", "0"])

    assert rc == 0
    assert len(wired["mcu"].frames) == 2
    assert "MCU reset cause not available: this firmware" in capsys.readouterr().err


def main_with(wired: dict[str, Any], argv: list[str]) -> int:
    return cpubars.main([*argv, "--stat", wired["stat"]])
