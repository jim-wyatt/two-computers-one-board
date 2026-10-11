#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# provision/90-cleanup.sh deletes things, as root, at the end of every run. So
# what is tested is mostly what it will NOT do: clean a cache it was asked to
# keep, clean root's uv cache and call it the user's, follow a symlink out of
# the home directory, or say "changed" on a board with nothing to clear.
#
# What this cannot show is how much space comes back on a board. One
# measurement exists, from a development machine: a uv cache that `du` called
# 760 MB gave back 65 MB, because its files are hard links into environments
# that are staying. That is why the step reports free space from `df` and not
# the sizes of what it removed.

setup() {
  load helpers/stub
  stub_setup

  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLEANUP="$PROJECT/provision/90-cleanup.sh"

  UNOQ_USER="$(id -un)"
  export UNOQ_USER
  FAKE_HOME="$BATS_TEST_TMPDIR/home"
  export FAKE_HOME
  mkdir -p "$FAKE_HOME/.local/bin" "$FAKE_HOME/.cache"
  export UNOQ_APT_CACHE_DIR="$BATS_TEST_TMPDIR/apt"
  mkdir -p "$UNOQ_APT_CACHE_DIR/archives"
  unset UNOQ_KEEP_CACHES

  stub_body id <<'SH'
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
SH
  # lib.sh finds the owner's home with getent. Point it at the fake one.
  stub_body getent <<'SH'
[ "$1" = passwd ] && { echo "$2:x:1000:1000::$FAKE_HOME:/bin/bash"; exit 0; }
exec /usr/bin/getent "$@"
SH
  # runuser -u <user> -- <cmd>: record who, then run the command as ourselves.
  stub_body runuser <<'SH'
while [ "$1" != "--" ]; do shift; done
shift
exec "$@"
SH
  stub apt-get
  stub df 0 "Filesystem 1048576-blocks Used Available Capacity Mounted
/dev/x 8000 5000 3000 63% /"

  # A uv with a cache directory of its own, which `cache clean` empties.
  UV_CACHE="$FAKE_HOME/.cache/uv"
  export UV_CACHE
  cat >"$FAKE_HOME/.local/bin/uv" <<SH
#!/bin/bash
echo "uv \$* HOME=\$HOME" >>"$STUB_LOG"
case "\$1 \$2" in
  "cache dir") echo "$UV_CACHE" ;;
  "cache clean") rm -rf "$UV_CACHE"/* ;;
esac
SH
  chmod +x "$FAKE_HOME/.local/bin/uv"
}

# fill <dir> <MB> - something there worth removing.
fill() {
  mkdir -p "$1"
  dd if=/dev/zero of="$1/blob" bs=1M count="$2" status=none
}

# --- apt ----------------------------------------------------------------------

@test "downloaded packages are removed when there are some" {
  fill "$UNOQ_APT_CACHE_DIR/archives" 3
  run "$CLEANUP"
  [ "$status" -eq 0 ]
  ran "apt-get clean"
  [[ "$output" == *"3 MB of .deb files"* ]]
}

@test "an empty package cache is left alone, and is not a change" {
  run "$CLEANUP"
  [ "$status" -eq 0 ]
  never_ran "apt-get"
  [[ "$output" == *"0 changed"* ]]
}

@test "apt-get clean failing is a warning, not a failed run" {
  fill "$UNOQ_APT_CACHE_DIR/archives" 3
  stub apt-get 1
  run "$CLEANUP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"apt-get clean failed"* ]]
  [[ "$output" != *"removed (3 MB"* ]]
}

# --- uv -----------------------------------------------------------------------

@test "uv's cache is cleared with the owner's HOME, not root's" {
  # Run with root's HOME, uv looks in /root/.cache/uv, finds nothing, and the
  # step reports a clean-up that cleaned nothing.
  fill "$UV_CACHE" 3
  HOME=/root run "$CLEANUP"
  [ "$status" -eq 0 ]
  ran "uv cache clean HOME=$FAKE_HOME"
  [ ! -e "$UV_CACHE/blob" ]
}

@test "a uv cache with nothing in it is not cleared" {
  mkdir -p "$UV_CACHE"
  run "$CLEANUP"
  [ "$status" -eq 0 ]
  ! ran_like "^uv cache clean"
}

@test "a board with no uv is not an error" {
  rm "$FAKE_HOME/.local/bin/uv"
  run "$CLEANUP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"uv is not installed"* ]]
}

# --- pip ----------------------------------------------------------------------

@test "pip's cache is removed when there is one" {
  fill "$FAKE_HOME/.cache/pip" 2
  run "$CLEANUP"
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE_HOME/.cache/pip" ]
}

@test "a pip cache that is a symlink is not followed" {
  fill "$BATS_TEST_TMPDIR/elsewhere" 2
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$FAKE_HOME/.cache/pip"
  run "$CLEANUP"
  [ "$status" -eq 0 ]
  [ -e "$BATS_TEST_TMPDIR/elsewhere/blob" ]
  [ -L "$FAKE_HOME/.cache/pip" ]
}

# --- the whole step -------------------------------------------------------------

@test "UNOQ_KEEP_CACHES=1 removes nothing at all" {
  fill "$UNOQ_APT_CACHE_DIR/archives" 3
  fill "$UV_CACHE" 3
  fill "$FAKE_HOME/.cache/pip" 2
  UNOQ_KEEP_CACHES=1 run "$CLEANUP"
  [ "$status" -eq 0 ]
  never_ran "apt-get"
  ! ran_like "^uv cache clean"
  [ -e "$UV_CACHE/blob" ]
  [ -e "$FAKE_HOME/.cache/pip/blob" ]
  [[ "$output" == *"kept"* ]]
}

@test "a second run finds nothing to do" {
  fill "$UV_CACHE" 3
  fill "$FAKE_HOME/.cache/pip" 2
  run "$CLEANUP"
  [ "$status" -eq 0 ]
  run "$CLEANUP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 changed"* ]]
}

@test "what it gave back is read from the filesystem" {
  run "$CLEANUP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"free on /: 3000 MB (was 3000 MB)"* ]]
}

@test "the workspace, the SDK and the build directories are never named for removal" {
  # In the file: the step's promise is a list of what it does not touch, and
  # the cheapest way to break it is one more rm.
  ! grep -nE '^[^#]*\brm\b' "$CLEANUP" | grep -v 'rm -rf -- "\$PIP_CACHE"'
  ! grep -nE '^[^#]*(zephyrproject|zephyr-sdk|/build)' "$CLEANUP"
}

@test "it refuses to run as anyone but root" {
  stub_body id <<'SH'
[ "${1:-}" = "-u" ] && { echo 1000; exit 0; }
exec /usr/bin/id "$@"
SH
  fill "$UNOQ_APT_CACHE_DIR/archives" 3
  run "$CLEANUP"
  [ "$status" -ne 0 ]
  never_ran "apt-get"
}

# --- where bootstrap puts it ------------------------------------------------------

@test "bootstrap runs it after everything that installs, and before the USB hand-over" {
  B="$PROJECT/bootstrap.sh"
  at="$(grep -n 'provision/90-cleanup.sh' "$B" | cut -d: -f1)"
  gadget="$(grep -n 'run_step "60  USB gadget' "$B" | cut -d: -f1)"
  last_other="$(grep -nE 'run_step "(1|2|3|4|5|6|7|8|u)[0-9]' "$B" | grep -v '"60 ' | tail -1 | cut -d: -f1)"
  [ -n "$at" ] && [ -n "$gadget" ] && [ -n "$last_other" ]
  [ "$last_other" -lt "$at" ]
  [ "$at" -lt "$gadget" ]
}
