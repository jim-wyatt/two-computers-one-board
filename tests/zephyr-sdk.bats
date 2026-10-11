#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# provision/user/25-zephyr-sdk.sh is the first slow step of bootstrap.sh, and
# the first one a stranger's board ever stopped at (issue #69):
#
#     installing the arm-zephyr-eabi toolchain...
#     FAILED  SDK setup.sh failed
#
# Two bugs, stacked. The SDK's setup.sh wants cmake on PATH, cmake lives in
# ~/.local/bin, and on a board nobody has logged into since that directory was
# created, nothing has put it on PATH. That is the failure. The second bug is
# why it took six weeks to find: setup.sh says exactly what is wrong, and the
# script sent it to /dev/null.
#
# It passed on every board it was developed on, because those had been logged
# into before. The PATH these tests build is the one a fresh board has.

setup() {
  load helpers/stub
  stub_setup

  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SDK_STEP="$PROJECT/provision/user/25-zephyr-sdk.sh"

  export HOME="$BATS_TEST_TMPDIR/home"
  SDK_DIR="$HOME/zephyr-sdk-1.0.1"
  mkdir -p "$HOME/.local/bin"

  # A PATH with no cmake and no wget on it, which a CI runner's real one is
  # not: only the handful of ordinary tools the script itself uses.
  BASE="$BATS_TEST_TMPDIR/base-bin"
  mkdir -p "$BASE"
  local tool
  for tool in bash dirname id uname mktemp rm head tail sed mkdir cat chmod cp awk cut sha256sum; do
    ln -s "$(command -v "$tool")" "$BASE/$tool"
  done
  FRESH_PATH="$STUB_DIR:$BASE"

  # By default the release serves an archive and a checksum that vouches for
  # it. It used to be a curl that wrote nothing at all, which every test above
  # the checksum section passed through - because a missing checksum was waved
  # on. It no longer is, so the ordinary case has to be an honest one.
  curl_serves 'the real archive'
  stub wget
  # Stands in for the extract: it leaves an SDK directory holding whatever
  # setup.sh the test wrote to $FAKE_SETUP.
  FAKE_SETUP="$BATS_TEST_TMPDIR/setup.sh"
  export FAKE_SETUP SDK_DIR
  stub_body tar <<'SH'
mkdir -p "$SDK_DIR"
cp "$FAKE_SETUP" "$SDK_DIR/setup.sh"
chmod +x "$SDK_DIR/setup.sh"
SH
}

# The step, run with the fresh board's PATH rather than the test runner's.
sdk_step() { run env PATH="$FRESH_PATH" "$SDK_STEP"; }

# A setup.sh that behaves like the real one where it matters: it refuses to
# start without cmake, and otherwise leaves a compiler where SDK 1.0.1 puts it.
working_setup() {
  cat >"$FAKE_SETUP" <<'SH'
#!/bin/bash
if ! command -v cmake >/dev/null 2>&1; then
  echo "Zephyr SDK setup requires 'cmake' to be installed and available in the PATH."
  exit 90
fi
mkdir -p gnu/arm-zephyr-eabi/bin
printf '#!/bin/bash\necho "arm-zephyr-eabi-gcc (fake) 14.0"\n' >gnu/arm-zephyr-eabi/bin/arm-zephyr-eabi-gcc
chmod +x gnu/arm-zephyr-eabi/bin/arm-zephyr-eabi-gcc
SH
}

fake_cmake_in_local_bin() {
  printf '#!/bin/bash\nexit 0\n' >"$HOME/.local/bin/cmake"
  chmod +x "$HOME/.local/bin/cmake"
}

@test "cmake that is only in ~/.local/bin is found (the fresh-board case)" {
  working_setup
  fake_cmake_in_local_bin
  sdk_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"arm-zephyr-eabi installed"* ]]
}

@test "no cmake anywhere fails before the download, and names the step that installs it" {
  working_setup
  sdk_step
  [ "$status" -eq 1 ]
  [[ "$output" == *"cmake is not on PATH"* ]]
  [[ "$output" == *"20-host-tools.sh"* ]]
  never_ran curl
}

@test "no wget fails before the download, and says how to get it" {
  working_setup
  fake_cmake_in_local_bin
  rm "$STUB_DIR/wget"
  sdk_step
  [ "$status" -eq 1 ]
  [[ "$output" == *"apt-get install -y wget"* ]]
  never_ran curl
}

@test "when setup.sh fails, what it said is shown" {
  cat >"$FAKE_SETUP" <<'SH'
#!/bin/bash
echo "ERROR: GNU toolchain download failed"
exit 20
SH
  fake_cmake_in_local_bin
  sdk_step
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: GNU toolchain download failed"* ]]
  [[ "$output" == *"SDK setup.sh failed"* ]]
}

@test "an SDK that is already there is not downloaded again" {
  working_setup
  fake_cmake_in_local_bin
  mkdir -p "$SDK_DIR" && (cd "$SDK_DIR" && PATH="$HOME/.local/bin:$PATH" bash "$FAKE_SETUP")
  sdk_step
  [ "$status" -eq 0 ]
  never_ran curl
  [[ "$output" == *"0 changed"* ]]
}

# --- the checksum -----------------------------------------------------------
#
# The archive is unpacked into $HOME and a script inside it is run. The release
# publishes a sha256 for it, and nothing used to look.

# A curl that writes what it was asked for: a payload for the archive, and a
# sum file that vouches for $PUBLISHED_FOR. Two ways of there being no sum:
# `none` is a sha256.sum that cannot be fetched, `absent` is one that arrives
# and has no line for this archive.
curl_serves() {
  export PUBLISHED_FOR="$1"
  stub_body curl <<'SH'
out=""
url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o)
      out="$2"
      shift
      ;;
    http*) url="$1" ;;
  esac
  shift
done
case "$url" in
  */sha256.sum)
    [ "$PUBLISHED_FOR" = none ] && exit 22
    name="zephyr-sdk-${SERVED_VERSION:-1.0.1}_linux-$(uname -m)_minimal.tar.xz"
    [ "$PUBLISHED_FOR" = absent ] && name="some-other-file.tar.xz"
    printf '%s  %s\n' "$(printf '%s' "$PUBLISHED_FOR" | sha256sum | cut -d" " -f1)" "$name" >"$out"
    ;;
  *) printf 'the real archive' >"$out" ;;
esac
SH
}

# A release other than the pinned one, chosen the way the script lets you.
overridden_to() {
  export ZEPHYR_SDK_VERSION="$1" SERVED_VERSION="$1"
  SDK_DIR="$HOME/zephyr-sdk-$1"
  export SDK_DIR
}

@test "an archive that matches its published checksum is unpacked" {
  working_setup
  fake_cmake_in_local_bin
  curl_serves 'the real archive'
  sdk_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"checksum matches"* ]]
}

@test "an archive that does not match is never unpacked, and its setup.sh never run" {
  working_setup
  fake_cmake_in_local_bin
  curl_serves 'something else entirely'
  sdk_step
  [ "$status" -eq 1 ]
  [[ "$output" == *"checksum mismatch"* ]]
  never_ran tar
  [ ! -e "$SDK_DIR" ]
}

# --- and when there is no checksum to compare with ---------------------------
#
# This used to be one test, and it asserted the bug: "a release with no
# published checksum is unpacked, and says it was not verified". A sum file
# that failed to download took the same path, so the check could be switched
# off by one dropped request.

@test "the pinned release is never unpacked when its checksum cannot be fetched" {
  working_setup
  fake_cmake_in_local_bin
  curl_serves none
  sdk_step
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not fetch"*"sha256.sum"* ]]
  [[ "$output" == *"not unpacking"* ]]
  never_ran tar
  [ ! -e "$SDK_DIR" ]
}

@test "nor when the checksum file arrives with no line for the archive" {
  working_setup
  fake_cmake_in_local_bin
  curl_serves absent
  sdk_step
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no line for"* ]]
  never_ran tar
  [ ! -e "$SDK_DIR" ]
}

@test "the opt-in does not apply to the pinned release" {
  # Also what goes red if the pin is bumped in one of the two places the
  # script states it and not the other.
  working_setup
  fake_cmake_in_local_bin
  curl_serves none
  export UNOQ_ALLOW_UNVERIFIED_SDK=1
  sdk_step
  [ "$status" -eq 1 ]
  never_ran tar
  [ ! -e "$SDK_DIR" ]
}

@test "an overridden release with no checksum is refused, and the opt-in is named" {
  working_setup
  fake_cmake_in_local_bin
  overridden_to 9.9.9
  curl_serves none
  sdk_step
  [ "$status" -eq 1 ]
  [[ "$output" == *"UNOQ_ALLOW_UNVERIFIED_SDK=1"* ]]
  never_ran tar
  [ ! -e "$SDK_DIR" ]
}

@test "an overridden release with no checksum is unpacked when asked for, and says it was not verified" {
  working_setup
  fake_cmake_in_local_bin
  overridden_to 9.9.9
  curl_serves none
  export UNOQ_ALLOW_UNVERIFIED_SDK=1
  sdk_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"unverified"* ]]
  [ -d "$SDK_DIR" ]
}

@test "the opt-in does not excuse a checksum that is published and does not match" {
  working_setup
  fake_cmake_in_local_bin
  overridden_to 9.9.9
  curl_serves 'something else entirely'
  export UNOQ_ALLOW_UNVERIFIED_SDK=1
  sdk_step
  [ "$status" -eq 1 ]
  [[ "$output" == *"checksum mismatch"* ]]
  never_ran tar
}
