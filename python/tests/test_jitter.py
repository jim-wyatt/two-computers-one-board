# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""unoq-jitter: the schedule, the three histograms, and every way a run ends.

The clock, the wait, the MCU and the load are all fakes: nothing here opens
/dev/ttyHS1, sleeps for real, or starts a process.
"""

from __future__ import annotations

import signal
import time

import pytest

from unoq import jitter
from unoq.heat import Stopped
from unoq.jitter import Result, Timing, histogram, jitter_bin, run, table, tick
from unoq.mcu import JITTER_BIN_LABELS, JITTER_BINS, JitterHist, JitterStat, MCUError

MIDDLE = JITTER_BINS // 2


def empty(src: str, period_us: int = 20_000) -> JitterHist:
    return JitterHist(src, period_us, 0, 0, 0, 0, (0,) * JITTER_BINS)


class FakeClock:
    """Monotonic seconds that move only when slept on, or when told to.

    `overshoot[i]` is how much later than asked the i-th sleep wakes up.
    """

    def __init__(self, overshoot: dict[int, float] | None = None) -> None:
        self.t = 100.0
        self.overshoot = overshoot or {}
        self.sleeps: list[float] = []

    def clock(self) -> float:
        return self.t

    def sleep(self, seconds: float) -> None:
        assert seconds > 0
        self.t += seconds + self.overshoot.get(len(self.sleeps), 0.0)
        self.sleeps.append(seconds)


class FakeMCU:
    def __init__(
        self,
        clock: FakeClock | None = None,
        write_s: float = 0.0,
        pwm: JitterHist | None = None,
        fail_tick: BaseException | None = None,
        fail_off: bool = False,
    ) -> None:
        self.clock = clock or FakeClock()
        self.write_s = write_s
        self.pwm = pwm
        self.fail_tick = fail_tick
        self.fail_off = fail_off
        self.calls: list[str] = []
        self.ticks: list[float] = []
        self.period_us = 0

    def __enter__(self) -> FakeMCU:
        self.calls.append("open")
        return self

    def __exit__(self, *exc: object) -> None:
        self.calls.append("close")

    def jitter_arm(self, period_us: int) -> int:
        self.calls.append(f"arm {period_us}")
        self.period_us = period_us
        return period_us

    def jitter_tick(self) -> None:
        if self.fail_tick is not None:
            raise self.fail_tick
        self.ticks.append(self.clock.t)
        self.clock.t += self.write_s

    def jitter_pwm(self, hz: int) -> int:
        self.calls.append(f"pwm {hz}")
        return 1_000_000 // hz

    def jitter_stat(self) -> JitterStat:
        self.calls.append("stat")
        n = len(self.ticks) - 1
        bins = tuple(n if i == MIDDLE else 0 for i in range(JITTER_BINS))
        tick_hist = JitterHist("tick", self.period_us, n, 0, 0, 0, bins)
        return JitterStat(tick_hist, self.pwm or empty("pwm", 0))

    def jitter_off(self) -> None:
        self.calls.append("off")
        if self.fail_off:
            raise MCUError("no reply")


class FakeWorker:
    def __init__(self, log: list[str]) -> None:
        self.log = log
        self.alive = False

    def start(self) -> None:
        self.alive = True
        self.log.append("start")

    def join(self, timeout: float | None = None) -> None:
        self.log.append("join")

    def is_alive(self) -> bool:
        return self.alive

    def terminate(self) -> None:
        self.alive = False
        self.log.append("terminate")

    def kill(self) -> None:
        self.alive = False


def timing(clock: FakeClock, log: list[str] | None = None, cores: int | None = 2) -> Timing:
    log = [] if log is None else log

    def spawn(s: float) -> FakeWorker:
        log.append(f"spawn {s}")
        return FakeWorker(log)

    return Timing(clock=clock.clock, sleep=clock.sleep, spawn=spawn, cores=cores, settle=1.0)


# -- the bins ----------------------------------------------------------------


@pytest.mark.parametrize(
    ("dev_ns", "label"),
    [
        (0, "-50..50"),
        (50_000, "-50..50"),
        (-50_000, "-50..50"),
        (50_001, "50..100"),
        (-50_001, "-100..-50"),
        (1_000_000, "500..1000"),
        (5_000_000, "2000..5000"),
        (5_000_001, ">5000"),
        (-5_000_001, "<-5000"),
        (-(2**31), "<-5000"),
    ],
)
def test_a_deviation_lands_in_the_firmware_s_bin(dev_ns: int, label: str) -> None:
    assert JITTER_BIN_LABELS[jitter_bin(dev_ns)] == label


def test_an_empty_histogram_is_all_zero() -> None:
    assert histogram("linux", 20_000, []) == empty("linux")


def test_a_histogram_counts_and_summarizes_like_the_mcu() -> None:
    hist = histogram("linux", 20_000, [10_000, 70_000, 6_000_000])
    assert (hist.n, hist.min_ns, hist.max_ns, hist.mean_ns) == (3, 10_000, 6_000_000, 2_026_666)
    assert sum(hist.bins) == 3
    assert hist.bins[MIDDLE] == 1
    assert hist.bins[MIDDLE + 1] == 1
    assert hist.bins[-1] == 1


def test_a_negative_mean_truncates_toward_zero_as_c_does() -> None:
    assert histogram("linux", 20_000, [-3, 0]).mean_ns == -1


# -- the schedule ------------------------------------------------------------


def test_ticks_land_on_deadlines_counted_from_the_start() -> None:
    clock = FakeClock()
    mcu = FakeMCU(clock)
    late, missed = tick(mcu, 0.01, 4, timing(clock))
    start = 101.0  # 100 + the settle
    assert mcu.ticks == pytest.approx([start + k * 0.01 for k in range(4)])
    assert late == [0, 0, 0, 0]
    assert missed == 0


def test_one_late_wake_up_delays_one_tick_not_the_rest() -> None:
    clock = FakeClock(overshoot={2: 0.003})  # the sleep before tick 2
    mcu = FakeMCU(clock)
    late, missed = tick(mcu, 0.01, 5, timing(clock))
    assert late == [0, 0, 3_000_000, 0, 0]
    assert mcu.ticks[3] == pytest.approx(101.03)
    assert missed == 0


def test_a_tick_already_due_is_written_without_waiting() -> None:
    # Each write takes 12 ms against a 10 ms period, so every deadline after
    # the first has passed by the time it is looked at, but by less than one
    # period: written at once, late, and never skipped.
    clock = FakeClock()
    mcu = FakeMCU(clock, write_s=0.012)
    late, missed = tick(mcu, 0.01, 3, timing(clock))
    assert late == [0, 2_000_000, 4_000_000]
    assert len(clock.sleeps) == 1
    assert missed == 0


def test_a_deadline_missed_by_a_whole_period_is_skipped() -> None:
    clock = FakeClock(overshoot={1: 0.015})  # tick 1 wakes 15 ms late
    mcu = FakeMCU(clock)
    late, missed = tick(mcu, 0.01, 4, timing(clock))
    # Tick 1 is skipped; tick 2 goes at once, 5 ms late; tick 3 is on time.
    assert late == [0, 5_000_000, 0]
    assert missed == 1
    assert mcu.ticks == pytest.approx([101.0, 101.025, 101.03])


def test_a_miss_at_the_end_ends_the_run() -> None:
    clock = FakeClock(overshoot={1: 0.025})
    mcu = FakeMCU(clock)
    late, missed = tick(mcu, 0.01, 3, timing(clock))
    assert late == [0]
    assert missed == 2


# -- the run -----------------------------------------------------------------


def test_a_run_arms_ticks_stops_then_reads() -> None:
    clock = FakeClock()
    mcu = FakeMCU(clock)
    result = run(mcu, period=0.02, seconds=1.0, timing=timing(clock))
    assert mcu.calls == ["arm 20000", "off", "stat"]
    assert len(mcu.ticks) == 51
    assert result.ticks == 51
    assert result.linux.n == 51
    assert result.linux.src == "linux"
    assert result.linux.period_us == 20_000
    assert (result.load, result.cores, result.pwm_hz, result.missed) == ("none", 0, None, 0)
    assert result.stat.tick.n == 50


def test_a_run_under_load_with_pwm_stops_the_load_before_the_mcu() -> None:
    clock = FakeClock()
    log: list[str] = []
    mcu = FakeMCU(clock)
    result = run(mcu, 0.01, 0.05, "spin", 1000, timing(clock, log, cores=3))
    assert mcu.calls == ["arm 10000", "pwm 1000", "off", "stat"]
    assert log.count("start") == 3
    assert log.count("terminate") == 3
    assert log[0] == f"spawn {1.0 + 0.05 + jitter.SPIN_SLACK}"
    assert (result.load, result.cores, result.pwm_hz) == ("spin", 3, 1000)


@pytest.mark.parametrize(("cpu_count", "cores"), [(4, 4), (None, 1)])
def test_the_load_takes_every_core(
    monkeypatch: pytest.MonkeyPatch, cpu_count: int | None, cores: int
) -> None:
    monkeypatch.setattr("os.cpu_count", lambda: cpu_count)
    clock = FakeClock()
    result = run(FakeMCU(clock), 0.01, 0.01, "spin", timing=timing(clock, cores=None))
    assert result.cores == cores


@pytest.mark.parametrize("fail_off", [False, True])
def test_a_run_cut_short_still_stops_the_mcu_and_the_load(fail_off: bool) -> None:
    clock = FakeClock()
    log: list[str] = []
    mcu = FakeMCU(clock, fail_tick=KeyboardInterrupt(), fail_off=fail_off)
    with pytest.raises(KeyboardInterrupt):
        run(mcu, 0.01, 1.0, "spin", 100, timing(clock, log))
    assert mcu.calls == ["arm 10000", "pwm 100", "off"]
    assert log.count("terminate") == 2


def test_the_default_timing_is_the_real_clock() -> None:
    t = Timing()
    assert t.clock is time.monotonic
    assert t.sleep is time.sleep


# -- the table ---------------------------------------------------------------


def result(load: str = "none", pwm_hz: int | None = None, pwm_n: int = 0) -> Result:
    bins = tuple(pwm_n if i == MIDDLE else 0 for i in range(JITTER_BINS))
    pwm = JitterHist("pwm", 1000, pwm_n, -6, 12, 1, bins)
    linux = histogram("linux", 20_000, [12_300, 80_100])
    tick_hist = JitterHist("tick", 20_000, 1, 67_700, 67_700, 67_700, (0,) * 8 + (1,) + (0,) * 6)
    return Result(load, 4 if load == "spin" else 0, pwm_hz, 2, 1, linux, JitterStat(tick_hist, pwm))


def test_the_table_puts_three_columns_side_by_side() -> None:
    lines = table(result()).splitlines()
    assert lines[0] == "period 20000 us, load none, pwm off"
    assert lines[1] == "2 ticks written, 1 deadlines missed"
    assert lines[3].split() == ["bin", "(us)", "Linux", "MCU", "tick", "MCU", "pwm"]
    rows = {line[:14].strip(): line[14:].split() for line in lines[5:]}
    assert rows["-50..50"] == ["1", "0", "0"]
    assert rows["50..100"] == ["1", "1", "0"]
    assert rows["n"] == ["2", "1", "0"]
    assert rows["max us"] == ["80.1", "67.7", "0.0"]
    assert rows["mean us"] == ["46.2", "67.7", "0.0"]
    assert len(rows) == JITTER_BINS + 4


def test_the_table_names_the_load_and_the_pwm() -> None:
    text = table(result("spin", 1000, pwm_n=999))
    assert text.splitlines()[0] == (
        "period 20000 us, load spin on 4 cores, pwm 1000 Hz on D3, captured on D2"
    )
    assert "jumper" not in text


def test_the_table_asks_after_the_jumper_when_no_pwm_arrived() -> None:
    assert table(result(pwm_hz=1000)).endswith("is the jumper on D3 to D2?")


# -- the command -------------------------------------------------------------


@pytest.mark.parametrize(
    ("argv", "said"),
    [
        (["--period", "0.00001"], "--period"),
        (["--period", "11"], "--period"),
        (["--seconds", "0"], "--seconds"),
        (["--pwm", "15"], "--pwm"),
        (["--pwm", "10001"], "--pwm"),
        (["--load", "build"], "--load"),
    ],
)
def test_main_refuses_bad_arguments(
    argv: list[str], said: str, capsys: pytest.CaptureFixture[str]
) -> None:
    with pytest.raises(SystemExit) as exit_:
        jitter.main(argv)
    assert exit_.value.code == 2
    assert said in capsys.readouterr().err


def test_main_runs_and_prints_the_table(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    clock = FakeClock()
    mcu = FakeMCU(clock)
    monkeypatch.setattr(jitter, "MCU", lambda: mcu)
    monkeypatch.setattr(jitter, "Timing", lambda: timing(clock))
    assert jitter.main(["--period", "0.01", "--seconds", "0.1", "--pwm", "1000"]) == 0
    assert mcu.calls == ["open", "arm 10000", "pwm 1000", "off", "stat", "close"]
    out = capsys.readouterr().out
    assert out.startswith("period 10000 us, load none, pwm 1000 Hz")
    assert "11 ticks written" in out


def test_main_explains_a_busy_port(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    def busy() -> None:
        raise MCUError("/dev/ttyHS1 is held by unoq-cpu-bars")

    monkeypatch.setattr(jitter, "MCU", busy)
    assert jitter.main([]) == 1
    err = capsys.readouterr().err
    assert "held by unoq-cpu-bars" in err
    assert "systemctl stop unoq-cpu-bars" in err


@pytest.mark.parametrize(
    ("error", "code", "said"),
    [
        (MCUError("this firmware has no `app jitter` command"), 1, "no `app jitter`"),
        (OSError("read failed"), 1, "read failed"),
        (KeyboardInterrupt(), 130, "interrupted; ticks and PWM stopped"),
        (Stopped(signal.SIGTERM), 143, "SIGTERM; ticks and PWM stopped"),
    ],
)
def test_main_reports_how_a_run_ended(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    error: BaseException,
    code: int,
    said: str,
) -> None:
    mcu = FakeMCU()

    def failing(*args: object, **kw: object) -> Result:
        raise error

    monkeypatch.setattr(jitter, "MCU", lambda: mcu)
    monkeypatch.setattr(jitter, "run", failing)
    assert jitter.main([]) == code
    assert said in capsys.readouterr().err
    assert mcu.calls == ["open", "close"]
