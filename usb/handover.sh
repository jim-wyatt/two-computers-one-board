#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Take the USB port from adbd and give it to this project's gadget.
#
#   sudo ~/two-computers-one-board/usb/handover.sh
#
# Run by provision/60-usb-gadget.sh as its last act, and not meant to be run
# before that step has installed the units it starts.
#
# WHY THIS IS A SEPARATE SCRIPT
# -----------------------------
# A stock board is reached with `adb shell`, over the USB cable, and adb's
# daemon owns the USB port. This project's gadget needs the same port, so adbd
# has to go - and `adb shell` is adbd's child. systemd stops a unit by killing
# its whole cgroup, which means a script run from `adb shell` that stops adbd
# has stopped itself.
#
# That is what happened the first time this was run on a factory-fresh board:
# the provisioning step stopped adbd half way down, died with it, and left a
# board with no adb, no gadget and no SSH. Powered, on wifi, and shut.
#
# So the part that cannot be done from inside adbd is this file, small enough
# to be handed to systemd-run and executed from outside. Run from an SSH
# session it is simply called; the order is the same either way.
#
# THE ORDER, AND WHY
# ------------------
#   1. sshd is running, or stop.   adb is the door being closed. Nothing is
#                                  closed until another one is open.
#   2. adbd stopped and disabled.  Checked, not assumed.
#   3. gadget definition rebuilt.  unoq-usb-gadget, which never binds.
#   4. bind, if a controller is    The udev rule binds when a controller
#      already there.              APPEARS. With the cable already in, it
#                                  appeared long ago and no event is coming.
#
# Idempotent: on a board where adbd is already gone it rebuilds and binds.
set -uo pipefail

G="${UNOQ_GADGET_DIR:-/sys/kernel/config/usb_gadget/unoq}"
CONFIGFS="$(dirname "$G")"
UDC_DIR="${UNOQ_UDC_DIR:-/sys/class/udc}"

log() {
  echo "unoq-usb-handover: $*"
  # Best effort: a journal that is not taking messages is not a reason for a
  # hand-over that worked to report that it did not.
  logger -t unoq-usb-handover "$*" 2>/dev/null || true
}

[ "$(id -u)" = 0 ] || {
  echo "must run as root" >&2
  exit 1
}

# --- 1. another way in -----------------------------------------------------

if ! systemctl is-active --quiet ssh.service; then
  log "REFUSED: sshd is not running, and adb is about to be the door that closes."
  log "  start it:  sudo systemctl enable --now ssh   - then run this again"
  exit 1
fi

# --- 2. adbd ---------------------------------------------------------------

if systemctl cat adbd.service >/dev/null 2>&1; then
  if systemctl is-active --quiet adbd.service ||
    systemctl is-enabled --quiet adbd.service 2>/dev/null; then
    systemctl disable --now adbd.service >/dev/null 2>&1
    if systemctl is-active --quiet adbd.service; then
      log "adbd is still running after being stopped - leaving the port with it"
      exit 1
    fi
    if systemctl is-enabled --quiet adbd.service 2>/dev/null; then
      # Stopped, and back at the next boot to race this gadget for the port.
      log "adbd stopped but is still enabled - not building a gadget it would fight at boot"
      exit 1
    fi
    # adbd exits with an error when it is stopped, and systemd then lists it as
    # failed. It did not fail, it was asked to go - and LED 2 blinks red for
    # any failed unit, which made the last thing a successful setup did the
    # reason the board ended it showing a fault.
    systemctl reset-failed adbd.service >/dev/null 2>&1 || true
    log "adbd stopped and disabled"
  else
    # A board handed over before the reset above existed still has the mark.
    systemctl reset-failed adbd.service >/dev/null 2>&1 || true
    log "adbd already stopped and disabled"
  fi
fi

# adbd unbinds its gadget when it stops. If a definition that is not ours is
# still holding a controller, ours cannot have it, and saying which one is
# worth more than a bind that fails without a reason.
#
# Read, not tested with `-s`: every file in configfs reports a size of 4096
# whatever is in it, so `-s` is true of an empty UDC file. On the first real
# hand-over this announced that adbd's gadget still held the controller, about
# a gadget that had already let go, twenty seconds before ours bound to it.
for udc in "$CONFIGFS"/*/UDC; do
  [ -e "$udc" ] || continue
  [ "$udc" = "$G/UDC" ] && continue
  holds="$(cat "$udc" 2>/dev/null)"
  [ -n "$holds" ] || continue
  log "another gadget still holds $holds: $(dirname "$udc")"
done

# --- 3. the definition -----------------------------------------------------

if ! systemctl restart unoq-usb-gadget.service; then
  log "unoq-usb-gadget failed - check: journalctl -u unoq-usb-gadget -n 40"
  log "  the board is reachable over SSH; adb comes back with: sudo systemctl enable --now adbd"
  exit 1
fi
log "gadget definition built"

# --- 4. bind, if there is something to bind to -------------------------------

have_udc=0
for u in "$UDC_DIR"/*; do
  [ -e "$u" ] && have_udc=1
done
if [ "$have_udc" = 0 ]; then
  log "no USB controller: not plugged into a computer, so nothing to bind yet"
  exit 0
fi
if ! systemctl start unoq-usb-bind.service; then
  log "bind failed - check: journalctl -u unoq-usb-bind -n 40"
  log "  the board is reachable over SSH; adb comes back with: sudo systemctl enable --now adbd"
  exit 1
fi
log "bound: the board is now a network adapter and a drive on this cable"
