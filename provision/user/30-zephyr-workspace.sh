#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# The Zephyr workspace (~2 GB). Runs as YOU, not root. This is the long one.
#
#   bash ~/two-computers-one-board/provision/user/30-zephyr-workspace.sh
#
# Idempotent: an existing workspace at the right version is left alone.
#
# THE MANIFEST FILTER
# -------------------
# Keeps the workspace at ~2 GB by skipping vendor HALs for hardware this board
# does not have - several more GB of other manufacturers' chips. It is not
# cosmetic: the home partition on this board is 8 GB.
#
# It lives in ../../west-project-filter and is READ from there, because CI now
# builds the same module set and a second copy would drift. Edit that file.
#
# NEVER `rm -rf` a module directory without filtering it out first: west would
# then be managing a project whose checkout has vanished, and every subsequent
# `west update` fails. Change the filter, then delete.
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"

[ "$(id -u)" = 0 ] && fail "run this WITHOUT sudo - it installs into \$HOME"

export PATH="$HOME/.local/bin:$PATH"

WS="${ZEPHYR_WORKSPACE:-$HOME/zephyrproject}"
ZEPHYR_VERSION="${ZEPHYR_VERSION:-v4.4.2}"
PYTHON_VERSION="${WS_PYTHON:-3.13}"

# Shared with CI rather than copied into it - see the file's own header. Read,
# not sourced, so the same bytes reach `west config` here and the workflow there.
FILTER_FILE="$PROJECT/west-project-filter"
[ -r "$FILTER_FILE" ] || fail "missing $FILTER_FILE - the module filter lives there now"
FILTER="$(grep -vE '^[[:space:]]*(#|$)' "$FILTER_FILE" | head -1)"
[ -n "$FILTER" ] || fail "$FILTER_FILE has no filter line"

command -v uv >/dev/null 2>&1 || fail "uv missing - run provision/user/20-host-tools.sh first"

step "workspace venv"
mkdir -p "$WS"
if [ -x "$WS/.venv/bin/python" ]; then
  skip "$WS/.venv exists"
else
  uv venv --python "$PYTHON_VERSION" "$WS/.venv" >/dev/null 2>&1 ||
    fail "could not create $WS/.venv"
  did "created $WS/.venv (python $PYTHON_VERSION)"
fi

step "west + imgtool in the workspace venv"
if [ -x "$WS/.venv/bin/west" ] && [ -x "$WS/.venv/bin/imgtool" ]; then
  skip "west and imgtool present"
else
  # imgtool signs the MCUboot image; zbuild.sh calls it by this path.
  uv pip install --python "$WS/.venv/bin/python" -q \
    -c "$PROJECT/mcu/requirements-zephyr-lock.txt" west imgtool ||
    fail "could not install west/imgtool"
  did "west + imgtool installed"
fi

step "Zephyr $ZEPHYR_VERSION checkout"
if [ -d "$WS/zephyr" ] && [ -f "$WS/.west/config" ]; then
  have="$(git -c safe.directory="$WS/zephyr" -C "$WS/zephyr" describe --tags 2>/dev/null)"
  skip "workspace initialised at ${have:-unknown}"
else
  # --clone-opt=--depth=1: the one commit that is the release, not the 137,000
  # behind it. Zephyr's history is a gigabyte of git objects - measured, 1004 MB
  # against 126 MB - and it was most of the wait in this step. Nothing here
  # reads it: the build asks `git describe` for the tag, and the tag is the
  # commit that was fetched.
  # To get the history later, for `git log` or `git bisect` in Zephyr itself:
  #   git -C ~/zephyrproject/zephyr fetch --unshallow
  echo "  west init (this clones Zephyr at $ZEPHYR_VERSION, without its history)..."
  "$WS/.venv/bin/west" init -m https://github.com/zephyrproject-rtos/zephyr \
    --mr "$ZEPHYR_VERSION" --clone-opt=--depth=1 "$WS" >/dev/null 2>&1 ||
    fail "west init failed"
  did "west init at $ZEPHYR_VERSION"
fi

step "manifest filter"
# `cd "$WS"`, not `-z "$WS"`: -z is --zephyr-base, which is not how west finds a
# workspace. Read from outside, it returned empty every time, so this compared
# the filter against "" and reported "changed" on every run of an idempotent
# script. The write below always used `cd` and was therefore always correct -
# only the reporting lied, which is why it survived.
current="$(cd "$WS" && "$WS/.venv/bin/west" config manifest.project-filter 2>/dev/null || true)"
if [ "$current" = "$FILTER" ]; then
  skip "filter already set"
else
  (cd "$WS" && "$WS/.venv/bin/west" config manifest.project-filter -- "$FILTER") ||
    fail "could not set the manifest filter"
  did "manifest filter set (keeps the workspace at ~2 GB)"
fi

step "west update"
# --narrow -o=--depth=1 fetches only the tips: full history of every Zephyr
# module is several GB of git objects nobody on this board will read.
if [ -d "$WS/modules/hal/stm32" ]; then
  skip "modules already checked out (delete $WS/modules to force a refresh)"
else
  echo "  west update (the modules: about 1.3 GB on disk - this is the slow step)..."
  (cd "$WS" && "$WS/.venv/bin/west" update --narrow -o=--depth=1) >/dev/null 2>&1 ||
    fail "west update failed"
  did "modules checked out"
fi

step "zephyr-export"
if [ -d "$HOME/.cmake/packages/Zephyr" ]; then
  skip "Zephyr already registered with CMake"
else
  (cd "$WS" && "$WS/.venv/bin/west" zephyr-export) >/dev/null 2>&1 ||
    fail "west zephyr-export failed"
  did "Zephyr registered with CMake"
fi

step "Zephyr's own python requirements"
# Zephyr pins its tool versions per release; these are deliberate, and
# check-versions.sh explains why `pip list --outdated` flags them.
#
# TWO OF ZEPHYR'S FIVE LISTS, NOT ALL OF THEM
# scripts/requirements.txt is everything anyone working on Zephyr might want:
# OpenCV for its camera tests, NXP's provisioning tools, plotly, pylint, a
# second copy of clang-format. Installed whole it was 656 MB, and not one of
# those is imported by anything this project runs. What is:
#
#   requirements-base.txt        west build, the devicetree and Kconfig scripts
#   requirements-build-test.txt  twister, which mcu/ztest.sh runs
#   natsort                      imported by twister, listed by Zephyr under
#                                "run-test" with the hardware-in-the-loop tools
#
# 124 MB. A firmware build and the whole of mcu/ztest.sh pass on it, which is
# checked on every pull request by the provisioning workflow. If a Zephyr
# script you run by hand wants something more:
#   uv pip install --python ~/zephyrproject/.venv/bin/python -r ~/zephyrproject/zephyr/scripts/requirements.txt
# One import from each thing asked for below, so "already satisfied" is true of
# all three. It used to ask only for elftools, which is in the base list: a
# workspace with the base list and nothing else was reported complete, and
# mcu/ztest.sh then failed on its first import.
if "$WS/.venv/bin/python" -c 'import elftools, junitparser, natsort' 2>/dev/null; then
  skip "requirements already satisfied"
else
  # Versions come from the lock file, compiled from these same lists at the
  # pinned Zephyr version (tools/update-constraints.sh).
  uv pip install --python "$WS/.venv/bin/python" -q \
    -c "$PROJECT/mcu/requirements-zephyr-lock.txt" \
    -r "$WS/zephyr/scripts/requirements-base.txt" \
    -r "$WS/zephyr/scripts/requirements-build-test.txt" \
    natsort ||
    fail "could not install Zephyr's requirements"
  did "Zephyr requirements installed (build and test)"
fi

step "size"
skip "workspace: $(du -sh "$WS" 2>/dev/null | cut -f1)"

summary
