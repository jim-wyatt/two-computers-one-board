#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# uv, and the host build tools it manages. Runs as YOU, not root.
#
#   bash ~/two-computers-one-board/provision/user/20-host-tools.sh
#
# Idempotent.
#
# cmake, ninja and west come from PyPI via `uv tool install` rather than apt:
# Debian's cmake here predates what recent Zephyr wants, and uv keeps each tool
# in its own venv so they cannot fight over dependencies.
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"

[ "$(id -u)" = 0 ] && fail "run this WITHOUT sudo - it installs into \$HOME"

export PATH="$HOME/.local/bin:$PATH"

# The one tool everything else is installed WITH, so it is pinned like the
# rest. It was the latest release, from an unversioned installer URL, and
# `uv pip compile` output and resolution change between uv releases: a board
# set up next month ran a different resolver from the one that wrote the lock.
# CI reads the same number: .github/workflows set UV_VERSION, and
# tools/check-zephyr-pin.sh fails if they disagree with this line.
UV_VERSION="${UV_VERSION:-0.13.5}"

step "uv"
have="$(uv --version 2>/dev/null | awk '{print $2}')"
if [ "$have" = "$UV_VERSION" ]; then
  skip "uv $have"
elif [ -n "$have" ] && out="$(uv self update "$UV_VERSION" 2>&1)"; then
  # A uv the installer put there can move itself, either way.
  did "uv brought to $UV_VERSION (was $have)"
else
  # Not there, or not able to update itself (one that came from pip or apt).
  # The installer for this release, which puts it in ~/.local/bin - first on
  # PATH, above - and needs no root.
  [ -n "$have" ] && printf '%s\n' "$out" | tail -5 >&2
  curl -LsSf "https://astral.sh/uv/$UV_VERSION/install.sh" | sh >/dev/null 2>&1 ||
    fail "uv $UV_VERSION install failed - check network access"
  now="$(uv --version 2>/dev/null | awk '{print $2}')"
  [ "$now" = "$UV_VERSION" ] ||
    fail "installed uv $UV_VERSION, but the uv on PATH is ${now:-missing}: $(command -v uv || echo none)"
  did "uv $UV_VERSION installed${have:+ (was $have)}"
fi

step "host build tools"
ZLOCK="$PROJECT/mcu/requirements-zephyr-lock.txt"
for tool in cmake ninja west; do
  # Present AT THE VERSION THE LOCK GIVES IT, not merely present: otherwise a
  # board set up before a pin moved keeps the old tool for good.
  want="$(lock_pin "$ZLOCK" "$tool")"
  have="$(uv tool list 2>/dev/null | awk -v t="$tool" '$1==t {print $2}' | sed 's/^v//')"
  if [ -n "$have" ] && { [ -z "$want" ] || [ "$have" = "$want" ]; }; then
    skip "$tool present: v$have"
  else
    # What uv said is kept and shown when it fails. This line once failed in
    # two seconds with nothing but its own name, worked when run again by
    # hand, and left no way of knowing which of the network, PyPI or uv it
    # had been.
    # At the version in the lock file, like every other Python package this
    # project installs: see tools/update-constraints.sh. Asked for by version
    # as well, because that is what makes uv replace one already installed.
    if out="$(uv tool install -c "$ZLOCK" -b "$ZLOCK" "$tool${want:+==$want}" 2>&1)"; then
      if [ -n "$have" ]; then
        did "$tool brought to v$want (was v$have)"
      else
        did "$tool installed"
      fi
    else
      printf '%s\n' "$out" | tail -15 >&2
      fail "uv tool install $tool - what it said is above. If it was the network, run this again."
    fi
  fi
done

step "verify"
for tool in cmake ninja; do
  command -v "$tool" >/dev/null 2>&1 ||
    warn "$tool not on PATH - ~/.local/bin may be missing from it (env.sh adds it)"
done

summary
