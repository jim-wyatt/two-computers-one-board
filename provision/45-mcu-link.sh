#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# The MCU link GPIOs, applied at every boot. Without this the board looks dead
# after a reboot: BOOT0 floats and the STM32 runs its ROM bootloader instead of
# your firmware.
#
#   sudo bash ~/two-computers-one-board/provision/45-mcu-link.sh
#
# Idempotent.
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
need_root

# --- 1. tio: a far better serial terminal than the minicom that ships here.
# REVERT: apt-get remove -y tio
step "serial terminal"
apt_install tio

# --- 2. Apply the MCU link GPIOs at every boot.
#
# gpiochip1 line 37 = MCU BOOT0 (latched at reset; high/floating -> the STM32
#                    boots its ROM bootloader and your firmware never runs)
# gpiochip1 line 70 = UART link enable (low/floating -> /dev/ttyHS1 is silent)
#
# These were previously held by arduino-router, which 15-dev-tools.sh disables.
#
# The unit runs as root, so it runs root's own copy of mcu/link-up.sh and not
# the one in this checkout - see "what root runs" in lib.sh. The copy is made
# first because install_unit checks that what the unit names is there. A change
# to link-up.sh reaches the board by running this step again, and the service
# applies it at the next boot: the lines are already driven, and re-driving
# them mid-session is not something a provisioning run should do unasked.
# REVERT: systemctl disable --now unoq-link.service &&
#         rm /etc/systemd/system/unoq-link.service && systemctl daemon-reload
#         then, once no other unoq-* unit that runs as root is left installed
#         (unoq-leds, the unoq-usb-* units, unoq-uplink-fallback):
#         rm -r /usr/local/lib/unoq
step "the scripts root runs"
install_root_scripts
step "unoq-link.service"
install_unit "$PROJECT/mcu/unoq-link.service"
enable_unit unoq-link.service

# --- 3. Prove it worked. The GPIO direction is readable without requesting the
# --- line (which would drop the drive and break the very link we just set up).
step "verify"
if [ -x "$PROJECT/.venv/bin/python" ]; then
  state="$(as_user "$PROJECT/.venv/bin/python" -c \
    'from unoq import link_state; print(link_state())' 2>/dev/null)"
  case "$state" in
    *"'boot0': 'OUTPUT'"*"'link_enable': 'OUTPUT'"*) skip "link lines driven: $state" ;;
    "") warn "could not read link state (venv not built yet?)" ;;
    *) warn "link lines look wrong: $state" ;;
  esac
else
  skip "venv not built yet - run provision/user/35-python-venv.sh, then re-check"
fi

summary
echo "Serial console:  tio /dev/ttyHS1 -b 115200"
