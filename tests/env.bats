#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# env.sh is sourced by every interactive shell on a board. It wrote out the
# workspace and the SDK as $HOME/zephyrproject and $HOME/zephyr-sdk-1.0.1, so
# with ZEPHYR_WORKSPACE or an SDK version of your own, every shell exported
# directories that did not exist - and an SDK directory that does not exist is
# one the Zephyr build will not look past (#116).

setup() {
  load helpers/stub
  stub_setup
  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  unset ZEPHYR_WORKSPACE ZEPHYR_SDK ZEPHYR_SDK_VERSION
}

# what <variable> - its value in a shell that has sourced env.sh.
what() { bash --norc --noprofile -c ". '$PROJECT/env.sh' >/dev/null 2>&1; echo \"\${$1-unset}\""; }

@test "the workspace is ZEPHYR_WORKSPACE when it is set" {
  export ZEPHYR_WORKSPACE="$BATS_TEST_TMPDIR/ws"
  [ "$(what ZEPHYR_BASE)" = "$BATS_TEST_TMPDIR/ws/zephyr" ]
}

@test "west is the workspace's own" {
  export ZEPHYR_WORKSPACE="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$ZEPHYR_WORKSPACE/.venv/bin"
  printf '#!/bin/sh\necho "the workspace west $*"\n' >"$ZEPHYR_WORKSPACE/.venv/bin/west"
  chmod +x "$ZEPHYR_WORKSPACE/.venv/bin/west"
  run bash --norc --noprofile -c ". '$PROJECT/env.sh' >/dev/null 2>&1; west --version"
  [ "$output" = "the workspace west --version" ]
}

@test "the SDK follows ZEPHYR_SDK_VERSION" {
  export ZEPHYR_SDK_VERSION=9.9.9
  mkdir -p "$HOME/zephyr-sdk-9.9.9"
  [ "$(what ZEPHYR_SDK_INSTALL_DIR)" = "$HOME/zephyr-sdk-9.9.9" ]
}

@test "the SDK follows ZEPHYR_SDK, as the mcu scripts do" {
  export ZEPHYR_SDK="$BATS_TEST_TMPDIR/sdk"
  mkdir -p "$ZEPHYR_SDK"
  [ "$(what ZEPHYR_SDK_INSTALL_DIR)" = "$ZEPHYR_SDK" ]
}

@test "an SDK directory that does not exist is not exported" {
  [ "$(what ZEPHYR_SDK_INSTALL_DIR)" = unset ]
}
