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
  # fail for one of them, saying why. It is the pinned release unless a test
  # says otherwise, and `self update` moves it.
  UV_PIN="$(sed -n 's/^UV_VERSION=.*:-\([0-9][0-9.]*\)}.*/\1/p' "$STEP")"
  [ -n "$UV_PIN" ]
  echo "$UV_PIN" >"$FLAGS/uv-version"
  FAKE_UV="$BATS_TEST_TMPDIR/fake-uv"
  export FAKE_UV
  cat >"$FAKE_UV" <<'SH'
#!/bin/bash
echo "uv $*" >>"$STUB_LOG"
case "$1 $2" in
  "--version ") echo "uv $(cat "$FLAGS/uv-version") (aarch64-unknown-linux-gnu)" ;;
  "self update")
    if [ -e "$FLAGS/no-self-update" ]; then
      echo "error: uv was installed through an external package manager" >&2
      exit 2
    fi
    echo "$3" >"$FLAGS/uv-version" ;;
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
  chmod +x "$FAKE_UV"
  cp "$FAKE_UV" "$HOME/.local/bin/uv"

  # The installer, as `curl ... | sh` sees it: a script that puts the release
  # its URL names in ~/.local/bin. Nothing here reaches the network.
  stub_body curl <<'SH'
url="${*: -1}"
ver="${url#https://astral.sh/uv/}"
ver="${ver%/install.sh}"
[ "$ver" = "$url" ] && exit 22
echo "cp '$FAKE_UV' '$HOME/.local/bin/uv'; echo '$ver' >'$FLAGS/uv-version'"
SH
}

# The step with a PATH that cannot reach any uv but the fake one: the runner's
# own ~/.local/bin may hold the real uv, which these tests must never update.
step_isolated() { run env PATH="$STUB_DIR:/usr/bin:/bin" "$STEP"; }

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

# --- uv itself ---------------------------------------------------------------
#
# Everything else here is pinned, and uv installs all of it. It was the latest
# release, from an unversioned installer URL piped to a shell (#117).

@test "uv at the pin is left alone" {
  step_isolated
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok      uv $UV_PIN"* ]]
  refute ran_like '^uv self update'
  never_ran curl
}

@test "a uv at another release is brought to the pin" {
  echo 0.13.0 >"$FLAGS/uv-version"
  step_isolated
  [ "$status" -eq 0 ]
  ran "uv self update $UV_PIN"
  [[ "$output" == *"changed  uv brought to $UV_PIN (was 0.13.0)"* ]]
  never_ran curl
}

@test "a uv that cannot update itself is replaced from the pinned release's installer" {
  echo 0.13.0 >"$FLAGS/uv-version"
  : >"$FLAGS/no-self-update"
  step_isolated
  [ "$status" -eq 0 ]
  ran_like "^curl .* https://astral\.sh/uv/$UV_PIN/install\.sh\$"
  [ "$(cat "$FLAGS/uv-version")" = "$UV_PIN" ]
  [[ "$output" == *"external package manager"* ]]
  [[ "$output" == *"changed  uv $UV_PIN installed (was 0.13.0)"* ]]
}

@test "a board with no uv gets the pinned release, never the latest" {
  rm "$HOME/.local/bin/uv"
  step_isolated
  [ "$status" -eq 0 ]
  ran_like "^curl .* https://astral\.sh/uv/$UV_PIN/install\.sh\$"
  refute ran_like '^curl .*astral\.sh/uv/install\.sh'
  [[ "$output" == *"changed  uv $UV_PIN installed"* ]]
}

@test "an installer that leaves some other uv first on PATH is a failure, not ok" {
  rm "$HOME/.local/bin/uv"
  stub_body curl <<'SH'
echo "cp '$FAKE_UV' '$HOME/.local/bin/uv'; echo 0.9.9 >'$FLAGS/uv-version'"
SH
  step_isolated
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED  installed uv $UV_PIN, but the uv on PATH is 0.9.9"* ]]
}
