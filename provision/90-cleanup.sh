#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Give back the disk space the setup borrowed and no longer needs.
#
#   sudo bash ~/two-computers-one-board/provision/90-cleanup.sh
#
# Idempotent. bootstrap.sh runs it near the end of every run.
#
# WHAT IT REMOVES, AND WHY THAT IS SAFE
# -------------------------------------
# Only things that are copies of something already installed, and that the tool
# which made them will fetch again by itself if it ever wants them:
#
#   apt's downloaded packages    /var/cache/apt. Every .deb in it has been
#                                unpacked already. Step 10 clears this after the
#                                upgrade; the steps after it install more.
#   uv's download cache          ~/.cache/uv. What uv fetched to build the
#                                Python environments, which are complete.
#   pip's download cache         ~/.cache/pip, if anything used pip.
#
# WHAT IT DOES NOT REMOVE
# -----------------------
# Nothing you would have to wait for again to keep working: not the Zephyr
# workspace, not the SDK, not either build directory (an incremental firmware
# build is seconds, a clean one is minutes), and not apt's package INDEX, which
# is what lets `apt install` find anything.
#
# HOW MUCH
# --------
# Less than the sizes suggest, and the last line of the output is the honest
# number: free space before and after, read from the filesystem. uv hard-links
# files from its cache into the environments it builds, so a cache `du` reports
# as 760 MB gave back 65 MB when it was cleared - the rest was the environment
# itself, counted twice.
#
# The space that mattered was never in a cache. It was Zephyr's git history and
# the Python packages Zephyr lists but this project never imports, about 1.4 GB
# between them, and provision/user/30-zephyr-workspace.sh no longer downloads
# either.
#
# UNOQ_KEEP_CACHES=1 skips the whole step - on a slow connection the caches are
# worth more than the space.
#
# REVERT: nothing to revert. Each tool refills its own cache on demand.
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
need_root

APT_CACHE="${UNOQ_APT_CACHE_DIR:-/var/cache/apt}"
UV="$TARGET_HOME/.local/bin/uv"
PIP_CACHE="$TARGET_HOME/.cache/pip"
# Below this a cache is not worth a line saying it was cleared.
WORTH_KB=1024

kb() { du -sk "$1" 2>/dev/null | awk '{print $1}'; }
free_mb() { df -Pm "$1" 2>/dev/null | awk 'NR==2 {print $4}'; }

if [ "${UNOQ_KEEP_CACHES:-0}" = "1" ]; then
  step "caches"
  skip "kept (UNOQ_KEEP_CACHES=1)"
  summary
  exit 0
fi

ROOT_BEFORE="$(free_mb /)"
HOME_BEFORE="$(free_mb "$TARGET_HOME")"

step "apt's downloaded packages"
have="$(kb "$APT_CACHE/archives")"
if [ "${have:-0}" -gt "$WORTH_KB" ]; then
  if apt-get clean; then
    did "removed ($((have / 1024)) MB of .deb files, all of them already installed)"
  else
    warn "apt-get clean failed - nothing lost, the space is just still in use"
  fi
else
  skip "nothing worth removing"
fi

step "uv's download cache"
# As the user who owns it, with their HOME: run as root, uv would be looking at
# /root/.cache/uv, find nothing, and say it had cleaned up.
if [ -x "$UV" ]; then
  dir="$(as_user env HOME="$TARGET_HOME" "$UV" cache dir 2>/dev/null)"
  have="$(kb "${dir:-/nonexistent}")"
  if [ "${have:-0}" -gt "$WORTH_KB" ]; then
    if as_user env HOME="$TARGET_HOME" "$UV" cache clean >/dev/null 2>&1; then
      did "cleared $dir"
    else
      warn "uv cache clean failed - nothing lost, the space is just still in use"
    fi
  else
    skip "nothing worth removing"
  fi
else
  skip "uv is not installed"
fi

step "pip's download cache"
# Only ever this exact directory, and only if it is a real directory: a
# symlink here would make rm follow someone else's idea of where the cache is.
if [ -d "$PIP_CACHE" ] && [ ! -L "$PIP_CACHE" ]; then
  have="$(kb "$PIP_CACHE")"
  if [ "${have:-0}" -gt "$WORTH_KB" ]; then
    if as_user rm -rf -- "$PIP_CACHE"; then
      did "removed $PIP_CACHE ($((have / 1024)) MB)"
    else
      warn "could not remove $PIP_CACHE"
    fi
  else
    skip "nothing worth removing"
  fi
else
  skip "no pip cache"
fi

step "what that gave back"
# From the filesystem, not from adding up what was deleted - see HOW MUCH.
ROOT_AFTER="$(free_mb /)"
HOME_AFTER="$(free_mb "$TARGET_HOME")"
skip "free on /: ${ROOT_AFTER:-?} MB (was ${ROOT_BEFORE:-?} MB)"
skip "free in $TARGET_HOME: ${HOME_AFTER:-?} MB (was ${HOME_BEFORE:-?} MB)"

summary
