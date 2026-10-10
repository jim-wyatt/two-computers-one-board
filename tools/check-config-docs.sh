#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Check that docs/reference/configuration.md and the code name the same
# settings. Run by tools/check.sh docs.
#
#   tools/check-config-docs.sh
#
# The page exists to answer "what can I change on this board", and the answer
# used to be forty-odd UNOQ_* variables spread over as many scripts, each with a
# good comment where it was defined and no list anywhere. A list written by hand
# is right on the day it is written. This is what keeps it right: a variable a
# script reads and the page does not mention fails here, and so does one the
# page still describes after the code stopped reading it.
#
# Static and instant - two greps and a comparison. No network, no board.
set -uo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
PAGE="docs/reference/configuration.md"
cd "$PROJECT" || exit 1

# Everything that runs: scripts, units, rules, the package. Not the docs (the
# page would vouch for itself), and not the tests (they set these, which is not
# the same as the project reading them).
in_code="$(git ls-files -- '*.sh' '*.service' '*.rules' '*.py' 'env.sh' |
  grep -vE '^(tests|python/tests)/' |
  xargs grep -ohE 'UNOQ_[A-Z0-9_]+' | sort -u)"
in_page="$(grep -oE 'UNOQ_[A-Z0-9_]+' "$PAGE" | sort -u)"

# Named in the code only to say they are gone.
RETIRED="UNOQ_USB_MODE"
# A prefix used in prose and in this script, not a variable.
IGNORED="UNOQ_ UNOQ_X"

drop() {
  local words="$1" w
  local pattern=""
  for w in $words; do pattern="${pattern:+$pattern|}$w"; done
  grep -vxE "$pattern" || true
}

in_code="$(drop "$RETIRED $IGNORED" <<<"$in_code")"
in_page="$(drop "$IGNORED" <<<"$in_page")"

undocumented="$(comm -23 <(echo "$in_code") <(echo "$in_page"))"
stale="$(comm -13 <(echo "$in_code") <(echo "$in_page"))"

rc=0
if [ -n "$undocumented" ]; then
  echo "read by the code, missing from $PAGE:"
  echo "$undocumented" | while read -r v; do
    echo "  $v    ($(git grep -l "$v" -- '*.sh' '*.service' '*.rules' '*.py' | grep -vE '^(tests|python/tests)/' | head -3 | tr '\n' ' '))"
  done
  rc=1
fi
if [ -n "$stale" ]; then
  echo "described in $PAGE, read by nothing:"
  echo "$stale" | while read -r v; do echo "  $v"; done
  rc=1
fi

[ "$rc" = 0 ] && echo "$(echo "$in_page" | wc -l) settings, and $PAGE names every one the code reads"
exit "$rc"
