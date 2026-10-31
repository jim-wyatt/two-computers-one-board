# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""Tests for the heat-under-load run.

Every source is a written-out sysfs tree under tmp_path, the MCU is a fake,
the clock advances only by what is slept, and the spinners are fakes except in
the one test that proves real ones die with a signal. Nothing here switches the
machine's governor or keeps its cores busy for longer than a blink.
"""

from __future__ import annotations

import csv
import functools
import multiprocessing
import os
import signal
from collections.abc import Callable, Iterator
from pathlib import Path

import pytest

from unoq import heat
from unoq.cpufreq import Policy
from unoq.heat import (
    Governor,
    Sources,
    Spinners,
    Stopped,
    Summary,
    gpu_hz,
    mcu_temp,
    mcu_uptime,
    raise_on_signals,
    run,
    signals_held,
    time_in_state_delta,
)
from unoq.mcu import MCUError

GOVERNORS = "ondemand userspace performance schedutil"


def cpufreq_tree(root: Path, policies: int = 1, governor: str = "schedutil") -> Path:
    for n in range(policies):
        p = root / f"policy{n}"
        (p / "stats").mkdir(parents=True)
        (p / "scaling_governor").write_text(governor + "\n")
        (p / "scaling_available_governors").write_text(GOVERNORS + " \n")
        (p / "related_cpus").write_text("0 1 2 3\n")
        (p / "scaling_cur_freq").write_text("1305600\n")
        (p / "stats" / "time_in_state").write_text("614400 100\n2016000 200\n")
    return root


def governor_of(root: Path, n: int = 0) -> str:
    return (root / f"policy{n}" / "scaling_governor").read_text().strip()


def thermal_tree(root: Path, temps: dict[str, int]) -> Path:
    for n, (name, mc) in enumerate(temps.items()):
        zone = root / f"thermal_zone{n}"
        zone.mkdir(parents=True)
        (zone / "type").write_text(name + "\n")
        (zone / "temp").write_text(f"{mc}\n")
    return root


def devfreq_tree(root: Path, hz: str = "355200000") -> Path:
    node = root / "5900000.gpu"
    node.mkdir(parents=True)
    (node / "cur_freq").write_text(hz + "\n")
    return root


@pytest.fixture
def cpufreq(tmp_path: Path) -> Path:
    return cpufreq_tree(tmp_path / "cpufreq", policies=2)


@pytest.fixture(autouse=True)
def handlers() -> Iterator[None]:
    """Whatever a test does to the signal handlers or mask, put them back."""
    saved = {sig: signal.getsignal(sig) for sig in heat._STOP_SIGNALS}
    mask = signal.pthread_sigmask(signal.SIG_BLOCK, [])
    yield
    for sig, handler in saved.items():
        signal.signal(sig, handler)
    signal.pthread_sigmask(signal.SIG_SETMASK, mask)


# -- signals -----------------------------------------------------------------


def test_raise_on_signals_turns_term_and_hup_into_stopped_then_puts_handlers_back() -> None:
    before = signal.getsignal(signal.SIGTERM)
    for sig in (signal.SIGTERM, signal.SIGHUP):
        with pytest.raises(Stopped) as caught, raise_on_signals():
            os.kill(os.getpid(), sig)
        assert caught.value.signum == sig
        assert str(caught.value) == sig.name
    assert signal.getsignal(signal.SIGTERM) is before


def test_signals_held_delivers_a_signal_once_released() -> None:
    reached = []

    def hold_then_release() -> None:
        with signals_held():
            os.kill(os.getpid(), signal.SIGTERM)
            reached.append("still inside")

    with pytest.raises(Stopped), raise_on_signals():
        hold_then_release()
    assert reached == ["still inside"]


# -- the governor ------------------------------------------------------------


def test_governor_switches_every_policy_and_restores_on_a_normal_end(cpufreq: Path) -> None:
    with Governor("performance", str(cpufreq)) as gov:
        assert governor_of(cpufreq, 0) == governor_of(cpufreq, 1) == "performance"
        assert list(gov.original.values()) == ["schedutil", "schedutil"]
    assert governor_of(cpufreq, 0) == governor_of(cpufreq, 1) == "schedutil"


def test_governor_restores_on_an_exception(cpufreq: Path) -> None:
    with pytest.raises(RuntimeError), Governor("performance", str(cpufreq)):
        raise RuntimeError("the workload broke")
    assert governor_of(cpufreq) == "schedutil"


@pytest.mark.parametrize(
    ("sig", "raised"),
    [
        (signal.SIGINT, KeyboardInterrupt),
        (signal.SIGTERM, Stopped),
        (signal.SIGHUP, Stopped),
    ],
)
def test_governor_restores_on_each_signal(
    cpufreq: Path, sig: signal.Signals, raised: type[BaseException]
) -> None:
    signal.signal(signal.SIGINT, signal.default_int_handler)
    during: list[str] = []

    def switched_then_signalled() -> None:
        with Governor("ondemand", str(cpufreq)):
            during.append(governor_of(cpufreq))
            os.kill(os.getpid(), sig)

    with pytest.raises(raised), raise_on_signals():
        switched_then_signalled()
    assert during == ["ondemand"]
    assert governor_of(cpufreq, 0) == governor_of(cpufreq, 1) == "schedutil"


def test_a_signal_during_the_restore_waits_until_every_policy_is_back(cpufreq: Path) -> None:
    def write(path: Path, text: str) -> None:
        path.write_text(text)
        if text == "schedutil" and path.parent.name == "policy0":
            # The impatient second Ctrl-C, halfway through putting it back.
            os.kill(os.getpid(), signal.SIGTERM)

    with pytest.raises(Stopped), raise_on_signals(), Governor("ondemand", str(cpufreq), write):
        pass
    assert governor_of(cpufreq, 0) == governor_of(cpufreq, 1) == "schedutil"


def test_a_failed_restore_still_tries_every_policy_and_raises_the_first(cpufreq: Path) -> None:
    written: list[str] = []

    def write(path: Path, text: str) -> None:
        if text == "schedutil":
            written.append(path.parent.name)
            raise PermissionError(f"refused {path.parent.name}")
        path.write_text(text)

    with pytest.raises(PermissionError, match="policy0"), Governor("ondemand", str(cpufreq), write):
        pass
    assert written == ["policy0", "policy1"]


def test_a_write_failing_partway_into_the_switch_restores_what_was_written(cpufreq: Path) -> None:
    def write(path: Path, text: str) -> None:
        if text == "ondemand" and path.parent.name == "policy1":
            raise PermissionError("not root")
        path.write_text(text)

    with pytest.raises(PermissionError), Governor("ondemand", str(cpufreq), write):
        pytest.fail("the block must not run")  # pragma: no cover
    assert governor_of(cpufreq, 0) == "schedutil"


def test_governor_refuses_before_writing(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="no cpufreq policies"):
        Governor("ondemand", str(tmp_path / "missing")).__enter__()

    root = cpufreq_tree(tmp_path / "a", policies=2)
    with pytest.raises(ValueError, match="does not offer 'turbo'"):
        Governor("turbo", str(root)).__enter__()
    assert governor_of(root) == "schedutil"

    (root / "policy1" / "scaling_governor").write_text("\n")
    with pytest.raises(ValueError, match="policy1: no governor to restore"):
        Governor("ondemand", str(root)).__enter__()
    assert governor_of(root) == "schedutil"

    (root / "policy1" / "scaling_governor").write_text("schedutil\n")
    (root / "policy1" / "scaling_available_governors").unlink()
    with pytest.raises(
        ValueError, match=r"policy1 does not offer 'ondemand' \(it offers nothing\)"
    ):
        Governor("ondemand", str(root)).__enter__()


def test_policy_dirs_ignore_other_entries_and_sort_on_the_number(tmp_path: Path) -> None:
    root = tmp_path / "cpufreq"
    for name in ("policy10", "policy2", "schedutil"):
        (root / name).mkdir(parents=True)
    (root / "policy3").write_text("a file, not a policy")
    (root / "boost").write_text("0")
    assert [p.name for p in heat._policy_dirs(str(root))] == ["policy2", "policy10"]


# -- the workload ------------------------------------------------------------


class FakeWorker:
    def __init__(self, log: list[str], n: int, stubborn: bool = False) -> None:
        self.log, self.n, self.stubborn = log, n, stubborn
        self.alive = False

    def start(self) -> None:
        self.alive = True
        self.log.append(f"start {self.n}")

    def join(self, timeout: float | None = None) -> None:
        self.log.append(f"join {self.n} {timeout}")

    def is_alive(self) -> bool:
        return self.alive

    def terminate(self) -> None:
        self.log.append(f"terminate {self.n}")
        self.alive = self.stubborn

    def kill(self) -> None:
        self.log.append(f"kill {self.n}")
        self.alive = False


class Spawner:
    def __init__(self, stubborn: int | None = None, fail_at: int | None = None) -> None:
        self.log: list[str] = []
        self.workers: list[FakeWorker] = []
        self.seconds: list[float] = []
        self.stubborn, self.fail_at = stubborn, fail_at

    def __call__(self, seconds: float) -> FakeWorker:
        n = len(self.workers)
        if n == self.fail_at:
            raise OSError("fork failed")
        self.seconds.append(seconds)
        worker = FakeWorker(self.log, n, stubborn=n == self.stubborn)
        self.workers.append(worker)
        return worker


def test_spinners_start_one_per_core_and_stop_every_one() -> None:
    spawn = Spawner(stubborn=1)
    with Spinners(3, 30.0, spawn, grace=0.5) as spinners:
        assert len(spinners.workers) == 3
        spawn.workers[2].alive = False  # this one finished on its own
    assert spawn.seconds == [30.0, 30.0, 30.0]
    assert spawn.log[3:] == [
        "terminate 0",
        "terminate 1",
        "join 0 0.5",
        "join 1 0.5",
        "kill 1",
        "join 1 None",
        "join 2 0.5",
    ]
    assert not any(w.alive for w in spawn.workers)


def test_spinners_stop_the_started_ones_if_a_spawn_fails() -> None:
    spawn = Spawner(fail_at=2)
    with pytest.raises(OSError, match="fork failed"), Spinners(4, 30.0, spawn):
        pytest.fail("the block must not run")  # pragma: no cover
    assert not any(w.alive for w in spawn.workers)
    assert spawn.log[:4] == ["start 0", "start 1", "terminate 0", "terminate 1"]


def test_spinners_stop_on_an_exception() -> None:
    spawn = Spawner()
    with pytest.raises(RuntimeError), Spinners(2, 30.0, spawn):
        raise RuntimeError
    assert not any(w.alive for w in spawn.workers)


def test_real_spinners_do_not_survive_a_signal() -> None:
    # The one test with real processes: a single spinner, asked for 30 s and
    # stopped by SIGTERM at once, which is the point.
    spinners = Spinners(1, 30.0)
    alive: list[bool] = []

    def started_then_signalled() -> None:
        with spinners:
            alive.append(spinners.workers[0].is_alive())
            os.kill(os.getpid(), signal.SIGTERM)

    with pytest.raises(Stopped), raise_on_signals():
        started_then_signalled()
    (worker,) = spinners.workers
    assert isinstance(worker, multiprocessing.Process)
    assert worker.daemon
    assert alive == [True]
    assert not worker.is_alive()
    assert worker.exitcode is not None


def test_spin_runs_for_its_seconds_and_ignores_ctrl_c() -> None:
    heat._spin(0.01)
    assert signal.getsignal(signal.SIGINT) is signal.SIG_IGN
    assert signal.getsignal(signal.SIGTERM) is signal.SIG_DFL


# -- the readings ------------------------------------------------------------


def test_gpu_hz(tmp_path: Path) -> None:
    root = devfreq_tree(tmp_path / "devfreq")
    (root / "1d84000.ufshc").mkdir()  # not a GPU, and sorts first
    assert gpu_hz(str(root)) == 355200000
    assert gpu_hz(str(tmp_path / "missing")) is None
    assert gpu_hz(str(tmp_path)) is None  # no .gpu node
    assert gpu_hz(str(devfreq_tree(tmp_path / "junk", "busy"))) is None


class FakeMCU:
    def __init__(
        self,
        temps: list[float] | None = None,
        uptime: int | str = 10_000,
        fail: bool = False,
    ) -> None:
        self.temps = temps or [30.0]
        self.uptime = uptime
        self.fail = fail
        self.reads = 0

    def die_temp(self) -> float:
        if self.fail:
            raise MCUError("no reply")
        self.reads += 1
        return self.temps[(self.reads - 1) % len(self.temps)]

    def status(self) -> dict[str, int | str]:
        if self.fail:
            raise OSError("port gone")
        if isinstance(self.uptime, int):
            self.uptime += 5_000
        return {"uptime_ms": self.uptime, "flip": 0}


def test_mcu_readings() -> None:
    assert mcu_temp(None) is None
    assert mcu_uptime(None) is None
    assert mcu_temp(FakeMCU([31.5])) == 31.5
    assert mcu_uptime(FakeMCU(uptime=1000)) == 6000
    assert mcu_temp(FakeMCU(fail=True)) is None
    assert mcu_uptime(FakeMCU(fail=True)) is None
    assert mcu_uptime(FakeMCU(uptime="later")) is None


def test_time_in_state_delta() -> None:
    def policy(tis: tuple[tuple[int, float], ...]) -> Policy:
        return Policy("policy0", (0,), None, None, (), None, None, None, (), tis)

    before = [policy(((614400, 1.0),))]
    after = [policy(((614400, 1.5), (2016000, 3.0)))]
    assert time_in_state_delta(before, after) == {
        "policy0_tis_614400": 0.5,
        "policy0_tis_2016000": 3.0,
    }


def test_summary_line() -> None:
    assert Summary("ondemand").line() == (
        "ondemand     load 0.0 s (MCU clock -), peak -, MCU mean -"
    )
    full = Summary("performance", 120.0, 119.9, ("cpuss0-thermal", 61.24), [40.0, 41.0])
    assert full.mcu_mean == 40.5
    assert full.line() == (
        "performance  load 120.0 s (MCU clock 119.9 s), peak cpuss0-thermal 61.2 C, MCU mean 40.5 C"
    )


# -- the run -----------------------------------------------------------------


class Clock:
    def __init__(self) -> None:
        self.now = 0.0
        self.slept: list[float] = []

    def time(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.slept.append(seconds)
        self.now += seconds


def sources(tmp_path: Path, **kw: object) -> tuple[Sources, Clock, Spawner]:
    clock, spawn = Clock(), Spawner()
    src = Sources(
        cpufreq=str(cpufreq_tree(tmp_path / "cpufreq")),
        thermal=str(thermal_tree(tmp_path / "thermal", {"cpuss0-thermal": 45000, "gpu": 40000})),
        devfreq=str(devfreq_tree(tmp_path / "devfreq")),
        spawn=spawn,
        clock=clock.time,
        wallclock=lambda: 1_700_000_000 + clock.now,
        sleep=clock.sleep,
    )
    for key, value in kw.items():
        setattr(src, key, value)
    return src, clock, spawn


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="") as f:
        return list(csv.DictReader(f))


def test_run_rests_then_loads_under_each_governor_and_restores(tmp_path: Path) -> None:
    mcu = FakeMCU([35.0, 37.0])
    src, clock, spawn = sources(tmp_path, mcu=mcu)
    seen: list[str] = []
    real_sleep = src.sleep

    def sleep(seconds: float) -> None:
        seen.append(governor_of(Path(src.cpufreq)))
        real_sleep(seconds)

    src.sleep = sleep
    out = tmp_path / "heat.csv"
    summaries = run(
        str(out), ["ondemand", "performance"], seconds=12, rest=5, interval=5, cores=4, src=src
    )

    # 5 s rest, then 5 + 5 + 2 s of load, per governor.
    assert clock.slept == [5, 5, 5, 2] * 2
    assert seen == ["ondemand"] * 4 + ["performance"] * 4
    assert governor_of(Path(src.cpufreq)) == "schedutil"
    assert spawn.seconds == [12] * 8
    assert not any(w.alive for w in spawn.workers)

    rows = read_csv(out)
    assert [(r["governor"], r["phase"], r["elapsed"]) for r in rows[:4]] == [
        ("ondemand", "rest", "5.0"),
        ("ondemand", "load", "5.0"),
        ("ondemand", "load", "10.0"),
        ("ondemand", "load", "12.0"),
    ]
    first = rows[0]
    assert first["time"] == "1700000005.000"
    assert first["policy0_governor"] == "ondemand"
    assert first["temp_cpuss0-thermal"] == "45.0"
    assert first["gpu_hz"] == "355200000"
    assert first["mcu_temp"] == "35.0"
    assert first["mcu_uptime_ms"] == "20000"
    assert first["policy0_tis_2016000"] == "0.00"

    load = summaries[0]
    assert [s.governor for s in summaries] == ["ondemand", "performance"]
    assert load.seconds == 12
    assert load.mcu_seconds == 15.0  # three rows of the fake's 5 s ticks
    assert load.peak == ("cpuss0-thermal", 45.0)
    assert load.mcu_temps == [37.0, 35.0, 37.0]


def test_run_keeps_the_hottest_row_and_copes_with_no_zones_or_mcu(tmp_path: Path) -> None:
    src, clock, _ = sources(tmp_path)
    temp = Path(src.thermal) / "thermal_zone0" / "temp"
    readings = iter(["50000", "60000", "55000"])

    def sleep(seconds: float) -> None:
        temp.write_text(next(readings))
        clock.sleep(seconds)

    src.sleep = sleep
    (summary,) = run(str(tmp_path / "a.csv"), ["ondemand"], 15, 0, 5, 1, src)
    assert summary.peak == ("cpuss0-thermal", 60.0)
    assert summary.mcu_seconds is None
    assert summary.mcu_mean is None

    src, _, _ = sources(tmp_path / "b", thermal=str(tmp_path / "none"))
    (summary,) = run(str(tmp_path / "b.csv"), ["ondemand"], 5, 0, 5, 1, src)
    assert summary.peak is None


def test_mcu_stopwatch_starts_at_the_first_reading_it_gets(tmp_path: Path) -> None:
    class LateMCU(FakeMCU):
        asked = 0

        def status(self) -> dict[str, int | str]:
            self.asked += 1
            if self.asked == 2:  # the load phase's opening read; 1 is the rest's
                raise MCUError("busy")
            return super().status()

    src, _, _ = sources(tmp_path, mcu=LateMCU())
    (summary,) = run(str(tmp_path / "a.csv"), ["ondemand"], 10, 0, 5, 1, src)
    assert summary.mcu_seconds == 5.0


def test_a_second_run_appends_under_the_first_header(tmp_path: Path) -> None:
    out = tmp_path / "heat.csv"
    src, _, _ = sources(tmp_path)
    run(str(out), ["ondemand"], 5, 0, 5, 1, src)
    run(str(out), ["performance"], 5, 0, 5, 1, src)
    assert out.read_text().count("governor,phase") == 1
    assert [r["governor"] for r in read_csv(out)] == ["ondemand", "performance"]


def test_run_restores_and_stops_the_spinners_when_interrupted(tmp_path: Path) -> None:
    src, clock, spawn = sources(tmp_path)

    def sleep(seconds: float) -> None:
        clock.sleep(seconds)
        if spawn.workers:
            os.kill(os.getpid(), signal.SIGTERM)

    src.sleep = sleep
    with pytest.raises(Stopped):
        run(str(tmp_path / "a.csv"), ["performance"], 30, 5, 5, 2, src)
    assert governor_of(Path(src.cpufreq)) == "schedutil"
    assert not any(w.alive for w in spawn.workers)
    # And the handlers are the caller's again.
    assert signal.getsignal(signal.SIGTERM) is signal.SIG_DFL


def test_run_checks_every_governor_before_switching_to_any(tmp_path: Path) -> None:
    src, _, spawn = sources(tmp_path)
    with pytest.raises(ValueError, match="does not offer turbo"):
        run(str(tmp_path / "a.csv"), ["ondemand", "turbo"], 5, 0, 5, 1, src)
    assert spawn.workers == []
    assert not (tmp_path / "a.csv").exists()


def test_run_defaults_to_every_core(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("os.cpu_count", lambda: None)
    src, _, spawn = sources(tmp_path)
    run(str(tmp_path / "a.csv"), ["ondemand"], 5, 0, 5, src=src)
    assert len(spawn.workers) == 1


def test_run_with_default_sources_reads_the_real_sysfs(tmp_path: Path) -> None:
    # Zero seconds and a governor nothing offers: it reaches Governor and
    # stops there, having written nothing.
    with pytest.raises(ValueError, match=r"cpufreq policies|does not offer"):
        run(str(tmp_path / "a.csv"), ["no-such-governor"], 0, 0, cores=1)


# -- main --------------------------------------------------------------------


@pytest.fixture
def root(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("os.geteuid", lambda: 0)


def test_main_refuses_without_root(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr("os.geteuid", lambda: 1000)
    assert heat.main(["out.csv"]) == 2
    assert "needs root" in capsys.readouterr().err


def fake_sources(tmp_path: Path) -> Callable[..., Sources]:
    clock = Clock()
    return functools.partial(
        Sources, spawn=Spawner(), clock=clock.time, wallclock=clock.time, sleep=clock.sleep
    )


@pytest.mark.usefixtures("root")
def test_main_runs_and_prints_a_line_per_governor(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    src, _, _ = sources(tmp_path)
    monkeypatch.setattr(heat, "Sources", fake_sources(tmp_path))
    args = ["--cpufreq", src.cpufreq, "--thermal", src.thermal, "--devfreq", src.devfreq]
    out = tmp_path / "heat.csv"
    code = heat.main(
        [
            str(out),
            "--governors",
            "performance",
            "schedutil",
            "--seconds",
            "10",
            "--rest",
            "0",
            "--no-mcu",
            *args,
        ]
    )
    assert code == 0
    lines = capsys.readouterr().out.splitlines()
    assert [line.split()[0] for line in lines] == ["performance", "schedutil"]
    assert len(read_csv(out)) == 4


@pytest.mark.usefixtures("root")
def test_main_opens_and_closes_the_mcu(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    events: list[str] = []

    class Opened(FakeMCU):
        def __enter__(self) -> Opened:
            events.append("open")
            return self

        def __exit__(self, *exc: object) -> None:
            events.append("close")

    src, _, _ = sources(tmp_path)
    monkeypatch.setattr(heat, "MCU", Opened)
    monkeypatch.setattr(heat, "Sources", fake_sources(tmp_path))
    out = tmp_path / "heat.csv"
    code = heat.main(
        [
            str(out),
            "--governors",
            "ondemand",
            "--seconds",
            "5",
            "--rest",
            "0",
            "--cpufreq",
            src.cpufreq,
            "--thermal",
            src.thermal,
        ]
    )
    assert code == 0
    assert events == ["open", "close"]
    assert read_csv(out)[0]["mcu_temp"] == "30.0"
    assert "MCU mean 30.0 C" in capsys.readouterr().out


@pytest.mark.usefixtures("root")
def test_main_explains_a_busy_port(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    def busy() -> None:
        raise MCUError("/dev/ttyHS1 is held by unoq-cpu-bars")

    monkeypatch.setattr(heat, "MCU", busy)
    assert heat.main(["out.csv"]) == 1
    assert "--no-mcu" in capsys.readouterr().err


@pytest.mark.usefixtures("root")
@pytest.mark.parametrize(
    ("error", "code", "said"),
    [
        (ValueError("policy0 does not offer 'turbo'"), 2, "does not offer"),
        (PermissionError("scaling_governor"), 1, "scaling_governor"),
        (KeyboardInterrupt(), 130, "interrupted; governor restored"),
        (Stopped(signal.SIGTERM), 143, "SIGTERM; governor restored"),
    ],
)
def test_main_reports_how_a_run_ended(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    error: BaseException,
    code: int,
    said: str,
) -> None:
    def failing(*args: object, **kw: object) -> list[Summary]:
        raise error

    monkeypatch.setattr(heat, "run", failing)
    assert heat.main(["out.csv", "--no-mcu"]) == code
    assert said in capsys.readouterr().err
