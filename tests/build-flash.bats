#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# mcu/zbuild.sh and mcu/flash.sh with nothing after them.
#
# The two commands a learner types most used to need a path each, and the
# second path was ~/zephyrproject/build/zephyr/zephyr.signed.hex - forty
# characters with one way to get them right and a nearby way to get them
# wrong: zephyr.hex, the unsigned image, sits in the same directory, flashes,
# verifies, and never boots.
#
# So the defaults are the project's own app and its own signed image, and
# these tests pin both, along with the promise that naming something else
# still does what it always did.

setup() {
  load helpers/stub
  stub_setup

  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  export HOME="$BATS_TEST_TMPDIR/home"
  export ZEPHYR_WORKSPACE="$HOME/zephyrproject"
  mkdir -p "$ZEPHYR_WORKSPACE/.venv/bin" "$ZEPHYR_WORKSPACE/zephyr/samples/hello_world"

  # zbuild.sh calls the workspace's own west by path, so the fake goes there
  # rather than on PATH. Same log, same format as the stubs.
  cat >"$ZEPHYR_WORKSPACE/.venv/bin/west" <<'SH'
#!/bin/bash
{ printf 'west'; printf ' %s' "$@"; printf '\n'; } >>"$STUB_LOG"
SH
  chmod +x "$ZEPHYR_WORKSPACE/.venv/bin/west"

  # flash.sh finds OpenOCD by OCD_ROOT, and raises BOOT0 through link-up.sh.
  export OCD_ROOT="$BATS_TEST_TMPDIR/openocd"
  mkdir -p "$OCD_ROOT/bin"
  cat >"$OCD_ROOT/bin/openocd" <<'SH'
#!/bin/bash
{ printf 'openocd'; printf ' %s' "$@"; printf '\n'; } >>"$STUB_LOG"
SH
  chmod +x "$OCD_ROOT/bin/openocd"
  stub gpioset
}

built() {
  mkdir -p "$ZEPHYR_WORKSPACE/build/zephyr"
  : >"$ZEPHYR_WORKSPACE/build/zephyr/zephyr.signed.hex"
  : >"$ZEPHYR_WORKSPACE/build/zephyr/zephyr.hex"
}

# --- zbuild ----------------------------------------------------------------

@test "zbuild with no arguments builds this project's firmware" {
  run "$PROJECT/mcu/zbuild.sh"
  [ "$status" -eq 0 ]
  ran "west build -b arduino_uno_q -d $ZEPHYR_WORKSPACE/build $PROJECT/mcu/app"
}

@test "zbuild with only west options applies them to this project's firmware" {
  run "$PROJECT/mcu/zbuild.sh" -p always
  [ "$status" -eq 0 ]
  ran "west build -b arduino_uno_q -d $ZEPHYR_WORKSPACE/build $PROJECT/mcu/app -p always"
}

@test "zbuild with an explicit app still builds that app, in its own directory" {
  run "$PROJECT/mcu/zbuild.sh" samples/hello_world -p always
  [ "$status" -eq 0 ]
  ran "west build -b arduino_uno_q -d $ZEPHYR_WORKSPACE/build-hello_world $ZEPHYR_WORKSPACE/zephyr/samples/hello_world -p always"
}

@test "zbuild still refuses an app that does not exist" {
  run "$PROJECT/mcu/zbuild.sh" no/such/app
  [ "$status" -eq 1 ]
  [[ "$output" == *"no such app"* ]]
  never_ran west
}

@test "zbuild puts ~/.local/bin on PATH, where cmake and ninja were installed" {
  # west runs cmake by name. From bootstrap.sh's first run, a VS Code task or a
  # unit, nothing else has put that directory on PATH.
  cat >"$ZEPHYR_WORKSPACE/.venv/bin/west" <<'SH'
#!/bin/bash
echo "PATH=$PATH" >>"$STUB_LOG"
SH
  run env PATH="$STUB_DIR:/usr/bin:/bin" "$PROJECT/mcu/zbuild.sh"
  [ "$status" -eq 0 ]
  ran_like "^PATH=$HOME/\.local/bin:"
}

# --- a build directory from before the checkout moved ------------------------
#
# The board this project is developed on spent two months unable to build its
# own firmware, and nobody knew: bootstrap.sh reports a failed build as a
# warning and skips the flash.

configured_for() {
  mkdir -p "$ZEPHYR_WORKSPACE/build"
  echo "APPLICATION_SOURCE_DIR:PATH=$1" >"$ZEPHYR_WORKSPACE/build/CMakeCache.txt"
}

@test "a build directory configured from another path is rebuilt from clean" {
  configured_for /home/arduino/unoq-cpu-bars/mcu/app
  run "$PROJECT/mcu/zbuild.sh"
  [ "$status" -eq 0 ]
  ran "west build -b arduino_uno_q -d $ZEPHYR_WORKSPACE/build -p always $PROJECT/mcu/app"
  [[ "$output" == *"/home/arduino/unoq-cpu-bars/mcu/app"* ]]
  [[ "$output" == *"rebuilding from clean"* ]]
}

@test "a build directory configured from this checkout is reused, not rebuilt" {
  configured_for "$PROJECT/mcu/app"
  run "$PROJECT/mcu/zbuild.sh"
  [ "$status" -eq 0 ]
  ran "west build -b arduino_uno_q -d $ZEPHYR_WORKSPACE/build $PROJECT/mcu/app"
}

@test "an explicit pristine choice is passed through once, not doubled" {
  configured_for /somewhere/else/mcu/app
  run "$PROJECT/mcu/zbuild.sh" -p always
  [ "$status" -eq 0 ]
  ran "west build -b arduino_uno_q -d $ZEPHYR_WORKSPACE/build $PROJECT/mcu/app -p always"
}

@test "a build directory with no cache is left for west to judge" {
  mkdir -p "$ZEPHYR_WORKSPACE/build"
  run "$PROJECT/mcu/zbuild.sh"
  [ "$status" -eq 0 ]
  ran "west build -b arduino_uno_q -d $ZEPHYR_WORKSPACE/build $PROJECT/mcu/app"
}

@test "a cache that cannot be read is left for west to judge too" {
  # -f is true of a file nobody may read. sed then fails, and under set -e the
  # script used to stop at the assignment, before west was ever asked.
  [ "$(id -u)" -ne 0 ] || skip "root can read anything, so there is no such cache"
  configured_for /somewhere/else/mcu/app
  chmod 000 "$ZEPHYR_WORKSPACE/build/CMakeCache.txt"
  run "$PROJECT/mcu/zbuild.sh"
  chmod 600 "$ZEPHYR_WORKSPACE/build/CMakeCache.txt"
  [ "$status" -eq 0 ]
  ran "west build -b arduino_uno_q -d $ZEPHYR_WORKSPACE/build $PROJECT/mcu/app"
}

# --- zbuild on a CI runner --------------------------------------------------
#
# A runner has west and imgtool on PATH and no venv inside the workspace, and
# its SDK is wherever the setup action put it. CI used to carry its own copy of
# the build because this script assumed the board's layout; these are what let
# it run the real one.

on_a_runner() {
  rm -rf "$ZEPHYR_WORKSPACE/.venv"
  stub west
  stub imgtool
  # mcu/sign-params.py reads two numbers out of the build's devicetree. Here
  # there is no devicetree, so python3 is a fake that answers as the real
  # script does for this board.
  stub python3 0 "--align 16 --slot-size 425984"
  # What `west build` would have left, so the signing branch is taken.
  mkdir -p "$ZEPHYR_WORKSPACE/build/zephyr"
  printf '%s\n' "CONFIG_BOOTLOADER_MCUBOOT=y" "CONFIG_ROM_START_OFFSET=0x400" \
    >"$ZEPHYR_WORKSPACE/build/zephyr/.config"
}

@test "with no workspace venv, west and imgtool come from PATH" {
  on_a_runner
  IMAGE_VERSION=0.0.0+7 run "$PROJECT/mcu/zbuild.sh"
  [ "$status" -eq 0 ]
  ran "west build -b arduino_uno_q -d $ZEPHYR_WORKSPACE/build $PROJECT/mcu/app"
}

# --- signing -----------------------------------------------------------------
#
# zbuild signs with imgtool itself. `west sign -t imgtool` did it before and is
# deprecated; the replacement Zephyr offers rebuilds every object whenever the
# version changes, and this project changes the version on every build.
#
# What these cannot show is that the image is the RIGHT one. That was checked
# once, by hand: one build signed both ways, and imgtool reporting the same
# digest, header and sizes for each, differing only in the signature bytes,
# which are random by design.

@test "the image is signed by imgtool directly, in both formats, with the build's own numbers" {
  on_a_runner
  B="$ZEPHYR_WORKSPACE/build/zephyr"
  K="$ZEPHYR_WORKSPACE/bootloader/mcuboot/root-rsa-2048.pem"
  IMAGE_VERSION=0.0.0+7 run "$PROJECT/mcu/zbuild.sh"
  [ "$status" -eq 0 ]
  ran "imgtool sign --version 0.0.0+7 --header-size 0x400 --align 16 --slot-size 425984 --key $K $B/zephyr.bin $B/zephyr.signed.bin"
  ran "imgtool sign --version 0.0.0+7 --header-size 0x400 --align 16 --slot-size 425984 --key $K $B/zephyr.hex $B/zephyr.signed.hex"
  ran "python3 $PROJECT/mcu/sign-params.py $ZEPHYR_WORKSPACE/build $ZEPHYR_WORKSPACE/zephyr"
}

@test "the deprecated west sign is not used" {
  on_a_runner
  run "$PROJECT/mcu/zbuild.sh"
  [ "$status" -eq 0 ]
  refute ran_like '^west sign'
}

@test "what was signed is verified against the key before the build says it is done" {
  on_a_runner
  run "$PROJECT/mcu/zbuild.sh"
  [ "$status" -eq 0 ]
  ran "imgtool verify -k $ZEPHYR_WORKSPACE/bootloader/mcuboot/root-rsa-2048.pem $ZEPHYR_WORKSPACE/build/zephyr/zephyr.signed.bin"
}

@test "an image that does not verify fails the build" {
  on_a_runner
  stub_body imgtool <<'SH'
[ "$1" = verify ] && exit 1
exit 0
SH
  run "$PROJECT/mcu/zbuild.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not verify"* ]]
}

@test "an image that does not verify is not left where flash.sh would find it" {
  on_a_runner
  # An imgtool that writes its output, as the real one does, and then fails
  # to verify it.
  stub_body imgtool <<'SH'
[ "$1" = verify ] && exit 1
[ "$1" = sign ] && : >"${@: -1}"
exit 0
SH
  run "$PROJECT/mcu/zbuild.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$ZEPHYR_WORKSPACE/build/zephyr/zephyr.signed.hex" ]
  [ ! -e "$ZEPHYR_WORKSPACE/build/zephyr/zephyr.signed.bin" ]
}

@test "a signing that fails does not leave the last build's signed image behind" {
  # Otherwise flash.sh, which takes zephyr.signed.hex by default, would flash
  # the PREVIOUS firmware and report success.
  on_a_runner
  : >"$ZEPHYR_WORKSPACE/build/zephyr/zephyr.signed.hex"
  : >"$ZEPHYR_WORKSPACE/build/zephyr/zephyr.signed.bin"
  stub_body imgtool <<'SH'
[ "$1" = sign ] && exit 1
exit 0
SH
  run "$PROJECT/mcu/zbuild.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$ZEPHYR_WORKSPACE/build/zephyr/zephyr.signed.hex" ]
  [ ! -e "$ZEPHYR_WORKSPACE/build/zephyr/zephyr.signed.bin" ]
}

@test "a signing that writes its output and then fails leaves nothing to flash" {
  # imgtool opens its output before it has finished deciding whether it can
  # sign. The .bin succeeds here and the .hex is written, then refused.
  on_a_runner
  stub_body imgtool <<'SH'
[ "$1" = sign ] || exit 0
: >"${@: -1}"
case "${@: -1}" in *.hex) exit 1 ;; esac
exit 0
SH
  run "$PROJECT/mcu/zbuild.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$ZEPHYR_WORKSPACE/build/zephyr/zephyr.signed.hex" ]
  [ ! -e "$ZEPHYR_WORKSPACE/build/zephyr/zephyr.signed.bin" ]
}

@test "a devicetree that gives no numbers stops the build before imgtool is asked to guess" {
  on_a_runner
  stub python3 1
  run "$PROJECT/mcu/zbuild.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not work out how to sign"* ]]
  refute ran_like '^imgtool sign'
}

@test "a build with no header size in its config is not signed with a guessed one" {
  on_a_runner
  echo "CONFIG_BOOTLOADER_MCUBOOT=y" >"$ZEPHYR_WORKSPACE/build/zephyr/.config"
  run "$PROJECT/mcu/zbuild.sh"
  [ "$status" -ne 0 ]
  refute ran_like '^imgtool sign'
}

@test "an SDK directory that does not exist is not exported" {
  on_a_runner
  stub_body west <<'SH'
echo "SDK=${ZEPHYR_SDK_INSTALL_DIR:-unset}" >>"$STUB_LOG"
SH
  run "$PROJECT/mcu/zbuild.sh"
  [ "$status" -eq 0 ]
  ran "SDK=unset"
}

@test "an SDK directory that does exist still is" {
  on_a_runner
  mkdir -p "$HOME/zephyr-sdk-1.0.1"
  stub_body west <<'SH'
echo "SDK=${ZEPHYR_SDK_INSTALL_DIR:-unset}" >>"$STUB_LOG"
SH
  run "$PROJECT/mcu/zbuild.sh"
  [ "$status" -eq 0 ]
  ran "SDK=$HOME/zephyr-sdk-1.0.1"
}

@test "a build that needs signing and has no imgtool fails, rather than shipping unsigned" {
  on_a_runner
  rm "$STUB_DIR/imgtool"
  run env PATH="$STUB_DIR:/usr/bin:/bin" "$PROJECT/mcu/zbuild.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot be signed"* ]]
  refute ran_like '^west sign'
}

# --- flash -----------------------------------------------------------------

@test "flash with no arguments flashes the signed image zbuild left" {
  built
  run "$PROJECT/mcu/flash.sh"
  [ "$status" -eq 0 ]
  ran_like "^openocd .*program \"$ZEPHYR_WORKSPACE/build/zephyr/zephyr.signed.hex\" verify reset exit$"
}

@test "flash with no arguments never picks the unsigned image" {
  mkdir -p "$ZEPHYR_WORKSPACE/build/zephyr"
  : >"$ZEPHYR_WORKSPACE/build/zephyr/zephyr.hex"
  run "$PROJECT/mcu/flash.sh"
  [ "$status" -eq 1 ]
  never_ran openocd
}

@test "flash before any build says to build, and touches nothing" {
  run "$PROJECT/mcu/flash.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"run zbuild first"* ]]
  never_ran openocd
  never_ran gpioset
}

@test "flash with an explicit image still flashes that image" {
  : >"$BATS_TEST_TMPDIR/other.hex"
  run "$PROJECT/mcu/flash.sh" "$BATS_TEST_TMPDIR/other.hex"
  [ "$status" -eq 0 ]
  ran_like "^openocd .*program \"$BATS_TEST_TMPDIR/other.hex\" verify reset exit$"
}

@test "a raw binary still gets a load address" {
  : >"$BATS_TEST_TMPDIR/fw.bin"
  run "$PROJECT/mcu/flash.sh" "$BATS_TEST_TMPDIR/fw.bin"
  [ "$status" -eq 0 ]
  ran_like "^openocd .*program \"$BATS_TEST_TMPDIR/fw.bin\" verify reset exit 0x08000000$"
}

@test "BOOT0 is held low before flashing" {
  built
  run "$PROJECT/mcu/flash.sh"
  [ "$status" -eq 0 ]
  ran "gpioset -c /dev/gpiochip1 -t0 37=0"
}

# --- flash-all ---------------------------------------------------------------
#
# The recovery path: bootloader, then application. The bootloader build used to
# live in /tmp and be trusted on sight.

mcuboot_tree() {
  mkdir -p "$ZEPHYR_WORKSPACE/bootloader/mcuboot/boot/zephyr" "$ZEPHYR_WORKSPACE/zephyr"
  local d
  for d in "$ZEPHYR_WORKSPACE/zephyr" "$ZEPHYR_WORKSPACE/bootloader/mcuboot"; do
    git -C "$d" init -q
    git -C "$d" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m one
  done
  # A west whose `build` leaves a bootloader image where -d points.
  cat >"$ZEPHYR_WORKSPACE/.venv/bin/west" <<'SH'
#!/bin/bash
{ printf 'west'; printf ' %s' "$@"; printf '\n'; } >>"$STUB_LOG"
while [ $# -gt 0 ]; do
  [ "$1" = -d ] && mkdir -p "$2/zephyr" && : >"$2/zephyr/zephyr.hex"
  shift
done
SH
  chmod +x "$ZEPHYR_WORKSPACE/.venv/bin/west"
}

@test "flash-all builds the bootloader inside the workspace, not in /tmp" {
  built
  mcuboot_tree
  run "$PROJECT/mcu/flash-all.sh"
  [ "$status" -eq 0 ]
  ran_like "^west build .* -d $ZEPHYR_WORKSPACE/build-mcuboot$"
  refute ran_like '/tmp/bmcuboot'
}

@test "flash-all flashes the bootloader first, then the signed application" {
  built
  mcuboot_tree
  run "$PROJECT/mcu/flash-all.sh"
  [ "$status" -eq 0 ]
  first="$(grep -n "build-mcuboot/zephyr/zephyr.hex" "$STUB_LOG" | grep openocd | cut -d: -f1)"
  second="$(grep -n "build/zephyr/zephyr.signed.hex" "$STUB_LOG" | cut -d: -f1)"
  [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ]
}

@test "a bootloader already built from these revisions is not built again" {
  built
  mcuboot_tree
  run "$PROJECT/mcu/flash-all.sh"
  : >"$STUB_LOG"
  run "$PROJECT/mcu/flash-all.sh"
  [ "$status" -eq 0 ]
  refute ran_like '^west build'
}

@test "a bootloader built before Zephyr moved is rebuilt, not flashed stale" {
  built
  mcuboot_tree
  run "$PROJECT/mcu/flash-all.sh"
  git -C "$ZEPHYR_WORKSPACE/zephyr" -c user.name=t -c user.email=t@example.invalid \
    commit -q --allow-empty -m two
  : >"$STUB_LOG"
  run "$PROJECT/mcu/flash-all.sh"
  [ "$status" -eq 0 ]
  ran_like '^west build'
}

@test "a bootloader built for another board is rebuilt, not flashed to this one" {
  # Same two revisions, different BOARD. The stamp used to name the revisions
  # only, so the second run found "its" bootloader already built.
  built
  mcuboot_tree
  BOARD=some_other_board run "$PROJECT/mcu/flash-all.sh"
  [ "$status" -eq 0 ]
  ran_like '^west build -b some_other_board '
  : >"$STUB_LOG"
  run "$PROJECT/mcu/flash-all.sh"
  [ "$status" -eq 0 ]
  ran_like '^west build -b arduino_uno_q '
}

@test "the default board and the default named out loud are the same build" {
  built
  mcuboot_tree
  run "$PROJECT/mcu/flash-all.sh"
  : >"$STUB_LOG"
  BOARD=arduino_uno_q run "$PROJECT/mcu/flash-all.sh"
  [ "$status" -eq 0 ]
  refute ran_like '^west build'
}

@test "a bootloader image of unknown origin is rebuilt rather than trusted" {
  built
  mcuboot_tree
  mkdir -p "$ZEPHYR_WORKSPACE/build-mcuboot/zephyr"
  echo planted >"$ZEPHYR_WORKSPACE/build-mcuboot/zephyr/zephyr.hex"
  run "$PROJECT/mcu/flash-all.sh"
  [ "$status" -eq 0 ]
  ran_like '^west build'
}

@test "flash-all with no application built flashes nothing at all" {
  mcuboot_tree
  run "$PROJECT/mcu/flash-all.sh"
  [ "$status" -eq 1 ]
  never_ran openocd
}
