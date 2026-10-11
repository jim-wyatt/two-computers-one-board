#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Flash the UNO Q's STM32U585 over SWD, bit-banged on the MPU's own GPIO lines.
#
#   ./flash.sh                                  # what zbuild.sh last built here
#   ./flash.sh build/zephyr/zephyr.hex          # any other west build
#   ./flash.sh firmware.bin 0x08000000          # a raw binary, at an address
#
# No root, no Arduino tooling needed.
#
# /opt/openocd is owned by NO Debian package - it was dropped in by an install
# script. `apt install openocd` will not substitute for it: Debian ships 0.12.0
# (2023), which predates the libgpiod v2 support this board needs. Rebuild from
# upstream OpenOCD master with ~/two-computers-one-board/tools/build-openocd.sh.
#
# SWD wiring, per /opt/openocd/openocd_gpiod.cfg - all on /dev/gpiochip1:
#   swclk = 26   swdio = 25   srst/trst = 38
# Your user needs to be in the `gpiod` group; provision/10-optimize-board.sh
# adds it.
set -euo pipefail

# Override to test a rebuilt OpenOCD without replacing the system one:
#   OCD_ROOT=/opt/openocd-rebuilt ./flash.sh ...
OCD_ROOT="${OCD_ROOT:-/opt/openocd}"
OPENOCD="$OCD_ROOT/bin/openocd"
CFG="$OCD_ROOT/openocd_gpiod.cfg"

# No image named means this project's own firmware, where zbuild.sh leaves it.
# The signed one, always: an unsigned image flashes and verifies, and MCUboot
# then refuses to start it, which looks exactly like a dead board.
WS="${ZEPHYR_WORKSPACE:-$HOME/zephyrproject}"
DEFAULT_IMG="$WS/build/zephyr/zephyr.signed.hex"
IMG="${1:-$DEFAULT_IMG}"
ADDR="${2:-}"

[ -f "$IMG" ] || {
  if [ $# -eq 0 ]; then
    echo "nothing built yet: $IMG is missing - run zbuild first" >&2
  else
    echo "no such image: $IMG" >&2
  fi
  exit 1
}
[ -x "$OPENOCD" ] || {
  echo "openocd missing at $OPENOCD" >&2
  exit 1
}

# BOOT0 (gpiochip1 line 37) is latched at MCU reset. If it is high or floating
# the STM32 boots its ROM bootloader instead of the image we just wrote - the
# flash succeeds and verifies, but nothing runs. Line 70 enables the UART link
# to Linux. Both were previously held by arduino-router. See link-up.sh.
"$(dirname "$0")/link-up.sh" || echo "warning: could not set BOOT0/link GPIOs" >&2

# .hex/.elf carry their own load addresses; raw .bin needs one supplied.
case "$IMG" in
  *.bin)
    ADDR="${ADDR:-0x08000000}"
    PROGRAM="program \"$IMG\" verify reset exit $ADDR"
    ;;
  *)
    PROGRAM="program \"$IMG\" verify reset exit"
    ;;
esac

echo "flashing $IMG ${ADDR:+@ $ADDR}"
"$OPENOCD" -s "$OCD_ROOT" -s "$OCD_ROOT/share/openocd/scripts" \
  -f "$CFG" -c "$PROGRAM"
echo "done."

# The demo retries while the chip is being written, and it has a limit. One
# flash is nowhere near it; several in a few minutes can be. If that has
# happened, say so here, where the person who caused it is looking.
if systemctl is-failed --quiet unoq-cpu-bars.service 2>/dev/null; then
  echo
  echo "The CPU-bars demo gave up retrying while the chip was being written."
  echo "Start it again:"
  echo "  sudo systemctl reset-failed unoq-cpu-bars && sudo systemctl start unoq-cpu-bars"
  echo "To avoid it: sudo systemctl stop unoq-cpu-bars before flashing, start it after."
fi
