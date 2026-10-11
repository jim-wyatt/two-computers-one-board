#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Recompile the two lock files that pin every Python package this project
# installs, on the board and in CI.
#
#   tools/update-constraints.sh
#
# Run it when you add a dependency, when Zephyr's version changes, or when you
# want newer versions on purpose. Then run the gates, and on a board,
# bootstrap: a new version of a package is a change like any other.
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
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"
command -v uv >/dev/null 2>&1 || {
  echo "uv is not installed - provision/user/20-host-tools.sh installs it" >&2
  exit 1
}

echo "== python/requirements-lock.txt =="
(cd "$PROJECT/python" && uv pip compile -q --universal --python-version 3.11 \
  --extra dev --extra docs --extra board pyproject.toml \
  --custom-compile-command "tools/update-constraints.sh" \
  -o requirements-lock.txt)
echo "  $(grep -cE '^[a-zA-Z0-9]' "$PROJECT/python/requirements-lock.txt") packages pinned"

# Zephyr's own lists, at the version this project pins. Read from the
# workspace if there is one, and fetched if not, so that this runs on a
# machine that has never built the firmware.
ZEPHYR_VERSION="$(sed -n 's/^ZEPHYR_VERSION="\${ZEPHYR_VERSION:-\(v[0-9.]*\)}"$/\1/p' \
  "$PROJECT/provision/user/30-zephyr-workspace.sh")"
[ -n "$ZEPHYR_VERSION" ] || {
  echo "could not read the pinned Zephyr version from 30-zephyr-workspace.sh" >&2
  exit 1
}
echo "== mcu/requirements-zephyr-lock.txt (Zephyr $ZEPHYR_VERSION) =="
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
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
printf '%s\n' west imgtool natsort cmake ninja >"$TMP/extra.txt"
(cd "$TMP" && uv pip compile -q --universal --python-version 3.11 \
  requirements-base.txt requirements-build-test.txt extra.txt \
  --custom-compile-command "tools/update-constraints.sh  (Zephyr $ZEPHYR_VERSION)" \
  -o "$PROJECT/mcu/requirements-zephyr-lock.txt")
echo "  $(grep -cE '^[a-zA-Z0-9]' "$PROJECT/mcu/requirements-zephyr-lock.txt") packages pinned"
