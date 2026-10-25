#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# provision/user/40-shell-env.sh puts one line in ~/.bashrc, under a marker,
# and repoints it when the checkout moves. The repoint was a sed over every
# `source .../env.sh` line in the file, so another project's env.sh was
# pointed at this one as well (#119) - a shell that quietly stopped setting
# up somebody else's tools, with nothing in this project's output to say so.

setup() {
  load helpers/stub
  stub_setup
  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  STEP="$PROJECT/provision/user/40-shell-env.sh"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  # Not a git checkout, as far as the hook step can tell: these tests must
  # never install a hook in the repository running them.
  export UNOQ_GIT_DIR="$BATS_TEST_TMPDIR/no-git"
}

@test "a moved checkout repoints its own line and nobody else's" {
  printf '%s\n' "source /opt/other-project/env.sh" "" \
    "# unoq hybrid dev environment" "source /home/old/place/env.sh" >"$HOME/.bashrc"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"changed  repointed the env.sh line at $PROJECT"* ]]
  grep -qx "source /opt/other-project/env.sh" "$HOME/.bashrc"
  grep -qx "source $PROJECT/env.sh" "$HOME/.bashrc"
  refute grep -qx "source /home/old/place/env.sh" "$HOME/.bashrc"
}

@test "a fresh ~/.bashrc gets the marker and the line once" {
  : >"$HOME/.bashrc"
  run "$STEP"
  [ "$status" -eq 0 ]
  run "$STEP"
  [ "$(grep -cx "source $PROJECT/env.sh" "$HOME/.bashrc")" -eq 1 ]
  [ "$(grep -cx "# unoq hybrid dev environment" "$HOME/.bashrc")" -eq 1 ]
}

@test "a marker with nothing to repoint after it is reported, not called done" {
  printf '%s\n' "# unoq hybrid dev environment" "echo someone edited this" >"$HOME/.bashrc"
  run "$STEP"
  [[ "$output" == *"no source line after it to repoint"* ]]
  [[ "$output" != *"repointed the env.sh line"* ]]
}
