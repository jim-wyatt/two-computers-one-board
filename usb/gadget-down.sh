#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Tear the USB gadget down: unbind, stop DHCP, remove the configfs tree.
#
#   sudo ~/two-computers-one-board/usb/gadget-down.sh            # unbind, keep the definition
#   sudo ~/two-computers-one-board/usb/gadget-down.sh --purge    # and delete it from configfs
#
# Idempotent. This is the revert path for provision/95-usb-gadget.sh, and the
# thing to run before rebuilding the fileshare image - the host must not be
# holding the image open while share/build-image.sh remounts it read-write.
#
# configfs will not let you rmdir a directory that is still referenced, so the
# order below matters: unbind the UDC, unlink functions from configs, remove
# strings, then configs, then functions, then the gadget.
set -uo pipefail

CONFIGFS=/sys/kernel/config/usb_gadget
G="$CONFIGFS/unoq"
HERE="$(cd "$(dirname "$0")" && pwd)"
BRIDGE="${UNOQ_USB_BRIDGE:-br-usb}"
UDHCPC_PID=/run/unoq-usb-udhcpc.pid
DNSMASQ_PID=/run/unoq-usb-dnsmasq.pid
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

log() { echo "unoq-gadget: $*"; }

[ "$(id -u)" = 0 ] || {
  echo "must run as root" >&2
  exit 1
}

# --- unbind ----------------------------------------------------------------

if [ -d "$G" ]; then
  if [ -s "$G/UDC" ]; then
    echo "" >"$G/UDC" 2>/dev/null && log "unbound from the UDC"
  else
    log "already unbound"
  fi
else
  log "no gadget at $G"
fi

# --- addressing ------------------------------------------------------------

# Both of the things that can be holding an address on this bridge, because the
# bridge is about to be deleted underneath them. A udhcpc or avahi-autoipd left
# running against an interface that no longer exists is not harmless: the next
# plug-in creates br-usb again, and the survivor is then a second daemon on it,
# defending or renewing an address the new one knows nothing about.
if [ -f "$UDHCPC_PID" ] && kill -0 "$(cat "$UDHCPC_PID")" 2>/dev/null; then
  kill "$(cat "$UDHCPC_PID")" 2>/dev/null
  rm -f "$UDHCPC_PID"
  # udhcpc does not run its script on SIGTERM, so the leased address and the
  # route it installed would outlive it. Run the teardown by hand, which also
  # hands /etc/resolv.conf back to NetworkManager.
  interface="$BRIDGE" "$HERE/usb-dhcp.sh" deconfig >/dev/null 2>&1
  log "udhcpc stopped"
fi

AUTOIPD="${UNOQ_AUTOIPD:-/usr/sbin/avahi-autoipd}"
if [ -x "$AUTOIPD" ] && "$AUTOIPD" --check "$BRIDGE" 2>/dev/null; then
  "$AUTOIPD" --kill "$BRIDGE" 2>/dev/null && log "link-local released"
fi

# Left over from the old server mode, where the board ran dnsmasq on this
# bridge. Kept only so that a board updated in place does not keep answering
# DHCP on a wire it no longer owns.
if [ -f "$DNSMASQ_PID" ] && kill -0 "$(cat "$DNSMASQ_PID")" 2>/dev/null; then
  kill "$(cat "$DNSMASQ_PID")" && rm -f "$DNSMASQ_PID"
  log "dnsmasq stopped (left over from server mode)"
fi

# --- bridge ----------------------------------------------------------------

if ip link show "$BRIDGE" >/dev/null 2>&1; then
  ip link set "$BRIDGE" down
  ip link delete "$BRIDGE" type bridge
  log "$BRIDGE removed"
fi

# --- configfs --------------------------------------------------------------

if [ "$PURGE" = 1 ] && [ -d "$G" ]; then
  # Links first: a config holding a function symlink cannot be removed, and a
  # function still linked from any config cannot be removed either.
  #
  # Every symlink under os_desc, not a named one. This said `rm -f os_desc/c.1`,
  # which was true only for the gadget the current script builds - and the whole
  # job of a purge is to clear a gadget built by some OLDER version of it. The
  # two-configuration gadget linked os_desc to c.2, so the purge left that
  # symlink in place, could not then rmdir configs/c.2, and quietly failed to
  # remove exactly the definition it was invoked to remove.
  find "$G/os_desc" -maxdepth 1 -type l -exec rm -f {} + 2>/dev/null
  for cfg in "$G"/configs/*; do
    [ -d "$cfg" ] || continue
    find "$cfg" -maxdepth 1 -type l -exec rm -f {} + 2>/dev/null
    rmdir "$cfg"/strings/* 2>/dev/null
    rmdir "$cfg" 2>/dev/null
  done
  for fn in "$G"/functions/*; do
    [ -d "$fn" ] || continue
    rmdir "$fn" 2>/dev/null || log "WARNING: could not remove $(basename "$fn")"
  done
  rmdir "$G"/strings/* 2>/dev/null
  if rmdir "$G" 2>/dev/null; then
    log "gadget definition removed"
  else
    log "WARNING: $G is still referenced - reboot to clear it"
  fi
fi

log "done"
