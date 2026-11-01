#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# mcu/micropython/build.sh: its arguments, and the two pins it holds the
# build to - MicroPython's commit, and the Zephyr release that commit was
# made for.
#
# The real build takes ten minutes and the network, so none of it runs here.
# MicroPython is a local repository with the pinned tag on it, and west is a
# stub that records what it was asked to build and builds nothing. So every
# run that gets as far as west then stops at "no signed image", which is the
# script's own guard against reporting an image it does not have.

setup() {
  load helpers/stub
  stub_setup

  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$PROJECT/mcu/micropython/build.sh"

  export HOME="$BATS_TEST_TMPDIR/home"
  export ZEPHYR_WORKSPACE="$HOME/zephyrproject"
  export MPY_HOME="$BATS_TEST_TMPDIR/mpy"
  mkdir -p "$ZEPHYR_WORKSPACE/.venv/bin" "$ZEPHYR_WORKSPACE/zephyr"
  zephyr_is 4 4 2

  # zbuild.sh calls the workspace's west by path, as in build-flash.bats.
  cat >"$ZEPHYR_WORKSPACE/.venv/bin/west" <<'SH'
#!/bin/bash
{ printf 'west'; printf ' %s' "$@"; printf '\n'; } >>"$STUB_LOG"
SH
  chmod +x "$ZEPHYR_WORKSPACE/.venv/bin/west"

  # A MicroPython with just enough in it: the file the Zephyr version is read
  # from, and the port directory zbuild is pointed at.
  UPSTREAM="$BATS_TEST_TMPDIR/upstream"
  mkdir -p "$UPSTREAM/tools" "$UPSTREAM/ports/zephyr"
  printf 'ZEPHYR_DOCKER_VERSION=v0.29.2\nZEPHYR_VERSION=v4.4.0\n' >"$UPSTREAM/tools/ci.sh"
  : >"$UPSTREAM/ports/zephyr/CMakeLists.txt"
  git -C "$UPSTREAM" init -q
  git -C "$UPSTREAM" add -A
  git -C "$UPSTREAM" -c user.name=t -c user.email=t@t commit -q -m upstream
  git -C "$UPSTREAM" tag v1.29.0
  export MICROPYTHON_REPO="file://$UPSTREAM"
  MICROPYTHON_COMMIT="$(git -C "$UPSTREAM" rev-parse HEAD)"
  export MICROPYTHON_COMMIT
}

# zephyr_is MAJOR MINOR PATCH - the workspace's zephyr/VERSION.
zephyr_is() {
  printf 'VERSION_MAJOR = %s\nVERSION_MINOR = %s\nPATCHLEVEL = %s\nVERSION_TWEAK = 0\n' \
    "$1" "$2" "$3" >"$ZEPHYR_WORKSPACE/zephyr/VERSION"
}

@test "an unknown argument is refused with the usage, before anything is fetched" {
  run "$SCRIPT" --frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown argument: --frobnicate"* ]]
  [[ "$output" == *"build.sh --clean"* ]]
  [ ! -e "$MPY_HOME/src" ]
}

@test "--help prints the usage and does nothing else" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"fetch the pinned tag, build, sign, check"* ]]
  [ ! -e "$MPY_HOME" ]
}

@test "the pinned tag is fetched and the port is built with this project's overlay and Kconfig" {
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$(git -C "$MPY_HOME/src" rev-parse HEAD)" = "$MICROPYTHON_COMMIT" ]
  [[ "$output" == *"made for Zephyr 4.4.0; building with 4.4.2"* ]]
  ran "west build -b arduino_uno_q -d $MPY_HOME/build $MPY_HOME/src/ports/zephyr -- -DEXTRA_CONF_FILE=$PROJECT/mcu/micropython/mcuboot.conf -DDTC_OVERLAY_FILE=$PROJECT/mcu/micropython/arduino_uno_q.overlay"
  # And the stub built nothing, which is not reported as an image.
  [[ "$output" == *"no signed image"* ]]
  [ ! -e "$MPY_HOME/zephyr.signed.bin" ]
}

@test "-p builds pristine" {
  run "$SCRIPT" -p
  ran "west build -b arduino_uno_q -d $MPY_HOME/build $MPY_HOME/src/ports/zephyr -p always -- -DEXTRA_CONF_FILE=$PROJECT/mcu/micropython/mcuboot.conf -DDTC_OVERLAY_FILE=$PROJECT/mcu/micropython/arduino_uno_q.overlay"
}

@test "a tag that is not the pinned commit stops the build" {
  export MICROPYTHON_COMMIT=0000000000000000000000000000000000000000
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"pins it at 0000000000000000000000000000000000000000"* ]]
  never_ran west
}

@test "a MicroPython made for another Zephyr minor release is refused" {
  zephyr_is 4 5 0
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"built against Zephyr"* ]]
  [[ "$output" == *"4.4.0"* && "$output" == *"4.5.0"* ]]
  never_ran west
}

@test "MPY_ZEPHYR_MISMATCH_OK=1 builds against another Zephyr anyway, and says so" {
  zephyr_is 4 5 0
  MPY_ZEPHYR_MISMATCH_OK=1 run "$SCRIPT"
  [[ "$output" == *"warning: MicroPython v1.29.0 is built against Zephyr 4.4.0; this is 4.5.0"* ]]
  ran_like "^west build -b arduino_uno_q "
}

@test "a build directory from other inputs is rebuilt from clean" {
  mkdir -p "$MPY_HOME/build"
  echo "some other inputs" >"$MPY_HOME/build/micropython-built-from"
  run "$SCRIPT"
  [[ "$output" == *"rebuilding from clean"* ]]
  ran_like "^west build -b arduino_uno_q -d $MPY_HOME/build $MPY_HOME/src/ports/zephyr -p always -- "
}

@test "the workspace's compile_commands.json still points at this project's firmware afterwards" {
  ln -s "$ZEPHYR_WORKSPACE/build/compile_commands.json" "$ZEPHYR_WORKSPACE/compile_commands.json"
  # zbuild repoints the link when the build leaves a compile_commands.json.
  cat >"$ZEPHYR_WORKSPACE/.venv/bin/west" <<'SH'
#!/bin/bash
{ printf 'west'; printf ' %s' "$@"; printf '\n'; } >>"$STUB_LOG"
mkdir -p "$MPY_HOME/build" && : >"$MPY_HOME/build/compile_commands.json"
SH
  run "$SCRIPT"
  ran_like "^west build "
  [ "$(readlink "$ZEPHYR_WORKSPACE/compile_commands.json")" = "$ZEPHYR_WORKSPACE/build/compile_commands.json" ]
}

@test "with no MPY_HOME it goes beside the workspace's real path, not into HOME" {
  unset MPY_HOME
  big="$BATS_TEST_TMPDIR/big"
  mkdir -p "$big"
  mv "$ZEPHYR_WORKSPACE" "$big/zephyrproject"
  ln -s "$big/zephyrproject" "$ZEPHYR_WORKSPACE"
  run "$SCRIPT"
  [ -d "$big/micropython/src/.git" ]
  [ ! -e "$HOME/micropython" ]
}
