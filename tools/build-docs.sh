#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Render docs/ into the static site the board serves.
#
#   tools/build-docs.sh          # build into share/learn/
#   tools/build-docs.sh --serve  # live-reloading preview on :8000
#
# --strict is not optional. MkDocs resolves every internal link against the
# real directory tree, so a link that points at a file which no longer exists
# is a build failure here rather than a 404 for a reader. The generator this
# replaced flattened every page into one directory, which silently repaired
# nineteen links that were broken on GitHub.
#
# NETWORK: the `privacy` plugin downloads the handful of assets the theme would
# otherwise fetch at page load, so that the built site needs nothing. That
# needs network access on the FIRST build; afterwards the copies are cached
# under .cache/plugin/privacy/ and rebuilds work offline.
set -uo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
VENV="${UNOQ_VENV:-$PROJECT/.venv}"
MKDOCS="$VENV/bin/mkdocs"

if [ ! -x "$MKDOCS" ]; then
  cat >&2 <<EOF
$MKDOCS is missing.

The site needs mkdocs-material, which lives in the 'docs' extra:

  uv pip install --python $VENV/bin/python -c $PROJECT/python/requirements-lock.txt -b $PROJECT/python/requirements-lock.txt -e '$PROJECT/python[dev,docs]'

or run $PROJECT/provision/user/35-python-venv.sh again.
EOF
  exit 1
fi

if [ "${1:-}" = "--serve" ]; then
  # 0.0.0.0 so the preview is reachable from the machine the board is plugged
  # into, which is where it will actually be looked at.
  exec "$MKDOCS" serve --strict -f "$PROJECT/mkdocs.yml" -a 0.0.0.0:8000
fi

"$MKDOCS" build --strict -f "$PROJECT/mkdocs.yml" || {
  echo >&2
  echo "docs build failed. Most often this is a link to a file that moved:" >&2
  echo "  paths in docs/ are relative to the page, and must resolve on GitHub too." >&2
  exit 1
}

SITE="$PROJECT/share/learn"
printf 'site: %s (%s, %s pages)\n' \
  "$SITE" "$(du -sh "$SITE" | cut -f1)" "$(find "$SITE" -name '*.html' | wc -l)"
