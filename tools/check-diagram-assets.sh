#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Are the diagram assets wired up so that a browser with no network could draw?
#
#   tools/check-diagram-assets.sh [site-dir]
#
# WHY THIS EXISTS, SEPARATELY FROM check-diagrams.sh
# --------------------------------------------------
# check-diagrams.sh opens a real browser and is the only thing that can prove a
# diagram actually draws. It is also slow (~60s), needs chromium, and has now
# failed twice for reasons that had nothing to do with the diagrams - once
# hanging a CI job for fifteen minutes, once reporting "0 of 1 drew" on every
# page of a build that renders perfectly on this board.
#
# That is a bad gate to put in front of every pull request, and a worse one to
# be the ONLY thing guarding a constraint the whole site is designed around.
#
# So the invariants that can be checked without a browser are checked here, in
# about a tenth of a second, with no dependencies:
#
#   1. the mermaid library is VENDORED, not fetched                (offline)
#   2. nothing in the theme bundle points at an absolute CDN url   (offline)
#   3. mermaid-init.js shipped                                     (rendering)
#   4. every page with a diagram on it loads that script           (rendering)
#
# (1) and (2) are the USB-drive constraint from the top of mkdocs.yml: a laptop
# with no internet, opening the drive as file://. (3) and (4) are the bug that
# started all this - the theme loads the library and never calls mermaid.run().
#
# What this canNOT catch is mermaid.run() throwing once it is called. That is
# what the browser gate is for, and why both exist.
set -uo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
SITE="${1:-${UNOQ_SITE:-$PROJECT/share/learn}}"

if [ ! -d "$SITE" ]; then
  echo "$SITE does not exist - run tools/build-docs.sh first" >&2
  exit 1
fi

fail=0
note() {
  printf '  FAIL  %s\n' "$1" >&2
  fail=1
}

# 1. The library itself must be on disk. The `privacy` plugin downloads it at
#    BUILD time and rewrites the reference; if that silently stopped happening,
#    every diagram would still draw for anyone with internet, and nobody would
#    notice until the drive was handed to someone without.
vendored="$(find "$SITE/assets/external" -name 'mermaid*.js' 2>/dev/null | head -1)"
if [ -z "$vendored" ]; then
  note "no vendored mermaid under $SITE/assets/external - the privacy plugin did not run,
        or had no network at build time. Every diagram would need a CDN to draw."
fi

# 2. ...and the theme bundle must reference it RELATIVELY. Setting site_url is
#    what breaks this: privacy then bakes in an absolute url and the vendored
#    copy sits there unused. Looking at the bundle rather than the pages,
#    because that is where the theme puts the reference.
for bundle in "$SITE"/assets/javascripts/bundle.*.js; do
  [ -e "$bundle" ] || continue
  if grep -qo 'https://[a-z0-9.-]*/mermaid' "$bundle"; then
    note "$(basename "$bundle") fetches mermaid over https - site_url is probably set
        again. See the comment above site_url in mkdocs.yml."
  fi
done

# 3 + 4. The init script, and every page that needs it. Counted rather than
#    spot-checked: the failure mode here is a NEW page getting a diagram and
#    not the script, which only shows up on that one page.
init="$SITE/assets/javascripts/mermaid-init.js"
[ -s "$init" ] || note "$init is missing or empty - nothing will call mermaid.run()"

pages=0
missing=0
while IFS= read -r page; do
  grep -q 'class="unoq-mermaid"' "$page" || continue
  pages=$((pages + 1))
  if ! grep -q 'mermaid-init\.js' "$page"; then
    note "${page#"$SITE"/} has a diagram but never loads mermaid-init.js"
    missing=$((missing + 1))
  fi
done < <(find "$SITE" -name '*.html')

# A site with no diagrams at all passes every check above, which would make
# this gate go quiet exactly when someone deletes the last one by accident.
if [ "$pages" = 0 ]; then
  note "no page in $SITE contains a mermaid diagram - if that is deliberate,
        delete this gate; if it is not, the superfences config is broken."
fi

if [ "$fail" != 0 ]; then
  echo >&2
  echo "Diagram assets are not wired for offline use. tools/check-diagrams.sh" >&2
  echo "would tell you the same thing sixty seconds later, in a browser." >&2
  exit 1
fi

printf '%s pages carry diagrams; library vendored, init shipped, all pages load it\n' "$pages"
