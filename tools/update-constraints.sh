#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Recompile the two lock files that pin every Python package this project
# installs, on the board and in CI.
#
#   tools/update-constraints.sh             # re-resolve, keeping every pin that still fits
#   tools/update-constraints.sh --upgrade   # take the newest versions that resolve together
#
# Run it when you add a dependency or when Zephyr's version changes, and with
# --upgrade when you want newer versions on purpose. Then run the gates, and on
# a board, bootstrap: a new version of a package is a change like any other.
#
# Without --upgrade, uv keeps whatever the existing lock already says wherever
# that still resolves, so a plain run moves nothing that does not have to move.
# That is what you want after adding a dependency, and it is why a plain run
# never picks up a new release: it used to be the only way to run this, and the
# header promised newer versions it could not deliver.
#
# WHY THERE ARE LOCK FILES
# ------------------------
# pyproject.toml says "pyserial", not which pyserial. Without these files a
# board set up today and one set up next month install different code under
# the same commit, a tagged release is not a known state, and neither a
# vulnerability scanner nor Dependabot has anything to read - which is how
# this came up: Trivy reported nothing, because there was nothing to scan.
#
# They are used as CONSTRAINTS, not as requirement lists. Each install still
# asks for what it wants by name; the lock only decides the version. So a step
# that installs three packages installs three, at the pinned versions, and a
# package nobody asks for is never installed because it is in the file.
#
# TWO FILES, BECAUSE THERE ARE TWO ENVIRONMENTS
#   python/requirements-lock.txt        this project's .venv
#   mcu/requirements-zephyr-lock.txt    the Zephyr workspace's .venv, and the
#                                       build tools beside it: cmake, ninja, west
#
# --universal: one resolution that holds on the board (aarch64, Python 3.13)
# and on a development machine or CI runner (x86_64), with environment markers
# where the two differ.
set -euo pipefail

UPGRADE=()
case "${1:-}" in
  "") ;;
  -U | --upgrade) UPGRADE=(--upgrade) ;;
  -h | --help)
    sed -n '4,18p' "$0"
    exit 0
    ;;
  *)
    echo "unknown argument: $1 (try --help)" >&2
    exit 2
    ;;
esac

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"
command -v uv >/dev/null 2>&1 || {
  echo "uv is not installed - provision/user/20-host-tools.sh installs it" >&2
  exit 1
}

echo "== python/requirements-lock.txt =="
# The build tools are in the lock too. An editable install of `unoq` is built
# by hatchling, and spidev is compiled from source by setuptools, each in an
# isolated environment of its own that an ordinary constraint does not reach.
# So the lock is also passed as BUILD constraints (-b), and it has to name
# what those builds ask for or they would still fetch whatever is newest.
# A fixed name beside pyproject.toml while it runs, so the "# via" comments uv
# writes into the lock say the same thing on every machine.
BUILD_IN="$PROJECT/python/build-tools.in"
printf '%s\n' hatchling setuptools wheel >"$BUILD_IN"
trap 'rm -f "$BUILD_IN"' EXIT
(cd "$PROJECT/python" && uv pip compile -q --universal --python-version 3.11 "${UPGRADE[@]}" \
  --extra dev --extra docs --extra board pyproject.toml build-tools.in \
  --custom-compile-command "tools/update-constraints.sh" \
  -o requirements-lock.txt)
echo "  $(grep -cE '^[a-zA-Z0-9]' "$PROJECT/python/requirements-lock.txt") packages pinned"

# Zephyr's own lists, at the version this project pins. Read from the
# workspace if there is one, and fetched if not, so that this runs on a
# machine that has never built the firmware.
# shellcheck disable=SC2016  # a literal ${...} in the file being read, not ours
ZEPHYR_VERSION="$(sed -n 's/^ZEPHYR_VERSION="\${ZEPHYR_VERSION:-\(v[0-9.]*\)}"$/\1/p' \
  "$PROJECT/provision/user/30-zephyr-workspace.sh")"
[ -n "$ZEPHYR_VERSION" ] || {
  echo "could not read the pinned Zephyr version from 30-zephyr-workspace.sh" >&2
  exit 1
}
echo "== mcu/requirements-zephyr-lock.txt (Zephyr $ZEPHYR_VERSION) =="
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; rm -f "$BUILD_IN"' EXIT
WS="${ZEPHYR_WORKSPACE:-$HOME/zephyrproject}"
for f in requirements-base.txt requirements-build-test.txt; do
  if [ -r "$WS/zephyr/scripts/$f" ] &&
    [ "$(git -C "$WS/zephyr" describe --tags 2>/dev/null)" = "$ZEPHYR_VERSION" ]; then
    cp "$WS/zephyr/scripts/$f" "$TMP/$f"
  else
    curl -fsSL -o "$TMP/$f" \
      "https://raw.githubusercontent.com/zephyrproject-rtos/zephyr/$ZEPHYR_VERSION/scripts/$f"
  fi
done
# What 30-zephyr-workspace.sh installs beyond Zephyr's two lists, and the
# build tools 20-host-tools.sh installs with `uv tool install`.
# setuptools and wheel for the same reason as in the lock above: anything
# here that is built from source is built with them.
printf '%s\n' west imgtool natsort cmake ninja setuptools wheel >"$TMP/extra.txt"
(cd "$TMP" && uv pip compile -q --universal --python-version 3.11 "${UPGRADE[@]}" \
  requirements-base.txt requirements-build-test.txt extra.txt \
  --custom-compile-command "tools/update-constraints.sh  (Zephyr $ZEPHYR_VERSION)" \
  -o "$PROJECT/mcu/requirements-zephyr-lock.txt")
# What was ASKED for, kept beside what was resolved. The gate has to know every
# package the workspace step installs by name, and it has to work with no
# workspace and no network - so the list is written down here, when both were
# to hand, instead of being looked up later.
{
  echo "# The packages provision/user/30-zephyr-workspace.sh and 20-host-tools.sh ask"
  echo "# for by name, at Zephyr $ZEPHYR_VERSION. Written by tools/update-constraints.sh;"
  echo "# read by tools/check-constraints.sh. Not an input to anything else."
  cat "$TMP/requirements-base.txt" "$TMP/requirements-build-test.txt" "$TMP/extra.txt" |
    sed 's/#.*//' | grep -oE '^[A-Za-z0-9][A-Za-z0-9._-]*' | tr 'A-Z_.' 'a-z--' | sort -u
} >"$PROJECT/mcu/requirements-zephyr.in"
echo "  $(grep -cE '^[a-zA-Z0-9]' "$PROJECT/mcu/requirements-zephyr-lock.txt") packages pinned, $(grep -cvE '^#' "$PROJECT/mcu/requirements-zephyr.in") of them asked for by name"
