# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""
Keep the MCU's temperature log on Linux, with the host's own temperatures beside it.

    unoq-temp-log                              # into /var/lib/unoq/templog, every 10 s
    python -m unoq.templog --dir ./log --interval 2 --count 3

The MCU samples its die temperature once a second on its own timer, and keeps
the last ten minutes (mcu/app/src/templog.c). It does that whether or not
anyone is listening. This is the listener: every interval it asks for what is
new since the last sample it stored, and appends it to temps.csv. A daemon
that was stopped for five minutes catches up on all five when it starts again,
because the MCU kept them.

The two clocks are the point. Each sample carries the MCU's uptime when it was
taken; the Linux time in the row is worked out from that, backwards from the
moment of the pull, so a pull that ran late because Linux was busy still puts
every sample where it belongs.

Three things are written down rather than smoothed over, as a row with a note:
a gap (samples the MCU overwrote before they were read), an MCU restart (its
numbering started again), and nothing else. A missing point nobody notices is
the failure this exists to prevent.

It writes only into its directory: temps.csv, and once per start an index.html
that graphs it, which unoq-learn serves at /data/.
"""

from __future__ import annotations

import argparse
import csv
import math
import os
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from importlib import resources
from pathlib import Path
from time import sleep as _sleep
from time import time as _time
from typing import IO, Protocol

from .mcu import MCU, PORT, MCUError, TempLogStat, TempSample
from .thermal import SYS_THERMAL, read_temps

DEFAULT_DIR = "/var/lib/unoq/templog"
# The MCU holds ten minutes, so anything well under that loses nothing. Ten
# seconds is ten samples a pull: often enough that the graph looks live, and
# each pull is one round-trip of a few hundred bytes.
DEFAULT_INTERVAL = 10.0
CSV_NAME = "temps.csv"
PAGE_NAME = "index.html"

# The columns every file has, in this order. One `linux_<zone>` per thermal
# zone follows, chosen when the file is created.
BASE_COLUMNS = ["time", "seq", "mcu_ms", "mcu_temp_c", "mcu_err", "note"]
RESTART_NOTE = "mcu-restart"

# How much of the end of an existing file is read to find where it stopped.
# A pull is at most a few hundred rows of about fifty bytes; this is enough
# for many of them, and reading the whole file - a few MB a day - would make
# the start slower every day the log runs.
_TAIL_BYTES = 64 * 1024


# run() needs these two methods of MCU and nothing else. Saying so is what
# lets the tests drive it with a fake that replays a scripted log.
class TempLog(Protocol):
    def temp_log(self, since: int | None = None) -> list[TempSample]: ...

    def temp_log_stat(self) -> TempLogStat: ...


def _same(a: TempSample, b: TempSample) -> bool:
    """Is b the sample a, as read back from the CSV?

    The temperature went through "%.3f", so it is compared to within that.
    """
    if (a.seq, a.ms, a.err) != (b.seq, b.ms, b.err):
        return False
    if a.temp_c is None or b.temp_c is None:
        return a.temp_c is b.temp_c
    return math.isclose(a.temp_c, b.temp_c, abs_tol=0.0005)


def zone_columns(temps: Sequence[tuple[str, float]]) -> list[tuple[str, float]]:
    """(column name, degrees) per thermal zone: `linux_<type>`, #2 on a repeat.

    Zone types are not unique (see thermal.read_temps); the suffix is the one
    powerlog uses, so the two files read the same.
    """
    out: list[tuple[str, float]] = []
    seen: dict[str, int] = {}
    for name, celsius in temps:
        seen[name] = seen.get(name, 0) + 1
        suffix = "" if seen[name] == 1 else f"#{seen[name]}"
        out.append((f"linux_{name}{suffix}", celsius))
    return out


def sample_row(sample: TempSample, when: float) -> dict[str, str]:
    """One MCU sample as a CSV row. A failed read keeps its number and its errno."""
    return {
        "time": f"{when:.3f}",
        "seq": str(sample.seq),
        "mcu_ms": str(sample.ms),
        "mcu_temp_c": "" if sample.temp_c is None else f"{sample.temp_c:.3f}",
        "mcu_err": str(sample.err) if sample.err else "",
    }


def note_row(note: str, when: float) -> dict[str, str]:
    return {"time": f"{when:.3f}", "note": note}


@dataclass
class Resume:
    """Where an existing file left off."""

    header: list[str] | None = None
    # The newest sample stored, which the next pull asks the MCU for again.
    last: TempSample | None = None
    # The seq the next stored sample should have; None if nothing says.
    expected: int | None = None
    # Whether the file ends part-way through a line (a write cut off by a
    # power cut), so the next row has to start on a line of its own.
    torn: bool = False


def _parse_sample(row: dict[str, str]) -> TempSample | None:
    try:
        seq = int(row["seq"])
        ms = int(row["mcu_ms"])
        err = int(row["mcu_err"] or 0)
        temp = float(row["mcu_temp_c"]) if row["mcu_temp_c"] else None
    except (KeyError, TypeError, ValueError):
        return None
    return TempSample(seq, ms, temp, err)


def resume(path: Path) -> Resume:
    """Read the header and the last sample of a CSV this wrote before.

    Only the end of the file is read. Walking back from the last line, the
    first row that says something decides: a sample is where to carry on
    from, and a restart note means the MCU's numbering had started again and
    nothing after it was stored yet. Gap notes and rows that do not parse are
    passed over.
    """
    try:
        with path.open("rb") as f:
            size = f.seek(0, os.SEEK_END)
            start = max(0, size - _TAIL_BYTES)
            f.seek(start)
            tail = f.read()
            f.seek(0)
            first = f.readline()
    except FileNotFoundError:
        return Resume()
    header = next(csv.reader([first.decode("utf-8", "replace")]), None)
    if not header:
        return Resume()
    out = Resume(header=header, torn=not tail.endswith(b"\n"))
    lines = tail.decode("utf-8", "replace").splitlines()
    # The first line is the header when the tail is the whole file, and
    # probably cut in half when it is not. Either way it is not a row.
    rows = list(csv.DictReader(lines[1:], fieldnames=header, restval=""))
    for row in reversed(rows):
        if row.get("note") == RESTART_NOTE:
            out.expected = 1
            return out
        sample = _parse_sample(row)
        if sample is not None:
            out.last = sample
            out.expected = sample.seq + 1
            return out
    return out


@dataclass
class Logger:
    """The state carried from one pull to the next.

    `last` is the newest sample stored. Each pull asks for it again
    (`since=last.seq - 1`) along with everything newer, and checks that the
    MCU still has the same sample under that number. That is how a restart
    the head alone cannot show is caught: an MCU that rebooted and has since
    counted past the old number again. Asking for one sample already held
    costs one line on the wire.
    """

    mcu: TempLog
    temps: Callable[[], list[tuple[str, float]]] = read_temps
    clock: Callable[[], float] = _time
    last: TempSample | None = None
    expected: int | None = None
    restarts: int = 0

    def pull(self) -> tuple[list[dict[str, str]], list[tuple[str, float]]]:
        """Collect what is new: the rows to append, and the host's zones now."""
        rows: list[dict[str, str]] = []
        stat = self.mcu.temp_log_stat()
        restarted = self.last is not None and stat.head < self.last.seq
        samples: list[TempSample] = []
        if not restarted:
            samples = self.mcu.temp_log(None if self.last is None else self.last.seq - 1)
            if self.last is not None and samples and samples[0].seq == self.last.seq:
                if _same(samples[0], self.last):
                    samples = samples[1:]
                else:
                    restarted = True
        if restarted:
            rows.append(note_row(RESTART_NOTE, self.clock()))
            self.restarts += 1
            self.last = None
            self.expected = 1
            samples = self.mcu.temp_log(None)

        # One reading of each clock, after the reply is in. The newest sample
        # is at most one period old at this moment, so every time below is
        # right to within the MCU's sampling period - whatever Linux was doing.
        now = self.clock()
        zones = zone_columns(self.temps())
        if not samples:
            return rows, zones
        head_ms = samples[-1].ms
        for sample in samples:
            when = now - (head_ms - sample.ms) / 1000
            if self.expected is not None and sample.seq > self.expected:
                rows.append(note_row(f"gap {self.expected}-{sample.seq - 1}", when))
            rows.append(sample_row(sample, when))
            self.expected = sample.seq + 1
            self.last = sample
        # The host's temperatures go on the newest row only: they were read
        # once, now, and copying them onto older rows would invent readings.
        for name, celsius in zones:
            rows[-1][name] = f"{celsius:.1f}"
        return rows, zones


def write_page(directory: Path) -> bool:
    """Put the graph page in the directory, if what is there is not already it.

    Written to a temporary name and renamed, so a browser never fetches half a
    page. Returns whether it wrote.
    """
    page = resources.files("unoq").joinpath("templog.html").read_text()
    target = directory / PAGE_NAME
    try:
        if target.read_text() == page:
            return False
    except FileNotFoundError:
        pass
    tmp = directory / f".{PAGE_NAME}.tmp"
    tmp.write_text(page)
    tmp.replace(target)
    return True


def run(
    mcu: TempLog,
    directory: str | Path,
    interval: float = DEFAULT_INTERVAL,
    count: int | None = None,
    temps: Callable[[], list[tuple[str, float]]] = read_temps,
    clock: Callable[[], float] = _time,
    sleep: Callable[[float], None] = _sleep,
) -> int:
    """Pull `count` times, or forever if count is None. Returns rows written.

    Pulls first and then sleeps, unlike cpubars: there is nothing to measure
    an interval against here, and a daemon that was stopped has a backlog
    waiting for it.

    The file's header is kept once it exists, as in powerlog: a zone the
    kernel added since is dropped rather than shifting every column after it.

    Flushed and fsynced after each pull. The MCU holds ten minutes, so a row
    lost in a power cut would be fetched again on the next start - but only if
    the file says it was never written.
    """
    target = Path(directory) / CSV_NAME
    state = resume(target)
    log = Logger(mcu, temps=temps, clock=clock, last=state.last, expected=state.expected)
    written = 0
    pulls = 0
    with target.open("a", newline="") as f:
        writer = None
        if state.header:
            writer = csv.DictWriter(f, state.header, restval="", extrasaction="ignore")
            if state.torn:
                f.write("\n")
        while True:
            rows, zones = log.pull()
            if rows:
                if writer is None:
                    writer = _new_writer(f, [name for name, _ in zones])
                writer.writerows(rows)
                f.flush()
                os.fsync(f.fileno())
                written += len(rows)
            pulls += 1
            if count is not None and pulls >= count:
                return written
            sleep(interval)


def _new_writer(f: IO[str], zones: list[str]) -> csv.DictWriter[str]:
    writer = csv.DictWriter(f, BASE_COLUMNS + zones, restval="", extrasaction="ignore")
    writer.writeheader()
    return writer


def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name, "")
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError:
        raise SystemExit(f"unoq-temp-log: {name}={raw!r} is not a number of seconds") from None
    if not value > 0:
        raise SystemExit(f"unoq-temp-log: {name}={raw!r} has to be more than 0")
    return value


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="unoq-temp-log",
        description="Append the MCU's temperature log, and the host's, to a CSV file.",
    )
    parser.add_argument(
        "--dir",
        default=os.environ.get("UNOQ_TEMPLOG_DIR") or DEFAULT_DIR,
        help="directory for temps.csv and index.html (UNOQ_TEMPLOG_DIR)",
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=_env_float("UNOQ_TEMPLOG_INTERVAL", DEFAULT_INTERVAL),
        help="seconds between pulls (UNOQ_TEMPLOG_INTERVAL)",
    )
    parser.add_argument("--count", type=int, default=None, help="stop after N pulls")
    parser.add_argument("--port", default=PORT, help="serial port to the MCU")
    parser.add_argument("--thermal", default=SYS_THERMAL, help="where to read thermal zones")
    args = parser.parse_args(argv)
    if not args.interval > 0:
        parser.error("--interval has to be more than 0")

    directory = Path(args.dir)
    try:
        if write_page(directory):
            print(f"wrote {directory / PAGE_NAME}", flush=True)
        with MCU(port=args.port) as mcu:
            print(f"logging to {directory / CSV_NAME} every {args.interval:g}s", flush=True)
            written = run(
                mcu,
                directory,
                interval=args.interval,
                count=args.count,
                temps=lambda: read_temps(args.thermal),
            )
    except KeyboardInterrupt:
        # Ctrl-C, and SIGINT from systemd, are how this stops. Every pull
        # already made is on disk.
        return 0
    except MCUError as err:
        # Among them a firmware that predates the log, which says how to fix it.
        print(f"unoq-temp-log: {err}", file=sys.stderr)
        return 1
    except OSError as err:
        print(f"unoq-temp-log: {err}", file=sys.stderr)
        return 1
    print(f"{written} rows appended to {directory / CSV_NAME}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
