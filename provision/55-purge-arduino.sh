#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Remove the remaining Arduino Debian packages.
#
#   sudo bash ~/two-computers-one-board/provision/55-purge-arduino.sh
#
# Their services are already disabled by 15-dev-tools.sh, so this only reclaims
# disk - it does not change behavior. Run it when you are confident you will
# not go back. Idempotent: a second run finds nothing to remove.
#
# SAFETY: /opt/openocd is owned by NO package (`dpkg -S /opt/openocd` finds
# nothing), so apt cannot remove it. It is the only way to flash the MCU.
# Verified below before and after; the script aborts rather than proceed
# without it.
#
# TO GO BACK: apt-get install -y arduino-app-cli arduino-app-lab \
#                                arduino-router arduino-cli
#             ~/two-computers-one-board/mcu/restore-arduino-firmware.sh
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
need_root

OCD="${OCD_ROOT:-/opt/openocd}"

step "openocd before"
if [ -x "$OCD/bin/openocd" ]; then
  skip "$OCD/bin/openocd present"
else
  fail "$OCD/bin/openocd is already missing - refusing to purge.
  Restore it first:  sudo cp -a ~/uno-q-backup/openocd $OCD
  or rebuild it:     sudo bash $PROJECT/tools/build-openocd.sh --promote"
fi

# The stock MCU firmware is Arduino's build and is not ours to redistribute, so it
# cannot be recovered from this repo or from apt.
#
# This comment used to say ~/.arduino15 is gone after the purge, and that is
# simply not true - apt removes packages, not files in $HOME. Measured after a
# real run of this script: ~/.arduino15 is still there, 621 MB of it, stock
# .hex included. Overstating the danger is its own kind of wrong, because the
# next person to read it learns to discount what this file says.
#
# What actually eats the image is a FACTORY RESTORE, which is also what puts it
# back. So the honest position is: the copy is cheap, take it early
# (bootstrap.sh does, in preflight), and refuse here if there is none - not
# because this script deletes it, but because this script is the point after
# which nobody thinks to look for it again.
#
# The image is FOUND, not guessed at. This used to glob
# .../hardware/zephyr/*/variants/*/*.hex, which matches nothing on core 0.55.2 -
# the .hex is in firmwares/, and variants/ holds the board's sources. So the
# backup silently found nothing, warned, and carried on into the purge, which
# is the failure this step exists to prevent, dressed up as having run.
#
# A find over the core covers both layouts and any later rearrangement, which
# matters because the layout is Arduino's to change and this script only gets
# one attempt at it, on someone else's board, with no way back.
step "stock firmware backup"
BACKUP_DIR="${UNOQ_BACKUP:-$TARGET_HOME/uno-q-backup}"
# Finding it is lib.sh's job, shared with bootstrap.sh's preflight - the layout
# moved between core versions and is not a detail worth having two copies of.
# Refusing is this script's job, because this is the one that deletes the tree.
if backup_stock_firmware; then
  :
elif [ "${UNOQ_ALLOW_NO_STOCK_FW:-0}" = "1" ]; then
  warn "no stock .hex found, and UNOQ_ALLOW_NO_STOCK_FW=1 - purging anyway."
  warn "restore-arduino-firmware.sh will have nothing to flash, permanently."
else
  # Refuses rather than warns. Everything else here has a revert line in the
  # comment above it; this is the one step whose damage is not undoable, so
  # "continuing" was never the right default - a warning scrolls past in a
  # bootstrap run and is read, if at all, after the fact.
  fail "no stock MCU firmware found under $TARGET_HOME/.arduino15 and none in
        $BACKUP_DIR. It is Arduino's build - not in this repo, not in apt -
        and after this script nobody looks for it again until they need it.

        Find and copy it first:
          find ~/.arduino15 -name '*stm32u585xx*.hex'
          mkdir -p $BACKUP_DIR && cp <that file> $BACKUP_DIR/

        Or accept losing it: sudo UNOQ_ALLOW_NO_STOCK_FW=1 bash $0"
fi

step "remove Arduino packages"
apt_remove arduino-app-cli arduino-app-lab arduino-router arduino-cli

step "autoremove"
if DEBIAN_FRONTEND=noninteractive apt-get -s autoremove 2>/dev/null | grep -q '^Remv'; then
  DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >/dev/null
  did "autoremoved orphaned dependencies"
else
  skip "nothing to autoremove"
fi

step "openocd after (must still work)"
if "$OCD/bin/openocd" --version >/dev/null 2>&1; then
  skip "flashing capability intact: $("$OCD/bin/openocd" --version 2>&1 | head -1 | cut -d' ' -f1-4)"
else
  fail "openocd is GONE - restore it now:
  sudo cp -a $BACKUP_DIR/openocd $OCD
  or rebuild: sudo bash $PROJECT/tools/build-openocd.sh --promote"
fi

summary
