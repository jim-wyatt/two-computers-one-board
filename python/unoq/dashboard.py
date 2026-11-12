# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""
A dashboard in the browser: the air around the board, and the board itself, over time.

    unoq-dashboard                             # :8090, into /var/lib/unoq/dashboard
    python -m unoq.dashboard --db ./samples.db --port 9000 --interval 2
    unoq-dashboard --no-mcu                    # the Linux side only; the port stays free

Every interval it takes one sample of everything it can read, and keeps it:

- from the MCU, over the shell: the BME680 on the header's I2C (`app env`), and
  the STM32's die temperature (`app temp`), which Linux has no view of
- from Linux: busy per core, the load average, memory and swap, every thermal
  zone, each cpufreq policy's clock and the GPU's, the bytes each network
  interface moved, and how full the root and home filesystems are

A sample is a flat dict of metric name to number, `env.temp_c` or `cpu.2`, and
is stored as one row of JSON in SQLite. Seven days at ten seconds is about
60 000 rows and a few tens of MB. The browser asks for a time range and gets it
back averaged into at most a few hundred points per metric, so a week costs it
no more than an hour does.

Two halves that fail apart. The MCU half needs the serial port, which has one
owner (see unoq-cpu-bars.service), and a firmware with `app env`. When it is
not there - the port is held, the MCU is silent, no BME680 answered at boot -
the Linux half records as before, the API says what is missing, and the MCU is
tried again a minute later. A metric that could not be read is left out of the
sample, never written as zero: the graph shows a gap, which is the truth.

The page itself is a React app, built once into dashboard_static/ (see
web/dashboard/README.md for why the build is committed) and served from disk.
Nothing here fetches anything, for the reason unoq.learn gives: the board is
often on a cable to a laptop with no internet at all. That is also why
FastAPI's own /docs pages are turned off - they load their scripts from a CDN.
The API is described at /openapi.json.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import math
import os
import socket
import sqlite3
import sys
import threading
from collections.abc import Callable, Iterator, Sequence
from importlib import resources
from pathlib import Path
from time import time as _time
from typing import Any, Protocol

from . import __version__
from .cpu import PROC_STAT, CpuSampler
from .cpufreq import SYS_CPUFREQ, Policy, read_policies
from .heat import SYS_DEVFREQ, gpu_hz
from .mcu import MCU, PORT, EnvError, EnvReading, MCUError
from .thermal import SYS_THERMAL, read_temps

DEFAULT_DB = "/var/lib/unoq/dashboard/samples.db"
# unoq-learn has 8080. One port up from it would read as the same server.
DEFAULT_PORT = 8090
DEFAULT_HOST = "0.0.0.0"
# A BME680 forced read is about 200 ms of hot plate, and the gas figure is
# steadier read slowly. Ten seconds also matches the temperature logger.
DEFAULT_INTERVAL = 10.0
DEFAULT_KEEP_DAYS = 7.0
# How long a silent MCU, or a held port, is left before it is tried again.
# Each try is a port open and up to a shell timeout; a minute keeps that off
# the sampling, and a port given back is picked up within one.
MCU_RETRY = 60.0
# Pruning deletes on an index and is cheap, but once an hour is often enough to
# keep the file within an hour of the limit.
PRUNE_EVERY = 3600.0
# Points per metric a history answer is averaged down to, by default and at
# most. A chart is a few hundred pixels wide; more points than that are not
# seen, only downloaded.
DEFAULT_POINTS = 600
MAX_POINTS = 5000
# The history an answer covers when the page does not say.
DEFAULT_SPAN = 3600.0
# The periods samples are averaged over as they end, in seconds (see Store):
# a minute, for a day's chart, and a quarter hour, for a week's.
ROLLUPS = (60.0, 900.0)

PROC_LOADAVG = "/proc/loadavg"
PROC_MEMINFO = "/proc/meminfo"
PROC_NET_DEV = "/proc/net/dev"
# (label, mount point): what disk.<label>_pct means. /home/arduino is its own
# partition on this board, and the one that fills first.
DEFAULT_MOUNTS = (("root", "/"), ("home", str(Path.home())))

Values = dict[str, float]


# -- the Linux half ------------------------------------------------------------


def read_loadavg(path: str = PROC_LOADAVG) -> tuple[float, float, float]:
    """The 1, 5 and 15 minute load averages."""
    one, five, fifteen = Path(path).read_text().split()[:3]
    return float(one), float(five), float(fifteen)


def read_meminfo(path: str = PROC_MEMINFO) -> dict[str, int]:
    """/proc/meminfo as field name to kibibytes.

    The kernel writes "kB" and means KiB. Lines without a number - there are
    none today, but proc(5) promises nothing - are left out.
    """
    out: dict[str, int] = {}
    for line in Path(path).read_text().splitlines():
        name, _, rest = line.partition(":")
        fields = rest.split()
        if fields and fields[0].isdigit():
            out[name.strip()] = int(fields[0])
    return out


def read_net(path: str = PROC_NET_DEV) -> dict[str, tuple[int, int]]:
    """Bytes received and sent per interface since it came up, loopback left out.

    Loopback is the board talking to itself - this server answering the page,
    for one - and charted it would mostly measure the chart.
    """
    out: dict[str, tuple[int, int]] = {}
    # Two header lines, then "  name: rx_bytes rx_packets ... tx_bytes ...":
    # eight receive counters, and the first transmit one is the ninth field.
    for line in Path(path).read_text().splitlines()[2:]:
        name, _, rest = line.partition(":")
        fields = rest.split()
        name = name.strip()
        if name == "lo" or len(fields) < 9:
            continue
        out[name] = (int(fields[0]), int(fields[8]))
    return out


def disk_used_pct(path: str) -> float:
    """How full the filesystem holding path is, as df counts it.

    df's Use% leaves out the blocks reserved for root, so a filesystem it calls
    100% full still has a little for root. Matching it means the dashboard and
    the terminal agree.
    """
    st = os.statvfs(path)
    used = st.f_blocks - st.f_bfree
    usable = used + st.f_bavail
    return 100 * used / usable if usable else 0.0


class Load(Protocol):
    def sample(self) -> list[int]: ...


class SystemSampler:
    """One reading of everything Linux knows about itself, as a flat dict.

    Keeps the state that a rate needs: the CPU counters (inside `cpu`) and the
    network counters, both differences between successive calls. So the first
    sample has no network rates, and every reader that fails leaves its
    metrics out instead of stopping the rest.
    """

    def __init__(
        self,
        cpu: Load,
        mounts: Sequence[tuple[str, str]] = DEFAULT_MOUNTS,
        loadavg: Callable[[], tuple[float, float, float]] = read_loadavg,
        meminfo: Callable[[], dict[str, int]] = read_meminfo,
        net: Callable[[], dict[str, tuple[int, int]]] = read_net,
        temps: Callable[[], list[tuple[str, float]]] = read_temps,
        policies: Callable[[], list[Policy]] = read_policies,
        gpu: Callable[[], int | None] = gpu_hz,
        disk: Callable[[str], float] = disk_used_pct,
    ) -> None:
        self._cpu = cpu
        self._mounts = mounts
        self._loadavg = loadavg
        self._meminfo = meminfo
        self._net = net
        self._temps = temps
        self._policies = policies
        self._gpu = gpu
        self._disk = disk
        self._prev_net: tuple[float, dict[str, tuple[int, int]]] | None = None

    def sample(self, now: float) -> Values:
        out: Values = {}
        with _skip_unreadable():
            for core, pct in enumerate(self._cpu.sample()):
                out[f"cpu.{core}"] = float(pct)
        with _skip_unreadable():
            out["load.1"], out["load.5"], out["load.15"] = self._loadavg()
        with _skip_unreadable():
            out.update(_memory(self._meminfo()))
        with _skip_unreadable():
            # Zone types repeat on some kernels (see thermal.read_temps);
            # the second of a name becomes name#2, as unoq.powerlog has it.
            seen: dict[str, int] = {}
            for name, celsius in self._temps():
                seen[name] = seen.get(name, 0) + 1
                suffix = "" if seen[name] == 1 else f"#{seen[name]}"
                out[f"temp.{name}{suffix}"] = celsius
        with _skip_unreadable():
            for policy in self._policies():
                if policy.cur_khz is not None:
                    out[f"freq.{policy.name}_mhz"] = policy.cur_khz / 1000
        with _skip_unreadable():
            hz = self._gpu()
            if hz is not None:
                out["freq.gpu_mhz"] = hz / 1e6
        with _skip_unreadable():
            out.update(self._net_rates(now, self._net()))
        for label, path in self._mounts:
            with _skip_unreadable():
                out[f"disk.{label}_pct"] = self._disk(path)
        return out

    def _net_rates(self, now: float, counters: dict[str, tuple[int, int]]) -> Values:
        out: Values = {}
        prev = self._prev_net
        self._prev_net = (now, counters)
        if prev is None or now <= prev[0]:
            return out
        elapsed = now - prev[0]
        for name, (rx, tx) in counters.items():
            before = prev[1].get(name)
            # An interface that went down and up again starts its counters at
            # zero. The difference across that is not a rate; skip one sample.
            if before is None or rx < before[0] or tx < before[1]:
                continue
            # kbit/s, the unit a link's speed is quoted in.
            out[f"net.{name}.rx_kbps"] = (rx - before[0]) * 8 / 1000 / elapsed
            out[f"net.{name}.tx_kbps"] = (tx - before[1]) * 8 / 1000 / elapsed
        return out


def _memory(info: dict[str, int]) -> Values:
    """Memory in use, as `free` counts it: everything the kernel could not hand out now."""
    out: Values = {}
    total = info.get("MemTotal")
    available = info.get("MemAvailable")
    if total and available is not None:
        out["mem.used_mib"] = (total - available) / 1024
        out["mem.used_pct"] = 100 * (total - available) / total
    swap_total = info.get("SwapTotal")
    swap_free = info.get("SwapFree")
    if swap_total is not None and swap_free is not None:
        out["swap.used_mib"] = (swap_total - swap_free) / 1024
    return out


@contextlib.contextmanager
def _skip_unreadable() -> Iterator[None]:
    """Leave out what could not be read, and carry on with the rest.

    OSError is a file that is missing or refused; ValueError is one that said
    something that is not a number. Either way the metric is absent from this
    sample, which the graph shows as a gap.
    """
    with contextlib.suppress(OSError, ValueError):
        yield


# -- the MCU half --------------------------------------------------------------


class Chip(Protocol):
    def env(self) -> EnvReading: ...
    def die_temp(self) -> float: ...
    def close(self) -> None: ...


class McuSampler:
    """The BME680 and the die temperature, with the port opened when it can be.

    `status` says, in a sentence each, what this half could not read last
    time: "mcu" for the MCU itself (the port, a silence, an old firmware) and
    "env" for the BME680. A key that is absent means that part read.
    """

    def __init__(
        self,
        opener: Callable[[], Chip],
        retry: float = MCU_RETRY,
    ) -> None:
        self._opener = opener
        self._retry = retry
        self._chip: Chip | None = None
        self._next_try = 0.0
        self.status: dict[str, str] = {}

    def sample(self, now: float) -> Values:
        out: Values = {}
        if self._chip is None:
            if now < self._next_try:
                return out
            try:
                self._chip = self._opener()
            except (MCUError, OSError) as exc:
                self._give_up(now, f"could not open the MCU's port: {exc}")
                return out
            self.status.pop("mcu", None)
        chip = self._chip
        try:
            out["mcu.die_c"] = chip.die_temp()
            try:
                r = chip.env()
            except EnvError as exc:
                self.status["env"] = str(exc)
            else:
                self.status.pop("env", None)
                out["env.temp_c"] = r.temp_c
                out["env.humidity_pct"] = r.humidity_pct
                out["env.pressure_hpa"] = r.pressure_hpa
                # kilohms: a fresh part reads a few, a settled one hundreds.
                out["env.gas_kohm"] = r.gas_ohm / 1000
        except (MCUError, OSError) as exc:
            # Anything but "no BME680" is the MCU or the link, and the port is
            # let go: a reset MCU, or one that is being updated, is better
            # found by opening it again than by talking into a stale handle.
            self.close()
            self._give_up(now, str(exc))
        return out

    def _give_up(self, now: float, why: str) -> None:
        self.status["mcu"] = why
        # The BME680 is behind the MCU: with no MCU there is no saying.
        self.status.pop("env", None)
        self._next_try = now + self._retry

    def close(self) -> None:
        if self._chip is not None:
            with contextlib.suppress(MCUError, OSError):
                self._chip.close()
            self._chip = None


# -- keeping it ---------------------------------------------------------------


class Store:
    """Samples in SQLite: one row per sample, its metrics as JSON.

    JSON rather than a column per metric, because which metrics there are is
    the board's business - a thermal zone appears with a kernel, an interface
    with a cable - and a schema that had to change with them would be a
    migration per USB stick.

    One connection, shared by the recorder's thread and the API's, behind a
    lock: SQLite is safe across threads only one at a time, and at one write
    every ten seconds there is nothing to gain from more.

    Beside the samples, ROLLUPS: each whole minute and quarter hour, averaged
    once when it ends. A week of samples is 60 000 rows, and reading and
    averaging them all took this board 7.7 s - every poll, which a page left
    on "7 days" sends every ten seconds. The same week is 672 quarter hours,
    read in a few hundredths of a second. history() picks the coarsest
    rollup that still gives the points asked for.
    """

    def __init__(self, path: str) -> None:
        self._db = sqlite3.connect(path, check_same_thread=False)
        self._lock = threading.Lock()
        with self._lock, self._db:
            # WAL: a reader does not wait for the writer, and a power cut
            # costs at most the last sample.
            self._db.execute("PRAGMA journal_mode=WAL")
            self._db.execute("CREATE TABLE IF NOT EXISTS samples (t REAL PRIMARY KEY, data TEXT)")
            # t is when the period began; width is how long it is, in seconds.
            self._db.execute(
                "CREATE TABLE IF NOT EXISTS rollups"
                " (width REAL, t REAL, data TEXT, PRIMARY KEY (width, t))"
            )

    def add(self, t: float, values: Values) -> None:
        with self._lock, self._db:
            self._db.execute(
                "INSERT OR REPLACE INTO samples VALUES (?, ?)", (t, json.dumps(values))
            )

    def prune(self, before: float) -> int:
        """Delete every sample and rollup older than before. Returns how many samples went."""
        with self._lock, self._db:
            self._db.execute("DELETE FROM rollups WHERE t < ?", (before,))
            return self._db.execute("DELETE FROM samples WHERE t < ?", (before,)).rowcount

    def roll(self, width: float, until: float) -> int:
        """Average every whole width-second period that ended by until and has no rollup yet.

        Returns how many were written. Called after each sample, this is
        usually none, and one each time a period ends. After a stop it is
        every period since the last rollup that has samples in it, worked out
        from the samples, which are kept as long as the rollups are.
        """
        end = math.floor(until / width) * width
        with self._lock:
            last = self._db.execute(
                "SELECT max(t) FROM rollups WHERE width = ?", (width,)
            ).fetchone()[0]
            if last is None:
                first = self._db.execute("SELECT min(t) FROM samples").fetchone()[0]
                if first is None:
                    return 0
                start = math.floor(first / width) * width
            else:
                start = last + width
            found = self._db.execute(
                "SELECT t, data FROM samples WHERE t >= ? AND t < ? ORDER BY t", (start, end)
            ).fetchall()
        periods: dict[float, list[Values]] = {}
        for t, data in found:
            periods.setdefault(math.floor(t / width) * width, []).append(json.loads(data))
        with self._lock, self._db:
            self._db.executemany(
                "INSERT OR REPLACE INTO rollups VALUES (?, ?, ?)",
                [(width, t, json.dumps(_mean(got))) for t, got in periods.items()],
            )
        return len(periods)

    def history(self, since: float, until: float, points: int, gap: float) -> dict[str, Any]:
        """downsample() of since to until, read from the coarsest tier that is fine enough.

        A tier is fine enough when its periods are no longer than the buckets
        downsample() will make. The rollups stop at the last period that has
        ended, so the samples after it are added on: the newest point on a
        week's chart is minutes old, not up to a quarter of an hour.
        """
        bucket = (until - since) / points if points > 0 else 0.0
        width = max((w for w in ROLLUPS if w <= bucket), default=0.0)
        if width == 0.0:
            return downsample(self.rows(since, until), since, until, points, gap)
        with self._lock:
            found = self._db.execute(
                "SELECT t, data FROM rollups WHERE width = ? AND t >= ? AND t <= ? ORDER BY t",
                (width, since, until),
            ).fetchall()
        # A period's point is its middle, which is where its average belongs.
        rows = [(t + width / 2, json.loads(data)) for t, data in found]
        tail = found[-1][0] + width if found else since
        rows += self.rows(tail, until)
        return downsample(rows, since, until, points, max(gap, 3 * width))

    def latest(self) -> tuple[float, Values] | None:
        with self._lock:
            row = self._db.execute("SELECT t, data FROM samples ORDER BY t DESC LIMIT 1").fetchone()
        return None if row is None else (row[0], json.loads(row[1]))

    def rows(self, since: float, until: float) -> list[tuple[float, Values]]:
        with self._lock:
            found = self._db.execute(
                "SELECT t, data FROM samples WHERE t >= ? AND t <= ? ORDER BY t",
                (since, until),
            ).fetchall()
        return [(t, json.loads(data)) for t, data in found]

    def close(self) -> None:
        with self._lock:
            self._db.close()


def _mean(samples: Sequence[Values]) -> Values:
    """Each metric's mean over the samples that have it."""
    sums: dict[str, float] = {}
    counts: dict[str, int] = {}
    for values in samples:
        for name, value in values.items():
            sums[name] = sums.get(name, 0.0) + value
            counts[name] = counts.get(name, 0) + 1
    return {name: sums[name] / counts[name] for name in sums}


def downsample(
    rows: Sequence[tuple[float, Values]],
    since: float,
    until: float,
    points: int,
    gap: float,
) -> dict[str, Any]:
    """rows, averaged into at most `points` time buckets, as columns.

    The answer is {"t": [...], "series": {metric: [...]}}, one list per metric
    as long as "t", with None where a metric had no reading in a bucket. That
    is the shape a chart takes, and no metric name is repeated per point.

    A bucket is the mean time and the mean of each metric over the samples in
    it. Where two buckets are more than `gap` apart, a row of None goes
    between them, so a chart breaks its line across a time nothing was
    recorded instead of drawing a straight one through it.
    """
    width = (until - since) / points if points > 0 else 0.0
    buckets: list[list[tuple[float, Values]]] = []
    for row in rows:
        if buckets and width > 0 and row[0] - buckets[-1][0][0] < width:
            buckets[-1].append(row)
        else:
            buckets.append([row])
    names = sorted({name for _, values in rows for name in values})
    t: list[float] = []
    series: dict[str, list[float | None]] = {name: [] for name in names}
    gap = max(gap, 2 * width)
    for bucket in buckets:
        when = sum(row[0] for row in bucket) / len(bucket)
        if t and when - t[-1] > gap:
            t.append((t[-1] + when) / 2)
            for name in names:
                series[name].append(None)
        t.append(when)
        for name in names:
            got = [values[name] for _, values in bucket if name in values]
            series[name].append(sum(got) / len(got) if got else None)
    return {"t": t, "series": series}


class Recorder:
    """Takes a sample from both halves every interval and stores it."""

    def __init__(
        self,
        store: Store,
        system: SystemSampler,
        mcu: McuSampler | None,
        interval: float = DEFAULT_INTERVAL,
        keep: float = DEFAULT_KEEP_DAYS * 86400,
        clock: Callable[[], float] = _time,
    ) -> None:
        self.store = store
        self.interval = interval
        self._system = system
        self._mcu = mcu
        self._keep = keep
        self._clock = clock
        self._last_prune = 0.0

    @property
    def status(self) -> dict[str, str]:
        if self._mcu is None:
            return {"mcu": "not asked: started with --no-mcu"}
        return dict(self._mcu.status)

    def step(self) -> Values:
        now = self._clock()
        values = self._system.sample(now)
        if self._mcu is not None:
            values.update(self._mcu.sample(now))
        self.store.add(now, values)
        for width in ROLLUPS:
            self.store.roll(width, now)
        if now - self._last_prune >= PRUNE_EVERY:
            self.store.prune(now - self._keep)
            self._last_prune = now
        return values

    def run(self, stop: threading.Event) -> None:
        """step() every interval until stop is set.

        Waits first, for the reason cpubars.run() does: busy per core is a
        difference between two readings, and the first needs an interval
        behind it. A sample that raises something unforeseen is said once on
        stderr, and the next one is tried: a recorder that stops on the first
        surprise leaves a page that looks live and is not.
        """
        while not stop.wait(self.interval):
            try:
                self.step()
            except Exception as exc:  # noqa: BLE001 - see the docstring
                print(f"unoq-dashboard: a sample failed: {exc!r}", file=sys.stderr)


# -- the API ------------------------------------------------------------------


def static_dir() -> Path:
    """Where the built page is: dashboard_static/, beside this module."""
    return Path(str(resources.files("unoq") / "dashboard_static"))


_NOT_BUILT = """<!doctype html><meta charset="utf-8"><title>UNO Q dashboard</title>
<p>The page has not been built. The API is up: <a href="/api/latest">/api/latest</a>.
Build the page with <code>tools/build-dashboard.sh</code>.</p>
"""


def create_app(
    recorder: Recorder,
    meta: dict[str, Any],
    static: Path | None = None,
    clock: Callable[[], float] = _time,
) -> Any:
    """The FastAPI application: /api/meta, /api/latest, /api/history, and the page.

    Typed Any on the way out so that importing this module for its samplers
    does not need FastAPI's types; the FastAPI import itself is here for the
    same reason, and costs a few hundred ms only when a server is made.
    """
    from fastapi import FastAPI, Query
    from fastapi.responses import HTMLResponse
    from fastapi.staticfiles import StaticFiles

    app = FastAPI(title="UNO Q dashboard", version=__version__, docs_url=None, redoc_url=None)
    store = recorder.store

    @app.get("/api/meta")
    def get_meta() -> dict[str, Any]:
        """What this server is: the host, its interval and how long it keeps."""
        return meta

    @app.get("/api/latest")
    def get_latest() -> dict[str, Any]:
        """The newest sample, and what could not be read."""
        found = store.latest()
        return {
            "t": None if found is None else found[0],
            "values": {} if found is None else found[1],
            "status": recorder.status,
        }

    @app.get("/api/history")
    def get_history(
        since: float | None = None,
        until: float | None = None,
        points: int = Query(DEFAULT_POINTS, ge=1, le=MAX_POINTS),
    ) -> dict[str, Any]:
        """Samples from since to until (Unix seconds), averaged into at most `points`.

        until defaults to now, and since to an hour before until.
        """
        end = clock() if until is None else until
        start = end - DEFAULT_SPAN if since is None else since
        out = store.history(start, end, points, 3 * recorder.interval)
        out.update(since=start, until=end)
        return out

    if static is not None and (static / "index.html").is_file():
        app.mount("/", StaticFiles(directory=static, html=True), name="page")
    else:

        @app.get("/", response_class=HTMLResponse)
        def not_built() -> str:
            return _NOT_BUILT

    return app


def _serve(app: Any, host: str, port: int) -> None:  # pragma: no cover - a real socket
    import uvicorn

    uvicorn.run(app, host=host, port=port, log_level="warning")


def main(
    argv: list[str] | None = None,
    serve: Callable[[Any, str, int], None] = _serve,
    opener: Callable[[str], Chip] = MCU,
) -> int:
    parser = argparse.ArgumentParser(
        prog="unoq-dashboard",
        description="Record the BME680 and the board's own stats, and graph them in a browser.",
    )
    parser.add_argument("--db", default=DEFAULT_DB, help=f"SQLite file (default {DEFAULT_DB})")
    parser.add_argument("--host", default=DEFAULT_HOST, help="address to listen on")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="port to listen on")
    parser.add_argument(
        "--interval", type=float, default=DEFAULT_INTERVAL, help="seconds between samples"
    )
    parser.add_argument(
        "--keep-days", type=float, default=DEFAULT_KEEP_DAYS, help="days of samples kept"
    )
    parser.add_argument(
        "--no-mcu", action="store_true", help="the Linux side only: never open the MCU's port"
    )
    parser.add_argument("--mcu-port", default=PORT, help="the serial port to the MCU")
    parser.add_argument("--stat", default=PROC_STAT, help="where to read CPU counters")
    parser.add_argument("--cpufreq", default=SYS_CPUFREQ, help="where to read cpufreq policies")
    parser.add_argument("--thermal", default=SYS_THERMAL, help="where to read thermal zones")
    parser.add_argument("--devfreq", default=SYS_DEVFREQ, help="where to read the GPU's clock")
    args = parser.parse_args(argv)
    if args.interval <= 0 or args.keep_days <= 0:
        parser.error("--interval and --keep-days must be more than zero")

    db = Path(args.db)
    if not db.parent.is_dir():
        print(
            f"unoq-dashboard: {db.parent} does not exist. "
            f"provision/69-dashboard.sh makes it; by hand, give --db a path in a directory "
            f"that does",
            file=sys.stderr,
        )
        return 1
    try:
        store = Store(str(db))
    except sqlite3.Error as err:
        print(f"unoq-dashboard: {db}: {err}", file=sys.stderr)
        return 1

    system = SystemSampler(
        CpuSampler(args.stat),
        temps=lambda: read_temps(args.thermal),
        policies=lambda: read_policies(args.cpufreq),
        gpu=lambda: gpu_hz(args.devfreq),
    )
    mcu = None if args.no_mcu else McuSampler(lambda: opener(args.mcu_port))
    recorder = Recorder(store, system, mcu, interval=args.interval, keep=args.keep_days * 86400)
    meta = {
        "host": socket.gethostname(),
        "version": __version__,
        "interval": args.interval,
        "keep_days": args.keep_days,
        "mcu": not args.no_mcu,
    }
    app = create_app(recorder, meta, static_dir())

    stop = threading.Event()
    thread = threading.Thread(target=recorder.run, args=(stop,), name="recorder", daemon=True)
    thread.start()
    print(
        f"unoq-dashboard: http://{args.host}:{args.port}/ - recording every "
        f"{args.interval:g} s into {db}",
        file=sys.stderr,
    )
    try:
        serve(app, args.host, args.port)
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        thread.join(timeout=args.interval + 5)
        if mcu is not None:
            mcu.close()
        store.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
