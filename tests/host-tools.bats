#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# provision/user/20-host-tools.sh is the first thing to touch the network as
# the user, on a board that has just been set up, so it is the first place a
# flaky download shows. It once failed in two seconds with the single line
# "FAILED  uv tool install cmake" and worked when run again by hand - which
# left no way of telling what had been wrong, and it turned out to be a full
# disk. What uv says is the only evidence there is, so it must reach the screen.

setup() {
  load helpers/stub
  stub_setup

  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  STEP="$PROJECT/provision/user/20-host-tools.sh"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.local/bin"
  UNOQ_USER="$(id -un)"
  export UNOQ_USER
  FLAGS="$BATS_TEST_TMPDIR/flags"
  mkdir -p "$FLAGS"
  export FLAGS

  # A uv that installs a tool by remembering that it did, and can be told to
  # fail for one of them, saying why.
  cat >"$HOME/.local/bin/uv" <<'SH'
#!/bin/bash
echo "uv $*" >>"$STUB_LOG"
case "$1 $2" in
  "--version ") echo "uv 0.0.0" ;;
  "tool list") for t in "$FLAGS"/installed-*; do [ -e "$t" ] && echo "${t##*installed-} v1.0"; done ;;
  "tool install")
    tool="${@: -1}"
    if [ -e "$FLAGS/fail-$tool" ]; then
      echo "error: Failed to download \`$tool\`" >&2
      echo "  Caused by: No space left on device (os error 28)" >&2
      exit 2
    fi
    touch "$FLAGS/installed-$tool" ;;
esac
exit 0
SH
  chmod +x "$HOME/.local/bin/uv"
}

@test "all three tools are installed on a board that has none" {
  run "$STEP"
  [ "$status" -eq 0 ]
  # Each at the version the lock file gives it.
  L="$PROJECT/mcu/requirements-zephyr-lock.txt"
  ran "uv tool install -c $L cmake"
  ran "uv tool install -c $L ninja"
  ran "uv tool install -c $L west"
}

@test "when uv cannot install a tool, what uv said is shown" {
  touch "$FLAGS/fail-cmake"
  run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No space left on device"* ]]
  [[ "$output" == *"uv tool install cmake"* ]]
}

@test "a failure stops the step there, not after the next tool" {
  touch "$FLAGS/fail-cmake"
  run "$STEP"
  refute ran_like "^uv tool install .* ninja\$"
}

@test "a second run installs nothing" {
  run "$STEP"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  refute ran_like "^uv tool install"
  [[ "$output" == *"0 changed"* ]]
}
