#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Default route out through whichever computer is on the other end of the USB
# cable. Called by usb-dhcp.sh on a lease event, not by you.
#
#   usb/usb-route.sh <add|old|del|prefer> <gateway-ip>
#
# WHY A LEASE HOOK
# ----------------
# The host's gateway address is not knowable in advance. Windows ICS uses
# 192.168.137.1, macOS Internet Sharing 192.168.2.1, a Linux host whatever it
# was configured with - and which computer is on the other end of the cable can
# change between one plug-in and the next. The lease is the only moment that
# address is authoritative, so the route is set from there rather than polled
# for or hardcoded.
#
# It took a <mac> second argument until recently, because it was a dnsmasq
# --dhcp-script back when the board could also be the DHCP server on this link.
# It has one caller now.
#
# WHAT THIS DOES NOT DO
# ---------------------
# It does not make the internet work by itself. It points the board's default
# route at the host; the host still has to be routing and NAT-ing for packets
# to go anywhere. On Windows that is Internet Connection Sharing, or
# New-NetNat from an elevated PowerShell. Without it you get a route and
# silence, which is why the metric below matters.
#
# THE METRIC
# ----------
# 700, chosen to lose to everything NetworkManager installs for a real link.
# The intent has always been that this route is a fallback of last resort: if
# the board has any genuine route to the internet, that keeps winning and this
# one sits unused. Only when the USB cable is the board's sole link should it
# take over. A USB gadget that silently stole the default route from a working
# network would be a nasty thing to debug.
#
# This was 500, which did not achieve that, and the reasoning is worth keeping
# because it is an easy mistake to repeat. NetworkManager does not give every
# connection the ~100 you see on ethernet - the default metric is per device
# type, and for wifi it is 600:
#
#   default via 192.168.0.1 dev wlan0 proto dhcp src 192.168.0.172 metric 600
#
# So on a board whose only uplink is wifi - which is the normal case for this
# one, and the configuration you are most likely to be developing over - 500
# beat the real connection instead of losing to it. Plugging the board into a
# computer would hand it the default route. SSH survived (that is a connected
# route on the LAN, not the default), so it looked fine, while every outbound
# connection went to a host that was almost certainly not NAT-ing: apt, git and
# anything else needing the internet simply stopped, with no error pointing
# anywhere near USB.
#
# Higher metric = lower priority, so 700 loses to wifi's 600 and to ethernet's
# 100. It also loses to a default route added with no metric at all: for IPv4
# that is metric 0, the best there is (1024 is IPv6's default, not IPv4's). If
# you would rather it never touched the default route at all, the escape hatch
# is UNOQ_USB_DEFAULT_ROUTE=0.
#
# AND THE OTHER METRIC, 550
# -------------------------
# `prefer` is the answer to "I plugged the cable in, why am I still on wifi".
# 700 means the USB link never carries traffic while the radio is on, so the
# only way to use the cable was to turn wifi off by hand. 550 beats wifi's 600
# and still loses to ethernet's 100, so the cable wins as soon as it is in.
#
# What makes that safe is that it is NOT what a lease installs. The bug this
# file documents above - metric 500 handing the default route to a machine that
# was not NAT-ing - was not caused by the number being low. It was caused by the
# number being low WITHOUT ANYONE CHECKING. So `add` still installs 700, and the
# promotion to 550 happens only after a packet has actually reached the internet
# through this bridge. No proof, no promotion, and a route that was promoted and
# then stops working is demoted again by the next event that re-runs the check.
#
# The residual case is honest to state: a host that goes to sleep with the cable
# in leaves a promoted route pointing at nothing until the next lease event or
# profile run. uplink-fallback.sh is the backstop for the version of that which
# actually strands the board - wifi off, nothing to fall back to - and turns the
# radio back on at boot.
set -uo pipefail

ACTION="${1:-}"
HOST_IP="${2:-}"

BRIDGE="${UNOQ_USB_BRIDGE:-br-usb}"
METRIC="${UNOQ_USB_ROUTE_METRIC:-700}"
# Below NetworkManager's 600 for wifi, above ethernet's 100. Only ever used by
# `prefer`, and only with proof - see the note above.
METRIC_PREFERRED="${UNOQ_USB_ROUTE_METRIC_PREFERRED:-550}"
PREFER="${UNOQ_USB_PREFER_OVER_WIFI:-1}"
PROBES="${UNOQ_USB_PROBE_IPS:-1.1.1.1 8.8.8.8}"
ENABLED="${UNOQ_USB_DEFAULT_ROUTE:-1}"

[ "$ENABLED" = "1" ] || exit 0

case "$ACTION" in
  add | old | del | prefer) ;;
  *) exit 0 ;;
esac

# An address is required, and it must be one - this runs as root with a
# value that came off the wire. The pattern here was [0-9]*.[0-9]*.[0-9]*.[0-9]*,
# which 999.1.1.1 and 1.2.3.4.5.6 both match.
# shellcheck source=usb/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
is_ipv4 "$HOST_IP" || exit 0

# Only act while the bridge is actually there; on shutdown it may already be
# gone and every ip(8) call would just print noise into the journal.
ip link show "$BRIDGE" >/dev/null 2>&1 || exit 0

log() {
  logger -t unoq-usb-route "$*"
  echo "unoq-usb-route: $*"
}

case "$ACTION" in
  add | old)
    # `replace`, not `add`: the host renewing its lease, or coming back with
    # the same address, must not fail on "file exists" and must not stack a
    # second identical route.
    if ip route replace default via "$HOST_IP" dev "$BRIDGE" metric "$METRIC" 2>/dev/null; then
      log "default route -> $HOST_IP dev $BRIDGE metric $METRIC"
    else
      log "could not set default route via $HOST_IP"
    fi
    ;;
  prefer)
    # Promote this route above wifi, but ONLY on proof that it goes anywhere.
    #
    # Bound to the interface, so this asks "does the USB path reach the
    # internet" rather than "does this board have internet somehow" - which,
    # with wifi up and winning, would answer yes no matter what the cable was
    # plugged into. That distinction is the whole check.
    #
    # ICMP first, then TCP: some hosts drop outbound ping while NAT-ing TCP
    # perfectly, and a ping-only test would refuse to promote a link that works.
    #
    # The TCP half runs with -k. What is being asked is whether packets reach
    # the internet through this bridge, not whether a certificate is valid for
    # an address - and a probe IP whose certificate does not name it would
    # otherwise fail TLS and be read as "no internet here", which refuses to
    # promote a link that works.
    if [ "$PREFER" != "1" ]; then
      log "not promoting the USB route (UNOQ_USB_PREFER_OVER_WIFI=0)"
      exit 0
    fi
    reached=1
    for probe in $PROBES; do
      ping -c1 -W3 -I "$BRIDGE" "$probe" >/dev/null 2>&1 && {
        reached=0
        break
      }
    done
    if [ "$reached" != 0 ] && command -v curl >/dev/null 2>&1; then
      for probe in $PROBES; do
        curl --interface "$BRIDGE" --max-time 5 -sS -k -o /dev/null \
          "https://$probe/" >/dev/null 2>&1 && {
          reached=0
          break
        }
      done
    fi

    if [ "$reached" = 0 ]; then
      if ip route replace default via "$HOST_IP" dev "$BRIDGE" metric "$METRIC_PREFERRED" 2>/dev/null; then
        # The unpromoted route goes, so there is one default route via this
        # gateway rather than two at different priorities. Two is not broken,
        # but it makes `ip route` unreadable at exactly the moment somebody is
        # reading it to find out why traffic is going the way it is.
        ip route del default via "$HOST_IP" dev "$BRIDGE" metric "$METRIC" 2>/dev/null
        log "the internet answers over $BRIDGE - default route -> $HOST_IP metric $METRIC_PREFERRED (ahead of wifi)"
      else
        log "could not promote the route via $HOST_IP"
      fi
    else
      # Not a failure to report loudly: this is the normal state whenever the
      # host is not sharing its connection. What matters is that anything left
      # promoted from a previous run comes back down, so a link that stopped
      # working stops taking the traffic.
      if ip route del default via "$HOST_IP" dev "$BRIDGE" metric "$METRIC_PREFERRED" 2>/dev/null; then
        log "no internet over $BRIDGE any more - route demoted to metric $METRIC"
      fi
      ip route replace default via "$HOST_IP" dev "$BRIDGE" metric "$METRIC" 2>/dev/null
    fi
    ;;

  del)
    # Only our own route, matched on all three fields, so a LAN default route
    # someone else installed is never touched. Both metrics, because `prefer`
    # may have promoted it - leaving the promoted one behind on a released
    # lease would be a default route pointing at a host that has gone away, at
    # a priority that beats wifi.
    if ip route del default via "$HOST_IP" dev "$BRIDGE" metric "$METRIC" 2>/dev/null; then
      log "default route via $HOST_IP withdrawn (lease released)"
    fi
    if ip route del default via "$HOST_IP" dev "$BRIDGE" metric "$METRIC_PREFERRED" 2>/dev/null; then
      log "promoted default route via $HOST_IP withdrawn (lease released)"
    fi
    ;;
esac
exit 0
