#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Do the mermaid diagrams actually draw?
#
#   tools/check-diagrams.sh
#
# WHY THIS EXISTS
# ---------------
# Because they did not, and nothing noticed. Twelve diagrams were added to the
# course, the build was clean, `--strict` was happy, the markup was right, the
# library was vendored and served with a 200 - and every one of them came out as
# a block of grey text, on every page, for hours.
#
# Nothing in a static-site build can catch that. The failure is in the browser,
# after the page loads, and the page is perfectly valid either way. The only
# honest test is to open it in a browser and look, so that is what this does:
# serves the built site, loads each page that contains a diagram in a headless
# browser, and asks the page how many of its diagrams are now SVG.
#
# HOW, AND WHY NOT THE WAY IT USED TO
# -----------------------------------
# It used to launch a browser per page with --dump-dom and grep what came out.
# Launching was nearly all of the cost (~5.5s of each ~7s page on the board)
# and all of the trouble: on a CI runner it hung, then tripped over a profile
# lock shared between launches, then met a chromium that never exits from
# --dump-dom, and was taken out of CI with zero true findings to its name.
#
# Now ONE browser is launched and driven over the DevTools protocol - navigate,
# ask, navigate, ask - by tools/check_diagrams.py, which explains the protocol
# choice (a pipe, not a WebSocket, so no dependency at all). Nothing waits for a
# browser to exit any more, so "the browser is stuck" and "the diagram did not
# draw" can no longer be the same symptom. A dozen pages take a few seconds.
#
# This script is the part around that: find a browser, build and serve the
# site, write the self-test fixtures, and take everything down again - on every
# way out, including the ones where the helper is killed.
#
# It needs a browser and python3, and nothing from the venv.
set -uo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
SITE="${UNOQ_SITE:-$PROJECT/share/learn}"
PORT="${UNOQ_DIAGRAM_PORT:-8099}"
# How long a page has to draw its diagrams. Running out is that PAGE failing.
# A healthy page is done in well under a second; this is only ever spent in
# full on a page that is not going to draw however long it is given.
BUDGET_MS="${UNOQ_DIAGRAM_BUDGET_MS:-8000}"
# How long the browser has to start, and to answer while on any one page.
# Running out is the BROWSER failing: it is killed and the gate stops there,
# rather than spending this long again on each of the pages left.
PAGE_TIMEOUT="${UNOQ_DIAGRAM_PAGE_TIMEOUT:-45}"

# Which browser. Anything Chromium-based that understands
# --remote-debugging-pipe, which is all of them:
#
#   the board    Debian's `chromium`, aarch64
#   CI           a pinned chrome-headless-shell, handed over in
#                UNOQ_DIAGRAM_BROWSER - see the diagrams job in ci.yml for why
#                it is not whatever the runner image happens to ship
#   elsewhere    whichever of the usual names is on PATH
#
# chromium first, so the board and a laptop with both installed agree.
BROWSER="${UNOQ_DIAGRAM_BROWSER:-}"
if [ -n "$BROWSER" ]; then
  # Set means MEANT. Falling back to PATH when the named one is missing would
  # quietly test with a different browser from the one somebody pinned.
  if ! command -v "$BROWSER" >/dev/null 2>&1; then
    echo "UNOQ_DIAGRAM_BROWSER=$BROWSER is not an executable" >&2
    exit 1
  fi
else
  for candidate in chromium chromium-browser chrome-headless-shell \
    google-chrome google-chrome-stable chrome; do
    if command -v "$candidate" >/dev/null 2>&1; then
      BROWSER="$candidate"
      break
    fi
  done
fi
if [ -z "$BROWSER" ]; then
  echo "no chromium/chrome on PATH - cannot check whether the diagrams render" >&2
  echo "  install one, or point UNOQ_DIAGRAM_BROWSER at one, or skip this gate with:" >&2
  echo "  tools/check.sh python shell c docs workflows" >&2
  exit 1
fi

# Build first rather than trusting whatever is on disk. share/learn is generated
# and gitignored, so switching branches leaves the previous branch's site there -
# and this gate then reports eleven confident failures about markup that is
# perfectly fine on the branch you are actually on. Costs ~8s; worth it to make
# the script mean the same thing standalone as it does inside check.sh.
if [ -z "${UNOQ_SITE:-}" ]; then
  "$PROJECT/tools/build-docs.sh" >/dev/null || {
    echo "tools/build-docs.sh failed - fix that before checking the diagrams" >&2
    exit 1
  }
fi

if [ ! -d "$SITE" ]; then
  echo "$SITE does not exist - run tools/build-docs.sh first" >&2
  exit 1
fi

lib="$(cd "$SITE" && find assets/external -name 'mermaid*.js' 2>/dev/null | head -1)"
if [ -z "$lib" ]; then
  echo "no vendored mermaid in $SITE - run tools/check-diagram-assets.sh for why" >&2
  exit 1
fi

# ONE cleanup, installed before anything it has to undo exists, and written so
# that every line is safe to run when its thing was never created.
SERVER=""
WORK=""
# shellcheck disable=SC2329  # it IS invoked, by the EXIT trap; shellcheck loses
# sight of that in a script whose last line is an explicit `exit`.
cleanup() {
  [ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null
  if [ -n "$WORK" ]; then
    # The helper kills its own browser on the way out. This is for the day it
    # cannot - killed with -9, or by the ceiling below - and would otherwise
    # leave a headless chromium running on a board with 3.6 GB to its name.
    # The browser leads its own process group, so the pid is the group.
    if [ -s "$WORK/pid" ]; then
      kill -KILL -- "-$(cat "$WORK/pid")" 2>/dev/null
      sleep 0.2
    fi
    rm -rf "$WORK" 2>/dev/null || { sleep 1 && rm -rf "$WORK"; }
  fi
  rm -f "$SITE"/_selftest-*.html
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

WORK="$(mktemp -d)"

# Serve over HTTP rather than pointing the browser at file://. The site is
# meant to work both ways, but a local server is what the board and Pages both
# do, and file:// adds its own failure modes that would muddy this test.
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$SITE" >/dev/null 2>&1 &
SERVER=$!

# Give it a moment to bind, and confirm rather than sleeping and hoping.
for _ in $(seq 1 40); do
  curl -sSf -o /dev/null "http://127.0.0.1:$PORT/index.html" 2>/dev/null && break
  kill -0 "$SERVER" 2>/dev/null || break
  sleep 0.25
done
# ...and confirm it is OURS. If the port was taken, http.server has already
# exited, and the curl above may have been answered by whatever took it - which
# would have every page checked against somebody else's site.
if ! kill -0 "$SERVER" 2>/dev/null; then
  echo "could not serve $SITE on 127.0.0.1:$PORT - is the port in use?" >&2
  echo "  choose another with UNOQ_DIAGRAM_PORT" >&2
  exit 1
fi

# THE SELF-TEST FIXTURES. Written here, judged by the helper before any real
# page is looked at.
#
# Without them, every failure looks like "the diagrams are broken" - and the
# first two were not. One was a profile lock, one was a headless-mode flag. Both
# reported eleven confident failures about markup that was perfectly correct,
# which is the most expensive kind of wrong a gate can be.
#
# All three use the SAME vendored library as the real pages, and the first the
# same init script, so if it draws, the browser and the library both work and a
# failure on a real page is genuinely that page's fault.
#
# They use the <code> wrapper because THAT IS WHAT MKDOCS EMITS.
#
# The first fixture once did not, and that single difference is why this gate
# passed while every real page failed. superfences renders a fence as
# `<pre class="unoq-mermaid"><code>...</code></pre>`, mermaid parses innerHTML,
# and the `<code>` made the source a syntax error - but the fixture wrote bare
# text inside the <pre>, which parses fine. A fixture that does not reproduce
# the real markup only proves the browser works.
#
# Entities too: mkdocs escapes `-->` to `--&gt;` inside the block, so the
# fixture has to carry it escaped or it is not testing the decode path either.
fixture() {
  local name="$1" source="$2" init="$3"
  {
    printf '<!doctype html><html><body>\n'
    printf '<pre class="unoq-mermaid"><code>%s</code></pre>\n' "$source"
    printf '<script src="%s"></script>\n' "$lib"
    [ "$init" = yes ] &&
      printf '<script src="assets/javascripts/mermaid-init.js"></script>\n'
    printf '</body></html>\n'
  } >"$SITE/$name"
}
GOOD='graph LR
  A[in] --&gt; B[out]'
# Must draw.
fixture _selftest-ok.html "$GOOD" yes
# Must NOT pass, in the two ways a diagram has actually failed here: the source
# does not parse and mermaid draws its error graphic instead, and nothing calls
# mermaid.run() so the source sits there as grey text. A gate that cannot fail
# these two is not checking anything, however green it is.
fixture _selftest-syntax.html 'graph LR
  A[in] --&gt;' yes
fixture _selftest-undrawn.html "$GOOD" no

# A ceiling on the whole run, as well as the helper's own clocks. The helper
# bounds every wait it makes; this is for the wait nobody thought of. It is
# generous on purpose - every page failing as slowly as it can, plus the
# browser taking its full allowance twice - because reaching it means a bug in
# the helper, and it must never fire on a run that was merely slow.
pages="$(grep -rl --include='*.html' 'class="unoq-mermaid"' "$SITE" | wc -l)"
CEILING=$((pages * (BUDGET_MS / 1000 + 2) + 2 * PAGE_TIMEOUT))

timeout -k 10 "$CEILING" python3 "$PROJECT/tools/check_diagrams.py" \
  --browser "$BROWSER" \
  --site "$SITE" \
  --base "http://127.0.0.1:$PORT" \
  --work "$WORK" \
  --budget-ms "$BUDGET_MS" \
  --page-timeout "$PAGE_TIMEOUT" \
  --selftest-ok _selftest-ok.html \
  --selftest-bad _selftest-syntax.html \
  --selftest-bad _selftest-undrawn.html
rc=$?

case "$rc" in
  0) exit 0 ;;
  1)
    cat >&2 <<EOF

Diagrams did not render. Things worth checking, in the order they have bitten:

  1. extra_javascript in mkdocs.yml still lists assets/javascripts/mermaid-init.js.
     Without it the library loads and nothing ever calls mermaid.run().
  2. site_url is still unset. With it, the privacy plugin rewrites the vendored
     library to an ABSOLUTE url, which is a network fetch on the USB drive.
  3. The library still publishes a global on its last line. Open
     share/learn/assets/external/.../mermaid.min.js and look for
     globalThis["mermaid"] - if that has gone, mermaid-init.js needs rewriting
     as a module.
  4. The diagram's own source. Paste the fence into https://mermaid.live - a
     syntax error there is a syntax error here.
EOF
    exit 1
    ;;
esac

# Anything else is the harness, and the helper has already said what it saw.
# Add what only this script knows.
if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
  echo "THE HARNESS IS BROKEN, not the site: the helper itself ran past the" >&2
  echo "${CEILING}s ceiling and was killed. That is a bug in tools/check_diagrams.py." >&2
fi
# Prove the server is serving, so a fixture that 404s is never mistaken for a
# browser that cannot render.
printf '\nfixture over HTTP: %s\nlibrary over HTTP: %s\n' \
  "$(curl -sS -m 10 -o /dev/null -w '%{http_code}, %{size_download} bytes' \
    "http://127.0.0.1:$PORT/_selftest-ok.html" 2>&1)" \
  "$(curl -sS -m 10 -o /dev/null -w '%{http_code}, %{size_download} bytes' \
    "http://127.0.0.1:$PORT/$lib" 2>&1)" >&2
cat >&2 <<EOF

That is the browser, this script, or the library - not the documentation.
Nothing above about the site's own pages should be believed.

  browser:  $BROWSER ($(timeout 5 "$BROWSER" --version 2>/dev/null || echo 'version unknown'))
  library:  $lib

Reproduce it by hand, and keep the browser's stderr this time:
  python3 -m http.server $PORT --bind 127.0.0.1 --directory $SITE &
  python3 $PROJECT/tools/check_diagrams.py --browser $BROWSER --site $SITE \\
    --base http://127.0.0.1:$PORT --work \$(mktemp -d)
EOF
exit 2
