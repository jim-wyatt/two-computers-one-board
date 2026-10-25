#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# share/fetch-vscode.sh downloads about 2 GB of VS Code installers into a
# staging directory, and share/build-image.sh then MOVES them onto the drive
# image, because the root filesystem has no room for two copies. So the
# staging directory is empty after every build, and this script read that as
# "nothing downloaded" and fetched all of it again (#119). Its checksum step
# also warned "no installers present" whenever one of its four patterns
# matched nothing, over a file that held the checksums of all the others.

setup() {
  load helpers/stub
  stub_setup
  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FETCH="$PROJECT/share/fetch-vscode.sh"
  export UNOQ_SHARE="$BATS_TEST_TMPDIR/staging"
  export UNOQ_SHARE_MOUNT="$BATS_TEST_TMPDIR/drive"
  UNOQ_USER="$(id -un)"
  export UNOQ_USER
  mkdir -p "$UNOQ_SHARE_MOUNT/vscode"
  stub_body id <<'SH'
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
SH
  # A download is a file named for its URL.
  stub_body curl <<'SH'
out=""
while [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; shift; done
echo "installer from $out" >"$out"
SH
}

ALL=(VSCodeUserSetup-x64.exe VSCodeUserSetup-arm64.exe VSCode-darwin-universal.zip
  code-amd64.deb code-arm64.deb code-x64.tar.gz)

on_drive() {
  local f
  for f in "$@"; do echo "already there: $f" >"$UNOQ_SHARE_MOUNT/vscode/$f"; done
}

@test "installers already moved onto the drive are not downloaded again" {
  on_drive "${ALL[@]}"
  run "$FETCH"
  [ "$status" -eq 0 ]
  never_ran curl
  [[ "$output" == *"already on the drive"* ]]
  [[ "$output" != *"no installers present"* ]]
}

@test "--refresh downloads them all the same" {
  on_drive "${ALL[@]}"
  run "$FETCH" --refresh
  [ "$status" -eq 0 ]
  [ "$(grep -c '^curl' "$STUB_LOG")" -eq 6 ]
}

@test "the checksums cover the drive's installers as well as the new one" {
  # build-image.sh moves this file over the drive's own, so it has to list
  # everything the drive will hold, not just what came down this time.
  on_drive "${ALL[@]:1}"
  run "$FETCH"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^curl' "$STUB_LOG")" -eq 1 ]
  sums="$UNOQ_SHARE/vscode/SHA256SUMS.txt"
  [ "$(grep -c . "$sums")" -eq 6 ]
  for f in "${ALL[@]}"; do grep -qE "^[0-9a-f]{64}  $f\$" "$sums"; done
}

@test "a pattern that matches nothing does not turn a full set of checksums into a warning" {
  # No .zip: the macOS download failed.
  stub_body curl <<'SH'
out=""
while [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; shift; done
case "$out" in *.zip.part) exit 22 ;; esac
echo "installer from $out" >"$out"
SH
  run "$FETCH"
  [[ "$output" != *"no installers present to checksum"* ]]
  [[ "$output" == *"SHA256SUMS.txt (5 files, 5 new)"* ]]
}
