#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# provision/user/30-zephyr-workspace.sh decides whether the board's Zephyr is
# the one this project pins. It said it was whenever a workspace existed: move
# ZEPHYR_VERSION to v4.4.3, re-run bootstrap, and every line read ok, west
# update was skipped, the lock record vouched for the venv, and the board was
# still on v4.4.2 (issue #111). CI builds from west.yml, so the board and CI
# then compiled different Zephyrs with every check green.
#
# git here is the real one, on a real shallow clone of a local repository with
# two tags, because whether a shallow checkout can be moved to another tag is
# the part most worth knowing. west, uv and the workspace's python are fakes:
# a module checkout and a package install are not what is under test.
#
# What this cannot show: that the fetch works against GitHub, or that west
# update then brings the modules to the new manifest. That is the board's job,
# and the provisioning workflow's.

setup() {
  load helpers/stub
  stub_setup

  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  WS_STEP="$PROJECT/provision/user/30-zephyr-workspace.sh"

  export HOME="$BATS_TEST_TMPDIR/home"
  export ZEPHYR_WORKSPACE="$HOME/zephyrproject"
  WS="$ZEPHYR_WORKSPACE"
  mkdir -p "$HOME"
  # Commits made here and by nothing else.
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  git config --global user.email test@example.invalid
  git config --global user.name test
  git config --global protocol.file.allow always

  # Upstream Zephyr, as far as this step can tell: two tagged releases.
  UP="$BATS_TEST_TMPDIR/upstream"
  git init -q "$UP"
  echo 4.4.2 >"$UP/VERSION"
  git -C "$UP" add VERSION
  git -C "$UP" commit -q -m v4.4.2
  git -C "$UP" tag v4.4.2
  echo 4.4.3 >"$UP/VERSION"
  git -C "$UP" commit -q -am v4.4.3
  git -C "$UP" tag v4.4.3

  # A workspace that west init made at v4.4.2, without history, with its
  # modules checked out and registered with CMake.
  git clone -q --depth=1 --branch v4.4.2 "file://$UP" "$WS/zephyr" 2>/dev/null
  mkdir -p "$WS/.west" "$WS/modules/hal/stm32" "$WS/.venv/bin"
  : >"$WS/.west/config"
  mkdir -p "$HOME/.cmake/packages/Zephyr"
  echo "$WS/zephyr/share/zephyr-package/cmake" >"$HOME/.cmake/packages/Zephyr/abc123"

  # west answers the filter question with the filter, so that step is quiet.
  FILTER="$(grep -vE '^[[:space:]]*(#|$)' "$PROJECT/west-project-filter" | head -1)"
  export FILTER
  stub_body west <<'SH'
[ "$1 $2" = "config manifest.project-filter" ] && [ $# -eq 2 ] && echo "$FILTER"
exit 0
SH
  mv "$STUB_DIR/west" "$WS/.venv/bin/west"
  stub_body python <<'SH'
exit 0
SH
  mv "$STUB_DIR/python" "$WS/.venv/bin/python"
  : >"$WS/.venv/bin/imgtool"
  chmod +x "$WS/.venv/bin/imgtool"
  stub uv
  stub du 0 "2.0G	x"

  # Built to the lock as it is: on an unmoved workspace nothing is installed.
  sha256sum "$PROJECT/mcu/requirements-zephyr-lock.txt" | cut -d' ' -f1 >"$WS/.venv/.unoq-lock"
}

ws_step() { run env ZEPHYR_VERSION="${1:-v4.4.2}" "$WS_STEP"; }
zephyr_at() { git -C "$WS/zephyr" describe --tags; }

@test "a workspace at the pin is left alone" {
  ws_step v4.4.2
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok      workspace at v4.4.2"* ]]
  refute ran_like 'west update'
  refute ran_like '^uv pip install'
  [ "$(zephyr_at)" = v4.4.2 ]
}

@test "moving the pin moves the workspace" {
  ws_step v4.4.3
  [ "$status" -eq 0 ]
  [ "$(zephyr_at)" = v4.4.3 ]
  [ "$(cat "$WS/zephyr/VERSION")" = 4.4.3 ]
  [[ "$output" == *"changed  Zephyr moved from v4.4.2 to v4.4.3"* ]]
}

@test "a moved workspace has its modules and requirements brought along" {
  # Both of these skip when something is already there, and something always
  # is: the modules and the requirements of the version being left.
  ws_step v4.4.3
  [ "$status" -eq 0 ]
  ran "west update --narrow -o=--depth=1"
  ran_like '^uv pip install .*requirements-base\.txt'
}

@test "the move happens once" {
  ws_step v4.4.3
  [ "$status" -eq 0 ]
  : >"$STUB_LOG"
  ws_step v4.4.3
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok      workspace at v4.4.3"* ]]
  [[ "$output" == *"0 changed,"* ]]
  refute ran_like 'west update'
}

@test "a Zephyr tree with local changes is not moved under them" {
  echo "a fix in progress" >>"$WS/zephyr/VERSION"
  ws_step v4.4.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED  $WS/zephyr is at v4.4.2, the pin is v4.4.3, and it has local changes"* ]]
  [ "$(zephyr_at)" = v4.4.2-dirty ] || [ "$(zephyr_at)" = v4.4.2 ]
  grep -q "a fix in progress" "$WS/zephyr/VERSION"
  refute ran_like 'west update'
}

@test "a pin that does not exist upstream fails, and names it" {
  ws_step v9.9.9
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED  could not fetch Zephyr v9.9.9"* ]]
  [ "$(zephyr_at)" = v4.4.2 ]
}

# --- zephyr-export -----------------------------------------------------------

@test "a CMake registration for this workspace is enough" {
  ws_step v4.4.2
  [ "$status" -eq 0 ]
  refute ran_like 'west zephyr-export'
}

@test "a CMake registration for some other workspace is not this one" {
  # The test was whether ~/.cmake/packages/Zephyr existed at all.
  echo "/home/someone/old-zephyr/zephyr/share/zephyr-package/cmake" \
    >"$HOME/.cmake/packages/Zephyr/abc123"
  ws_step v4.4.2
  [ "$status" -eq 0 ]
  ran "west zephyr-export"
  [[ "$output" == *"changed  Zephyr registered with CMake"* ]]
}
