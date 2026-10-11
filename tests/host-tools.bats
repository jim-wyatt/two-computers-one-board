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
  "tool list")
    for t in "$FLAGS"/installed-*; do
      [ -e "$t" ] && echo "${t##*installed-} v$(cat "$t")"
    done ;;
  "tool install")
    spec="${@: -1}"
    tool="${spec%%==*}"
    ver="1.0"
    [ "$spec" != "$tool" ] && ver="${spec##*==}"
    if [ -e "$FLAGS/fail-$tool" ]; then
      echo "error: Failed to download \`$tool\`" >&2
      echo "  Caused by: No space left on device (os error 28)" >&2
      exit 2
    fi
    echo "$ver" >"$FLAGS/installed-$tool" ;;
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
  ran_like "^uv tool install -c $L -b $L cmake==[0-9.]+\$"
  ran_like "^uv tool install -c $L -b $L ninja==[0-9.]+\$"
  ran_like "^uv tool install -c $L -b $L west==[0-9.]+\$"
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
  refute ran_like "^uv tool install .* ninja"
}

@test "a second run installs nothing" {
  run "$STEP"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  refute ran_like "^uv tool install"
  [[ "$output" == *"0 changed"* ]]
}

@test "a tool installed at another version is brought to the one in the lock file" {
  # Present is not enough. A board set up before a pin moved would otherwise
  # keep the old cmake for good, under a line that said ok.
  echo "3.0.0" >"$FLAGS/installed-cmake"
  run "$STEP"
  [ "$status" -eq 0 ]
  ran_like '^uv tool install .* cmake==[0-9.]+$'
  [[ "$output" == *"cmake brought to v"*"(was v3.0.0)"* ]]
  [ "$(cat "$FLAGS/installed-cmake")" != "3.0.0" ]
}
