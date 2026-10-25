#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# tools/pre-commit-hook.sh runs tools/check.sh, and check.sh runs these suites.
# git hands a hook GIT_DIR and GIT_INDEX_FILE, and both were passed straight
# on. tests/build-flash.bats makes scratch repositories with `git init` and
# `git commit`; with those variables set, both acted on the repository being
# committed to, and the commit started the hook again, inside itself. A commit
# never finished, and nothing said why.
#
# What this cannot show: that every suite is now safe. It shows the two ends,
# the hook and the shared setup every suite calls.

setup() {
  load helpers/stub
  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  git config --global user.email test@example.invalid
  git config --global user.name test
}

@test "check.sh is run without the repository git gave the hook" {
  # A repository whose check.sh only records what it was handed.
  repo="$BATS_TEST_TMPDIR/repo"
  git init -q "$repo"
  mkdir -p "$repo/tools" "$repo/hooks"
  cat >"$repo/tools/check.sh" <<'SH'
#!/bin/bash
echo "GIT_DIR=${GIT_DIR-unset} GIT_INDEX_FILE=${GIT_INDEX_FILE-unset}" >"$(dirname "$0")/../seen"
SH
  chmod +x "$repo/tools/check.sh"
  ln -s "$PROJECT/tools/pre-commit-hook.sh" "$repo/hooks/pre-commit"
  git -C "$repo" config core.hooksPath hooks
  git -C "$repo" add tools/check.sh
  run git -C "$repo" commit -q -m one
  [ "$status" -eq 0 ]
  [ "$(cat "$repo/seen")" = "GIT_DIR=unset GIT_INDEX_FILE=unset" ]
}

@test "a suite run from inside a hook does not see the hook's repository" {
  export GIT_DIR=/somewhere/else/.git GIT_INDEX_FILE=/somewhere/else/.git/index GIT_WORK_TREE=/somewhere/else
  stub_setup
  [ -z "${GIT_DIR+x}" ]
  [ -z "${GIT_INDEX_FILE+x}" ]
  [ -z "${GIT_WORK_TREE+x}" ]
}
