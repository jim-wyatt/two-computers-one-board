#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# The two board LEDs Linux can drive: connectivity, and whether anything failed.
#
#   sudo bash ~/two-computers-one-board/provision/50-status-leds.sh
#
# Idempotent, and cheap: it installs one unit and starts it. Nothing here
# touches the network, the USB port or the MCU.
#
# WHY THIS IS NOT PART OF THE USB GADGET
# --------------------------------------
# It used to be. `leds.sh` lived in usb/ because the first thing it reported was
# the USB link, so 95-usb-gadget.sh installed it - which meant the LEDs only
# existed if you passed `--with-usb-gadget`.
#
# That is backwards. These LEDs are the board's ONLY output when the network is
# down, the gadget is unbound and nobody can log in. Making them conditional on
# an optional feature is making the fallback conditional on the thing it is a
# fallback for. A board provisioned without the gadget had no way to say
# anything at all.
#
# So they are installed unconditionally, from here, and `bootstrap.sh` runs this
# with the rest of the base setup rather than with the extras.
#
# REVERT: systemctl disable --now unoq-leds.service &&
#         rm /etc/systemd/system/unoq-leds.service && systemctl daemon-reload
#         then, once no other unoq-* unit that runs as root is left installed
#         (unoq-link, the unoq-usb-* units, unoq-uplink-fallback):
#         rm -r /usr/local/lib/unoq
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
need_root

step "the LEDs this board has"
# Six writable channels, which are two RGB packages rather than six lights - a
# distinction that cost an afternoon the first time. See docs/reference/hardware.md.
found=0
for ch in unoq:user-red1 unoq:user-green1 unoq:user-blue1 \
  unoq:panic-red2 unoq:wlan-green2 unoq:bt-blue2; do
  [ -w "/sys/class/leds/$ch/brightness" ] && found=$((found + 1))
done
if [ "$found" = 6 ]; then
  skip "all six channels present and writable"
elif [ "$found" -gt 0 ]; then
  warn "only $found of 6 LED channels found - the service will drive what it can"
else
  warn "no unoq:* LEDs under /sys/class/leds - is this an UNO Q?"
  warn "  the service is still installed; it degrades to doing nothing"
fi

step "the scripts root runs"
# The service runs as root, so it runs root's own copy of status/leds.sh and
# not the one in this checkout - see "what root runs" in lib.sh. Copied before
# the unit is installed, because install_unit checks that what the unit names
# is there. This is also the cheapest step to run when all you want is for an
# edited script to reach the board: it refreshes every copy, not only the LEDs'.
scripts_changed=0
install_root_scripts && scripts_changed=1

step "systemd unit"
# Capture the unit as it is now, so a CHANGED unit can be restarted. Without
# this, a run that rewrites ExecStart reports "already enabled and running" and
# leaves the old process in place - which is exactly what happened when the
# script moved out of usb/: correct file on disk, stale process still running
# from a path that no longer exists.
#
# The same goes for a changed SCRIPT, now that the unit runs a copy: the unit
# file is byte for byte what it was, and the process is still the old leds.sh,
# which bash read from a file that has since been replaced underneath it.
before="$(cat /etc/systemd/system/unoq-leds.service 2>/dev/null)"
install_unit "$PROJECT/status/unoq-leds.service"
after="$(cat /etc/systemd/system/unoq-leds.service 2>/dev/null)"

if [ "$before" != "$after" ] && systemctl is-active --quiet unoq-leds.service; then
  systemctl restart unoq-leds.service >/dev/null 2>&1 ||
    warn "could not restart unoq-leds.service - check: journalctl -u unoq-leds"
  did "unit changed, service restarted"
elif [ "$scripts_changed" = 1 ] && systemctl is-active --quiet unoq-leds.service; then
  systemctl restart unoq-leds.service >/dev/null 2>&1 ||
    warn "could not restart unoq-leds.service - check: journalctl -u unoq-leds"
  did "scripts changed, service restarted"
elif systemctl is-enabled --quiet unoq-leds.service 2>/dev/null &&
  systemctl is-active --quiet unoq-leds.service; then
  skip "already enabled and running"
else
  # Started as well as enabled: there is nothing to wait for, and a board that
  # has just been provisioned should light up now rather than at the next boot.
  systemctl enable --now unoq-leds.service >/dev/null 2>&1 ||
    warn "could not start unoq-leds.service - check: journalctl -u unoq-leds"
  did "enabled and started"
fi

summary
cat <<EOF

What the colors mean:  $PROJECT/status/leds.sh explain
Learn them by watching: sudo $RUNTIME_DIR/status/leds.sh test

The service runs the copy in $RUNTIME_DIR, not the one in the checkout.
After editing a script, run this step again for the board to use it.
EOF
