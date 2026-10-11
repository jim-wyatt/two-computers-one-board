#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# RECOVERY: put the board back to the stock Arduino Zephyr firmware.
#
#   ./restore-arduino-firmware.sh
#
# Run this if a west-built firmware misbehaves, or if you want the Arduino
# App / Bridge stack working again.
#
# You supply the image. It is Arduino's build rather than this project's, so
# it is not redistributed here (docs/third-party.md) - copy it off your own board
# before purging the Arduino tree, and it will still work once ~/.arduino15 is
# gone.
#
# After restoring, the MCU again exposes the Router Bridge on /dev/ttyHS1,
# and `arduino-app-cli` (if still installed) will behave as it did originally.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# The stock image is Arduino's build, not ours to redistribute, so it is not in
# this repository - see docs/third-party.md. Point STOCK_FW at your own copy.
FW="${STOCK_FW:-$HOME/uno-q-backup/zephyr-arduino_uno_q_stm32u585xx.hex}"

[ -f "$FW" ] || {
  cat >&2 <<EOF
stock firmware not found at: $FW

It is Arduino's image, so this repository does not ship it - but it is not
lost, either. It ships in the arduino-* Debian packages, so every board that
has not been purged still has a copy:

  mkdir -p ~/uno-q-backup
  find ~/.arduino15 -name '*stm32u585xx*.hex' -exec cp {} ~/uno-q-backup/ \;

A find rather than a path, because the layout has moved: on core 0.55.2 the
image is in firmwares/, not the variants/ directory this used to name.

bootstrap.sh takes that copy during preflight, and 55-purge-arduino.sh refuses
to run without one. If you have neither - purged an older checkout, or lost the
backup - a factory restore puts the packages back, and with them the image.
That is the only way back, and it is worth knowing it EXISTS: the copy is
recoverable, the board is not stuck.

then re-run this, or set STOCK_FW=/path/to/image.hex
EOF
  exit 1
}

echo "This will overwrite the MCU with the stock Arduino firmware:"
echo "  $FW"
read -rp "continue? [y/N] " ans
[ "$ans" = "y" ] || {
  echo "aborted."
  exit 0
}

exec "$HERE/flash.sh" "$FW"
