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

step "uv"
if command -v uv >/dev/null 2>&1; then
  skip "uv present: $(uv --version)"
else
  # The official installer; it drops uv into ~/.local/bin and needs no root.
  curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1 ||
    fail "uv install failed - check network access"
  command -v uv >/dev/null 2>&1 || fail "uv installed but not on PATH"
  did "uv installed: $(uv --version)"
fi

step "host build tools"
for tool in cmake ninja west; do
  if uv tool list 2>/dev/null | grep -q "^$tool "; then
    skip "$tool present: $(uv tool list 2>/dev/null | awk -v t="$tool" '$1==t {print $2}')"
  else
    # What uv said is kept and shown when it fails. This line once failed in
    # two seconds with nothing but its own name, worked when run again by
    # hand, and left no way of knowing which of the network, PyPI or uv it
    # had been.
    # At the version in the lock file, like every other Python package this
    # project installs: see tools/update-constraints.sh.
    if out="$(uv tool install -c "$PROJECT/mcu/requirements-zephyr-lock.txt" "$tool" 2>&1)"; then
      did "$tool installed"
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
