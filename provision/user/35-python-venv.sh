#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# The MPU-side Python venv and the `unoq` package. Runs as YOU, not root.
#
#   bash ~/two-computers-one-board/provision/user/35-python-venv.sh
#
# Idempotent.
#
# The package is installed EDITABLE (-e) on purpose: this is the working
# checkout, and an editable install means an edit to python/unoq/ takes effect
# without a reinstall. It is also why python/ must not move.
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"

[ "$(id -u)" = 0 ] && fail "run this WITHOUT sudo - it installs into the checkout"

export PATH="$HOME/.local/bin:$PATH"
VENV="${UNOQ_VENV:-$PROJECT/.venv}"
# Every install below takes its versions from here, so that a board set up next
# month gets what a board set up today got. tools/update-constraints.sh
# rewrites it; see there for why it is a constraints file and not a list. It is
# passed twice: -c for what is installed, and -b for what BUILDS what is
# installed, which happens in an isolated environment -c does not reach.
LOCK="$PROJECT/python/requirements-lock.txt"

command -v uv >/dev/null 2>&1 || fail "uv missing - run provision/user/20-host-tools.sh first"

step "venv"
if [ -x "$VENV/bin/python" ]; then
  skip "$VENV exists ($("$VENV/bin/python" --version))"
else
  uv venv "$VENV" >/dev/null 2>&1 || fail "could not create $VENV"
  did "created $VENV"
fi

step "hardware libraries"
# gpiod drives the BOOT0/link lines, pyserial the shell, smpclient the FOTA
# path. smbus2 and spidev are for the Qwiic/SPI headers - not used by the
# CPU-bars demo, but this is the venv you get a REPL in.
#
# One list, used for BOTH the install and the check. It used to install five
# packages and then test three of them, so a venv holding gpiod, pyserial and
# smpclient but missing smbus2 and spidev reported "already correct" and stayed
# broken forever - which is what this board did. The install branch never runs
# again once the subset is satisfied, so the gap is not merely undetected, it is
# unreachable.
#
# The mapping has to be written out because it is not derivable: pyserial
# imports as `serial`. That asymmetry is the reason the short list looked
# complete enough to leave alone.
HW_LIBS="gpiod:gpiod smbus2:smbus2 pyserial:serial spidev:spidev smpclient:smpclient"

# The package names, split out once, so the install and the messages below
# cannot disagree with the list above either.
HW_PKGS=""
for pair in $HW_LIBS; do
  HW_PKGS="$HW_PKGS ${pair%%:*}"
done
HW_PKGS="${HW_PKGS# }"

hw_missing() {
  local pair pkg mod out=""
  for pair in $HW_LIBS; do
    pkg="${pair%%:*}"
    mod="${pair##*:}"
    "$VENV/bin/python" -c "import $mod" 2>/dev/null || out="$out $pkg"
  done
  echo "${out# }"
}

# Was this environment built to the lock file as it now is? If not - a pin
# moved, or the environment predates the lock - every install below runs
# again, and uv changes only what the lock now disagrees with.
LOCKED=0
lock_current "$VENV" "$LOCK" && LOCKED=1

MISSING="$(hw_missing)"
if [ -z "$MISSING" ] && [ "$LOCKED" = 1 ]; then
  skip "all hardware libraries present: $HW_PKGS"
else
  # Everything, not just what is missing: uv resolves the set together, and a
  # re-run costs nothing when they are already there.
  # shellcheck disable=SC2086  # deliberate word splitting of the package list
  uv pip install --python "$VENV/bin/python" -q -c "$LOCK" -b "$LOCK" $HW_PKGS ||
    fail "could not install the hardware libraries (missing:$MISSING)
        spidev is a C extension - if it failed to build, the board is missing
        gcc or python3-dev. provision/15-dev-tools.sh installs both."
  STILL="$(hw_missing)"
  [ -z "$STILL" ] || fail "still missing after install:$STILL"
  if [ -n "$MISSING" ]; then
    did "hardware libraries installed ($MISSING)"
  else
    did "hardware libraries brought to the locked versions"
  fi
fi

step "unoq package (editable)"
# The [docs] extra comes along at provisioning time, not just for developers:
# share/build-image.sh renders the learning site during the same bootstrap, and
# a board without mkdocs produces a USB drive and a web server with no content.
if [ "$LOCKED" = 1 ] && "$VENV/bin/python" -c 'import unoq' 2>/dev/null &&
  [ -x "$VENV/bin/unoq-cpu-bars" ] && [ -x "$VENV/bin/mkdocs" ]; then
  skip "unoq importable, unoq-cpu-bars and mkdocs on PATH"
else
  uv pip install --python "$VENV/bin/python" -q -c "$LOCK" -b "$LOCK" -e "$PROJECT/python[docs]" ||
    fail "could not install the unoq package"
  did "unoq installed editable from $PROJECT/python (with the docs extra)"
fi

step "dev tooling"
# Delegated rather than duplicated: install-dev-tools.sh already knows how to
# get ruff/mypy/pytest into this venv and shellcheck/shfmt into ~/.local/bin,
# and it is what CI runs too.
if [ "$LOCKED" = 1 ] && [ -x "$VENV/bin/pytest" ] && [ -x "$VENV/bin/mypy" ] &&
  [ -x "$VENV/bin/ruff" ]; then
  skip "ruff, mypy and pytest present"
else
  "$PROJECT/tools/install-dev-tools.sh" >/dev/null 2>&1 ||
    fail "tools/install-dev-tools.sh failed - run it directly to see why"
  did "dev tooling installed"
fi

# Only now, with every install above done: a run that died half way must find
# no record, and do them again.
lock_record "$VENV" "$LOCK"

step "verify"
if out="$("$VENV/bin/python" -c 'import unoq; print(unoq.__version__)' 2>&1)"; then
  skip "unoq $out"
else
  fail "unoq will not import: $out"
fi

summary
