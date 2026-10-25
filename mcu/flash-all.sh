#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Flash the complete MCUboot chain over SWD: bootloader + signed application.
#
#   ./flash-all.sh
#
# Use this for a from-scratch recovery, or after changing the bootloader.
# For routine app updates you do NOT need SWD at all - upload over serial:
#
#   python -c "from unoq import fota; fota.upload('.../zephyr.signed.bin'); \
#              fota.test(); fota.reset()"
#   # then fota.confirm() once it boots, or it reverts on the next reset.
#
# Layout (from the board DTS):
#   0x08000000  boot_partition  64K   MCUboot
#   0x08010000  slot0          416K   signed application
#   0x08078000  slot1          416K   staged update
#   0x080e0000  storage        128K   NVS (settings: panel orientation)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WS="${ZEPHYR_WORKSPACE:-$HOME/zephyrproject}"
# In the workspace, beside the application's build - not in /tmp, where this
# used to live. /tmp is writable by everything on the board and its contents
# were trusted: a zephyr.hex already sitting there was flashed to the boot
# partition without being rebuilt or looked at.
MCUBOOT_BUILD="${MCUBOOT_BUILD:-$WS/build-mcuboot}"
APP_HEX="${1:-$WS/build/zephyr/zephyr.signed.hex}"

# Same reasons as zbuild.sh: cmake and ninja are in ~/.local/bin, which only an
# interactive shell has on PATH, and a CI runner keeps west on PATH rather than
# in the workspace venv.
export PATH="$HOME/.local/bin:$PATH"
WEST="$WS/.venv/bin/west"
[ -x "$WEST" ] || WEST="$(command -v west || true)"
SDK="${ZEPHYR_SDK:-$HOME/zephyr-sdk-${ZEPHYR_SDK_VERSION:-1.0.1}}"
[ -d "$SDK" ] && export ZEPHYR_SDK_INSTALL_DIR="$SDK"

# WHEN THE BOOTLOADER IS REBUILT
# ------------------------------
# A bootloader is built from two trees, Zephyr and MCUboot, and one that was
# built against last month's is not the one this workspace would build today.
# "The file exists" used to be the whole test, so a Zephyr upgrade left the old
# bootloader in place to be flashed in front of a new application. The revisions
# it was built from are written beside it, and it is rebuilt when either has
# moved - or when they cannot be read at all, because not knowing is not the
# same as unchanged.
#
# And for a BOARD. The stamp used to name the two revisions only, so a
# bootloader built once with BOARD=something_else was found again by a run with
# the default: both revisions still matched, nothing was rebuilt, and another
# board's bootloader was flashed to this one's boot partition. The board is part
# of what it was built from, so it is part of the stamp. A stamp written before
# this has no board in it, matches nothing, and costs one rebuild.
#
# And for its configuration: mcu/mcuboot.conf (downgrade prevention, see its
# header) is part of what the bootloader is built from, so a change to it
# rebuilds rather than flashing a bootloader built without it.
rev() { git -C "$1" rev-parse HEAD 2>/dev/null || echo unknown; }
BOARD="${BOARD:-arduino_uno_q}"
MCUBOOT_CONF="$HERE/mcuboot.conf"
REVS="zephyr $(rev "$WS/zephyr") mcuboot $(rev "$WS/bootloader/mcuboot")"
CONF_SUM="$(sha256sum "$MCUBOOT_CONF" 2>/dev/null | cut -d' ' -f1)"
BUILT_FROM="board $BOARD $REVS conf ${CONF_SUM:-unknown}"
STAMP="$MCUBOOT_BUILD/built-from"

# "unknown" is looked for in the revisions alone: a board is whatever the
# caller named, and may spell anything.
if [ ! -f "$MCUBOOT_BUILD/zephyr/zephyr.hex" ] ||
  [ "$(cat "$STAMP" 2>/dev/null)" != "$BUILT_FROM" ] ||
  [[ "$REVS" == *unknown* ]] || [ -z "$CONF_SUM" ]; then
  echo "Building MCUboot..."
  [ -n "$WEST" ] || {
    echo "no west: not in $WS/.venv/bin and not on PATH" >&2
    exit 1
  }
  # The cd is load-bearing, and naming the workspace's own west is not enough
  # on its own. `build` is an extension command: west discovers it by walking
  # UP FROM THE CURRENT DIRECTORY looking for a workspace, so run from anywhere
  # outside ~/zephyrproject the same binary reports
  #
  #   west: unknown command "build"; do you need to run this inside a workspace?
  #
  # This script used to inherit whatever directory the caller happened to be in,
  # which works perfectly by hand - you are usually sitting in the workspace -
  # and fails from bootstrap.sh, from a systemd unit, or from the repo checkout.
  # A subshell, so the flash steps below keep the caller's directory.
  (
    cd "$WS" || exit 1
    ZEPHYR_TOOLCHAIN_VARIANT=zephyr \
      "$WEST" build -b "$BOARD" \
      "$WS/bootloader/mcuboot/boot/zephyr" -p always -d "$MCUBOOT_BUILD" \
      -- -DEXTRA_CONF_FILE="$MCUBOOT_CONF"
  )
  echo "$BUILT_FROM" >"$STAMP"
fi

[ -f "$APP_HEX" ] || {
  echo "no signed app image at $APP_HEX" >&2
  echo "build it with: $HERE/zbuild.sh" >&2
  exit 1
}

echo "== 1/2 MCUboot -> boot_partition =="
"$HERE/flash.sh" "$MCUBOOT_BUILD/zephyr/zephyr.hex"

echo "== 2/2 signed application -> slot0 =="
"$HERE/flash.sh" "$APP_HEX"

echo
echo "Chain flashed. Verify:"
echo "  python -c \"from unoq import MCU; print(MCU().status())\""
