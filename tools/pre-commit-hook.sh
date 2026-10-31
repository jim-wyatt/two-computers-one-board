#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Pre-commit gate. Installed by tools/install-hooks.sh.
#
# Runs check.sh --staged: every gate a --fast run has, except that shellcheck
# and the bats suites look only at what this commit touches. Those two are most
# of a full run on the board (about eight and eleven minutes), and CI runs both
# in full on every pull request, which merging needs green. The MCU suite,
# which builds Zephyr, and the diagram render are left to CI as before.
# `tools/check.sh` with no flags still runs everything, for when you want it.
#
# Skip once with:  git commit --no-verify
set -uo pipefail

PROJECT="$(git rev-parse --show-toplevel)"
cd "$PROJECT" || exit 1

# Where the unstaged changes are parked while the gates run. Inside .git/, so
# it can never itself look like part of the tree being committed.
PATCH="$(git rev-parse --git-dir)/pre-commit-unstaged.patch"
SAVED=0

# A patch, not `git stash push --keep-index`. The stash records the file's
# whole change from HEAD, so popping it onto a working tree that has been reset
# to the index conflicts whenever a file is both staged AND further edited -
# which is exactly the case --keep-index exists to handle. Re-applying a diff
# of index->worktree onto a tree known to equal the index always applies.
#
# And restoring from a trap rather than inline after check.sh: the gates take
# long enough that people do interrupt them, and without this that left the
# working tree looking just like the staged version with the unstaged edits
# parked somewhere nobody had been told about.
restore() {
  [ "$SAVED" = 1 ] || return 0
  SAVED=0 # so the EXIT trap does not run again after an explicit call
  if git apply --whitespace=nowarn "$PATCH"; then
    rm -f "$PATCH"
    return 0
  fi
  echo >&2
  echo "pre-commit: could not restore your unstaged changes automatically." >&2
  echo "They are NOT lost - they are a patch. Recover them with:" >&2
  echo "  git apply $PATCH" >&2
  return 1
}
trap 'restore' EXIT
trap 'restore; exit 130' INT
trap 'restore; exit 143' TERM

# Check the tree as it will exist after the commit, not the working tree:
# a partially staged file would otherwise be judged on unstaged content.
#
# The && chain matters: the working tree is only discarded once the patch that
# undoes that is safely on disk.
if ! git diff --quiet; then
  git diff --binary --no-color >"$PATCH" &&
    git checkout -- . &&
    SAVED=1
fi

# Without the variables git sets for a hook. check.sh runs the bats suites,
# and a test that ran git in a scratch directory with this commit's GIT_DIR
# and GIT_INDEX_FILE still set was running it on THIS repository: its
# `git commit` started this hook again, inside itself, for as long as anyone
# waited. The hook's own git commands above need them; nothing it starts does.
#
# What this commit adds or changes is worked out here, while GIT_INDEX_FILE
# still names the index being committed, and passed on: a `git commit -a`
# stages into an index of its own, which check.sh could not find without it.
UNOQ_STAGED="$(git diff --cached --name-only --diff-filter=ACMR)"
export UNOQ_STAGED
# shellcheck disable=SC2046 # one name per word is the point
env $(printf -- '-u %s ' $(git rev-parse --local-env-vars)) "$PROJECT/tools/check.sh" --staged
STATUS=$?

# A failed restore blocks the commit too. Committing on top of a tree we could
# not put back means committing something other than what the gates just saw.
restore || STATUS=1

if [ "$STATUS" -ne 0 ]; then
  echo
  echo "Commit blocked. Fix the failures above, or:"
  echo "  tools/check.sh --fix     # reformat in place"
  echo "  git commit --no-verify   # skip this once"
fi
exit "$STATUS"
