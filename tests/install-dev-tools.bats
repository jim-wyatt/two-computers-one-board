#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# tools/install-dev-tools.sh puts shellcheck, shfmt, bats and actionlint into
# ~/.local/bin, where every gate runs them, here and in CI. It pinned which
# release to ask for and then installed whatever bytes came back (#118). Each
# download is now checked against a SHA-256 recorded beside its version.
#
# Nothing here reaches the network: curl is a fake that serves a file of the
# test's choosing. So a matching download is shown with a hash given through
# the script's own override, and the recorded hashes themselves are checked
# only for being there - that they are the real ones was checked by hand
# against the digests GitHub lists for each release asset.

setup() {
  load helpers/stub
  stub_setup

  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  INSTALL="$PROJECT/tools/install-dev-tools.sh"
  export HOME="$BATS_TEST_TMPDIR/home"
  export UNOQ_BIN="$HOME/.local/bin"
  export UNOQ_VENV="$BATS_TEST_TMPDIR/venv"
  mkdir -p "$UNOQ_BIN" "$UNOQ_VENV/bin"
  FLAGS="$BATS_TEST_TMPDIR/flags"
  mkdir -p "$FLAGS"
  export FLAGS

  # The Python half is not under test: a venv that is already there, and a uv
  # that does nothing.
  stub uv
  local t
  for t in python ruff mypy mkdocs; do
    printf '#!/bin/bash\necho "%s 1.0 1.0"\n' "$t" >"$UNOQ_VENV/bin/$t"
    chmod +x "$UNOQ_VENV/bin/$t"
  done

  # Every tool already at its pin, so each test moves exactly one.
  SC_PIN="$(pin SHELLCHECK_VERSION)"
  SHFMT_PIN="$(pin SHFMT_VERSION)"
  BATS_PIN="$(pin BATS_VERSION)"
  AL_PIN="$(pin ACTIONLINT_VERSION)"
  fake_tool shellcheck "version: $SC_PIN"
  fake_tool shfmt "v$SHFMT_PIN"
  fake_tool bats "Bats $BATS_PIN"
  fake_tool actionlint "$AL_PIN"

  # curl -fsSL <url> -o <file>: writes $FLAGS/serve to <file>, or fails.
  stub_body curl <<'SH'
out=""
while [ $# -gt 0 ]; do
  [ "$1" = -o ] && out="$2"
  shift
done
[ -e "$FLAGS/serve" ] || exit 22
cp "$FLAGS/serve" "$out"
SH
}

# The script with a PATH that holds no real copy of any of the four: on a
# board, ~/.local/bin has them all at their pins, and the script would find
# those and call the job done.
run_install() { run env PATH="$STUB_DIR:/usr/bin:/bin" "$INSTALL"; }

pin() { sed -n "s/^$1=.*:-\\([0-9][0-9.]*\\)}.*/\\1/p" "$INSTALL"; }

# fake_tool <name> <what --version prints>
fake_tool() {
  printf '#!/bin/bash\necho "%s"\n' "$2" >"$UNOQ_BIN/$1"
  chmod +x "$UNOQ_BIN/$1"
}

# serve <content> - what the next download returns, and its SHA-256.
serve() {
  printf '%s' "$1" >"$FLAGS/serve"
  SERVED_SHA="$(sha256sum "$FLAGS/serve" | cut -d' ' -f1)"
}

@test "a download that does not match its recorded checksum is not installed" {
  rm "$UNOQ_BIN/shfmt"
  serve "not shfmt at all"
  run_install
  [ "$status" -ne 0 ]
  [[ "$output" == *"shfmt v$SHFMT_PIN did not match its checksum - not installed"* ]]
  [[ "$output" == *"got      $SERVED_SHA"* ]]
  [ ! -e "$UNOQ_BIN/shfmt" ]
}

@test "a download that matches is installed" {
  rm "$UNOQ_BIN/shfmt"
  serve $'#!/bin/bash\necho v'"$SHFMT_PIN"
  export SHFMT_SHA256="$SERVED_SHA"
  run_install
  [ "$status" -eq 0 ]
  [ -x "$UNOQ_BIN/shfmt" ]
  [ "$("$UNOQ_BIN/shfmt")" = "v$SHFMT_PIN" ]
}

@test "a download that fails its check leaves the old tool where it was" {
  # shfmt was downloaded straight over the installed one, so a bad download
  # replaced a working tool.
  fake_tool shfmt "v3.0.0"
  serve "not shfmt at all"
  run_install
  [ "$status" -ne 0 ]
  [ "$("$UNOQ_BIN/shfmt" --version)" = "v3.0.0" ]
}

@test "an archive that does not match is never unpacked" {
  # Checked before tar sees it, not after: unpacking is already running it.
  rm "$UNOQ_BIN/actionlint"
  serve "a tarball from somewhere else"
  stub tar
  run_install
  [ "$status" -ne 0 ]
  [[ "$output" == *"actionlint v$AL_PIN did not match its checksum"* ]]
  never_ran tar
}

@test "a version with no recorded checksum is refused before anything is downloaded" {
  export SHFMT_VERSION=9.9.9
  run_install
  [ "$status" -ne 0 ]
  [[ "$output" == *"no checksum recorded for shfmt 9.9.9"* ]]
  [[ "$output" == *"SHFMT_SHA256"* ]]
  never_ran curl
}

@test "every pinned tool has a checksum for every architecture it is fetched for" {
  # A bump that moves a version without its line fails here, not on a runner.
  sums="$(sed -n "/^DEV_TOOL_SUMS='/,/^'/p" "$INSTALL")"
  for want in "shellcheck $SC_PIN aarch64" "shellcheck $SC_PIN x86_64" \
    "shfmt $SHFMT_PIN arm64" "shfmt $SHFMT_PIN amd64" \
    "actionlint $AL_PIN arm64" "actionlint $AL_PIN amd64" "bats $BATS_PIN any"; do
    awk -v w="$want" '{ if ($1 " " $2 " " $3 == w && $4 ~ /^[0-9a-f]{64}$/) f = 1 } END { exit !f }' <<<"$sums" ||
      {
        echo "no sha256 for: $want" >&2
        return 1
      }
  done
}
