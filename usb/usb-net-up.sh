#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Put the USB gadget link on the bridge and get it an address.
#
#   sudo ~/two-computers-one-board/usb/usb-net-up.sh
#
# Idempotent.
#
# ADDRESSING
# ----------
#   the board    asks the computer for an address by DHCP
#   if nobody    answers, IPv4 link-local instead - 169.254.x.y, RFC 3927
#   either way   the board answers to <hostname>.local over mDNS
#
# ONE DIRECTION, NOT TWO
# ----------------------
# The board is always the DHCP client here. It used to be switchable - a server
# mode where the board sat at a static 10.55.0.1 and ran dnsmasq to lease the
# computer an address, and a client mode for when the computer was the one
# sharing its internet. Both existed at once, the mode was a file in /etc, and
# 10.55.0.1 stayed on the bridge in both.
#
# That was two of everything: two DHCP daemons to keep from fighting over one
# wire, two sets of route and DNS handling, two answers to "what do I ssh to",
# and a second address on the bridge whose only job was to be there when the
# other one was not.
#
# Client-only is what makes a single address possible, because the two hosts we
# do not control are not negotiable. Windows Internet Connection Sharing pins
# its adapter to 192.168.137.1/24 and macOS Internet Sharing to 192.168.2.1,
# each runs its own DHCP server, and neither will ever take a lease from us. A
# board that wants internet over the cable has to accept their numbering. So it
# accepts it, and the fixed thing you type is a NAME rather than an address.
#
# WHEN NOBODY IS SERVING DHCP
# ---------------------------
# The cable is plugged into a computer that is not sharing anything, or ICS is
# off, or the host is still booting. This is the case the old static 10.55.0.1
# existed for, and link-local does the same job properly.
#
# Every desktop OS self-assigns 169.254.x.y when its own DHCP finds nothing, so
# a board doing the same lands on the same /16 as the computer automatically -
# no host configuration, no elevated `route add`, on Windows, macOS and Linux
# alike. That is the part 10.55.0.1 could never do: a board on a private /24 of
# its own needed a static route added by hand at the other end before anything
# could reach it.
#
# avahi is what turns that into something typeable. It publishes <hostname>.local
# on every interface, so the name resolves to whichever address this link ended
# up with - leased or link-local - and Windows 10+, macOS and Linux all resolve
# it with nothing installed.
#
# WHY A BRIDGE
# ------------
# Historically: the gadget offered two configurations, RNDIS and NCM, each with
# its own netdev on this side, and we could not know which the host would pick.
#
# That is no longer the reason - gadget-up.sh now builds one configuration with
# one network function. br-usb is kept because it is the interface name the
# units, uplink-fallback.sh, wifi.sh and every ssh instruction in the docs refer
# to, and because it survives the netdev disappearing on unplug where an address
# on usb0 would not. It is a stable name doing the work now, not a bridge.
#
# This deliberately does NOT set a default route or NAT. Routing is usb-route.sh's
# business, from a lease event, at a metric that loses to every real link.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BRIDGE="${UNOQ_USB_BRIDGE:-br-usb}"
RUN_DIR="${UNOQ_RUN_DIR:-/run}"
NET_SYSFS="${UNOQ_NET_SYSFS:-/sys/class/net}"
UDHCPC_PID="$RUN_DIR/unoq-usb-udhcpc.pid"
DNSMASQ_PID="$RUN_DIR/unoq-usb-dnsmasq.pid"

log() { echo "unoq-usb-net: $*"; }
die() {
  echo "unoq-usb-net: $*" >&2
  exit 1
}

[ "$(id -u)" = 0 ] || die "must run as root"

# pid_is, is_udhcpc and is_ipv4 are shared by the scripts in usb/.
# shellcheck source=usb/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# --- migration: no dnsmasq on this link any more ----------------------------
#
# Not tidiness. A board updated in place from the two-mode design still has our
# dnsmasq running from the previous boot, and it would go on answering DHCP on
# this bridge - a second DHCP server on the same wire as the host's, with the
# board taking whichever reply arrives first. Left alone that is an intermittent
# fault, and on a host that is NOT sharing its connection it is a rogue DHCP
# server handing out leases on a subnet that no longer exists.
if pid_is "$DNSMASQ_PID" dnsmasq; then
  kill "$(cat "$DNSMASQ_PID")" 2>/dev/null
  log "stopped the dnsmasq left over from server mode - this link is client-only now"
fi
# The file goes either way: a pid file with no dnsmasq behind it is only ever
# a number waiting to be mistaken for one.
rm -f "$DNSMASQ_PID"

# --- bridge ----------------------------------------------------------------

modprobe bridge 2>/dev/null
if ip link show "$BRIDGE" >/dev/null 2>&1; then
  log "$BRIDGE exists"
else
  ip link add name "$BRIDGE" type bridge || die "could not create $BRIDGE"
  # No STP: there is exactly one path here, and STP's forwarding delay would
  # make the host wait ~30s for DHCP on every plug-in.
  ip link set "$BRIDGE" type bridge stp_state 0 forward_delay 0
  log "created $BRIDGE"
fi

ip link set "$BRIDGE" up

# A 10.55.0.1 left over from server mode has to go, and for a sharper reason
# than neatness: avahi advertises every address on an interface, so a second one
# here means <hostname>.local resolves to two A records and the host picks one -
# half the time the one it has no route to. The whole point of this design is
# that the name is a reliable answer, so there must be exactly one address for
# it to give.
while read -r stale; do
  [ -n "$stale" ] || continue
  ip addr del "$stale" dev "$BRIDGE" 2>/dev/null &&
    log "removed $stale (left over from server mode)"
done < <(ip -4 -o addr show dev "$BRIDGE" 2>/dev/null |
  awk '$4 ~ /^10\.55\.0\./ {print $4}')

# --- enslave whatever the gadget created -----------------------------------

# usb0 is what the gadget's single network function registers as. The loop still
# enslaves every usb* it finds rather than naming one, because a gadget built
# with the other function, or an older one still bound from before a rebuild,
# numbers them differently - and enslaving a netdev that never passes a frame
# costs nothing.
enslaved=0
for iface in "$NET_SYSFS"/usb*; do
  [ -e "$iface" ] || continue
  name="$(basename "$iface")"
  master="$(basename "$(readlink -f "$iface/master" 2>/dev/null || echo none)")"
  if [ "$master" = "$BRIDGE" ]; then
    log "$name already on $BRIDGE"
    enslaved=$((enslaved + 1))
    continue
  fi
  # A gadget netdev cannot hold an address of its own while bridged.
  ip addr flush dev "$name" 2>/dev/null
  if ip link set "$name" master "$BRIDGE" 2>/dev/null; then
    ip link set "$name" up
    log "$name -> $BRIDGE"
    enslaved=$((enslaved + 1))
  else
    log "WARNING: could not enslave $name"
  fi
done

if [ "$enslaved" = 0 ]; then
  log "no gadget interfaces yet - the bridge is up and waiting"
fi

# --- ask the computer for an address ---------------------------------------

# busybox rather than a package: this image ships no dhclient, dhcpcd or
# standalone udhcpc, and busybox is already here. It is also about the right
# size of tool for the job - one interface, one lease, a handler script.
command -v busybox >/dev/null 2>&1 || die "busybox not installed (needed for udhcpc)"

if is_udhcpc "$UDHCPC_PID"; then
  log "udhcpc already running (pid $(cat "$UDHCPC_PID"))"
else
  rm -f "$UDHCPC_PID"
  # Ask for the address we had last time. A DHCP server is free to refuse, and
  # this changes nothing if it does - but Windows ICS and macOS both honor it
  # in practice, which keeps the numeric address stable across reboots for
  # anyone who prefers typing it to typing the name.
  #
  # Read once, here, which is why usb-dhcp.sh deletes the file on a NAK rather
  # than leaving it for the next lease to overwrite: a refusal that is not
  # written down is a refusal this line repeats on every restart. That is the
  # case where the cable moved between a PC and a Mac, whose shared adapters
  # number from subnets neither will lease the other's addresses out of.
  REQUEST=()
  LAST="${UNOQ_STATE_DIR:-/var/lib/unoq}/usb-dhcp-last"
  if [ -r "$LAST" ]; then
    read -r last_ip <"$LAST"
    if is_ipv4 "$last_ip"; then
      REQUEST=(--request="$last_ip")
      log "asking for $last_ip again (last address on this link)"
    fi
  fi
  # -b: go to the background and keep trying rather than exiting, because at
  #     boot the host's shared adapter is usually not up yet. There is no
  #     failure here worth giving up on - the cable is either plugged in now
  #     or it will be.
  # -R: release the lease on a clean exit, so the host does not hold an
  #     address for a board that has gone away.
  # -t/-T: five tries three seconds apart before backing off, which keeps a
  #     normal plug-in feeling immediate without hammering a host that is
  #     not sharing anything. usb-dhcp.sh brings link-local up on the way past.
  if busybox udhcpc \
    --interface="$BRIDGE" \
    --script="$HERE/usb-dhcp.sh" \
    --pidfile="$UDHCPC_PID" \
    -x "hostname:$(hostname)" \
    "${REQUEST[@]+"${REQUEST[@]}"}" \
    --background --release \
    --retries=5 --timeout=3 >/dev/null 2>&1; then
    log "udhcpc asking for an address on $BRIDGE"
  else
    die "udhcpc failed to start on $BRIDGE"
  fi
fi

log "board reachable at $(hostname).local, and at whatever address this link gets"
