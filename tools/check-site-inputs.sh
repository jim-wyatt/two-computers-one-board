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

# The targets of every snippet include, single or block form, whichever quote.
# A leading ; is the documented way to write one that is NOT an include.
includes="$(git ls-files 'docs/**/*.md' 'docs/*.md' | xargs grep -hoE -- '^[^;]*-{1,}8<-{1,}[[:space:]]+["'"'"'][^"'"'"']+["'"'"']' 2>/dev/null |
  sed -E 's/.*["'"'"']([^"'"'"']+)["'"'"']$/\1/; s/:[0-9:]*$//' | sort -u)"

rc=0
while IFS= read -r target; do
  [ -n "$target" ] || continue
  case "$target" in
    docs/* | http://* | https://*) continue ;;
  esac
  if grep -qF -- "- '$target'" "$PAGES"; then
    continue
  fi
  [ "$rc" = 0 ] && echo "pages embed files the site workflows do not watch:"
  echo "  $target    ($(git grep -lF -- "$target" -- 'docs/' | head -3 | tr '\n' ' '))"
  rc=1
done <<<"$includes"

if [ "$rc" = 0 ]; then
  echo "every file a page embeds is covered by the path filter in $PAGES"
else
  echo "add each one to \`paths:\` in $PAGES and to the diagrams filter in"
  echo ".github/workflows/ci.yml, or a change to it will not rebuild the site"
fi
exit "$rc"
