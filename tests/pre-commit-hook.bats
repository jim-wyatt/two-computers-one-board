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

# --- what the hook checks ---------------------------------------------------
#
# The hook runs `check.sh --staged`: shellcheck and the bats suites cut to what
# the commit touches, because over the whole tree they are about twenty
# minutes on the board, and CI runs them in full before anything merges. What
# is at stake is the cut: a suite that names a changed script and is not run
# is a failure the commit hides until CI.

# staged_run <file>... - check.sh --staged's shell gates, as if the commit
# held these files, with shellcheck, shfmt and bats recording what they got.
staged_run() {
  stub_setup
  stub shellcheck
  stub shfmt
  stub bats
  # check.sh puts ~/.local/bin first, where the real tools are on a board.
  HOME="$BATS_TEST_TMPDIR/home" UNOQ_STAGED="$(printf '%s\n' "$@")" \
    run "$PROJECT/tools/check.sh" --staged shell
}

# suites_run - the suites bats was handed, one per line, relative and sorted.
suites_run() {
  grep '^bats ' "$STUB_LOG" | cut -d' ' -f2- | tr ' ' '\n' | sed "s#^$PROJECT/##" | sort
}

@test "the hook hands check.sh --staged the files of the commit, git commit -a included" {
  repo="$BATS_TEST_TMPDIR/repo"
  git init -q "$repo"
  mkdir -p "$repo/tools" "$repo/hooks"
  cat >"$repo/tools/check.sh" <<'SH'
#!/bin/bash
{ echo "args: $*"; echo "$UNOQ_STAGED"; } >"$(dirname "$0")/../seen"
SH
  chmod +x "$repo/tools/check.sh"
  ln -s "$PROJECT/tools/pre-commit-hook.sh" "$repo/hooks/pre-commit"
  git -C "$repo" config core.hooksPath hooks
  echo one >"$repo/a.sh"
  git -C "$repo" add tools/check.sh a.sh
  git -C "$repo" commit -q -m one
  # Changed and not added: only -a stages it, into an index of its own.
  echo two >"$repo/a.sh"
  run git -C "$repo" commit -q -a -m two
  [ "$status" -eq 0 ]
  [ "$(head -1 "$repo/seen")" = "args: --staged" ]
  [ "$(tail -n +2 "$repo/seen")" = "a.sh" ]
}

@test "a changed script is linted alone, and the suites that name it are run" {
  staged_run provision/50-status-leds.sh
  [ "$status" -eq 0 ]
  ran "shellcheck -x provision/50-status-leds.sh"
  ran "shfmt -i 2 -ci -d provision/50-status-leds.sh"
  expected="$(grep -lF provision/50-status-leds.sh "$PROJECT"/tests/*.bats | sed "s#^$PROJECT/##" | sort)"
  [ -n "$expected" ]
  [ "$(suites_run)" = "$expected" ]
}

@test "a changed suite is run" {
  staged_run tests/lock.bats
  [ "$status" -eq 0 ]
  [ "$(suites_run)" = "tests/lock.bats" ]
  never_ran shellcheck
}

@test "a change to the suites' shared helpers runs every suite" {
  staged_run tests/helpers/stub.bash
  [ "$status" -eq 0 ]
  [ "$(suites_run | wc -l)" -eq "$(git -C "$PROJECT" ls-files 'tests/*.bats' | wc -l)" ]
}

@test "a commit with no script and no suite in it says what it left to CI" {
  # Split, or this file would name it, and be a suite that does.
  staged_run "docs/learn/""knowing-it-works.md"
  [ "$status" -eq 0 ]
  never_ran shellcheck
  never_ran bats
  [[ "$output" == *"shellcheck and shfmt (skipped: no shell script in this commit)"* ]]
  [[ "$output" == *"bats (shell behavior) (skipped: no suite is in this commit or names a file in it; CI runs them all)"* ]]
}

@test "without --staged, every script and every suite, as CI runs them" {
  stub_setup
  stub shellcheck
  stub shfmt
  stub bats
  HOME="$BATS_TEST_TMPDIR/home" UNOQ_STAGED="README.md" run "$PROJECT/tools/check.sh" --fast shell
  [ "$status" -eq 0 ]
  ran "bats $PROJECT/tests"
  ran_like "^shellcheck -x .*bootstrap.sh .*provision/lib.sh"
}
