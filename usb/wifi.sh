#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Turn the board's wifi radio off, once the USB link can carry the traffic.
#
#   ~/two-computers-one-board/usb/wifi.sh status      # what is on, and what would be left
#   sudo ~/two-computers-one-board/usb/wifi.sh off    # checks the USB link first, then off
#   sudo ~/two-computers-one-board/usb/wifi.sh on     # back on, whatever state anything is in
#
# WHY
# ---
# As a device the board is a power sink, and a host port with no PD contract
# gives it USB default current - not much for four cores plus an MCU. The wifi
# radio is the largest thing on the board that can simply be switched off, and
# on a board that is plugged into a computer anyway, it is also the most
# redundant: the NCM link is already there and is faster.
#
# WHY THIS IS NOT JUST `nmcli radio wifi off`
# -------------------------------------------
# Because that command, run at the wrong moment, is how you lose the board.
#
# You are almost certainly typing it over the wifi it is about to turn off. If
# the USB link is not carrying traffic - the gadget did not bind, the cable is
# charge-only, the host is not sharing its connection - then the moment the
# radio goes down there is no path to the board at all. Not slow: absent. The
# next step is a serial console or a factory restore.
#
# So `off` refuses unless it can see the link actually working, and says which
# check failed. --force skips the checks for when you know better (a serial
# console open, or you are not on wifi in the first place).
#
# WHAT `off` DOES BEYOND THE RADIO
# --------------------------------
# It kicks the DHCP client into renewing. NetworkManager owns /etc/resolv.conf
# on this image and rewrites it when the radio goes down, taking the board's
# nameservers with it; usb-dhcp.sh puts them back, but only on a lease event.
# Without the kick the board would route fine and resolve nothing until the
# lease next renewed, which on a Windows ICS lease is days away. That symptom -
# ping 8.8.8.8 works, apt does not - is a genuinely annoying one to chase.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BRIDGE="${UNOQ_USB_BRIDGE:-br-usb}"
METRIC="${UNOQ_USB_ROUTE_METRIC:-700}"
UDHCPC_PID="${UNOQ_RUN_DIR:-/run}/unoq-usb-udhcpc.pid"
G="${UNOQ_GADGET_DIR:-/sys/kernel/config/usb_gadget/unoq}"

# pid_is, is_udhcpc and is_ipv4 are shared by the scripts in usb/.
# shellcheck source=usb/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

FORCE=0
ACTION=""
for arg in "$@"; do
  case "$arg" in
    off | on | status | check) ACTION="$arg" ;;
    -f | --force) FORCE=1 ;;
    *)
      echo "usage: $(basename "$0") {status|check|off|on} [--force]" >&2
      exit 2
      ;;
  esac
done
[ -n "$ACTION" ] || {
  echo "usage: $(basename "$0") {status|check|off|on} [--force]" >&2
  exit 2
}

say() { printf '  %s\n' "$*"; }
die() {
  printf 'wifi.sh: %s\n' "$*" >&2
  exit 1
}
need_root() { [ "$(id -u)" = 0 ] || die "run this with sudo"; }

command -v nmcli >/dev/null 2>&1 || die "nmcli not found - this board is not on NetworkManager"

# The default route via the bridge is the single best proof that the USB link is
# not merely up but usable: usb-route.sh only installs it from a real lease, and
# only when there is a gateway on the other end.
usb_gateway() {
  ip -4 route show default dev "$BRIDGE" 2>/dev/null |
    sed -n 's/^default via \([0-9.]*\).*/\1/p' | head -1
}

# A gateway is the good case. A link-local address is the other one worth
# knowing about: it means the cable found a computer but nothing is serving
# DHCP, so there is a peer to reach the board from and no route past it. Falling
# back to the neighbor table rather than refusing outright keeps `off` usable
# for the "reach the board from this one machine" case, which is a legitimate
# thing to want - preflight still warns that nothing else is reachable.
#
# BOTH FAMILIES, because this used to ask only IPv4 and got the answer wrong in
# the exact case it exists for. With no DHCP server on the other end the board
# autoconfigures 169.254/16 and the host does too, but nothing makes the two
# ARP for each other until something sends v4 traffic - while IPv6 link-local
# comes up on its own and carries the ssh session. So the v4 table held one
# FAILED entry with no lladdr, the v6 table held the host REACHABLE, and this
# function reported "no computer on br-usb" to a person connected through it.
#
# v4 is still asked first: an address the host routes with is a better answer
# than one it merely answers on. Multicast is excluded because a neighbor that
# is not a host is not a way back in.
usb_peer() {
  local gw peer
  gw="$(usb_gateway)"
  if [ -n "$gw" ]; then
    echo "$gw"
    return 0
  fi
  peer="$(ip -4 neigh show dev "$BRIDGE" 2>/dev/null |
    awk '$0 ~ /lladdr/ {print $1; exit}')"
  [ -n "$peer" ] || peer="$(ip -6 neigh show dev "$BRIDGE" 2>/dev/null |
    awk '$0 ~ /lladdr/ && $1 !~ /^[Ff][Ff]/ {print $1; exit}')"
  [ -n "$peer" ] && echo "$peer"
}

# Whether the computer on the other end is actually there.
#
# Not by ping alone: Windows blocks ICMP to its ICS adapter by default, so the
# gateway that is routing the board's traffic perfectly well does not answer,
# and refusing on that basis would refuse in the normal case. The ping is worth
# trying because it succeeds outright on macOS and Linux hosts - and when it
# fails it has still forced ARP, which is the check that matters. A resolved
# neighbor means frames cross the wire and get answered, which is exactly the
# property "will I still be able to reach this board" depends on.
#
# The family is taken from the address rather than left to `ping` to guess,
# because a link-local v6 peer is meaningless without a scope: -6 with -I names
# the interface the fe80:: address belongs to, and without it the ping fails on
# an address that is perfectly reachable.
peer_reachable() {
  local peer="$1" entry
  case "$peer" in
    *:*) ping -6 -c1 -W2 -I "$BRIDGE" "$peer" >/dev/null 2>&1 && return 0 ;;
    *) ping -c1 -W2 -I "$BRIDGE" "$peer" >/dev/null 2>&1 && return 0 ;;
  esac
  entry="$(ip neigh show "$peer" dev "$BRIDGE" 2>/dev/null)"
  case "$entry" in
    *FAILED* | *INCOMPLETE*) return 1 ;;
    *lladdr*) return 0 ;;
    *) return 1 ;;
  esac
}

val() { printf '  %-22s %s\n' "$1" "${2:-<none>}"; }

show_status() {
  printf '\n== wifi ==\n'
  val "radio" "$(nmcli radio wifi 2>/dev/null)"
  val "wlan0" "$(ip -br addr show wlan0 2>/dev/null | tr -s ' ')"
  printf '\n== what would be left ==\n'
  val "gadget bound to" "$(cat "$G/UDC" 2>/dev/null)"
  val "$BRIDGE" "$(ip -br addr show "$BRIDGE" 2>/dev/null | tr -s ' ')"
  val "dhcp mode" "$(pid_mode)"
  val "gateway over USB" "$(usb_gateway)"
  val "nameservers" "$(sed -n 's/^nameserver //p' /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
  printf '\n== default routes (lowest metric wins) ==\n'
  ip route show default | sed 's/^/  /' || val "routes"
}

# Everything that has to be true before the radio can go off, and the address
# to reconnect on if it does. Each failure names the thing to fix, because
# "refused" on its own would only send you to usb/status.sh anyway.
preflight() {
  local peer
  [ -n "$(cat "$G/UDC" 2>/dev/null)" ] ||
    die "the gadget is not bound to a UDC - nothing would be left. Check usb/status.sh, then --force if you are sure."
  ip link show "$BRIDGE" >/dev/null 2>&1 ||
    die "$BRIDGE does not exist - run usb/usb-net-up.sh first."
  peer="$(usb_peer)"
  [ -n "$peer" ] ||
    die "no computer on $BRIDGE: no gateway, and no IPv4 or IPv6 neighbor either.
       Plug the cable in and check usb/status.sh. If the host is meant to be
       sharing its connection, that is the thing to turn on - on Windows,
       Internet Connection Sharing on the adapter the board appears as."
  peer_reachable "$peer" ||
    die "$peer is on the routing table but does not answer on $BRIDGE - the
       link is configured and not working, which is the one state where
       turning the radio off strands the board. --force to override."
  say "gadget bound, and $peer answers on $BRIDGE"

  # Internet is a warning, not a refusal. There are good reasons to want the
  # board reachable from one computer without wanting a route to the world, and
  # that choice is not this script's to make.
  if ping -c1 -W3 -I "$BRIDGE" "${UNOQ_PROBE_IP:-1.1.1.1}" >/dev/null 2>&1; then
    say "the host is NAT-ing: the board keeps its internet over USB"
  else
    say "WARNING: no internet through $peer. The board will be reachable from"
    say "         that computer but will not reach anything else. On Windows"
    say "         that means ICS is off, or shared to the wrong adapter."
    say "         apt and git will stop working."
  fi

  # The last thing printed before the radio goes, because it is the thing you
  # will need thirty seconds later and cannot look up once wifi is down.
  say ""
  say "RECONNECT ON:  $(reconnect_address)"
}

# What to ssh to afterwards.
#
# Both the name and the address, which this used to refuse to do. The old
# comment here said the mDNS name was unprintable because avahi advertises every
# address on the bridge, and there were always two - the leased one and the
# static 10.55.0.1 - so <hostname>.local resolved to two A records and the host
# picked one, half the time the one it had no route to.
#
# There is one address on this bridge now, which is what makes the name a
# reliable answer rather than a coin flip. The numeric address is still printed
# beside it, because this is the line you read thirty seconds later when the
# radio is already off and nothing is going to help you look it up.
reconnect_address() {
  local addr
  addr="$(ip -4 -br addr show "$BRIDGE" 2>/dev/null |
    tr ' ' '\n' | grep '/' | head -1)"
  addr="${addr%%/*}"
  if [ -n "$addr" ]; then
    printf '%s@%s.local   (or %s@%s)' \
      "${SUDO_USER:-$USER}" "$(hostname)" "${SUDO_USER:-$USER}" "$addr"
  else
    printf '%s@%s.local   - no address on %s yet' \
      "${SUDO_USER:-$USER}" "$(hostname)" "$BRIDGE"
  fi
}

pid_mode() {
  if is_udhcpc "$UDHCPC_PID"; then
    echo "udhcpc - asking the host for an address"
  else
    echo "<udhcpc not running>"
  fi
}

case "$ACTION" in
  status)
    show_status
    ;;

  on)
    need_root
    nmcli radio wifi on >/dev/null 2>&1 || die "could not enable the radio"
    echo "wifi radio on. NetworkManager will reconnect and take back the default"
    echo "route (metric 600) and /etc/resolv.conf; the USB route stays as the"
    echo "fallback at metric $METRIC."
    ;;

  check)
    preflight
    echo
    echo "Safe to turn the radio off:  sudo $HERE/wifi.sh off"
    ;;

  off)
    need_root
    if [ "$FORCE" = 0 ]; then
      preflight
    else
      say "checks skipped (--force)"
    fi

    nmcli radio wifi off >/dev/null 2>&1 || die "could not disable the radio"
    say "wifi radio off (persists across reboot)"

    # NM has just rewritten resolv.conf without our nameservers. A renew makes
    # usb-dhcp.sh reassert address, route and DNS now rather than in days.
    #
    # is_udhcpc, not `pid_is ... busybox udhcpc`: every applet started as
    # `busybox <name>` is called busybox, so a stale pid file whose pid had
    # since gone to another applet got SIGUSR1 - from root - and for most
    # applets that is the default action, which ends them.
    if is_udhcpc "$UDHCPC_PID"; then
      kill -USR1 "$(cat "$UDHCPC_PID")" 2>/dev/null &&
        say "asked udhcpc to renew, so DNS comes back on this link"
      sleep 2
    fi

    show_status
    cat <<EOF

The gadget is now the only way in. If it stops binding, the bind guard turns
this radio back on by itself after $((${UNOQ_USB_BIND_MAX_ATTEMPTS:-3})) unconfirmed boots - see bind-guard.sh.
To undo by hand:  sudo $HERE/wifi.sh on
EOF
    ;;
esac
