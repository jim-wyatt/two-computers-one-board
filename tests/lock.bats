#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# The steps that build a Python environment skip the install when it is
# already there. With versions pinned in a lock file, "already there" has to
# mean "built to THIS lock": otherwise a pin moves, the board is provisioned
# again as the docs say to, every line reads `ok`, and it is still running the
# old versions.
#
# The environment keeps a record of the lock it was built to. These are the
# three small functions that keep it, and the two steps' use of them.

setup() {
  load helpers/stub
  stub_setup
  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  VENV="$BATS_TEST_TMPDIR/venv"
  LOCK="$BATS_TEST_TMPDIR/lock.txt"
  mkdir -p "$VENV"
  printf '%s\n' "cmake==4.4.4" "west==1.5.0 ; python_version >= '3.9'" "pyserial==3.5" >"$LOCK"
  # shellcheck disable=SC1090
  source "$PROJECT/provision/lib.sh"
}

@test "an environment with no record was not built to this lock" {
  run lock_current "$VENV" "$LOCK"
  [ "$status" -ne 0 ]
}

@test "once recorded, it is current" {
  lock_record "$VENV" "$LOCK"
  run lock_current "$VENV" "$LOCK"
  [ "$status" -eq 0 ]
}

@test "one pin moving makes it not current" {
  lock_record "$VENV" "$LOCK"
  sed -i 's/^pyserial==3.5$/pyserial==3.6/' "$LOCK"
  run lock_current "$VENV" "$LOCK"
  [ "$status" -ne 0 ]
}

@test "a lock file that has gone missing is never 'current'" {
  lock_record "$VENV" "$LOCK"
  rm "$LOCK"
  run lock_current "$VENV" "$LOCK"
  [ "$status" -ne 0 ]
}

@test "the version a lock gives a package can be read, with or without a marker" {
  [ "$(lock_pin "$LOCK" cmake)" = "4.4.4" ]
  [ "$(lock_pin "$LOCK" west)" = "1.5.0" ]
  [ -z "$(lock_pin "$LOCK" not-in-it)" ]
}

@test "a package whose name merely starts the same is not mistaken for it" {
  echo "cmake-extras==9.9" >>"$LOCK"
  [ "$(lock_pin "$LOCK" cmake)" = "4.4.4" ]
}

# --- the two steps ------------------------------------------------------------
#
# In the file, because running either needs uv, a network and several minutes.
# What each has to do is fixed: ask before the first install, and record only
# after the last one.

@test "the project environment asks whether it is current before installing, and records after" {
  F="$PROJECT/provision/user/35-python-venv.sh"
  ask="$(grep -n '^lock_current "\$VENV" "\$LOCK"' "$F" | cut -d: -f1)"
  first="$(grep -n 'uv pip install' "$F" | grep -v '^\s*[0-9]*:\s*#' | head -1 | cut -d: -f1)"
  last="$(grep -n 'install-dev-tools.sh"' "$F" | tail -1 | cut -d: -f1)"
  record="$(grep -n '^lock_record "\$VENV" "\$LOCK"' "$F" | cut -d: -f1)"
  [ -n "$ask" ] && [ -n "$record" ]
  [ "$ask" -lt "$first" ]
  [ "$last" -lt "$record" ]
  # and each of the three skips depends on the answer
  [ "$(grep -c 'LOCKED" = 1' "$F")" -ge 3 ]
}

@test "the workspace environment does the same" {
  F="$PROJECT/provision/user/30-zephyr-workspace.sh"
  ask="$(grep -n '^lock_current "\$WS/.venv" "\$ZLOCK"' "$F" | cut -d: -f1)"
  first="$(grep -nE '^\s+uv pip install' "$F" | head -1 | cut -d: -f1)"
  last="$(grep -nE '^\s+uv pip install' "$F" | tail -1 | cut -d: -f1)"
  record="$(grep -n '^lock_record "\$WS/.venv" "\$ZLOCK"' "$F" | cut -d: -f1)"
  [ -n "$ask" ] && [ -n "$record" ]
  [ "$ask" -lt "$first" ]
  [ "$last" -lt "$record" ]
  [ "$(grep -c 'LOCKED" = 1' "$F")" -ge 2 ]
}
