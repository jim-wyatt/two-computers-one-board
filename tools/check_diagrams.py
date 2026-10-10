#!/usr/bin/env python3
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""Drive ONE headless browser over every page that carries a diagram.

    tools/check-diagrams.sh          # what you run; it calls this

This is the half of the gate that talks to the browser. The shell script finds
one, builds and serves the site, and cleans up; this launches the browser once,
points a single tab at each page in turn, and asks the page itself how many of
its diagrams are now SVG.

WHY ONE BROWSER
---------------
The gate used to launch a browser per page with --dump-dom. That cost ~5.5s a
launch on the board, and every one of its three failures on a CI runner came
from the launching rather than from the looking: a hang, a profile lock shared
between launches, and a chromium that never exited from --dump-dom at all. One
long-lived browser has none of those. Nothing waits for a process to exit, so a
browser that will not exit cannot be mistaken for a diagram that will not draw.

WHY A PIPE, AND WHY NO DEPENDENCY
---------------------------------
The DevTools protocol is JSON messages. The usual way to carry them is a
WebSocket on a TCP port (--remote-debugging-port), which needs a WebSocket
client - a dependency, or a hand-written one - plus a port to choose, an HTTP
request to discover the socket's url, and a wait for the port to open.

--remote-debugging-pipe carries the same messages over two inherited file
descriptors instead: the browser reads commands on fd 3 and writes replies on
fd 4, each message terminated by a NUL byte. No port, no handshake, no framing
beyond that one byte, nothing to race against at startup, and nothing else on
the machine can connect to it. It is what Playwright and Puppeteer use to drive
Chromium themselves, so it is not a back door that might quietly rot.

So this file is standard library only, and runs under the system python3 with
no venv - which matters, because the gate must mean the same on the board, on a
CI runner and on a laptop, and "a browser and python3" is all three have.

WHAT IT ASSERTS
---------------
A diagram has drawn when its <pre class="unoq-mermaid"> CONTAINS an <svg> that
is not mermaid's error graphic. That is stricter than counting `data-processed`,
which mermaid sets before it has drawn anything and sets just the same on a
diagram it could not parse. A page passes when every block it has on disk has
drawn and there is no error graphic anywhere in the document.

A diagram that drew must also be READABLE: its lettering displayed at a legible
size and the drawing no wider than its column, at a desktop window. See
MIN_TEXT_PX below for the measurement that made this part of the gate.

EXIT STATUS - three answers, because conflating the last two has cost days
    0   every diagram on every page drew
    1   the SITE is wrong: some diagram did not draw, or cannot be read
    2   the HARNESS is wrong: the browser did not start, stopped answering, or
        the self-test fixtures came back with the wrong verdicts. Nothing this
        run says about the site should be believed.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import io
import json
import os
import select
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any
from urllib.parse import quote

MARKER = 'class="unoq-mermaid"'

# Asked of the page itself, so the answer is about the live DOM after scripts
# have run rather than about the HTML that was served.
#
# `errors` looks at the whole document, not just inside the blocks: when mermaid
# cannot parse a diagram it draws its "Syntax error in text" graphic into a
# temporary container of its own, and where that ends up has changed between
# versions. Wherever it is, it carries one of these two marks.
STATE_JS = """
(() => {
  const blocks = [...document.querySelectorAll("pre.unoq-mermaid")];
  const drawn = blocks.filter((el) => {
    const svg = el.querySelector("svg");
    return svg && svg.getAttribute("aria-roledescription") !== "error";
  }).length;
  // How each drawn diagram ended up on the screen: the size its smallest
  // lettering is DISPLAYED at, which is the font size times however much the
  // drawing was scaled, and whether it is wider than the block that holds it.
  const sizes = blocks.map((el, i) => {
    const svg = el.querySelector("svg");
    if (!svg || svg.getAttribute("aria-roledescription") === "error") return null;
    const box = svg.getBoundingClientRect();
    const natural = svg.viewBox.baseVal.width;
    const scale = natural ? box.width / natural : 1;
    let text = Infinity;
    svg.querySelectorAll("foreignObject *, text, tspan").forEach((t) => {
      if (t.children.length || !t.textContent.trim()) return;
      text = Math.min(text, parseFloat(getComputedStyle(t).fontSize) * scale);
    });
    return {
      n: i + 1,
      text: Number.isFinite(text) ? Math.round(text * 10) / 10 : null,
      width: Math.round(box.width),
      room: Math.round(el.clientWidth),
    };
  }).filter(Boolean);
  return {
    href: location.href,
    ready: document.readyState,
    blocks: blocks.length,
    drawn: drawn,
    sizes: sizes,
    marked: blocks.filter((el) => el.getAttribute("data-processed")).length,
    errors: document.querySelectorAll(
      '[aria-roledescription="error"], .error-text').length,
  };
})()
"""

# DRAWN IS NOT THE SAME AS READABLE
#
# A diagram that drew can still be useless. Mermaid's default is to scale a
# drawing down until it fits the column, lettering and all: measured in this
# site's 688px text column, one diagram's 16px labels were on screen at 5.9px
# and four more were under 10px. Every one of them "drew".
#
# So two more things are asked of each diagram, at a desktop window:
#
#   - its smallest lettering is displayed at MIN_TEXT_PX or more
#   - it is no wider than the block it sits in, so nobody scrolls sideways
#
# The window is fixed so the answer does not depend on the machine. 1440 wide
# is past the point where the theme shows both sidebars, which is when the text
# column is at its NARROWEST for a desktop (688px); a diagram that fits there
# fits every wider or narrower desktop layout. A phone is not checked: there a
# wide diagram scrolls, by design - see extra.css.
MIN_TEXT_PX = 12.0
VIEWPORT = {"width": 1440, "height": 900, "deviceScaleFactor": 1, "mobile": False}


def unreadable(sizes: list[dict[str, Any]]) -> str:
    """Why the drawn diagrams on a page cannot be read, or "" if they can."""
    faults = []
    for d in sizes:
        if d["text"] is not None and d["text"] < MIN_TEXT_PX:
            faults.append(
                f"diagram {d['n']}: lettering is displayed at {d['text']:g}px "
                f"(under {MIN_TEXT_PX:g}px) - it was scaled down to fit"
            )
        elif d["width"] > d["room"] + 1:
            faults.append(
                f"diagram {d['n']}: {d['width']}px wide in a {d['room']}px column - "
                f"lay it out top to bottom, or split it"
            )
    return "; ".join(faults)


# Once an error graphic is on the page the verdict cannot improve, so stop
# waiting for it to - but give the other diagrams a moment to finish, so the
# "N of M drew" in the report is the real number.
SETTLE_AFTER_ERROR = 0.5
POLL = 0.05
# The fixture that deliberately never draws would otherwise cost the whole
# budget on every run, to learn something that no amount of waiting changes.
UNDRAWN_BUDGET = 1.5


class HarnessError(Exception):
    """The browser, not the site: it did not start, died, or stopped answering."""


class Browser:
    """One headless browser, one tab, spoken to over --remote-debugging-pipe."""

    def __init__(self, binary: str, profile: Path, log: Path, pidfile: Path | None) -> None:
        self._next_id = 0
        self._buffer = b""
        self._session: str | None = None
        self._answering = True
        self.events: list[dict[str, Any]] = []
        self.log = log
        self.pidfile = pidfile

        to_browser_r, self._tx = os.pipe()
        self._rx, from_browser_w = os.pipe()
        # Moved out of the way first. The browser wants these on fds 3 and 4
        # exactly, and os.pipe() may well have just handed out 3 and 4 - in
        # which case dup2(3, 3) is a no-op that leaves close-on-exec set, and
        # the browser starts with no pipe and no way to say so.
        child_r = fcntl.fcntl(to_browser_r, fcntl.F_DUPFD_CLOEXEC, 10)
        child_w = fcntl.fcntl(from_browser_w, fcntl.F_DUPFD_CLOEXEC, 10)
        os.close(to_browser_r)
        os.close(from_browser_w)

        def wire_pipe() -> None:
            os.dup2(child_r, 3)
            os.dup2(child_w, 4)

        argv = [
            binary,
            # Plain --headless. chrome-headless-shell is headless whatever it
            # is told; a full chromium needs the flag; neither wants a mode
            # spelled out, and =old was removed in Chrome 132.
            "--headless",
            "--remote-debugging-pipe",
            f"--user-data-dir={profile}",
            # No sandbox: a CI runner has no user namespaces to build one from,
            # and the only content this browser ever loads is the site this
            # repository just built, from 127.0.0.1.
            "--no-sandbox",
            "--disable-gpu",
            # CI containers give /dev/shm 64 MB, where chrome deadlocks rather
            # than failing.
            "--disable-dev-shm-usage",
            "--no-first-run",
            "--disable-extensions",
            "--disable-background-networking",
            "about:blank",
        ]
        with log.open("wb") as err:
            # Its own session, so that everything it forks - zygote, renderer,
            # GPU process - can be killed as one group and nothing outlives us.
            #
            # close_fds=False because the default closes everything above 2
            # AFTER preexec_fn has run, taking the two descriptors just wired
            # up with it. Nothing else leaks: every descriptor python opens is
            # close-on-exec already. preexec_fn is safe here for the reason the
            # docs give for avoiding it - this program has no threads.
            self.proc = subprocess.Popen(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=err,
                preexec_fn=wire_pipe,
                close_fds=False,
                start_new_session=True,
            )
        os.close(child_r)
        os.close(child_w)
        if pidfile is not None:
            # For the shell script's trap: if THIS process is killed outright,
            # somebody still has to know which process group to take down.
            pidfile.write_text(f"{self.proc.pid}\n")

    # -- the wire ----------------------------------------------------------

    def _read_message(self, deadline: float) -> dict[str, Any]:
        while b"\0" not in self._buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                self._answering = False
                raise HarnessError("the browser stopped answering")
            ready, _, _ = select.select([self._rx], [], [], remaining)
            if not ready:
                continue
            chunk = os.read(self._rx, 1 << 16)
            if not chunk:
                self._answering = False
                with contextlib.suppress(subprocess.TimeoutExpired):
                    self.proc.wait(timeout=1)
                status = self.proc.poll()
                raise HarnessError(
                    "the browser closed its end of the pipe"
                    + (f" and exited with status {status}" if status is not None else "")
                )
            self._buffer += chunk
        raw, self._buffer = self._buffer.split(b"\0", 1)
        message: dict[str, Any] = json.loads(raw)
        return message

    def call(self, method: str, params: dict[str, Any], deadline: float) -> dict[str, Any]:
        """Send one command and return its result, or raise if none comes in time."""
        self._next_id += 1
        want = self._next_id
        message: dict[str, Any] = {"id": want, "method": method, "params": params}
        if self._session is not None:
            message["sessionId"] = self._session
        try:
            os.write(self._tx, json.dumps(message).encode() + b"\0")
        except OSError as exc:
            raise HarnessError(f"could not write to the browser: {exc}") from exc
        while True:
            reply = self._read_message(deadline)
            if reply.get("id") != want:
                # Not ours: an event. Kept, because an exception thrown on the
                # page is the best available explanation for a failure.
                self.events.append(reply)
                continue
            if "error" in reply:
                raise HarnessError(f"{method} was refused: {reply['error'].get('message')}")
            result: dict[str, Any] = reply.get("result", {})
            return result

    # -- lifecycle ---------------------------------------------------------

    def open_tab(self, deadline: float) -> str:
        """Open the one tab everything is loaded into; return the browser's name."""
        version = self.call("Browser.getVersion", {}, deadline)
        target = self.call("Target.createTarget", {"url": "about:blank"}, deadline)
        attached = self.call(
            "Target.attachToTarget", {"targetId": target["targetId"], "flatten": True}, deadline
        )
        self._session = attached["sessionId"]
        # For Runtime.exceptionThrown. See call().
        self.call("Runtime.enable", {}, deadline)
        return str(version.get("product", "unknown browser"))

    def close(self) -> None:
        """Stop the browser. Never raises, never waits long, leaves nothing running."""
        if self._answering and self.proc.poll() is None:
            self._session = None
            # Asked nicely first, so the profile is closed rather than torn.
            # Not if it has already gone quiet: it would only cost the wait.
            with contextlib.suppress(HarnessError, KeyError):
                self.call("Browser.close", {}, time.monotonic() + 3)
            with contextlib.suppress(subprocess.TimeoutExpired):
                self.proc.wait(timeout=3)
        # Then the whole group regardless. The polite path leaves stragglers
        # often enough - and the impolite one, where the browser is hung, is
        # the entire reason this gate was once removed from CI.
        with contextlib.suppress(ProcessLookupError, PermissionError):
            os.killpg(self.proc.pid, signal.SIGKILL)
        with contextlib.suppress(subprocess.TimeoutExpired):
            self.proc.wait(timeout=5)
        for fd in (self._tx, self._rx):
            with contextlib.suppress(OSError):
                os.close(fd)
        if self.pidfile is not None and self.proc.poll() is not None:
            self.pidfile.unlink(missing_ok=True)

    def said(self, lines: int = 20) -> str:
        """The head of the browser's own stderr - the only thing that can say why."""
        try:
            text = self.log.read_text(errors="replace")
        except OSError:
            return ""
        return "\n".join(text.splitlines()[:lines])


def thrown(events: list[dict[str, Any]]) -> str:
    """The first exception the page threw, as one line, or ''."""
    for event in events:
        if event.get("method") != "Runtime.exceptionThrown":
            continue
        details = event.get("params", {}).get("exceptionDetails", {})
        text = str(details.get("exception", {}).get("description") or "")
        # mermaid rejects with a plain object, which the protocol describes as
        # the single word "Object". That explains nothing; say nothing.
        if text and text != "Object":
            return text.splitlines()[0][:160]
    return ""


def inspect(
    browser: Browser, url: str, want: int, budget: float, page_timeout: float
) -> tuple[bool, str]:
    """Load one page and say whether all `want` of its diagrams drew.

    Two clocks, and they mean different things. `budget` is how long the page
    has to draw; running out of it is the page's failure and is reported as
    one. `page_timeout` is how long the browser has to answer at all; running
    out of that raises HarnessError and ends the run.
    """
    started = time.monotonic()
    hard = started + page_timeout
    give_up = min(started + budget, hard)
    browser.events.clear()

    navigated = browser.call("Page.navigate", {"url": url}, hard)
    if navigated.get("errorText"):
        return False, f"did not load: {navigated['errorText']}"

    state: dict[str, Any] = {}
    while True:
        reply = browser.call(
            "Runtime.evaluate", {"expression": STATE_JS, "returnByValue": True}, hard
        )
        # No value means the old document was being torn down under us.
        # Normal for the first poll or two after a navigation; ask again.
        value = reply.get("result", {}).get("value")
        # The href check is not paranoia: until the navigation commits, the
        # tab is still showing the PREVIOUS page, and would happily report
        # that page's diagrams as this one's.
        if isinstance(value, dict) and value.get("href") == url:
            state = value
            if state["errors"]:
                give_up = min(give_up, time.monotonic() + SETTLE_AFTER_ERROR)
            elif state["ready"] == "complete" and state["drawn"] == want == state["blocks"]:
                why = unreadable(state["sizes"])
                if why:
                    return False, f"{want} of {want} drew, but: {why}"
                return True, f"{want} of {want} drew"
        if time.monotonic() >= give_up:
            break
        time.sleep(POLL)

    if not state:
        return False, "the page never became the current document"
    why = thrown(browser.events)
    tail = f" - {why}" if why else ""
    if state["errors"]:
        return False, (
            f'mermaid drew its "Syntax error in text" graphic '
            f"({state['drawn']} of {want} drew){tail}"
        )
    if state["blocks"] != want:
        return False, f"{want} blocks on disk but {state['blocks']} in the page{tail}"
    if not state["marked"]:
        return False, f"0 of {want} drew - nothing ever called mermaid.run() on them{tail}"
    return False, f"{state['drawn']} of {want} drew within {budget:g}s{tail}"


def pages_with_diagrams(site: Path) -> list[tuple[str, int]]:
    """Every page that has diagrams on disk, with how many. The fixtures excluded."""
    found = []
    for path in sorted(site.rglob("*.html")):
        if path.name.startswith("_selftest"):
            continue
        count = path.read_text(encoding="utf-8", errors="replace").count(MARKER)
        if count:
            found.append((path.relative_to(site).as_posix(), count))
    return found


def run(args: argparse.Namespace, browser: Browser) -> int:
    def url(page: str) -> str:
        return f"{args.base.rstrip('/')}/{quote(page)}"

    budget = args.budget_ms / 1000
    began = time.monotonic()
    product = browser.open_tab(began + args.page_timeout)
    # A fixed window, so "does it fit" has one answer everywhere. See VIEWPORT.
    browser.call("Emulation.setDeviceMetricsOverride", VIEWPORT, began + args.page_timeout)
    print(f"  browser up in {time.monotonic() - began:.2f}s: {product}")

    # SELF-TEST FIRST, in both directions.
    #
    # A fixture that must draw proves the browser, the vendored library and the
    # init script work together, so a failure on a real page is that page's
    # fault. Fixtures that must NOT pass prove the opposite and rarer thing:
    # that this gate is still capable of saying no. It has said yes to a site
    # where every diagram was an error box before.
    wrong = []
    for name in args.selftest_ok:
        ok, detail = inspect(browser, url(name), 1, budget, args.page_timeout)
        print(f"  self  {name:<46} {'drew, as it must' if ok else 'DID NOT DRAW'}")
        if not ok:
            wrong.append(f"{name} must draw and did not: {detail}")
    for name in args.selftest_bad:
        # The one with a syntax error ends itself as soon as the error graphic
        # appears; only the one that never draws would run the clock out.
        short = UNDRAWN_BUDGET if "undrawn" in name else budget
        ok, detail = inspect(browser, url(name), 1, min(short, budget), args.page_timeout)
        print(f"  self  {name:<46} {'PASSED, and must not' if ok else 'failed, as it must'}")
        if ok:
            wrong.append(f"{name} is broken on purpose and was reported as drawn")
    if wrong:
        raise HarnessError("the self-test gave the wrong answer\n  " + "\n  ".join(wrong))

    pages = pages_with_diagrams(args.site)
    if not pages:
        # A site with no diagrams would pass everything below in silence,
        # which is how a gate goes quiet on the day the last one is deleted.
        print(f"no page under {args.site} contains a diagram", file=sys.stderr)
        return 1

    failed = 0
    total = 0
    for page, want in pages:
        t0 = time.monotonic()
        ok, detail = inspect(browser, url(page), want, budget, args.page_timeout)
        print(f"  {'ok  ' if ok else 'FAIL'}  {page:<46} {detail}  ({time.monotonic() - t0:.2f}s)")
        if ok:
            total += want
        else:
            failed += 1

    elapsed = time.monotonic() - began
    if failed:
        print(
            f"{failed} of {len(pages)} pages have diagrams that did not draw "
            f"or cannot be read ({elapsed:.1f}s)"
        )
        return 1
    print(
        f"{total} diagrams drew, at a readable size, across {len(pages)} pages, "
        f"in one browser, in {elapsed:.1f}s"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--browser", required=True)
    parser.add_argument("--site", required=True, type=Path)
    parser.add_argument("--base", required=True, help="where the site is being served")
    parser.add_argument("--work", required=True, type=Path, help="scratch dir, ours to fill")
    parser.add_argument("--budget-ms", type=int, default=8000)
    parser.add_argument("--page-timeout", type=float, default=45)
    parser.add_argument("--selftest-ok", action="append", default=[])
    parser.add_argument("--selftest-bad", action="append", default=[])
    args = parser.parse_args()

    # In a CI log stdout is a pipe, and block-buffered: without this the
    # per-page lines arrive after the stderr that explains them.
    if isinstance(sys.stdout, io.TextIOWrapper):
        sys.stdout.reconfigure(line_buffering=True)

    # `timeout` sends TERM, a terminal sends INT or HUP. All three must unwind
    # through the `finally` below rather than leave a browser behind.
    def stop(signum: int, _frame: object) -> None:
        raise HarnessError(f"interrupted by {signal.Signals(signum).name}")

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, stop)

    try:
        browser = Browser(
            args.browser, args.work / "profile", args.work / "browser.log", args.work / "pid"
        )
    except OSError as exc:
        print(
            f"THE HARNESS IS BROKEN, not the site: cannot run {args.browser}: {exc}",
            file=sys.stderr,
        )
        return 2
    try:
        return run(args, browser)
    except HarnessError as exc:
        print(f"\nTHE HARNESS IS BROKEN, not the site: {exc}", file=sys.stderr)
        said = browser.said()
        if said:
            print(f"--- what the browser said, verbatim ---\n{said}\n---", file=sys.stderr)
        return 2
    finally:
        browser.close()


if __name__ == "__main__":
    sys.exit(main())
