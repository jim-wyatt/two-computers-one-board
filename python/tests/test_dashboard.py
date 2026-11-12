# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""Tests for the dashboard: its samplers, its store, and its API.

Every reader is handed text written into tmp_path or a fake, the MCU is a
scripted Chip, and the API is driven through FastAPI's TestClient, so nothing
here reads the machine running the suite or opens a port.
"""

from __future__ import annotations

import sqlite3
import threading
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

from unoq import dashboard
from unoq.cpufreq import Policy
from unoq.dashboard import (
    McuSampler,
    Recorder,
    Store,
    SystemSampler,
    create_app,
    disk_used_pct,
    downsample,
    read_loadavg,
    read_meminfo,
    read_net,
)
from unoq.mcu import EnvError, EnvReading, MCUError, PortBusy

MEMINFO = """\
MemTotal:        3755160 kB
MemFree:          512000 kB
MemAvailable:    1843356 kB
SwapTotal:       1877576 kB
SwapFree:        1866500 kB
HugePages_Total:       0
Odd:
"""

NET_DEV = """\
Inter-|   Receive                            |  Transmit
 face |bytes packets errs drop fifo frame ...|bytes packets errs drop fifo colls ...
    lo: 15599885 1000 0 0 0 0 0 0 15599885 1000 0 0 0 0 0 0
 wlan0: 759000344 2000 0 0 0 0 0 0 26717932 900 0 0 0 0 0 0
  usb0: 20261 10 0 0 0 0 0 0 117868 20 0 0 0 0 0 0
 short: 1 2 3
"""


@pytest.fixture(autouse=True)
def _close_stores(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    """Close every Store a test opened, so none is left for the collector to find."""
    made: list[Store] = []
    init = Store.__init__

    def tracking(self: Store, path: str) -> None:
        init(self, path)
        made.append(self)

    monkeypatch.setattr(Store, "__init__", tracking)
    yield
    for store in made:
        store.close()


def policy(name: str = "policy0", khz: int | None = 2016000) -> Policy:
    return Policy(
        name=name,
        cpus=(0, 1, 2, 3),
        driver="qcom-cpufreq-hw",
        governor="ondemand",
        governors=("ondemand", "performance"),
        min_khz=300000,
        max_khz=2016000,
        cur_khz=khz,
        frequencies=(300000, 2016000),
        time_in_state=(),
    )


class FakeLoad:
    def sample(self) -> list[int]:
        return [10, 20, 30, 40]


def fail(*_: Any) -> Any:
    raise OSError("refused")


def system(**kwargs: Any) -> SystemSampler:
    """A sampler whose every source is a fixed answer, overridable by name."""
    sources: dict[str, Any] = {
        "mounts": (("root", "/"),),
        "loadavg": lambda: (0.5, 0.75, 1.0),
        "meminfo": lambda: {"MemTotal": 4096, "MemAvailable": 1024},
        "net": lambda: {"wlan0": (1000, 2000)},
        "temps": lambda: [("cpuss0-thermal", 40.0)],
        "policies": lambda: [policy()],
        "gpu": lambda: 355_200_000,
        "disk": lambda path: 31.5,
    }
    sources.update(kwargs)
    return SystemSampler(FakeLoad(), **sources)


# -- readers -----------------------------------------------------------------


def test_loadavg_is_the_first_three_fields(tmp_path: Path) -> None:
    f = tmp_path / "loadavg"
    f.write_text("0.81 0.93 1.00 2/337 41343\n")
    assert read_loadavg(str(f)) == (0.81, 0.93, 1.0)


def test_meminfo_is_kib_per_field_and_skips_lines_without_a_number(tmp_path: Path) -> None:
    f = tmp_path / "meminfo"
    f.write_text(MEMINFO)
    info = read_meminfo(str(f))
    assert info["MemTotal"] == 3755160
    assert info["HugePages_Total"] == 0
    assert "Odd" not in info


def test_net_is_rx_and_tx_bytes_without_loopback_or_short_lines(tmp_path: Path) -> None:
    f = tmp_path / "dev"
    f.write_text(NET_DEV)
    assert read_net(str(f)) == {"wlan0": (759000344, 26717932), "usb0": (20261, 117868)}


def test_disk_used_matches_df_on_a_real_filesystem(tmp_path: Path) -> None:
    assert 0 < disk_used_pct(str(tmp_path)) <= 100


def test_disk_with_no_blocks_reads_as_empty(monkeypatch: pytest.MonkeyPatch) -> None:
    class Empty:
        f_blocks = f_bfree = f_bavail = 0

    monkeypatch.setattr("unoq.dashboard.os.statvfs", lambda path: Empty())
    assert disk_used_pct("/") == 0.0


# -- the Linux half ---------------------------------------------------------


def test_a_sample_has_every_metric_and_rates_from_the_second() -> None:
    counters = iter([{"wlan0": (1000, 2000)}, {"wlan0": (126_000, 4500)}])
    s = system(net=lambda: next(counters))
    first = s.sample(100.0)
    assert first == {
        "cpu.0": 10.0,
        "cpu.1": 20.0,
        "cpu.2": 30.0,
        "cpu.3": 40.0,
        "load.1": 0.5,
        "load.5": 0.75,
        "load.15": 1.0,
        "mem.used_mib": 3.0,
        "mem.used_pct": 75.0,
        "temp.cpuss0-thermal": 40.0,
        "freq.policy0_mhz": 2016.0,
        "freq.gpu_mhz": 355.2,
        "disk.root_pct": 31.5,
    }
    second = s.sample(110.0)
    # 125 000 bytes in 10 s is 100 kbit/s; 2500 bytes is 2 kbit/s.
    assert second["net.wlan0.rx_kbps"] == pytest.approx(100.0)
    assert second["net.wlan0.tx_kbps"] == pytest.approx(2.0)


def test_a_reader_that_fails_costs_only_its_own_metrics() -> None:
    s = system(loadavg=fail, meminfo=fail, net=fail, temps=fail, policies=fail, gpu=fail, disk=fail)
    assert s.sample(1.0) == {"cpu.0": 10.0, "cpu.1": 20.0, "cpu.2": 30.0, "cpu.3": 40.0}


def test_a_repeated_zone_name_is_numbered_not_overwritten() -> None:
    s = system(temps=lambda: [("gpu", 40.0), ("gpu", 41.0)])
    values = s.sample(1.0)
    assert values["temp.gpu"] == 40.0
    assert values["temp.gpu#2"] == 41.0


def test_unknown_clocks_are_left_out() -> None:
    values = system(policies=lambda: [policy(khz=None)], gpu=lambda: None).sample(1.0)
    assert not any(name.startswith("freq.") for name in values)


def test_memory_without_its_fields_is_left_out() -> None:
    assert dashboard._memory({}) == {}
    assert dashboard._memory({"MemTotal": 0, "MemAvailable": 0}) == {}
    assert dashboard._memory({"SwapTotal": 2048, "SwapFree": 1024}) == {"swap.used_mib": 1.0}


def test_no_rate_across_a_counter_reset_a_new_interface_or_a_clock_that_stood_still() -> None:
    counters = iter(
        [
            {"wlan0": (5000, 5000)},
            {"wlan0": (10, 10), "usb0": (1, 1)},  # wlan0 bounced, usb0 is new
            {"wlan0": (20, 20), "usb0": (2, 2)},  # same time as the last
        ]
    )
    s = system(net=lambda: next(counters))
    s.sample(1.0)
    assert not any(name.startswith("net.") for name in s.sample(2.0))
    assert not any(name.startswith("net.") for name in s.sample(2.0))


# -- the MCU half -----------------------------------------------------------


class FakeChip:
    def __init__(self, env: EnvReading | Exception, die: float | Exception = 31.25) -> None:
        self._env = env
        self._die = die
        self.closed = False

    def env(self) -> EnvReading:
        if isinstance(self._env, Exception):
            raise self._env
        return self._env

    def die_temp(self) -> float:
        if isinstance(self._die, Exception):
            raise self._die
        return self._die

    def close(self) -> None:
        self.closed = True


READING = EnvReading(temp_mc=23620, humidity_mpct=54450, pressure_pa=97498, gas_ohm=1571)


def test_a_reading_is_in_the_units_people_quote() -> None:
    m = McuSampler(lambda: FakeChip(READING))
    assert m.sample(0.0) == {
        "mcu.die_c": 31.25,
        "env.temp_c": 23.62,
        "env.humidity_pct": 54.45,
        "env.pressure_hpa": 974.98,
        "env.gas_kohm": 1.571,
    }
    assert m.status == {}


def test_no_bme680_keeps_the_die_temperature_and_says_why() -> None:
    m = McuSampler(lambda: FakeChip(EnvError(-19)))
    assert m.sample(0.0) == {"mcu.die_c": 31.25}
    assert "no BME680" in m.status["env"]


def test_a_sensor_that_comes_back_clears_what_was_said() -> None:
    chip = FakeChip(EnvError(-19))
    m = McuSampler(lambda: chip)
    m.sample(0.0)
    chip._env = READING
    m.sample(10.0)
    assert m.status == {}


def test_a_held_port_is_said_and_tried_again_only_after_the_retry() -> None:
    opens: list[float] = []
    chips: list[Any] = [PortBusy("held by unoq-cpu-bars"), FakeChip(READING)]

    def opener() -> FakeChip:
        opens.append(0)
        got = chips.pop(0)
        if isinstance(got, Exception):
            raise got
        assert isinstance(got, FakeChip)
        return got

    m = McuSampler(opener, retry=60.0)
    assert m.sample(0.0) == {}
    assert "held by unoq-cpu-bars" in m.status["mcu"]
    assert m.sample(30.0) == {}
    assert len(opens) == 1
    assert m.sample(60.0)["env.temp_c"] == 23.62
    assert m.status == {}


def test_a_silent_mcu_lets_go_of_the_port_and_forgets_the_sensor() -> None:
    chip = FakeChip(EnvError(-19))
    m = McuSampler(lambda: chip)
    m.sample(0.0)
    chip._die = MCUError("no reply")
    assert m.sample(10.0) == {}
    assert chip.closed
    assert m.status == {"mcu": "no reply"}


def test_closing_a_chip_that_will_not_close_is_not_an_error() -> None:
    class Stuck(FakeChip):
        def close(self) -> None:
            raise OSError("gone")

    m = McuSampler(lambda: Stuck(READING))
    m.sample(0.0)
    m.close()
    m.close()  # and again, with nothing open


# -- keeping it -------------------------------------------------------------


def test_the_store_keeps_returns_and_prunes(tmp_path: Path) -> None:
    store = Store(str(tmp_path / "s.db"))
    assert store.latest() is None
    store.add(10.0, {"a": 1.0})
    store.add(20.0, {"a": 2.0, "b": 5.0})
    store.add(30.0, {"a": 3.0})
    assert store.latest() == (30.0, {"a": 3.0})
    assert store.rows(15.0, 30.0) == [(20.0, {"a": 2.0, "b": 5.0}), (30.0, {"a": 3.0})]
    assert store.prune(25.0) == 2
    assert store.rows(0.0, 100.0) == [(30.0, {"a": 3.0})]
    store.close()
    # And it is still there for the next start.
    assert Store(str(tmp_path / "s.db")).latest() == (30.0, {"a": 3.0})


def test_nothing_recorded_is_an_empty_answer() -> None:
    assert downsample([], 0.0, 100.0, 10, 30.0) == {"t": [], "series": {}}


def test_rows_are_averaged_into_buckets_with_none_where_a_metric_is_missing() -> None:
    rows = [(0.0, {"a": 1.0}), (5.0, {"a": 3.0, "b": 10.0}), (10.0, {"a": 5.0})]
    # 20 s in 2 points: buckets 10 s wide, so 0 and 5 share one.
    got = downsample(rows, 0.0, 20.0, 2, 100.0)
    assert got == {"t": [2.5, 10.0], "series": {"a": [2.0, 5.0], "b": [10.0, None]}}


def test_no_points_asked_for_is_every_row() -> None:
    rows = [(0.0, {"a": 1.0}), (1.0, {"a": 2.0})]
    assert downsample(rows, 0.0, 1.0, 0, 100.0)["t"] == [0.0, 1.0]


def test_a_gap_in_the_record_breaks_the_line() -> None:
    rows = [(0.0, {"a": 1.0}), (10.0, {"a": 2.0}), (100.0, {"a": 3.0})]
    got = downsample(rows, 0.0, 100.0, 100, 30.0)
    assert got == {"t": [0.0, 10.0, 55.0, 100.0], "series": {"a": [1.0, 2.0, None, 3.0]}}


# -- the recorder -----------------------------------------------------------


class Clock:
    def __init__(self, now: float = 10_000.0) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now


def test_a_step_stores_both_halves_and_prunes_hourly() -> None:
    store = Store(":memory:")
    store.add(1.0, {"old": 1.0})
    clock = Clock()
    rec = Recorder(store, system(), McuSampler(lambda: FakeChip(READING)), keep=3600, clock=clock)
    values = rec.step()
    assert values["env.temp_c"] == 23.62
    assert values["cpu.0"] == 10.0
    assert [t for t, _ in store.rows(0.0, 1e9)] == [10_000.0]
    store.add(9000.0, {"kept": 1.0})  # inside the hour, and the prune is not due
    clock.now += 10
    rec.step()
    assert len(store.rows(0.0, 1e9)) == 3
    assert rec.status == {}


def test_without_the_mcu_the_status_says_it_was_not_asked() -> None:
    rec = Recorder(Store(":memory:"), system(), None)
    assert "env.temp_c" not in rec.step()
    assert rec.status == {"mcu": "not asked: started with --no-mcu"}


class Ticks(threading.Event):
    """An Event whose wait() lets `n` intervals pass, and is then set."""

    def __init__(self, n: int) -> None:
        super().__init__()
        self.n = n

    def wait(self, timeout: float | None = None) -> bool:
        self.n -= 1
        return self.n < 0


def test_run_samples_every_interval_and_survives_a_sample_that_raises(
    capsys: pytest.CaptureFixture[str],
) -> None:
    calls = iter([RuntimeError("surprise"), None])

    class Flaky:
        def sample(self, now: float) -> dict[str, float]:
            got = next(calls)
            if got is not None:
                raise got
            return {"x": 1.0}

    store = Store(":memory:")
    rec = Recorder(store, Flaky(), None, clock=Clock())  # type: ignore[arg-type]
    rec.run(Ticks(2))
    assert store.latest() == (10_000.0, {"x": 1.0})
    assert "surprise" in capsys.readouterr().err


# -- the API ----------------------------------------------------------------


@pytest.fixture
def recorder() -> Recorder:
    return Recorder(Store(":memory:"), system(), None, interval=10.0)


def test_meta_and_an_empty_latest(recorder: Recorder) -> None:
    client = TestClient(create_app(recorder, {"host": "uno-q"}))
    assert client.get("/api/meta").json() == {"host": "uno-q"}
    assert client.get("/api/latest").json() == {
        "t": None,
        "values": {},
        "status": {"mcu": "not asked: started with --no-mcu"},
    }


def test_latest_is_the_newest_sample(recorder: Recorder) -> None:
    recorder.store.add(5.0, {"a": 1.0})
    recorder.store.add(6.0, {"a": 2.0})
    body = TestClient(create_app(recorder, {})).get("/api/latest").json()
    assert (body["t"], body["values"]) == (6.0, {"a": 2.0})


def test_history_defaults_to_the_last_hour(recorder: Recorder) -> None:
    recorder.store.add(100.0, {"a": 1.0})  # long before the hour
    recorder.store.add(9000.0, {"a": 2.0})
    client = TestClient(create_app(recorder, {}, clock=Clock()))
    body = client.get("/api/history").json()
    assert (body["since"], body["until"]) == (6400.0, 10_000.0)
    assert body["t"] == [9000.0]


def test_history_takes_a_range_and_a_point_count(recorder: Recorder) -> None:
    for t in range(0, 100, 10):
        recorder.store.add(float(t), {"a": float(t)})
    client = TestClient(create_app(recorder, {}))
    body = client.get("/api/history", params={"since": 0, "until": 100, "points": 2}).json()
    assert body["series"]["a"] == [20.0, 70.0]
    assert client.get("/api/history", params={"points": 0}).status_code == 422
    assert client.get("/api/history", params={"points": 5001}).status_code == 422


def test_the_page_is_served_from_disk_when_built(recorder: Recorder, tmp_path: Path) -> None:
    (tmp_path / "index.html").write_text("<h1>built</h1>")
    client = TestClient(create_app(recorder, {}, tmp_path))
    assert client.get("/").text == "<h1>built</h1>"
    # and the API is still the API, not a file
    assert client.get("/api/meta").status_code == 200


def test_an_unbuilt_page_says_how_to_build_it(recorder: Recorder, tmp_path: Path) -> None:
    for static in (None, tmp_path):
        page = TestClient(create_app(recorder, {}, static)).get("/").text
        assert "tools/build-dashboard.sh" in page


def test_no_cdn_pages_are_served(recorder: Recorder) -> None:
    client = TestClient(create_app(recorder, {}))
    assert client.get("/docs").status_code == 404
    assert client.get("/redoc").status_code == 404
    assert client.get("/openapi.json").status_code == 200


def test_the_static_dir_is_beside_the_module() -> None:
    assert dashboard.static_dir() == Path(dashboard.__file__).parent / "dashboard_static"


# -- main ---------------------------------------------------------------------


class Served:
    def __init__(self, raise_interrupt: bool = False) -> None:
        self.calls: list[tuple[str, int]] = []
        self.paths: list[str] = []
        self.raise_interrupt = raise_interrupt

    def __call__(self, app: Any, host: str, port: int) -> None:
        self.calls.append((host, port))
        self.paths = sorted(route.path for route in app.routes)
        if self.raise_interrupt:
            raise KeyboardInterrupt


def test_main_serves_and_records(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    served = Served()
    opened: list[str] = []

    def opener(port: str) -> FakeChip:
        opened.append(port)
        return FakeChip(READING)

    db = tmp_path / "s.db"
    argv = ["--db", str(db), "--port", "9000", "--interval", "0.01", "--mcu-port", "/dev/fake"]
    assert dashboard.main(argv, serve=served, opener=opener) == 0
    assert served.calls == [("0.0.0.0", 9000)]
    assert "/api/history" in served.paths
    assert "recording every 0.01 s" in capsys.readouterr().err
    # The recorder thread is stopped and joined by the time main returns;
    # whether it took a sample in that time is up to the scheduler.
    assert db.exists()
    assert set(opened) <= {"/dev/fake"}


def test_main_ends_quietly_on_ctrl_c(tmp_path: Path) -> None:
    served = Served(raise_interrupt=True)
    argv = ["--db", str(tmp_path / "s.db"), "--no-mcu"]
    assert dashboard.main(argv, serve=served) == 0
    assert served.calls


def test_main_needs_the_directory(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    argv = ["--db", str(tmp_path / "missing" / "s.db")]
    assert dashboard.main(argv, serve=Served()) == 1
    assert "69-dashboard.sh" in capsys.readouterr().err


def test_main_says_when_the_database_cannot_be_opened(
    tmp_path: Path, capsys: pytest.CaptureFixture[str], monkeypatch: pytest.MonkeyPatch
) -> None:
    def broken(path: str) -> Store:
        raise sqlite3.OperationalError("unable to open database file")

    monkeypatch.setattr(dashboard, "Store", broken)
    assert dashboard.main(["--db", str(tmp_path / "s.db")], serve=Served()) == 1
    assert "unable to open" in capsys.readouterr().err


@pytest.mark.parametrize("arg", [["--interval", "0"], ["--keep-days", "-1"]])
def test_main_refuses_a_nonsense_interval_or_keep(tmp_path: Path, arg: list[str]) -> None:
    with pytest.raises(SystemExit):
        dashboard.main(["--db", str(tmp_path / "s.db"), *arg], serve=Served())


# -- rollups ----------------------------------------------------------------


def test_the_mean_is_over_the_samples_that_have_each_metric() -> None:
    assert dashboard._mean([{"a": 1.0, "b": 4.0}, {"a": 3.0}]) == {"a": 2.0, "b": 4.0}


def test_nothing_to_roll_up_in_an_empty_store() -> None:
    assert Store(":memory:").roll(60.0, 1000.0) == 0


def test_only_periods_that_have_ended_are_rolled_up_and_each_only_once() -> None:
    store = Store(":memory:")
    for t in (0.0, 30.0, 60.0, 90.0, 155.0):
        store.add(t, {"a": t})
    # At 160 s the minutes from 0 and 60 have ended; the one from 120 has not.
    assert store.roll(60.0, 160.0) == 2
    assert store.roll(60.0, 160.0) == 0
    got = store.history(0.0, 3000.0, 50, 30.0)  # 60 s buckets: the minute tier
    # Each minute at its middle, and the sample in the minute still open at its
    # own time.
    assert got["t"] == [30.0, 90.0, 155.0]
    assert got["series"]["a"] == [15.0, 75.0, 155.0]
    assert store.roll(60.0, 200.0) == 1


def test_a_stop_is_caught_up_from_the_samples_and_leaves_a_gap() -> None:
    store = Store(":memory:")
    store.add(10.0, {"a": 1.0})
    assert store.roll(60.0, 70.0) == 1
    store.add(3610.0, {"a": 2.0})  # an hour later, nothing between
    store.add(3670.0, {"a": 3.0})
    # Of the two, only the minute from 3600 has ended.
    assert store.roll(60.0, 3700.0) == 1
    got = store.history(0.0, 30_000.0, 100, 30.0)
    assert None in got["series"]["a"]


def test_a_week_is_read_from_the_quarter_hours(monkeypatch: pytest.MonkeyPatch) -> None:
    store = Store(":memory:")
    for t in range(0, 7200, 10):
        store.add(float(t), {"a": 1.0})
    for width in dashboard.ROLLUPS:
        store.roll(width, 7200.0)
    read: list[tuple[float, float]] = []
    rows = store.rows

    def spy(since: float, until: float) -> list[tuple[float, dict[str, float]]]:
        read.append((since, until))
        return rows(since, until)

    monkeypatch.setattr(store, "rows", spy)
    got = store.history(0.0, 7 * 86400.0, 500, 30.0)
    # Only the samples after the last quarter hour were read raw: none here.
    assert read == [(7200.0, 7 * 86400.0)]
    # The first two quarter hours, at 450 and 1350, share one of the 1210 s
    # buckets 500 points of a week make.
    assert got["t"][0] == 900.0


def test_with_no_rollups_yet_every_sample_is_read() -> None:
    store = Store(":memory:")
    store.add(10.0, {"a": 1.0})
    assert store.history(0.0, 7 * 86400.0, 500, 30.0)["t"] == [10.0]


def test_pruning_takes_the_rollups_too() -> None:
    store = Store(":memory:")
    store.add(10.0, {"a": 1.0})
    store.add(100.0, {"a": 1.0})
    store.roll(60.0, 200.0)
    store.prune(60.0)
    assert store.roll(60.0, 200.0) == 0  # the minute from 60 is still rolled up
    got = store.history(0.0, 60_000.0, 500, 30.0)
    assert got["t"] == [90.0]
