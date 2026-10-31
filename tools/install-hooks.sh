#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Point git's pre-commit hook at tools/pre-commit-hook.sh.
#
#   ~/two-computers-one-board/tools/install-hooks.sh
#
# A symlink, not a copy, so edits to the tracked script take effect without
# reinstalling. Git hooks are not themselves versioned, which is why this
# exists rather than the hook just being in .git/hooks.
#
# The pre-commit framework would work too, but it fetches its own pinned copies
# of ruff and shellcheck - a second toolchain to keep in step with the one
# check.sh uses, on a board with 3.6 GiB of RAM. This reuses check.sh instead.
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
# Absolute: --git-path on its own answers ".git/hooks", relative to the
# repository, and mkdir and ln below would read that against wherever this was
# run from. Run from $HOME, the hook went into ~/.git/hooks and the repository
# got none.
HOOK_DIR="$(git -C "$PROJECT" rev-parse --path-format=absolute --git-path hooks)"
HOOK="$HOOK_DIR/pre-commit"

mkdir -p "$HOOK_DIR"

if [ -e "$HOOK" ] && [ ! -L "$HOOK" ]; then
  echo "refusing to overwrite an existing non-symlink hook: $HOOK" >&2
  echo "move it aside and re-run." >&2
  exit 1
fi

ln -sfn "$PROJECT/tools/pre-commit-hook.sh" "$HOOK"
echo "installed $HOOK -> tools/pre-commit-hook.sh"
echo "runs: tools/check.sh --staged   (skip once with git commit --no-verify)"
