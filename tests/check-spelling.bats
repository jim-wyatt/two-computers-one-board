#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# tools/check-spelling.sh decides WHICH files are checked for American
# spelling, and hands them to codespell. The deciding is what is tested: the
# first version left other people's text in (it "skipped" a directory in a way
# that skips nothing when files are named one by one), and a version that
# skipped too much would pass over the project's own files without a word.
#
# codespell itself is a fake that records what it was given. That it finds
# British spellings is codespell's business, tried by hand on a sentence of
# them; that it is asked about the right files is this script's.

setup() {
  load helpers/stub
  stub_setup
  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CHECK="$PROJECT/tools/check-spelling.sh"
  export UNOQ_CODESPELL="$STUB_DIR/codespell"
  stub_body codespell <<'SH'
printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/given"
exit "${FAKE_SPELL_RC:-0}"
SH
  export BATS_TEST_TMPDIR
}

given() { grep -qxF "$1" "$BATS_TEST_TMPDIR/given"; }

@test "the project's own files are checked: prose, scripts, firmware, tests, workflows" {
  run "$CHECK"
  [ "$status" -eq 0 ]
  given README.md
  given docs/setup.md
  given bootstrap.sh
  given provision/lib.sh
  given mcu/app/src/status_leds.c
  given python/unoq/mcu.py
  given tests/leds.bats
  given .github/workflows/ci.yml
  # including the first-party scripts under share/, which a careless skip of
  # the built site's directory would take with it
  given share/build-image.sh
}

@test "other people's text is not" {
  run "$CHECK"
  [ "$status" -eq 0 ]
  refute given LICENSE
  refute given LICENSES/Apache-2.0.txt
  refute grep -q '^docs/assets/javascripts/lunr/' "$BATS_TEST_TMPDIR/given"
  refute grep -qE '\.svd$' "$BATS_TEST_TMPDIR/given"
  refute given python/requirements-lock.txt
  refute given mcu/requirements-zephyr-lock.txt
}

@test "a misspelling fails the gate and says where the rule is written down" {
  FAKE_SPELL_RC=65 run "$CHECK"
  [ "$status" -ne 0 ]
  [[ "$output" == *".codespellrc"* ]]
}

@test "a clean run says how many files it looked at" {
  run "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" =~ spelling:\ [0-9]+\ files ]]
}

@test "with no codespell anywhere it fails, and names the installer" {
  rm "$STUB_DIR/codespell"
  run env PATH="/usr/bin:/bin" UNOQ_CODESPELL="$STUB_DIR/codespell" "$CHECK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"install-dev-tools.sh"* ]]
}

@test "the anchors the renamed headings used to have are still there" {
  # Five headings changed spelling, and with them the address of each section.
  # Links from outside the repository still point at the old ones.
  grep -q '<a id="licence"></a>' "$PROJECT/README.md"  # codespell:ignore licence
  grep -q '<a id="licence"></a>' "$PROJECT/CONTRIBUTING.md"  # codespell:ignore licence
  grep -q '<a id="colour-alone-was-not-enough"></a>' "$PROJECT/docs/learn/four-lights.md"  # codespell:ignore colour
  grep -q '<a id="grey-from-a-panel-that-has-no-grey"></a>' "$PROJECT/docs/learn/the-led-matrix.md"  # codespell:ignore grey
  grep -q '<a id="licences-not-trademarks"></a>' "$PROJECT/docs/third-party.md"  # codespell:ignore licences
}
