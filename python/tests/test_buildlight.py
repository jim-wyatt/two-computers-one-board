# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""Tests for the build light.

Nothing here touches the network. GitHub is a fake `urlopen` handed to
GitHub(), and an autouse fixture replaces the module's default with one that
fails the test, so a code path that forgot to take the fake cannot quietly
reach api.github.com.

The fixtures in fixtures/buildlight/ are GitHub's own answers.
success.json is one real response of the workflow-runs endpoint for this
repository's ci.yml, recorded once with `gh api` and trimmed to the run's own
fields (no actor, no repository object). The others are that run with its
status or conclusion changed, and GitHub's documented error bodies.
"""

from __future__ import annotations

import io
import json
import os
import urllib.error
import urllib.request
from email.message import Message
from pathlib import Path
from typing import Any, ClassVar

import pytest

from unoq import buildlight
from unoq.buildlight import (
    CHECK,
    CROSS,
    QUESTION,
    GitHub,
    Response,
    State,
    describe,
    glyph,
    next_wait,
    running_frame,
    state_from,
)
from unoq.mcu import MATRIX_COLS, MATRIX_MAX_LEVEL, MATRIX_ROWS, MCUError

FIXTURES = Path(__file__).parent / "fixtures" / "buildlight"
TOKEN = "ghp_SECRETSECRETSECRET"


def fixture(name: str) -> Any:
    return json.loads((FIXTURES / f"{name}.json").read_text())


@pytest.fixture(autouse=True)
def no_network(monkeypatch: pytest.MonkeyPatch) -> None:
    def refuse(*a: Any, **k: Any) -> Any:
        raise AssertionError("a test reached for the network")

    monkeypatch.setattr(buildlight, "URLOPEN", refuse)
    for name in [n for n in os.environ if n.startswith("UNOQ_BUILDLIGHT_")]:
        monkeypatch.delenv(name)


# --- the pictures -----------------------------------------------------------


def _valid(rows: tuple[str, ...]) -> bool:
    return len(rows) == MATRIX_ROWS and all(
        len(r) == MATRIX_COLS and all("0" <= c <= str(MATRIX_MAX_LEVEL) for c in r) for r in rows
    )


@pytest.mark.parametrize("rows", [CHECK, CROSS, QUESTION])
def test_each_glyph_is_a_frame_matrix_frame_takes(rows: tuple[str, ...]) -> None:
    assert _valid(rows)
    assert any(c != "0" for r in rows for c in r)


def test_every_running_frame_is_a_frame_and_they_all_differ() -> None:
    frames = [running_frame(i) for i in range(buildlight.RUNNING_FRAMES)]
    assert all(_valid(f) for f in frames)
    assert len(set(frames)) == buildlight.RUNNING_FRAMES
    # It repeats, so a counter that keeps climbing is fine.
    assert running_frame(buildlight.RUNNING_FRAMES) == running_frame(0)
    assert running_frame(buildlight.RUNNING_FRAMES * 7 + 3) == running_frame(3)


def test_the_running_bar_moves_one_column_a_frame_with_its_tail_behind() -> None:
    assert running_frame(0)[0] == "7000000000013"
    assert running_frame(1)[0] == "3700000000001"
    assert running_frame(5)[0] == "0001370000000"
    assert len(set(running_frame(5))) == 1  # a full-height column


def test_the_states_look_different_from_each_other() -> None:
    still = {CHECK, CROSS, QUESTION}
    assert len(still) == 3
    assert not still & {running_frame(i) for i in range(buildlight.RUNNING_FRAMES)}


def test_the_cross_is_symmetric_and_the_check_is_not() -> None:
    # A cheap guard against a typo in one stroke.
    assert all(r == r[::-1] for r in CROSS)
    assert CROSS[::-1] == CROSS
    assert any(r != r[::-1] for r in CHECK)


@pytest.mark.parametrize(
    ("state", "rows"),
    [
        (State.PASSING, CHECK),
        (State.FAILING, CROSS),
        (State.UNREACHABLE, QUESTION),
        (State.RATE_LIMITED, QUESTION),
    ],
)
def test_glyph_maps_each_state(state: State, rows: tuple[str, ...]) -> None:
    assert glyph(state) == rows
    assert glyph(state, 5) == rows


def test_glyph_for_running_is_the_frame_for_the_step() -> None:
    assert glyph(State.RUNNING, 4) == running_frame(4)


# --- state_from -------------------------------------------------------------


@pytest.mark.parametrize(
    ("name", "state"),
    [
        ("success", State.PASSING),
        ("failure", State.FAILING),
        ("in_progress", State.RUNNING),
        ("queued", State.RUNNING),
        ("no_runs", State.UNREACHABLE),
    ],
)
def test_state_from_recorded_answers(name: str, state: State) -> None:
    assert state_from(200, {}, fixture(name)) is state


@pytest.mark.parametrize("conclusion", ["neutral", "skipped"])
def test_conclusions_that_are_not_a_failure_are_passing(conclusion: str) -> None:
    body = fixture("success")
    body["workflow_runs"][0]["conclusion"] = conclusion
    assert state_from(200, {}, body) is State.PASSING


# GitHub's own spelling of a run someone stopped.
STOPPED = "cancelled"  # codespell:ignore cancelled


@pytest.mark.parametrize(
    "conclusion", [STOPPED, "timed_out", "startup_failure", "action_required", None]
)
def test_any_other_finished_run_is_failing(conclusion: str | None) -> None:
    body = fixture("success")
    body["workflow_runs"][0]["conclusion"] = conclusion
    assert state_from(200, {}, body) is State.FAILING


def test_no_response_is_unreachable() -> None:
    assert state_from(None, {}, None) is State.UNREACHABLE


@pytest.mark.parametrize(
    ("status", "name"), [(404, "not_found"), (401, "bad_credentials"), (500, None), (502, None)]
)
def test_errors_that_waiting_will_not_fix_are_unreachable(status: int, name: str | None) -> None:
    body = fixture(name) if name else None
    assert state_from(status, {}, body) is State.UNREACHABLE


def test_a_403_with_no_rate_limit_in_it_is_unreachable() -> None:
    # A token without access to the repository: a permission problem.
    body = {"message": "Resource not accessible by personal access token"}
    assert state_from(403, {"x-ratelimit-remaining": "4000"}, body) is State.UNREACHABLE
    assert state_from(403, {}, None) is State.UNREACHABLE
    assert state_from(403, {}, {"message": 5}) is State.UNREACHABLE


def test_the_primary_rate_limit_is_rate_limited() -> None:
    headers = {"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1793488381"}
    assert state_from(403, headers, fixture("rate_limited")) is State.RATE_LIMITED
    # The header alone is enough.
    assert state_from(403, headers, None) is State.RATE_LIMITED


def test_a_secondary_rate_limit_is_rate_limited() -> None:
    assert state_from(403, {"Retry-After": "60"}, None) is State.RATE_LIMITED
    assert state_from(403, {}, fixture("secondary_rate_limit")) is State.RATE_LIMITED
    assert state_from(429, {}, None) is State.RATE_LIMITED


@pytest.mark.parametrize(
    "body",
    [
        None,
        [],
        "text",
        {},
        {"workflow_runs": None},
        {"workflow_runs": "x"},
        {"workflow_runs": [None]},
    ],
)
def test_a_body_that_is_not_the_expected_shape_is_unreachable(body: Any) -> None:
    assert state_from(200, {}, body) is State.UNREACHABLE


# --- next_wait --------------------------------------------------------------


def test_a_good_answer_waits_the_interval() -> None:
    assert next_wait(State.PASSING, {"x-ratelimit-remaining": "59"}, 60, now=0) == 60


def test_failures_in_a_row_double_the_wait_up_to_a_ceiling() -> None:
    waits = [next_wait(State.UNREACHABLE, {}, 60, 0, failures=n) for n in range(1, 7)]
    assert waits == [60, 120, 240, 480, 900, 900]


def test_backoff_never_waits_less_than_the_interval() -> None:
    # An interval above the ceiling stays the interval.
    assert next_wait(State.UNREACHABLE, {}, 1200, 0, failures=3) == 1200


def test_retry_after_is_honored() -> None:
    assert next_wait(State.RATE_LIMITED, {"Retry-After": "300"}, 60, 0, failures=1) == 300
    # ...but not past the cap.
    assert next_wait(State.RATE_LIMITED, {"Retry-After": "99999"}, 60, 0, 1) == (
        buildlight.MAX_RATE_WAIT
    )


def test_no_requests_left_waits_for_the_reset_even_after_a_good_answer() -> None:
    headers = {"x-ratelimit-remaining": "0", "x-ratelimit-reset": "10500"}
    assert next_wait(State.PASSING, headers, 60, now=10000) == 501
    assert next_wait(State.RATE_LIMITED, headers, 60, now=10000, failures=1) == 501


def test_a_reset_in_the_past_or_absurdly_far_off_is_not_believed() -> None:
    past = {"x-ratelimit-remaining": "0", "x-ratelimit-reset": "100"}
    assert next_wait(State.RATE_LIMITED, past, 60, now=10000, failures=1) == 60
    far = {"x-ratelimit-remaining": "0", "x-ratelimit-reset": str(10000 + 86400)}
    assert next_wait(State.RATE_LIMITED, far, 60, now=10000, failures=1) == (
        buildlight.MAX_RATE_WAIT
    )


def test_headers_that_do_not_parse_are_ignored() -> None:
    headers = {"retry-after": "soon", "x-ratelimit-remaining": "0", "x-ratelimit-reset": "x"}
    assert next_wait(State.RATE_LIMITED, headers, 60, 0, failures=1) == 60


# --- describe ---------------------------------------------------------------


def test_describe_a_run() -> None:
    assert describe(200, fixture("success")) == "run #301 completed success 2140ab2"
    assert describe(200, fixture("in_progress")) == "run #301 in_progress 2140ab2"
    body = {"workflow_runs": [{"status": "queued", "head_sha": None}]}
    assert describe(200, body) == "run #? queued"


def test_describe_errors() -> None:
    assert describe(None, None, "URLError: no route") == "URLError: no route"
    assert describe(None, None) == "no response"
    assert describe(404, fixture("not_found")) == "HTTP 404: Not Found"
    assert describe(502, None) == "HTTP 502"
    assert describe(200, fixture("no_runs")) == "no runs of the workflow on this branch"
    assert describe(200, None) == "no runs of the workflow on this branch"


# --- GitHub -----------------------------------------------------------------


class FakeResp:
    def __init__(self, status: int, body: bytes, headers: dict[str, str]) -> None:
        self.status = status
        self._body = body
        self.headers = headers

    def read(self) -> bytes:
        return self._body

    def __enter__(self) -> FakeResp:
        return self

    def __exit__(self, *a: object) -> None:
        return None


def http_error(code: int, body: bytes | None, headers: dict[str, str]) -> urllib.error.HTTPError:
    msg = Message()
    for k, v in headers.items():
        msg[k] = v
    fp = io.BytesIO(body) if body is not None else None
    return urllib.error.HTTPError("https://api.github.com/x", code, "x", msg, fp)


class FakeOpener:
    """urlopen, replaying a script. Each item is a FakeResp or an exception."""

    def __init__(self, *script: Any) -> None:
        self.script = list(script)
        self.requests: list[urllib.request.Request] = []
        self.timeouts: list[float] = []

    def __call__(self, req: urllib.request.Request, timeout: float) -> Any:
        self.requests.append(req)
        self.timeouts.append(timeout)
        item = self.script.pop(0)
        if isinstance(item, BaseException):
            raise item
        return item


def ok(name: str, etag: str | None = '"abc"', **headers: str) -> FakeResp:
    if etag:
        headers["ETag"] = etag
    return FakeResp(200, (FIXTURES / f"{name}.json").read_bytes(), headers)


def test_the_url_names_the_workflow_the_branch_and_one_run() -> None:
    gh = GitHub("o/r", "ci.yml", "main", urlopen=FakeOpener())
    assert gh.url == (
        "https://api.github.com/repos/o/r/actions/workflows/ci.yml/runs?branch=main&per_page=1"
    )


def test_the_branch_and_workflow_are_quoted() -> None:
    gh = GitHub("o/r", "a/b.yml", "feature/x y", urlopen=FakeOpener())
    assert "/workflows/a%2Fb.yml/runs?branch=feature%2Fx+y&per_page=1" in gh.url


def test_no_token_means_no_authorization_header() -> None:
    opener = FakeOpener(ok("success"))
    resp = GitHub("o/r", "ci.yml", "main", urlopen=opener)()
    assert resp.status == 200
    assert state_from(resp.status, resp.headers, resp.body) is State.PASSING
    req = opener.requests[0]
    assert req.get_header("Authorization") is None
    assert req.get_header("User-agent") == "unoq-buildlight"
    assert req.get_header("Accept") == "application/vnd.github+json"
    assert opener.timeouts == [buildlight.TIMEOUT]


def test_a_token_is_sent_as_a_bearer_header_and_nowhere_else() -> None:
    opener = FakeOpener(ok("success"))
    gh = GitHub("o/r", "ci.yml", "main", token=TOKEN, urlopen=opener)
    gh()
    req = opener.requests[0]
    assert req.get_header("Authorization") == f"Bearer {TOKEN}"
    assert TOKEN not in req.full_url
    assert TOKEN not in repr(gh)
    assert "token" in repr(gh)


def test_an_empty_token_is_no_token() -> None:
    opener = FakeOpener(ok("success"))
    gh = GitHub("o/r", "ci.yml", "main", token="", urlopen=opener)
    gh()
    assert opener.requests[0].get_header("Authorization") is None
    assert "no token" in repr(gh)


def test_the_etag_is_sent_back_and_a_304_returns_the_kept_answer() -> None:
    opener = FakeOpener(
        ok("in_progress", etag='W/"one"'),
        http_error(304, b"", {"ETag": 'W/"one"', "X-RateLimit-Remaining": "59"}),
    )
    gh = GitHub("o/r", "ci.yml", "main", urlopen=opener)
    first = gh()
    second = gh()
    assert opener.requests[0].get_header("If-none-match") is None
    assert opener.requests[1].get_header("If-none-match") == 'W/"one"'
    assert second.status == 200
    assert second.body == first.body
    assert second.headers["X-RateLimit-Remaining"] == "59"


def test_a_304_with_nothing_kept_is_not_a_pass() -> None:
    # Cannot happen if GitHub keeps to the protocol; if it does, say so.
    gh = GitHub("o/r", "ci.yml", "main", urlopen=FakeOpener(http_error(304, None, {})))
    resp = gh()
    assert resp.status == 304
    assert state_from(resp.status, resp.headers, resp.body) is State.UNREACHABLE


def test_an_answer_with_no_etag_or_a_bad_body_is_not_kept() -> None:
    opener = FakeOpener(
        ok("success", etag=None),
        FakeResp(200, b"not json", {"ETag": '"x"'}),
        ok("success", etag=None),
    )
    gh = GitHub("o/r", "ci.yml", "main", urlopen=opener)
    gh()
    bad = gh()
    assert bad.body is None
    gh()
    assert all(r.get_header("If-none-match") is None for r in opener.requests)


def test_an_http_error_keeps_its_status_headers_and_body() -> None:
    body = json.dumps(fixture("rate_limited")).encode()
    opener = FakeOpener(http_error(403, body, {"X-RateLimit-Remaining": "0"}))
    resp = GitHub("o/r", "ci.yml", "main", urlopen=opener)()
    assert resp.status == 403
    assert resp.headers["X-RateLimit-Remaining"] == "0"
    assert state_from(resp.status, resp.headers, resp.body) is State.RATE_LIMITED


def test_an_http_error_with_no_body() -> None:
    resp = GitHub("o/r", "w", "b", urlopen=FakeOpener(http_error(502, None, {})))()
    assert resp.status == 502
    assert resp.body is None


@pytest.mark.parametrize(
    "exc",
    [
        urllib.error.URLError("Temporary failure in name resolution"),
        TimeoutError("timed out"),
        ConnectionResetError("reset"),
        ValueError("unknown url type"),
    ],
)
def test_no_answer_is_a_response_with_no_status_and_a_reason(exc: Exception) -> None:
    resp = GitHub("o/r", "w", "b", token=TOKEN, urlopen=FakeOpener(exc))()
    assert resp.status is None
    assert resp.error is not None
    assert type(exc).__name__ in resp.error
    assert TOKEN not in resp.error


def test_the_default_opener_is_looked_up_when_made() -> None:
    gh = GitHub("o/r", "w", "b")
    with pytest.raises(AssertionError, match="network"):
        gh()


# --- run --------------------------------------------------------------------


class FakePanel:
    def __init__(self) -> None:
        self.frames: list[tuple[str, ...]] = []
        self.off = 0

    def matrix_frame(self, rows: Any) -> None:
        self.frames.append(tuple(rows))

    def matrix_off(self) -> None:
        self.off += 1


class Script:
    def __init__(self, *responses: Response) -> None:
        self.responses = list(responses)

    def __call__(self) -> Response:
        return self.responses.pop(0)


def passing() -> Response:
    return Response(200, {}, fixture("success"))


def failing() -> Response:
    return Response(200, {}, fixture("failure"))


def running() -> Response:
    return Response(200, {}, fixture("in_progress"))


def test_one_poll_is_one_picture_and_no_wait() -> None:
    panel = FakePanel()
    sleeps: list[float] = []
    logs: list[str] = []
    state = buildlight.run(
        panel, Script(passing()), 60, count=1, sleep=sleeps.append, log=logs.append
    )
    assert state is State.PASSING
    assert panel.frames == [CHECK]
    assert sleeps == []
    assert logs == ["passing: run #301 completed success 2140ab2"]


def test_it_waits_the_interval_between_polls_and_logs_only_changes() -> None:
    panel = FakePanel()
    sleeps: list[float] = []
    logs: list[str] = []
    buildlight.run(
        panel,
        Script(passing(), passing(), failing()),
        60,
        count=3,
        sleep=sleeps.append,
        now=lambda: 0.0,
        log=logs.append,
    )
    assert panel.frames == [CHECK, CHECK, CROSS]
    assert sleeps == [60, 60]
    assert [line.split(":")[0] for line in logs] == ["passing", "failing"]


def test_the_bar_moves_while_a_run_is_running(capsys: pytest.CaptureFixture[str]) -> None:
    panel = FakePanel()
    sleeps: list[float] = []
    buildlight.run(panel, Script(running(), running()), 1.0, count=2, sleep=sleeps.append)
    # The default log is stdout, the journal under systemd; once per change.
    assert capsys.readouterr().out == "running: run #301 in_progress 2140ab2\n"
    steps = int(1.0 / buildlight.ANIM_STEP)
    assert sleeps == [buildlight.ANIM_STEP] * steps
    # The first frame, one per step while waiting, then the next poll's - and
    # the bar carries on from where it was rather than jumping back.
    assert panel.frames == [running_frame(i) for i in range(steps + 2)]


def test_a_wait_shorter_than_a_frame_still_moves_the_bar_once() -> None:
    panel = FakePanel()
    sleeps: list[float] = []
    buildlight.run(panel, Script(running(), passing()), 0.1, count=2, sleep=sleeps.append)
    assert sleeps == [buildlight.ANIM_STEP]
    assert panel.frames == [running_frame(0), running_frame(1), CHECK]


def test_unreachable_backs_off_and_a_good_answer_resets_it() -> None:
    panel = FakePanel()
    sleeps: list[float] = []
    logs: list[str] = []
    down = Response(None, error="URLError: down")
    buildlight.run(
        panel,
        Script(down, down, down, passing(), passing()),
        60,
        count=5,
        sleep=sleeps.append,
        now=lambda: 0.0,
        log=logs.append,
    )
    assert sleeps == [60, 120, 240, 60]
    assert panel.frames[:3] == [QUESTION] * 3
    assert logs == ["unreachable: URLError: down", "passing: run #301 completed success 2140ab2"]


def test_rate_limited_waits_for_the_reset_and_says_so() -> None:
    panel = FakePanel()
    sleeps: list[float] = []
    logs: list[str] = []
    limited = Response(
        403, {"x-ratelimit-remaining": "0", "x-ratelimit-reset": "1300"}, fixture("rate_limited")
    )
    buildlight.run(
        panel,
        Script(limited, passing()),
        60,
        count=2,
        sleep=sleeps.append,
        now=lambda: 1000.0,
        log=logs.append,
    )
    assert sleeps == [301]
    assert panel.frames == [QUESTION, CHECK]
    assert logs[0].startswith("rate-limited: HTTP 403: API rate limit exceeded")
    assert logs[1] == "GitHub asked to wait: next poll in 301s"


def test_the_loop_runs_until_interrupted() -> None:
    panel = FakePanel()

    def stop_after_three(seconds: float) -> None:
        if len(panel.frames) >= 3:
            raise KeyboardInterrupt

    with pytest.raises(KeyboardInterrupt):
        buildlight.run(panel, lambda: passing(), 60, sleep=stop_after_three, log=lambda s: None)
    assert panel.frames == [CHECK] * 3


# --- main -------------------------------------------------------------------


class FakeMCU(FakePanel):
    made: ClassVar[list[FakeMCU]] = []

    def __init__(self, port: str) -> None:
        super().__init__()
        self.port = port
        self.closed = False
        FakeMCU.made.append(self)

    def __enter__(self) -> FakeMCU:
        return self

    def __exit__(self, *a: object) -> None:
        self.closed = True


@pytest.fixture
def wired(monkeypatch: pytest.MonkeyPatch) -> dict[str, Any]:
    """main() with a fake MCU and a fake GitHub, recording what it was given."""
    FakeMCU.made = []
    seen: dict[str, Any] = {}
    opener = FakeOpener(ok("success"), ok("success"), ok("success"))
    seen["opener"] = opener
    monkeypatch.setattr(buildlight, "MCU", FakeMCU)
    monkeypatch.setattr(buildlight, "URLOPEN", opener)

    def fake_run(panel: Any, fetch: Any, interval: float, count: int | None) -> State:
        seen.update(panel=panel, fetch=fetch, interval=interval, count=count)
        resp = fetch()
        panel.matrix_frame(glyph(state_from(resp.status, resp.headers, resp.body)))
        if count is None and "interrupt" in seen:
            raise KeyboardInterrupt
        return State.PASSING

    monkeypatch.setattr(buildlight, "run", fake_run)
    return seen


def test_main_once_draws_and_leaves_the_picture_up(
    wired: dict[str, Any], capsys: pytest.CaptureFixture[str]
) -> None:
    assert buildlight.main(["--once"]) == 0
    mcu = FakeMCU.made[0]
    assert mcu.frames == [CHECK]
    assert mcu.off == 0  # a hand run is to look at
    assert mcu.closed
    assert wired["count"] == 1
    assert wired["interval"] == 60
    assert wired["fetch"].url.startswith(
        "https://api.github.com/repos/jim-wyatt/two-computers-one-board/actions/workflows/ci.yml/"
    )
    assert "branch=main" in wired["fetch"].url
    out = capsys.readouterr().out
    assert "without a token" in out


def test_main_as_a_daemon_blanks_the_panel_when_it_stops(wired: dict[str, Any]) -> None:
    wired["interrupt"] = True
    assert buildlight.main([]) == 0
    assert wired["count"] is None
    assert FakeMCU.made[0].off == 1


def test_main_reads_its_settings_from_the_environment(
    wired: dict[str, Any], monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("UNOQ_BUILDLIGHT_REPO", "someone/else")
    monkeypatch.setenv("UNOQ_BUILDLIGHT_WORKFLOW", "build.yml")
    monkeypatch.setenv("UNOQ_BUILDLIGHT_BRANCH", "release")
    monkeypatch.setenv("UNOQ_BUILDLIGHT_INTERVAL", "120")
    monkeypatch.setenv("UNOQ_BUILDLIGHT_TOKEN", f" {TOKEN}\n")
    assert buildlight.main(["--once", "--port", "/dev/ttyX"]) == 0
    assert wired["fetch"].url == (
        "https://api.github.com/repos/someone/else/actions/workflows/build.yml/runs"
        "?branch=release&per_page=1"
    )
    assert wired["interval"] == 120
    assert FakeMCU.made[0].port == "/dev/ttyX"
    assert wired["opener"].requests[0].get_header("Authorization") == f"Bearer {TOKEN}"
    out, err = capsys.readouterr()
    assert "with a token" in out
    # The point of the whole exercise: it is said that there is one, never what.
    assert TOKEN not in out + err


def test_main_has_no_token_option() -> None:
    with pytest.raises(SystemExit):
        buildlight.main(["--token", TOKEN])


@pytest.mark.parametrize(
    ("value", "says"), [("soon", "is not a number"), ("0", "more than 0"), ("-5", "more than 0")]
)
def test_main_refuses_a_bad_interval_in_the_environment(
    monkeypatch: pytest.MonkeyPatch, value: str, says: str
) -> None:
    monkeypatch.setenv("UNOQ_BUILDLIGHT_INTERVAL", value)
    with pytest.raises(SystemExit, match=says):
        buildlight.main(["--once"])


def test_main_refuses_a_bad_interval_or_repo_on_the_command_line(
    capsys: pytest.CaptureFixture[str],
) -> None:
    with pytest.raises(SystemExit):
        buildlight.main(["--interval", "0"])
    assert "more than 0" in capsys.readouterr().err
    with pytest.raises(SystemExit):
        buildlight.main(["--repo", "not-a-repo"])
    assert "is not owner/name" in capsys.readouterr().err


def test_main_reports_an_mcu_that_will_not_open(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    def busy(port: str) -> Any:
        raise MCUError("/dev/ttyHS1 is held by unoq-cpu-bars")

    monkeypatch.setattr(buildlight, "MCU", busy)
    assert buildlight.main(["--once"]) == 1
    assert "held by unoq-cpu-bars" in capsys.readouterr().err


def test_main_reports_a_firmware_without_frames(
    wired: dict[str, Any], monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    def old(self: Any, rows: Any) -> None:
        raise MCUError("'app matrix frame ...': command not found")

    monkeypatch.setattr(FakeMCU, "matrix_frame", old)
    assert buildlight.main([]) == 1
    assert "command not found" in capsys.readouterr().err
    assert FakeMCU.made[0].off == 1


def test_main_says_so_when_the_panel_cannot_be_blanked(
    wired: dict[str, Any], monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    def gone(self: Any) -> None:
        raise MCUError("no prompt")

    wired["interrupt"] = True
    monkeypatch.setattr(FakeMCU, "matrix_off", gone)
    assert buildlight.main([]) == 0
    assert "could not blank the panel: no prompt" in capsys.readouterr().err
