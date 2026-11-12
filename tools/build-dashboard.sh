#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Build the dashboard's page from web/dashboard/ into python/unoq/dashboard_static/.
#
#   tools/build-dashboard.sh           # install the locked packages, then build
#   tools/build-dashboard.sh --check   # build into a scratch directory, and fail
#                                      # if it differs from what is committed
#
# The built page is committed: the board has no Node.js and serves the page
# from disk (web/dashboard/README.md has the reasons). So whoever changes
# web/dashboard/src runs this and commits both, and CI runs --check, which is
# what notices a change to the source whose build was never committed.
#
# NODE: the exact version web/dashboard/package.json names in "engines", or
# this stops. The packages are pinned by package-lock.json, and a build is
# only the same build on the same Node - which is what lets --check compare
# file by file. Get it from https://nodejs.org/dist/ (no root needed: unpack
# it anywhere and put its bin/ first on PATH), or with nvm, fnm or volta.
#
# NETWORK: `npm ci` downloads the locked packages into web/dashboard/
# node_modules/ (about 130 MB, ignored by git) the first time; later runs
# find them there and need none.
set -uo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
WEB="$PROJECT/web/dashboard"
OUT="$PROJECT/python/unoq/dashboard_static"

CHECK=0
case "${1:-}" in
  "") ;;
  --check) CHECK=1 ;;
  -h | --help)
    sed -n '4,22p' "$0"
    exit 0
    ;;
  *)
    echo "unknown argument: $1 (try --help)" >&2
    exit 2
    ;;
esac

if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  echo "node and npm are not on PATH - see the NODE note: $0 --help" >&2
  exit 1
fi
WANT="$(node -p "require('$WEB/package.json').engines.node")"
HAVE="$(node --version)"
if [ "v$WANT" != "$HAVE" ]; then
  echo "Node $HAVE is not the $WANT web/dashboard/package.json pins - see: $0 --help" >&2
  exit 1
fi

cd "$WEB" || exit 1
# ci, not install: it installs exactly the lock file, and fails rather than
# rewriting it when package.json and the lock disagree. Skipped when the
# packages were installed after the lock last changed: npm writes
# node_modules/.package-lock.json as it installs. Not compared by content,
# because npm's copy is not the lock file byte for byte.
if [ ! package-lock.json -ot node_modules/.package-lock.json ]; then
  npm ci --no-audit --no-fund || {
    echo "npm ci failed: see above" >&2
    exit 1
  }
fi

if [ "$CHECK" = 0 ]; then
  npm run --silent build || exit 1
  echo "built: ${OUT#"$PROJECT"/} - commit it with the source"
  exit 0
fi

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
npm run --silent build -- --outDir "$SCRATCH/out" --logLevel warn || exit 1
if diff -r "$SCRATCH/out" "$OUT" >"$SCRATCH/diff" 2>&1; then
  echo "dashboard: the committed page is what web/dashboard/ builds"
  exit 0
fi
cat "$SCRATCH/diff" | head -20 >&2
echo >&2
echo "python/unoq/dashboard_static/ is not what web/dashboard/ builds." >&2
echo "Run tools/build-dashboard.sh and commit what it changes." >&2
exit 1
