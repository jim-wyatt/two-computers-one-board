#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Turn wifi back on if the USB link has not produced a route to the internet
# within a few minutes of boot. Run once per boot by unoq-uplink-fallback.service.
#
#   ~/two-computers-one-board/net/uplink-fallback.sh          # the check, as the unit runs it
#   UNOQ_UPLINK_DEADLINE=60 ...              # shorter wait, for testing
#
# WHY THIS IS SEPARATE FROM THE BIND GUARD
# ----------------------------------------
# bind-guard.sh covers one failure: the bind itself is killing the board, so
# stop binding. It cannot see this one, because everything it checks succeeded.
# The gadget binds, br-usb comes up, the address is there - and the board still
# has no way out, because the computer at the other end is not sharing its
# connection, or is asleep, or woke up with the sharing switched off, or is a
# different computer than the one this board was set up against.
#
# With wifi on that is a nuisance. With wifi off - which is the whole point of
# wifi.sh, and the reason the power budget works at all - it is a board that
# boots, looks healthy, and cannot fetch anything, with no obvious culprit and
# no second path to go and look down.
#
# WHY A DEADLINE AFTER BOOT, RATHER THAN A WATCHDOG
# -------------------------------------------------
# A timer that polled forever would keep flipping the radio every time the host
# slept or the cable was jostled, and each flip is a NetworkManager reconnect
# and a resolv.conf rewrite. Worse, it would fight anyone who deliberately
# turned wifi off for a while.
#
# Boot is the moment the question is actually live: the board has just come up,
# something either works or it does not, and nobody is watching. So this asks
# once per boot, waits a few minutes for a host that may still be booting
# itself, and then either says nothing at all or turns the radio on and leaves
# it on. Falling back is a decision that stays made until a person unmakes it,
# which is the property you want from a fallback you are relying on.
#
# It does nothing whatsoever if wifi is already on - there is then nothing to
# fall back TO, and the check would only cost a few pings.
set -uo pipefail

DEADLINE="${UNOQ_UPLINK_DEADLINE:-240}" # seconds from this unit starting
INTERVAL="${UNOQ_UPLINK_INTERVAL:-15}"  # between probes
PROBES="${UNOQ_UPLINK_PROBE_IPS:-1.1.1.1 8.8.8.8}"
ENABLED="${UNOQ_UPLINK_FALLBACK:-1}"
BRIDGE="${UNOQ_USB_BRIDGE:-br-usb}"

log() {
  logger -t unoq-uplink-fallback "$*" 2>/dev/null
  echo "unoq-uplink-fallback: $*"
}

[ "$ENABLED" = "1" ] || {
  log "disabled (UNOQ_UPLINK_FALLBACK=0)"
  exit 0
}

command -v nmcli >/dev/null 2>&1 || {
  log "no nmcli - nothing to fall back to"
  exit 0
}

case "$(nmcli radio wifi 2>/dev/null)" in
  enabled)
    log "wifi is already on - nothing to do"
    exit 0
    ;;
esac

# Reachability is deliberately tested THROUGH the bridge, not just "can this
# board reach the internet somehow". Binding the probe to the interface is what
# makes this a test of the USB path rather than of whatever else might be up.
reachable() {
  local ip
  for ip in $PROBES; do
    ping -c1 -W3 -I "$BRIDGE" "$ip" >/dev/null 2>&1 && return 0
  done
  # Some hosts firewall outbound ICMP while happily NAT-ing TCP, which would
  # make a ping-only check condemn a link that works perfectly.
  #
  # -k, for the same reason the other two copies of this probe carry it (see
  # usb-profile.sh): the question is whether packets get out through this
  # bridge, and a probe address whose certificate does not name it would fail
  # TLS and be read as "no internet" - here, that turns the radio back on.
  if command -v curl >/dev/null 2>&1; then
    for ip in $PROBES; do
      curl --interface "$BRIDGE" --max-time 5 -sS -k -o /dev/null \
        "https://$ip/" >/dev/null 2>&1 && return 0
    done
  fi
  return 1
}

log "waiting up to ${DEADLINE}s for a route to the internet over $BRIDGE"

waited=0
while [ "$waited" -lt "$DEADLINE" ]; do
  if reachable; then
    log "internet reachable over $BRIDGE after ${waited}s - wifi stays off"
    exit 0
  fi
  sleep "$INTERVAL"
  waited=$((waited + INTERVAL))
done

log "NO route to the internet over $BRIDGE after ${DEADLINE}s."
log "  Turning wifi back on as the fallback. The USB link keeps whatever it has;"
log "  its route is metric 700 and loses to wifi's 600, so wifi carries traffic"
log "  from here. Check the host end - on Windows, Internet Connection Sharing"
log "  on the adapter the board appears as - then: sudo $(dirname "$0")/wifi.sh off"
if nmcli radio wifi on >/dev/null 2>&1; then
  log "  wifi radio on"
else
  log "  could not turn the radio on - the board may have no uplink at all"
  exit 1
fi
exit 0
