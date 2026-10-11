#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Break the boot loop that a bad USB bind can put this board into.
#
#   bind-guard.sh check     # before binding: count the attempt, refuse after N
#   bind-guard.sh confirm   # once the board is demonstrably healthy: reset
#
# WHY THIS EXISTS
# ---------------
# usb.md's model is that plugging in is an occasional event: a UDC appears,
# udev fires, the gadget binds. That is true on a bench. It is not true of a
# board powered over the same USB-C cable that carries the gadget, which is the
# normal way this one is used - there, the cable is NEVER unplugged, so a UDC
# is present within seconds of every boot and the bind runs on every boot.
#
# That turns a survivable one-off failure into an unsurvivable repeating one.
# Binding re-enumerates the port. If the board is a sink at
# power_operation_mode=default - USB default current, no PD contract, which is
# what a laptop port gives you and is not much for four cores plus an MCU -
# re-enumerating under load can brown it out. It reboots, the UDC is still
# there, udev fires the bind, and it browns out again.
#
# The loop has no SSH window in it. Nothing to log into, wifi never finishes
# coming up, and the only way out is a factory restore. The cost of being
# wrong here is the whole board, which is what justifies a guard at all.
#
# HOW IT BREAKS THE LOOP
# ----------------------
# `check` increments a counter on disk and fails once it exceeds MAX, which
# stops the bind from running at all. `confirm` clears it, and is run by
# unoq-usb-confirm.service a couple of minutes into a boot that actually got
# as far as having a network. So:
#
#   healthy boot -> bind, counter 1, ... confirm clears it -> next boot starts at 0
#   brownout loop -> bind, counter 1, reset, 2, reset, 3, reset, 4 > MAX
#                    -> bind refuses -> board boots clean -> wifi -> ssh
#
# The board gives up the gadget and keeps the network, which is the right way
# round: the gadget is the thing being experimented with, the network is how
# you get in to fix it. If wifi has been turned off to save the power budget,
# refusing to bind also turns it back on - see wifi_rescue() below, because
# without that the "network" the guard is protecting does not exist.
#
# This is the same shape as the MCU's FOTA rollback - try the new thing, and
# fall back automatically if it does not confirm itself - applied to the half
# of the board that can also strand you.
#
# RECOVER by hand after the guard has tripped:
#
#   sudo rm -f /var/lib/unoq/usb-bind-attempts
#   sudo systemctl start unoq-usb-bind.service
set -uo pipefail

STATE_DIR="${UNOQ_STATE_DIR:-/var/lib/unoq}"
COUNTER="$STATE_DIR/usb-bind-attempts"
MAX="${UNOQ_USB_BIND_MAX_ATTEMPTS:-3}"
WIFI_RESCUE="${UNOQ_GUARD_WIFI_RESCUE:-1}"

log() {
  logger -t unoq-bind-guard "$*" 2>/dev/null
  echo "unoq-bind-guard: $*"
}

# Turning the radio back on is the other half of refusing to bind.
#
# The reasoning above - give up the gadget, keep the network - holds only while
# there IS another network. Once wifi is off to save the power budget (wifi.sh),
# the gadget is the sole way in, and a guard that refuses to bind would take the
# board off the air entirely rather than rescue it: exactly the outage it exists
# to prevent, arrived at from the other direction.
#
# So the guard restores the thing that was given up. Wifi costs power, which is
# what the board is short of, but a board you can reach is worth more than a
# board that boots quietly forever, and this only ever runs on a board that has
# already failed to survive three boots.
#
# nmcli persists the radio state, so it stays on across the reboot too - which
# it must, because the next boot is the one you will be trying to log into.
# Disable with UNOQ_GUARD_WIFI_RESCUE=0 if the board genuinely has no wifi.
wifi_rescue() {
  [ "$WIFI_RESCUE" = "1" ] || return 0
  command -v nmcli >/dev/null 2>&1 || return 0
  case "$(nmcli radio wifi 2>/dev/null)" in
    enabled)
      log "  wifi is already on - the board should be reachable over it"
      return 0
      ;;
  esac
  if nmcli radio wifi on >/dev/null 2>&1; then
    log "  WIFI TURNED BACK ON as the rescue path - the board will come up on it"
  else
    log "  could not turn wifi back on - serial console may be the only way in"
  fi
}

# State is "<boot_id> <count>", not a bare number, and the boot id is the part
# that makes the count mean BOOTS rather than invocations.
#
# The bind unit deliberately runs more than once per plug-in. udev triggers it
# when the UDC appears, and again for each gadget netdev - usb0 for ncm, usb1
# for rndis - because those only exist a moment after the bind. That is three
# runs on a perfectly healthy plug-in. Counting invocations would therefore
# have reached a limit of 3 during the first SUCCESSFUL plug-in and refused to
# bind ever again: a guard that causes exactly the outage it exists to prevent,
# and one that would have looked like the gadget being broken rather than the
# guard being wrong.
#
# So only the first check of any given boot counts. Later ones in the same boot
# are waved through, and the counter only advances when the board has come up
# again without ever having confirmed.
CURRENT_BOOT="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"

read_state() {
  local raw
  raw="$(cat "$COUNTER" 2>/dev/null)"
  STATE_BOOT="${raw%% *}"
  STATE_COUNT="${raw##* }"
  # Anything unparsable is a clean slate rather than an error: a file
  # truncated by a reset mid-write must not be able to wedge the guard
  # permanently in either direction. This also migrates the older bare-number
  # format, which carries no boot id, by treating it as some previous boot.
  case "$STATE_COUNT" in
    '' | *[!0-9]*) STATE_COUNT=0 ;;
  esac
  case "$raw" in
    *' '*) ;;
    *) STATE_BOOT="" ;;
  esac
}

case "${1:-}" in
  check)
    mkdir -p "$STATE_DIR" 2>/dev/null
    read_state
    if [ "$STATE_COUNT" -ge "$MAX" ]; then
      log "REFUSING to bind: $STATE_COUNT consecutive boots never confirmed (max $MAX)."
      log "  The board has been rebooting without ever staying up long enough"
      log "  to confirm a bind. Suspect USB power - check the cable is on a"
      log "  powered hub or PD supply, not a 0.5 A port."
      log "  Clear with: sudo rm -f $COUNTER"
      wifi_rescue
      exit 1
    fi
    if [ "$STATE_BOOT" = "$CURRENT_BOOT" ]; then
      # Same boot, so this is udev's second or third trigger for one plug-in.
      log "bind attempt $STATE_COUNT/$MAX (already counted this boot)"
      exit 0
    fi
    # Written BEFORE the bind, not after. If the bind is what kills the board
    # there is no "after" in which to record that it was tried.
    echo "$CURRENT_BOOT $((STATE_COUNT + 1))" >"$COUNTER" 2>/dev/null
    sync -f "$COUNTER" 2>/dev/null || sync
    log "bind attempt $((STATE_COUNT + 1))/$MAX"
    ;;
  confirm)
    read_state
    if [ "$STATE_COUNT" = "0" ]; then
      log "already confirmed"
    else
      rm -f "$COUNTER" 2>/dev/null
      log "boot confirmed healthy - bind attempt counter cleared (was $STATE_COUNT)"
    fi
    ;;
  status)
    read_state
    echo "attempts: $STATE_COUNT/$MAX  ($COUNTER)"
    if [ -n "$STATE_BOOT" ] && [ "$STATE_BOOT" = "$CURRENT_BOOT" ]; then
      echo "  (already counted in the current boot)"
    fi
    ;;
  *)
    echo "usage: $(basename "$0") {check|confirm|status}" >&2
    exit 2
    ;;
esac
exit 0
