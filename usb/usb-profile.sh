#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Work out which kind of computer is on the other end of the USB cable, and take
# an address on its terms when it will not lease us one. Called by usb-dhcp.sh
# on leasefail, not by you - except `detect`, which changes nothing.
#
#   usb/usb-profile.sh detect            # name the host on the other end
#   usb/usb-profile.sh up <profile>      # claim its address, keep it only if it routes
#   usb/usb-profile.sh down <profile>    # give the address back
#
# WHY THIS EXISTS
# ---------------
# A lease is still the right answer and still wins outright. This is for the
# case the lease path cannot cover, which is not hypothetical - it is the board
# this was written on:
#
#   the host answers ARP at 192.168.137.1        it is there
#   it forwards and NATs to the internet         ping and TCP both out, ~17ms
#   it answers no DHCP discover at all           three tries, nothing
#
# That is Windows Internet Connection Sharing with its NAT half working and its
# DHCP half not - most often the firewall profile on that adapter dropping
# inbound DHCP. Everything the board needs is on the other end of the cable and
# reachable; the only missing thing is somebody to hand over an address. So the
# board takes one.
#
# WHY PROFILES RATHER THAN ONE HARDCODED SUBNET
# ---------------------------------------------
# Because "which computer is this plugged into" is genuinely a variable, and it
# is the ONLY thing that varies. There is one wire, one gadget function, one
# netdev and one bridge - gadget-up.sh builds a single configuration on purpose,
# and usb-net-up.sh explains why br-usb survives as a name rather than as a
# bridge. What differs between a PC and a Mac is not the link, it is the
# numbering on it: ICS pins 192.168.137.1/24, macOS Internet Sharing 192.168.2.1,
# a Linux host whatever its dnsmasq was told.
#
# So the thing there are several of is the ADDRESS PROFILE, and exactly one of
# them is ever active. That is not a style preference: avahi advertises every
# address an interface has, so two live profiles would mean two A records for
# <hostname>.local and a host free to pick the one it cannot route to. That is
# the exact failure the old static 10.55.0.1 caused, and the reason this whole
# design has one address on this bridge. See usb-dhcp.sh.
#
# HOW A PROFILE IS CHOSEN
# -----------------------
# By asking the wire, not by guessing from a config file. Each profile names the
# address its kind of host puts on its own shared adapter, and detection is an
# ARP request for it: a reply means that host is on the other end, silence means
# it is not. ARP because it is answered by the network stack itself - ICMP is
# not, since Windows firewalls ping to the ICS adapter by default, and a check
# that used ping would report "no host" for the most common host there is.
#
# NOTHING IS CLAIMED WITHOUT PROOF
# --------------------------------
# Two proofs, both required, because an address claimed wrongly is worse than no
# address:
#
#   1. the address is free   RFC 5227 ARP probe (arping -D) before taking it, so
#                            the board never collides with a host, or with
#                            another board on a machine running two of them.
#   2. the route works       an actual packet to the internet through the bridge
#                            after the route is in. A profile that matches but
#                            does not forward is torn straight back down and the
#                            caller falls back to link-local, which at least
#                            reaches the one computer.
#
# WHAT THIS DELIBERATELY DOES NOT DO
# ----------------------------------
# It does not guess. If no profile's gateway answers, this reports nothing and
# link-local takes over - it will not sweep the subnet, invent numbering, or
# claim an address on a network it has not identified. A Linux host with its own
# numbering is a line in the config file below, not something to be divined.
#
# It does not touch avahi-autoipd. usb-dhcp.sh owns the one-address rule and
# stops link-local before calling `up`, because that rule has to be enforced in
# one place to be enforceable at all.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BRIDGE="${UNOQ_USB_BRIDGE:-br-usb}"
# Overridable so the tests do not write into /run.
STATE="${UNOQ_USB_PROFILE_STATE:-/run/unoq-usb-profile.state}"
CONF="${UNOQ_USB_PROFILE_CONF:-/etc/unoq/usb-profiles.conf}"
PROBES="${UNOQ_USB_PROBE_IPS:-1.1.1.1 8.8.8.8}"
ENABLED="${UNOQ_USB_PROFILE_FALLBACK:-1}"

# The built-in table: name, gateway, the address to ask for, prefix length.
#
# .210 rather than .2 for the board's own address. Both shared adapters lease
# from the low end of their range - ICS starts at .2 - so taking a high one
# keeps the board clear of anything the host hands out if its DHCP half comes
# back to life later. It is also the address this link was leased last time it
# worked, which is worth something: it makes the fallback land on the same
# number the lease would have.
PROFILES_BUILTIN="\
windows-ics    192.168.137.1  192.168.137.210  24
macos-sharing  192.168.2.1    192.168.2.210    24"

log() {
  logger -t unoq-usb-profile "$*" 2>/dev/null
  echo "unoq-usb-profile: $*"
}

# pid_is, is_udhcpc and is_ipv4 are shared by the scripts in usb/.
# shellcheck source=usb/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# The table, with the operator's file appended so a Linux host - or an ICS that
# has been renumbered - is one line rather than a patch. Later rows are tried
# after the built-ins; comments and blank lines are ignored.
profiles() {
  printf '%s\n' "$PROFILES_BUILTIN"
  if [ -r "$CONF" ]; then
    sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$CONF"
  fi
}

# One row by name, validated. Every caller goes through this, so a malformed
# line in the operator's file is refused once here rather than in three places.
profile_row() {
  local want="$1" name gw addr plen
  while read -r name gw addr plen; do
    [ "$name" = "$want" ] || continue
    is_ipv4 "$gw" || return 1
    is_ipv4 "$addr" || return 1
    case "${plen:-}" in '' | *[!0-9]*) return 1 ;; esac
    [ "$plen" -ge 8 ] && [ "$plen" -le 30 ] || return 1
    printf '%s %s %s %s\n' "$name" "$gw" "$addr" "$plen"
    return 0
  done < <(profiles)
  return 1
}

# Is this host on the other end? An ARP request for the address its kind of host
# puts on its shared adapter.
#
# Deliberately not `ping`: Windows blocks ICMP to the ICS adapter by default, so
# the single most common host this will ever meet does not answer one. ARP is
# answered by the stack below the firewall, which is why the neighbor table
# knew about that host all along while every ping to it timed out.
gateway_answers() {
  busybox arping -c2 -w3 -I "$BRIDGE" "$1" >/dev/null 2>&1
}

# Is the address we want to take actually free? RFC 5227's probe: an ARP request
# for it sourced from 0.0.0.0, which is what -D sends. A reply means somebody
# already has it, and taking it anyway would break both of us.
#
# Sourcing from 0.0.0.0 matters. An ordinary arping would source from whatever
# the bridge currently holds - the link-local address - and a probe that carries
# a sender address is a claim, not a question.
address_is_free() {
  busybox arping -D -c2 -w3 -I "$BRIDGE" "$1" >/dev/null 2>&1
}

# Does traffic actually reach the internet through this bridge?
#
# The same two-stage check uplink-fallback.sh uses, for the same reason: some
# hosts firewall outbound ICMP while NAT-ing TCP perfectly, so a ping-only test
# would condemn a link that works. Bound to the interface, so this is a test of
# the USB path and not of whatever else the board might have up.
#
# -k, because the question is "did packets get there and come back", not "is
# this certificate valid for this name". The defaults answer to a bare IP -
# 1.1.1.1 and 8.8.8.8 both carry it in a SAN - but UNOQ_USB_PROBE_IPS is
# somebody else's to set, and without -k the first probe address whose
# certificate does not name it would fail TLS and be read here as "the host is
# not NAT-ing", which is the one conclusion this check must not reach wrongly.
routes_to_internet() {
  local ip
  for ip in $PROBES; do
    ping -c1 -W3 -I "$BRIDGE" "$ip" >/dev/null 2>&1 && return 0
  done
  if command -v curl >/dev/null 2>&1; then
    for ip in $PROBES; do
      curl --interface "$BRIDGE" --max-time 5 -sS -k -o /dev/null \
        "https://$ip/" >/dev/null 2>&1 && return 0
    done
  fi
  return 1
}

# --- detect ----------------------------------------------------------------

do_detect() {
  local name gw addr plen
  while read -r name gw addr plen; do
    [ -n "${name:-}" ] || continue
    is_ipv4 "${gw:-}" || continue
    if gateway_answers "$gw"; then
      printf '%s\n' "$name"
      return 0
    fi
  done < <(profiles)
  return 1
}

# --- up --------------------------------------------------------------------

# already_up <profile> <cidr> - is this profile the one claimed, with its
# address still on the bridge? Both, because the state file alone survives an
# address somebody else removed.
already_up() {
  local name cidr _gw
  [ -r "$STATE" ] || return 1
  read -r name cidr _gw <"$STATE"
  [ "$name" = "$1" ] && [ "$cidr" = "$2" ] || return 1
  ip -4 -o addr show dev "$BRIDGE" 2>/dev/null | grep -qF " $2 "
}

do_up() {
  local want="$1" row name gw addr plen

  row="$(profile_row "$want")" || {
    log "no such profile '$want'"
    return 1
  }
  read -r name gw addr plen <<<"$row"

  # Already up, and this is the re-check: usb-dhcp.sh calls `up` on every
  # leasefail, which on a host that serves no DHCP is about every 35 seconds
  # for as long as the cable is in. Each call used to prove the route from
  # scratch and, on one bad probe window, run `down` - taking the address, and
  # every SSH session over it, away from a link the host was still answering on
  # (detect has just seen it answer ARP, or this would not have been called).
  #
  # So a re-check never takes the address down. It only decides what the
  # route deserves: `prefer` promotes it with proof and demotes it without,
  # which is the right response to an internet that has gone away behind a
  # host that is still there - and it runs its own probe to decide. A cable
  # pulled out ends this through usb-dhcp.sh and the bridge going away, not
  # through here.
  if already_up "$name" "$addr/$plen"; then
    "$HERE/usb-route.sh" prefer "$gw" >/dev/null
    return 0
  fi

  if ! address_is_free "$addr"; then
    # Somebody answered for the address we were going to take. That is a real
    # possibility rather than a formality: the host's DHCP may have come back
    # and leased it to something, or a second board is plugged into the same
    # machine. Link-local is the correct answer here - it has collision
    # detection of its own and will find a free address by itself.
    log "$addr is already in use on $BRIDGE - not claiming it"
    return 1
  fi

  if ! ip addr replace "$addr/$plen" dev "$BRIDGE" 2>/dev/null; then
    log "could not put $addr/$plen on $BRIDGE"
    return 1
  fi
  # Written before the route goes in, so `down` can undo a half-finished `up`.
  printf '%s %s/%s %s\n' "$name" "$addr" "$plen" "$gw" >"$STATE"
  log "$BRIDGE += $addr/$plen (profile $name - the host is not serving DHCP)"

  "$HERE/usb-route.sh" add "$gw" >/dev/null

  if ! routes_to_internet; then
    # A gateway that answers ARP but forwards nothing. Worth saying plainly,
    # because it is the difference between "ICS is off" and "ICS is half on",
    # and the fix is at the other end either way.
    log "$gw answers on $BRIDGE but nothing routes through it - giving the address back"
    # And actually give it back, here, rather than leaving that to whoever
    # called. usb-dhcp.sh does call `down` on this path, but a caller having to
    # remember is a caller that can forget - and running this by hand is the
    # case where nobody is going to. `down` after this is a no-op, by design:
    # the state file it keys off is gone.
    do_down "$name"
    return 1
  fi

  log "internet reachable through $gw - the USB link is carrying traffic"
  # Only now, with a packet's worth of proof, is this route allowed to outrank
  # a real one. usb-route.sh owns that decision; see the metric note there.
  "$HERE/usb-route.sh" prefer "$gw" >/dev/null
  return 0
}

# --- down ------------------------------------------------------------------

do_down() {
  local want="${1:-}" name cidr gw
  [ -r "$STATE" ] || return 0
  read -r name cidr gw <"$STATE"
  # A named argument has to match what is actually on the bridge. Tearing down
  # "windows-ics" while "macos-sharing" is what got claimed would leave the
  # address on and the state file gone, which is the one unrecoverable mess
  # here - nothing would know to remove it afterwards.
  if [ -n "$want" ] && [ "$want" != "$name" ]; then
    log "asked to remove $want but $name is what is up - leaving it alone"
    return 1
  fi
  [ -n "${cidr:-}" ] && ip addr del "$cidr" dev "$BRIDGE" 2>/dev/null
  [ -n "${gw:-}" ] && "$HERE/usb-route.sh" del "$gw" >/dev/null 2>&1
  rm -f "$STATE"
  log "profile $name removed from $BRIDGE"
  return 0
}

# --- entry point -----------------------------------------------------------

case "${1:-}" in
  detect)
    [ "$ENABLED" = "1" ] || exit 1
    do_detect
    ;;
  # No root check on `up`/`down`, matching usb-route.sh. Both are called by
  # usb-dhcp.sh, which udhcpc already runs as root, and a check here would only
  # fire for someone running it by hand - who gets a plain ip(8) permission
  # error, which says the same thing more precisely.
  up)
    [ "$ENABLED" = "1" ] || {
      log "disabled (UNOQ_USB_PROFILE_FALLBACK=0)"
      exit 1
    }
    do_up "${2:?usage: usb-profile.sh up <profile>}"
    ;;
  down)
    do_down "${2:-}"
    ;;
  list)
    profiles
    ;;
  *)
    echo "usage: $(basename "$0") {detect|up <profile>|down [profile]|list}" >&2
    exit 2
    ;;
esac
