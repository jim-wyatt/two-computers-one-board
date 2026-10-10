#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Check that the site is built only from files the workflows know to watch.
# Run by tools/check.sh docs.
#
#   tools/check-site-inputs.sh
#
# The site is rebuilt and published, and its diagrams re-checked, only when
# something it is built from has changed: `paths:` in pages.yml, and the
# `diagrams` filter in ci.yml. That is safe for exactly as long as those lists
# are complete.
#
# pymdownx.snippets is how they would stop being complete without anyone
# noticing. A page can embed any file in the repository:
#
#     --8<-- "mcu/app/src/bars.c"
#
# and from then on a change to bars.c changes a rendered page while touching
# nothing under docs/. The site would go stale, silently, which is the reason
# pages.yml used to refuse a path filter at all.
#
# So: every file a page includes must be covered by the filter in pages.yml.
# Anything under docs/ is. Anything else has to be listed there by name, and in
# ci.yml's `diagrams` filter - this says so, and fails until it is.
#
# Static and instant. No network, no build.
set -uo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT" || exit 1
PAGES=.github/workflows/pages.yml

# The targets of every snippet include, in both forms pymdownx.snippets has:
#
#     --8<-- "path/to/file"            one line, either kind of quote
#
#     --8<--                           a block: every line between two bare
#     path/to/file                     markers is a target
#     path/to/other:12:40
#     --8<--
#
# A line beginning with ; is the documented way to write one that is NOT an
# include. What follows the path after a colon selects part of the file - line
# numbers, or a named region such as bars.c:draw - and is not part of its name.
# shellcheck disable=SC2016  # awk's own $0, not the shell's
includes="$(git ls-files 'docs/**/*.md' 'docs/*.md' | xargs awk '
  FNR == 1 { in_block = 0 }
  /^[ \t]*;/ { next }
  /^[ \t]*-+8<-+[ \t]*$/ { in_block = !in_block; next }
  in_block {
    line = $0; gsub(/^[ \t]+|[ \t]+$/, "", line)
    if (line != "") print line
    next
  }
  match($0, /-+8<-+[ \t]+["\047][^"\047]+["\047]/) {
    t = substr($0, RSTART, RLENGTH)
    sub(/^-+8<-+[ \t]+["\047]/, "", t); sub(/["\047]$/, "", t)
    print t
  }
' | sed -E 's/:.*$//' | sort -u)"

# The second filter: the regex the `changes` job in ci.yml uses to decide whether
# the diagrams are rendered again. Read out of the workflow rather than copied
# here, so it is the one that actually runs.
CI=.github/workflows/ci.yml
diagrams_re="$(awk '/site inputs changed/ { print prev; exit } /grep -qE/ { prev = $0 }' "$CI" |
  sed -E "s/^[^']*'([^']*)'.*$/\1/")"
[ -n "$diagrams_re" ] || {
  echo "could not find the diagrams filter in $CI - has the changes job been rewritten?" >&2
  exit 1
}

rc=0
while IFS= read -r target; do
  [ -n "$target" ] || continue
  case "$target" in
    docs/* | http://* | https://*) continue ;;
  esac
  missing=""
  grep -qF -- "- '$target'" "$PAGES" || missing="$PAGES"
  grep -qE -- "$diagrams_re" <<<"$target" || missing="${missing:+$missing and }$CI"
  [ -n "$missing" ] || continue
  [ "$rc" = 0 ] && echo "pages embed files the site workflows do not watch:"
  echo "  $target    not covered by: $missing"
  rc=1
done <<<"$includes"

if [ "$rc" = 0 ]; then
  echo "every file a page embeds is covered by the filters in $PAGES and $CI"
else
  echo "add each one to \`paths:\` in $PAGES and to the diagrams filter in"
  echo ".github/workflows/ci.yml, or a change to it will not rebuild the site"
fi
exit "$rc"
