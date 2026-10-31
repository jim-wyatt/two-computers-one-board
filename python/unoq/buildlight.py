# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""
A build light: the board watches a GitHub Actions workflow and shows it on the panel.

    unoq-buildlight                       # poll every 60 s, until Ctrl-C
    unoq-buildlight --once                # one poll and one picture, then exit

Every interval it asks GitHub for the latest run of one workflow on one branch,
and draws a picture of the answer with MCU.matrix_frame():

    passing        a check mark
    failing        a cross
    running        a bar sweeping across the panel
    unreachable    a question mark - no network, a wrong repo, no runs yet
    rate-limited   the same question mark: GitHub said to wait, so it waits

Unlike the other daemons, the thing it watches is not on the board. Linux does
what Linux is good at (TLS, HTTP, JSON, retrying) and the MCU only ever sees
eight rows of digits, which is the whole of the split this project teaches.

The settings come from the environment (the unit reads /etc/unoq/buildlight.env):
UNOQ_BUILDLIGHT_REPO, _WORKFLOW, _BRANCH, _INTERVAL and _TOKEN. The token is
optional, sent as a header and nowhere else, and never printed. Without one
GitHub allows 60 requests an hour from an address, which is what a 60 s
interval spends; so each request is conditional (If-None-Match), and GitHub
does not count an unchanged answer, a 304, against that limit.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field
from enum import StrEnum
from time import sleep as _sleep
from time import time as _time
from typing import Any, Protocol

from .mcu import MATRIX_COLS, MATRIX_ROWS, MCU, PORT, MCUError

DEFAULT_REPO = "jim-wyatt/two-computers-one-board"
DEFAULT_WORKFLOW = "ci.yml"
DEFAULT_BRANCH = "main"
# Once a minute is as fast as a build light needs to be, and without a token
# it is the whole of GitHub's hourly allowance for an address: see the module
# docstring for why that is still enough.
DEFAULT_INTERVAL = 60.0
API = "https://api.github.com"
TIMEOUT = 15.0
# How long a run of failed polls can stretch the wait to. Doubling from 60 s,
# that is reached after four failures in a row.
MAX_BACKOFF = 900.0
# A rate-limit reset more than this far ahead is not believed. GitHub's window
# is an hour; a clock that is wrong should not park the light for a day.
MAX_RATE_WAIT = 3600.0 + 60.0
# Seconds between frames of the running bar: a sweep of the panel every 3.25 s.
ANIM_STEP = 0.25


class State(StrEnum):
    PASSING = "passing"
    FAILING = "failing"
    RUNNING = "running"
    RATE_LIMITED = "rate-limited"
    UNREACHABLE = "unreachable"


# Conclusions of a finished run that mean "nothing is wrong". Everything else a
# finished run can conclude - failure, timed_out, startup_failure, a run
# someone stopped, action_required, stale - is not a pass, and a build light that is not sure
# should not be green.
_PASSING_CONCLUSIONS = frozenset({"success", "neutral", "skipped"})
_REPO = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")


# --- the pictures -----------------------------------------------------------
#
# Eight strings of thirteen levels, row 0 at the top, as matrix_frame() takes
# them. Strokes two LEDs wide, because one is hard to read across a room.

CHECK = (
    "0000000000770",
    "0000000007700",
    "0000000077000",
    "0770000770000",
    "0077007700000",
    "0007777000000",
    "0000770000000",
    "0000000000000",
)

CROSS = (
    "0077000007700",
    "0007700077000",
    "0000770770000",
    "0000077700000",
    "0000077700000",
    "0000770770000",
    "0007700077000",
    "0077000007700",
)

QUESTION = (
    "0000777770000",
    "0007700077000",
    "0000000077000",
    "0000000770000",
    "0000077700000",
    "0000077000000",
    "0000000000000",
    "0000077000000",
)

# The running bar: a full-height column at full brightness, with a fading tail
# behind it, moving one column a frame and wrapping round.
_TAIL = (7, 3, 1)
RUNNING_FRAMES = MATRIX_COLS


def running_frame(step: int) -> tuple[str, ...]:
    """Frame `step` of the running bar. It repeats every RUNNING_FRAMES."""
    head = step % MATRIX_COLS
    levels = [0] * MATRIX_COLS
    for behind, level in enumerate(_TAIL):
        levels[(head - behind) % MATRIX_COLS] = level
    row = "".join(str(v) for v in levels)
    return (row,) * MATRIX_ROWS


def glyph(state: State, step: int = 0) -> tuple[str, ...]:
    """The picture for a state. Only the running bar uses `step`."""
    if state is State.PASSING:
        return CHECK
    if state is State.FAILING:
        return CROSS
    if state is State.RUNNING:
        return running_frame(step)
    return QUESTION


# --- what GitHub said -------------------------------------------------------


def _header(headers: Mapping[str, str], name: str) -> str | None:
    """A header by name, whatever case the server or urllib gave it."""
    for key, value in headers.items():
        if key.lower() == name:
            return value
    return None


def _number(headers: Mapping[str, str], name: str) -> float | None:
    raw = _header(headers, name)
    if raw is None:
        return None
    try:
        return float(raw)
    except ValueError:
        return None


def _is_rate_limited(status: int, headers: Mapping[str, str], body: Any) -> bool:
    """GitHub's two ways of saying "slow down", per its REST documentation.

    The primary limit: 403 or 429 with x-ratelimit-remaining 0. A secondary
    limit: 403 or 429 with retry-after, or a message that says so. A 403 with
    none of those is a permission problem, which waiting will not fix.
    """
    if status not in (403, 429):
        return False
    if status == 429:
        return True
    if _header(headers, "retry-after") is not None:
        return True
    if _number(headers, "x-ratelimit-remaining") == 0:
        return True
    message = body.get("message", "") if isinstance(body, dict) else ""
    return isinstance(message, str) and "rate limit" in message.lower()


def state_from(status: int | None, headers: Mapping[str, str], body: Any) -> State:
    """What a response from the workflow-runs endpoint means for the light.

    `status` is None when there was no response at all. `body` is the decoded
    JSON, or None if there was none or it did not decode. Pure: no clock, no
    network, so every answer GitHub can give is a test.
    """
    if status is None:
        return State.UNREACHABLE
    if _is_rate_limited(status, headers, body):
        return State.RATE_LIMITED
    if status != 200 or not isinstance(body, dict):
        return State.UNREACHABLE
    runs = body.get("workflow_runs")
    if not isinstance(runs, list) or not runs or not isinstance(runs[0], dict):
        # No runs of this workflow on this branch: there is nothing to show yet.
        return State.UNREACHABLE
    run = runs[0]
    if run.get("status") != "completed":
        # queued, in_progress, waiting, requested, pending.
        return State.RUNNING
    if run.get("conclusion") in _PASSING_CONCLUSIONS:
        return State.PASSING
    return State.FAILING


def next_wait(
    state: State,
    headers: Mapping[str, str],
    interval: float,
    now: float,
    failures: int = 0,
) -> float:
    """Seconds until the next poll.

    The interval, doubled for each poll in a row that got no answer (up to
    MAX_BACKOFF), and never sooner than GitHub asked: retry-after, or the
    reset time when no requests are left. That last one applies to a good
    answer too - the 200 that spent the last request says so in its headers.
    """
    wait = interval
    if state in (State.UNREACHABLE, State.RATE_LIMITED) and failures > 1:
        wait = max(interval, min(interval * 2 ** (failures - 1), MAX_BACKOFF))
    retry_after = _number(headers, "retry-after")
    if retry_after is not None:
        wait = max(wait, min(retry_after, MAX_RATE_WAIT))
    reset = _number(headers, "x-ratelimit-reset")
    if _number(headers, "x-ratelimit-remaining") == 0 and reset is not None:
        # One second past the reset, so the next request is in the new window.
        wait = max(wait, min(reset - now + 1, MAX_RATE_WAIT))
    return wait


def describe(status: int | None, body: Any, error: str | None = None) -> str:
    """A line for the journal: what was seen, without anything secret in it."""
    if status is None:
        return error or "no response"
    if status != 200:
        message = body.get("message") if isinstance(body, dict) else None
        return f"HTTP {status}" + (f": {message}" if isinstance(message, str) else "")
    runs = body.get("workflow_runs") if isinstance(body, dict) else None
    if not isinstance(runs, list) or not runs or not isinstance(runs[0], dict):
        return "no runs of the workflow on this branch"
    run = runs[0]
    parts = [f"run #{run.get('run_number', '?')}", str(run.get("status"))]
    if run.get("conclusion"):
        parts.append(str(run["conclusion"]))
    sha = run.get("head_sha")
    if isinstance(sha, str):
        parts.append(sha[:7])
    return " ".join(parts)


# --- asking GitHub ----------------------------------------------------------


@dataclass
class Response:
    status: int | None
    headers: dict[str, str] = field(default_factory=dict)
    body: Any = None
    error: str | None = None


# The one thing GitHub needs from urllib, so a test can stand in for the
# network. Looked up when a GitHub is made, so the tests can replace it.
URLOPEN: Callable[..., Any] = urllib.request.urlopen


def runs_url(repo: str, workflow: str, branch: str) -> str:
    """The workflow-runs endpoint for one workflow on one branch, newest run only."""
    query = urllib.parse.urlencode({"branch": branch, "per_page": 1})
    wf = urllib.parse.quote(workflow, safe="")
    return f"{API}/repos/{repo}/actions/workflows/{wf}/runs?{query}"


class GitHub:
    """Fetches the latest run, conditionally.

    It keeps the ETag of the last good answer and sends it back as
    If-None-Match. GitHub replies 304 when nothing changed, which does not
    count against the rate limit, and this hands back the answer it kept.
    """

    def __init__(
        self,
        repo: str,
        workflow: str,
        branch: str,
        token: str | None = None,
        urlopen: Callable[..., Any] | None = None,
        timeout: float = TIMEOUT,
    ) -> None:
        self.url = runs_url(repo, workflow, branch)
        self._token = token or None
        self._urlopen = urlopen or URLOPEN
        self._timeout = timeout
        self._etag: str | None = None
        self._kept: Any = None

    def __repr__(self) -> str:
        # Never the token, even by accident in a traceback or a debug print.
        auth = "token" if self._token else "no token"
        return f"GitHub({self.url!r}, {auth})"

    def request(self) -> urllib.request.Request:
        headers = {
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            # GitHub refuses requests with no User-Agent.
            "User-Agent": "unoq-buildlight",
        }
        if self._token:
            headers["Authorization"] = f"Bearer {self._token}"
        if self._etag:
            headers["If-None-Match"] = self._etag
        return urllib.request.Request(self.url, headers=headers)

    def __call__(self) -> Response:
        try:
            with self._urlopen(self.request(), timeout=self._timeout) as resp:
                status, headers, raw = int(resp.status), dict(resp.headers), resp.read()
        except urllib.error.HTTPError as err:
            # Every answer that is not 2xx, 304 among them. It is still an
            # answer, with headers that matter (the rate limit's).
            status, headers = err.code, dict(err.headers or {})
            raw = err.read() if err.fp is not None else b""
        except (urllib.error.URLError, OSError, ValueError) as err:
            # No answer: no network, no DNS, a timeout, a TLS failure.
            reason = getattr(err, "reason", None) or err
            return Response(None, error=f"{type(err).__name__}: {reason}")
        if status == 304 and self._etag is not None:
            return Response(200, headers, self._kept)
        try:
            body = json.loads(raw) if raw else None
        except ValueError:
            body = None
        etag = _header(headers, "etag")
        if status == 200 and etag and isinstance(body, dict):
            self._etag, self._kept = etag, body
        return Response(status, headers, body)


# --- the loop ---------------------------------------------------------------


class Panel(Protocol):
    def matrix_frame(self, rows: Sequence[str]) -> None: ...


def _log(line: str) -> None:
    # Flushed: under systemd stdout is a pipe, and a buffered line would reach
    # the journal minutes after the change it reports.
    print(line, flush=True)


def run(
    panel: Panel,
    fetch: Callable[[], Response],
    interval: float = DEFAULT_INTERVAL,
    count: int | None = None,
    sleep: Callable[[float], None] = _sleep,
    now: Callable[[], float] = _time,
    log: Callable[[str], None] = _log,
) -> State:
    """Poll and draw `count` times, or forever if count is None.

    Returns the last state seen. The last poll is drawn and not waited after,
    so `count=1` is one request and one picture.
    """
    polls = 0
    failures = 0
    step = 0
    last: State | None = None
    while True:
        resp = fetch()
        state = state_from(resp.status, resp.headers, resp.body)
        polls += 1
        failures = failures + 1 if state in (State.UNREACHABLE, State.RATE_LIMITED) else 0
        wait = next_wait(state, resp.headers, interval, now(), failures)
        if state is not last:
            # Only changes, so the journal is a history of the build and not
            # a line a minute. The token is in no part of this.
            log(f"{state}: {describe(resp.status, resp.body, resp.error)}")
        if state is State.RATE_LIMITED:
            log(f"GitHub asked to wait: next poll in {wait:.0f}s")
        last = state
        step = _show(panel, state, step)
        if count is not None and polls >= count:
            return state
        if state is State.RUNNING:
            # The bar moves while it waits. Whole frames, so the poll after
            # comes no later than the wait asked for.
            for _ in range(max(1, int(wait / ANIM_STEP))):
                sleep(ANIM_STEP)
                step = _show(panel, state, step)
        else:
            sleep(wait)


def _show(panel: Panel, state: State, step: int) -> int:
    """Draw the state; return the running bar's next step.

    The bar's step only moves on while it is drawn, so a poll that finds the
    run still going carries on from where the bar was instead of jumping.
    """
    panel.matrix_frame(glyph(state, step))
    return step + 1 if state is State.RUNNING else step


# --- settings ---------------------------------------------------------------


def _env(name: str, default: str) -> str:
    return os.environ.get(name, "").strip() or default


def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError:
        raise SystemExit(f"unoq-buildlight: {name}={raw!r} is not a number of seconds") from None
    if not value > 0:
        raise SystemExit(f"unoq-buildlight: {name}={raw!r} has to be more than 0")
    return value


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="unoq-buildlight",
        description="Show a GitHub Actions workflow's latest run on the UNO Q's LED matrix.",
        epilog="The token is read from UNOQ_BUILDLIGHT_TOKEN only, never from the command line.",
    )
    parser.add_argument(
        "--repo",
        default=_env("UNOQ_BUILDLIGHT_REPO", DEFAULT_REPO),
        help="owner/name (UNOQ_BUILDLIGHT_REPO)",
    )
    parser.add_argument(
        "--workflow",
        default=_env("UNOQ_BUILDLIGHT_WORKFLOW", DEFAULT_WORKFLOW),
        help="the workflow's file name or id (UNOQ_BUILDLIGHT_WORKFLOW)",
    )
    parser.add_argument(
        "--branch",
        default=_env("UNOQ_BUILDLIGHT_BRANCH", DEFAULT_BRANCH),
        help="(UNOQ_BUILDLIGHT_BRANCH)",
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=_env_float("UNOQ_BUILDLIGHT_INTERVAL", DEFAULT_INTERVAL),
        help="seconds between polls (UNOQ_BUILDLIGHT_INTERVAL)",
    )
    parser.add_argument("--once", action="store_true", help="poll once, draw, and exit")
    parser.add_argument("--port", default=PORT, help="serial port to the MCU")
    args = parser.parse_args(argv)
    if not args.interval > 0:
        parser.error("--interval has to be more than 0")
    if not _REPO.fullmatch(args.repo):
        parser.error(f"--repo {args.repo!r} is not owner/name")
    # A command-line flag would put the token in `ps` for every user to read.
    token = os.environ.get("UNOQ_BUILDLIGHT_TOKEN", "").strip() or None

    fetch = GitHub(args.repo, args.workflow, args.branch, token)
    print(
        f"watching {args.repo} {args.workflow} on {args.branch}, "
        f"{'with a token' if token else 'without a token'}, every {args.interval:g}s",
        flush=True,
    )
    try:
        with MCU(port=args.port) as mcu:
            try:
                run(mcu, fetch, args.interval, 1 if args.once else None)
            except KeyboardInterrupt:
                pass  # Ctrl-C, and SIGINT from systemd, are how this stops.
            finally:
                if not args.once:
                    # A daemon that stopped leaves the panel dark: a frozen
                    # check mark would say the build is fine for as long as
                    # nobody looks at the journal.
                    try:
                        mcu.matrix_off()
                    except MCUError as err:
                        print(f"unoq-buildlight: could not blank the panel: {err}", file=sys.stderr)
    except MCUError as err:
        # A busy port, a silent MCU, or a firmware without `app matrix frame`.
        print(f"unoq-buildlight: {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
