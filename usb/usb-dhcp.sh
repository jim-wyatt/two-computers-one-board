#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Take an address from the computer on the other end of the USB cable. Called
# by udhcpc, not by you.
#
#   busybox udhcpc -i br-usb -s /home/arduino/two-computers-one-board/usb/usb-dhcp.sh
#   argv: <deconfig|bound|renew|nak|leasefail>
#   env:  $interface $ip $subnet $router $dns $lease
#
# WHY THE BOARD IS THE CLIENT
# ---------------------------
# Because the two hosts we do not control are not negotiable. Windows Internet
# Connection Sharing pins its shared adapter to 192.168.137.1/24 and runs its own
# DHCP server there; macOS Internet Sharing does the same at 192.168.2.1. Neither
# will ever ask us for a lease. A board that wants internet over the cable has to
# take the address, the gateway and the DNS servers from whatever the host is
# running, so that is what this does. Nothing here is hardcoded to Microsoft's
# numbering: the same code works for macOS, for a Linux host running its own
# dnsmasq, and for whatever ICS is changed to next.
#
# WHEN NOBODY IS SERVING - LINK-LOCAL
# -----------------------------------
# `leasefail` is not an error to log and forget. It is the cable plugged into a
# computer that is not sharing anything, and it used to be the case a static
# 10.55.0.1 on the bridge existed to cover.
#
# It is covered by IPv4 link-local instead, which is the same answer every
# desktop OS already reaches on its own: Windows, macOS and Linux all self-assign
# 169.254.x.y when their DHCP finds nothing. So both ends land on the same /16 by
# themselves, with no host configuration at all - where 10.55.0.1 needed a static
# route typed in at the other end, elevated, before anything could reach the
# board.
#
# avahi makes it typeable. <hostname>.local resolves to whichever address this
# link ended up with, leased or link-local, on all three OSes with nothing
# installed. That only works because there is now exactly ONE address on this
# bridge: avahi advertises every address an interface has, and the old pair meant
# two A records with the host free to pick the one it had no route to.
#
# So: link-local goes on when DHCP gives up, and comes off the moment a real
# lease arrives. Never both.
#
# AND BEFORE LINK-LOCAL, THE HOST PROFILE
# ---------------------------------------
# Link-local has one weakness, and it is the one that matters to somebody who
# plugged the cable in to get online: it has no gateway, and RFC 3927 forbids
# routing off-link through a 169.254 next hop. The board is reachable from that
# one computer and from nowhere else.
#
# There is a host that deserves better than that, and it is not rare - it is a
# Windows box whose ICS is NAT-ing perfectly while its DHCP half answers
# nothing. The gateway is up, it forwards, and the only thing missing is the
# address. usb-profile.sh recognizes that host by ARP, takes an address on its
# subnet, and keeps it only if a packet actually reaches the internet.
#
# So the order on leasefail is: a recognized host that routes, else link-local.
# Still exactly one address on the bridge, whichever it is.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ENABLED="${UNOQ_USB_DEFAULT_ROUTE:-1}"
# Overridable only so the tests do not write into /run; nothing in the running
# system sets it, and status.sh reads the default path literally.
STATE="${UNOQ_USB_DHCP_STATE:-/run/unoq-usb-dhcp.state}"
# Survives a reboot, unlike the one above, and exists for one reason: so the
# board asks for the same address it had last time. "What do I ssh to?" has to
# have a durable answer on a board whose whole point is that wifi is off, and a
# lease that moves after every power cut - which on this board is every cable
# change - does not give you one. See usb-net-up.sh, which passes it to udhcpc.
LAST="${UNOQ_STATE_DIR:-/var/lib/unoq}/usb-dhcp-last"
# Written by usb-profile.sh when it claims an address on a host that will not
# lease one: "<profile> <addr>/<plen> <gateway>". Read here for the gateway,
# which is the only nameserver a self-assigned address comes with.
PROFILE_STATE="${UNOQ_USB_PROFILE_STATE:-/run/unoq-usb-profile.state}"
RESOLV="${UNOQ_RESOLV_CONF:-/etc/resolv.conf}"
# Where DNS goes when the host on the other end of the cable does not do DNS.
# Cloudflare then Google, the same pair the reachability probes use, so a board
# that has proved it can reach 1.1.1.1 is pointed at something it has just
# pinged. Set UNOQ_USB_DNS_PUBLIC="" to refuse the fallback entirely.
DNS_PUBLIC="${UNOQ_USB_DNS_PUBLIC:-1.1.1.1 8.8.8.8}"
# The name looked up to decide whether a nameserver is answering. It has to be
# one that exists, because "does not resolve" and "does not exist" come back as
# the same failure - example.com is reserved by IANA for exactly this and is not
# going anywhere.
DNS_PROBE_NAME="${UNOQ_USB_DNS_PROBE_NAME:-example.com}"
# Five seconds, matching the reachability probes rather than a resolver's usual
# patience. A gateway with no resolver behind it does not refuse the query, it
# drops it, so this whole timeout is spent on every check the fallback exists
# for - and udhcpc will not process the next lease event until this script
# returns. Long enough for a cold answer over a NAT, short enough to bound that.
DNS_TIMEOUT="${UNOQ_USB_DNS_TIMEOUT:-5}"
# Overridable for the same reason as UNOQ_AUTOIPD above: a name is not a seam,
# and "what happens on a board that has no nslookup" is a behavior worth being
# able to test rather than reason about.
NSLOOKUP="${UNOQ_NSLOOKUP:-nslookup}"
# udhcpc exports this; default it once here rather than at every use, because
# under `set -u` an unset $interface is a crash rather than a fallback, and the
# link-local helpers below are reached on the path where udhcpc is least happy.
interface="${interface:-${UNOQ_USB_BRIDGE:-br-usb}}"
# An absolute path, not `command -v`. avahi-autoipd installs to /usr/sbin, which
# is not on an ordinary user's PATH, so `command -v avahi-autoipd` reports it
# missing on a board where it is installed and working. status.sh keeps its own
# copy of this line for the same reason, and it is the one that matters most:
# that script is meant to run without root, where /usr/sbin is absent from PATH.
AUTOIPD="${UNOQ_AUTOIPD:-/usr/sbin/avahi-autoipd}"

log() {
  logger -t unoq-usb-dhcp "$*" 2>/dev/null
  echo "unoq-usb-dhcp: $*"
}

# The lease arrives from a machine we do not control, and every value below is
# about to be handed to ip(8) as root. Anything that is not plainly an address
# is dropped rather than escaped - there is no legitimate lease that needs it.
is_ipv4() {
  case "$1" in
    '' | *[!0-9.]*) return 1 ;;
    *.*.*.*) return 0 ;;
    *) return 1 ;;
  esac
}

# --- DNS -------------------------------------------------------------------
#
# Only when this link is actually carrying the board's traffic. NetworkManager
# owns /etc/resolv.conf on this image (dns=default, systemd-resolved is off), so
# writing it is taking something off NM - fine when the USB cable is the only
# uplink, and a regression if wifi is up, because unplugging the cable would
# then leave the board pointing at a nameserver it can no longer reach.
#
# "Actually carrying it" is decided by the routing table rather than by a flag,
# which makes it self-correcting: turn wifi off and the next renew takes DNS
# over, turn it back on and the next one hands it back. It is why wifi.sh kicks
# a renew rather than editing resolv.conf itself.
#
# This asks WHICH INTERFACE wins, rather than comparing our metric to a number.
# It used to do the latter - "is the best metric >= 700" - which was a correct
# reading of the routing table only while our route was always the worst one on
# it. usb-route.sh's `prefer` broke that assumption the day it was added: a
# promoted route is metric 550, the best default route on the board becomes
# 550, and `550 >= 700` is false - so the check would conclude the USB link was
# NOT carrying traffic at the exact moment it had just taken it over, and hand
# resolv.conf back to NetworkManager. Comparing devices cannot rot that way.
usb_route_is_the_default() {
  local best_dev
  best_dev="$(ip -4 route show default 2>/dev/null |
    awk '{
      m = 1024; d = ""
      for (i = 1; i <= NF; i++) {
        if ($i == "metric") m = $(i + 1)
        if ($i == "dev") d = $(i + 1)
      }
      if (d != "") print m, d
    }' | sort -n | head -1 | awk '{print $2}')"
  [ -n "$best_dev" ] && [ "$best_dev" = "$interface" ]
}

# Does this nameserver actually answer a query? Asked of the address directly,
# so it tests that resolver rather than whatever resolv.conf currently says.
#
# `timeout` rather than nslookup's own flags: this runs with busybox nslookup on
# a board with no dnsutils just as often as with bind9's, and the two disagree
# about which timeout options they take. They agree about "name, then server".
dns_answers() {
  timeout "$DNS_TIMEOUT" "$NSLOOKUP" "$DNS_PROBE_NAME" "$1" >/dev/null 2>&1
}

# A verified list of nameservers to write, given the ones this link offered.
#
# WHY THE LINK'S OWN NAMESERVER IS NOT TAKEN ON TRUST
# ---------------------------------------------------
# Because the host this whole fallback path exists for is a host with half its
# services working. Windows ICS NATs perfectly while answering no DHCP - that is
# what usb-profile.sh is for - and the same adapter answers no DNS on the
# gateway address either, since the DNS proxy is the other half of the service
# that is not running. A Linux host NAT-ing with plain nftables never had a
# resolver on that address to begin with.
#
# Pointing resolv.conf at that gateway anyway gives the worst-shaped failure in
# this file: traffic routes, `ping 8.8.8.8` works, and every name lookup hangs
# until it times out. "apt does not work but the network is fine" is a long
# afternoon, and it is indistinguishable at the terminal from the wifi-off
# symptom that wifi.sh's renew kick already exists to prevent.
#
# So the nameserver is asked a question before it is written down, and if it
# cannot answer, DNS goes to a public resolver over the link that has already
# been proved to carry traffic. Routing and resolving are separate capabilities
# and this is the one host that has one without the other.
#
# It ASSIGNS its answer - RESOLVERS for the list, DNS_NOTE for the reason - and
# logs nothing itself. Both are deliberate:
#
# An earlier version printed the list and was read through a command
# substitution, so the first log line it emitted went into resolv.conf as a
# nameserver. That is not a hypothetical either; it happened on the board this
# was written on, and produced a resolv.conf of eleven English words.
#
# Leaving the logging to the caller is what keeps the journal readable. This
# runs on every lease event, and on a host that serves no DHCP that is every 35
# seconds for as long as the cable is in. write_resolv says the reason when the
# file actually changes, which is when somebody would want to read it.
choose_resolvers() {
  local candidates="$1" answering="" public="" s
  RESOLVERS="$candidates"
  DNS_NOTE=""
  # No nslookup - no verification, and the old behavior rather than a guess.
  # A board that cannot ask the question has not learned that the answer is no.
  command -v "$NSLOOKUP" >/dev/null 2>&1 || return 0
  for s in $candidates; do
    dns_answers "$s" && answering="$answering $s"
  done
  if [ -n "$answering" ]; then
    RESOLVERS="$answering"
    return 0
  fi
  for s in $DNS_PUBLIC; do
    is_ipv4 "$s" && public="$public $s"
  done
  for s in $public; do
    dns_answers "$s" || continue
    # All of them, not just the one that answered. The check is a spot check;
    # what goes in the file should still have a second entry to fall to.
    RESOLVERS="$public"
    DNS_NOTE="the host on $interface answers no DNS - resolving through$public instead"
    return 0
  done
  # Neither end answered. The link's own nameserver goes in anyway, because the
  # honest reading of "nothing answers" on a link that has only just come up is
  # that the check was early - and this is written on every lease event, so a
  # resolver that starts working gets picked up on the next one.
  DNS_NOTE="no nameserver answers on $interface - keeping$candidates for now"
}

write_resolv() {
  local servers="$1" tmp chosen="" s
  for s in $servers; do
    is_ipv4 "$s" || continue
    chosen="$chosen $s"
  done
  # ICS proxies DNS on the gateway itself when it is working, so a lease with no
  # option 6 is still usable - fall back to the router rather than leaving no
  # resolver at all. Whether it IS working is decided below, not here.
  if [ -z "$chosen" ] && is_ipv4 "${router:-}"; then
    chosen=" $router"
  fi
  [ -n "$chosen" ] || return 1
  choose_resolvers "$chosen"
  chosen="$RESOLVERS"
  [ -n "$chosen" ] || return 1
  tmp="$(mktemp)" || return 1
  {
    echo "# Written by unoq usb-dhcp.sh - the USB gadget link is this board's"
    echo "# only uplink. NetworkManager takes this file back when wifi returns."
    for s in $chosen; do
      echo "nameserver $s"
    done
  } >"$tmp"
  if cmp -s "$tmp" "$RESOLV"; then
    rm -f "$tmp"
    return 0
  fi
  if install -m 0644 "$tmp" "$RESOLV"; then
    [ -n "$DNS_NOTE" ] && log "$DNS_NOTE"
    log "resolv.conf ->$chosen"
  fi
  rm -f "$tmp"
}

# Hand the file back rather than leaving the board pointing at a gateway that
# has gone away. NM regenerates it from its own state, which is the correct
# content for whatever connections it still has - including none.
restore_resolv() {
  grep -q "^# Written by unoq usb-dhcp.sh" "$RESOLV" 2>/dev/null || return 0
  if command -v nmcli >/dev/null 2>&1 && nmcli general reload dns-rc 2>/dev/null; then
    log "resolv.conf handed back to NetworkManager"
  fi
}

# --- link-local, for when no DHCP server answers ----------------------------
#
# avahi-autoipd rather than picking a 169.254 address ourselves, because RFC 3927
# is more than choosing one: it probes with ARP before claiming, defends the
# claim afterwards, and gives up and re-picks on a conflict. A board that skipped
# that would occasionally collide with the very host it is plugged into - the
# host self-assigns from the same /16 for the same reason, at the same moment,
# on the same wire.
#
# It brings its own address up and takes it down again through the packaged
# action script, so there is nothing to clean up here beyond stopping it.
autoipd_start() {
  [ -x "$AUTOIPD" ] || {
    log "no avahi-autoipd - this link has no address until the host serves DHCP"
    return 1
  }
  # --check first: this runs again on every leasefail, and a second daemon would
  # be a second claimant defending the same address against the first.
  if "$AUTOIPD" --check "$interface" 2>/dev/null; then
    return 0
  fi
  # No --force-bind, deliberately. Its default is to refuse when the interface
  # already holds a routable address, which is exactly the check we want: if a
  # lease landed between the failure and here, the lease wins.
  if "$AUTOIPD" --daemonize --syslog "$interface" 2>/dev/null; then
    log "no DHCP server on $interface - claiming a link-local address instead"
  else
    log "could not start avahi-autoipd on $interface"
    return 1
  fi
}

autoipd_stop() {
  [ -x "$AUTOIPD" ] || return 0
  "$AUTOIPD" --check "$interface" 2>/dev/null || return 0
  # --kill runs the action script on the way out, so the 169.254 address is
  # removed rather than left alongside the lease we just took. Two addresses on
  # this bridge is the state mDNS cannot give a single answer for.
  "$AUTOIPD" --kill "$interface" 2>/dev/null &&
    log "link-local released on $interface - a real lease supersedes it"
}

# --- lease events ----------------------------------------------------------

case "${1:-}" in
  deconfig)
    # udhcpc's "I am starting, or I have lost the lease". Remove only the
    # address we ourselves put on, which is why it was written down: flushing
    # the interface would take a link-local address with it, and that is the
    # one keeping the board reachable in exactly this situation.
    ip link set "$interface" up 2>/dev/null
    if [ -r "$STATE" ]; then
      read -r old_cidr old_router <"$STATE"
      [ -n "${old_cidr:-}" ] && ip addr del "$old_cidr" dev "$interface" 2>/dev/null
      [ -n "${old_router:-}" ] && "$HERE/usb-route.sh" del "$old_router" >/dev/null 2>&1
      rm -f "$STATE"
      log "lease released on $interface"
    fi
    restore_resolv
    ;;

  bound | renew)
    is_ipv4 "${ip:-}" || {
      log "ignoring lease with implausible address '${ip:-}'"
      exit 0
    }
    # Before the address goes on, not after: for the moment in between there
    # would be a lease and a link-local address on one bridge, which is the
    # two-A-record state that makes <hostname>.local a coin flip.
    autoipd_stop
    # Same rule, other fallback. If the host's DHCP was dead when we last
    # looked, usb-profile.sh will have claimed an address on its subnet - and a
    # lease arriving now supersedes it exactly as it supersedes link-local. It
    # also has to go before the lease lands, and for a sharper reason than the
    # A records: the profile address is one we assigned ourselves on the host's
    # subnet, and leaving it there alongside a lease is two addresses on one
    # /24 with only one of them known to the host that issued the other.
    "$HERE/usb-profile.sh" down >/dev/null 2>&1
    # busybox gives the mask as dotted quad; ip(8) wants a prefix length.
    mask="${subnet:-255.255.255.0}"
    case "$mask" in
      255.255.255.0) plen=24 ;;
      255.255.0.0) plen=16 ;;
      255.0.0.0) plen=8 ;;
      255.255.255.128) plen=25 ;;
      255.255.255.192) plen=26 ;;
      255.255.255.224) plen=27 ;;
      255.255.255.240) plen=28 ;;
      255.255.255.248) plen=29 ;;
      255.255.255.252) plen=30 ;;
      # Anything else is unusual enough on a point-to-point USB link that
      # guessing is worse than taking the common case and saying so.
      *)
        plen=24
        log "unrecognized netmask '$mask' - assuming /24"
        ;;
    esac

    # `replace`, so a renew of the same address is a no-op rather than an error.
    if ip addr replace "$ip/$plen" dev "$interface" 2>/dev/null; then
      [ "$1" = bound ] && log "$interface += $ip/$plen (leased by the host)"
    else
      log "could not set $ip/$plen on $interface"
    fi
    printf '%s %s\n' "$ip/$plen" "${router:-}" >"$STATE"
    mkdir -p "$(dirname "$LAST")" 2>/dev/null
    printf '%s\n' "$ip" >"$LAST"

    # The route, and therefore the metric, is usb-route.sh's business - one
    # place that decides how the gadget ranks against a real link.
    if [ "$ENABLED" = "1" ] && is_ipv4 "${router:-}"; then
      "$HERE/usb-route.sh" "$([ "$1" = bound ] && echo add || echo old)" "$router" >/dev/null
      # Then ask whether it has earned the right to beat wifi. Every lease event
      # re-runs the check, which is what makes the promotion self-correcting: a
      # host that stops forwarding gets demoted on the next renew rather than
      # holding the default route on the strength of having worked once.
      "$HERE/usb-route.sh" prefer "$router" >/dev/null
    fi

    if [ "$ENABLED" = "1" ] && usb_route_is_the_default; then
      write_resolv "${dns:-}" || log "lease carried no usable DNS server"
    else
      restore_resolv
    fi
    ;;

  nak)
    # A refusal, and the one refusal we can name in advance: the cable moved to
    # a different computer. usb-net-up.sh opens by asking for the address this
    # link had last time, and Windows ICS numbers from 192.168.137.0/24 while
    # macOS Internet Sharing numbers from 192.168.2.0/24 - neither will lease an
    # address out of the other's subnet, so the very first request after a swap
    # is the one that gets NAKed.
    #
    # So stop remembering it. The running client recovers by itself - it goes
    # back to discovery and `bound` writes down whatever this host actually
    # offers - but the file is read once at STARTUP, so without this every
    # restart on the new host opens by asking for the old host's address again
    # and taking another refusal to get past it.
    #
    # Forgetting costs nothing when the NAK was not a swap: the address is a
    # request, not a claim, and a host that refused it once was not going to
    # honor it the second time either.
    log "DHCP NAK from the host - the lease was refused"
    if [ -e "$LAST" ]; then
      refused=""
      [ -r "$LAST" ] && read -r refused <"$LAST"
      # Both outcomes are logged. A failed rm leaves the board doing exactly
      # what this branch exists to stop - asking for the refused address again
      # after every reboot - and the whole value of the branch is that it says
      # so somewhere a person will read it.
      if rm -f "$LAST"; then
        log "forgetting ${refused:-the remembered address} - asking fresh from here"
      else
        log "could not remove $LAST - the next start will ask for ${refused:-the same address} again"
      fi
    fi
    ;;

  leasefail)
    # Normal while the cable is out or the host has not brought its shared
    # adapter up yet, and udhcpc keeps retrying by itself either way. What is
    # NOT normal is leaving the board with no address while it retries, so this
    # is where the two fallbacks come up. If a lease turns up later, `bound`
    # takes whichever one is in place straight back down again.
    log "no DHCP offer on $interface yet - is the host sharing its connection?"

    # A known host is the better fallback, because it comes with a GATEWAY.
    # Link-local never can: RFC 3927 forbids using a 169.254 next hop for
    # off-link traffic, so a board on link-local can reach the one computer it
    # is plugged into and nothing beyond it. If usb-profile.sh recognizes what
    # is on the other end and can prove traffic gets out through it, that is
    # worth strictly more than an address nobody can route.
    #
    # detect is read-only, so nothing is disturbed when it finds nothing - which
    # is the common case, and the one that must stay cheap.
    #
    # stderr is NOT suppressed, and that is deliberate: the first run of this
    # went straight past with no explanation because usb-profile.sh had been
    # written without its execute bit, and "permission denied" was the one line
    # that would have said so. A failure here is meant to be a quiet fall
    # through to link-local, not a silent one.
    if profile="$("$HERE/usb-profile.sh" detect)" && [ -n "$profile" ]; then
      log "the host on $interface looks like $profile - trying its addressing"
      # Link-local first, because there is exactly one address on this bridge
      # and the profile is about to be it. This ordering is the whole invariant.
      autoipd_stop
      if "$HERE/usb-profile.sh" up "$profile"; then
        # DNS, on the same terms as a lease. There is no lease here to carry
        # option 6, so the gateway is the only nameserver on offer - which is
        # exactly what write_resolv falls back to, and it is asked to prove it
        # answers before it is written down. That check matters most on this
        # path: a host that is not serving DHCP is a host with half its sharing
        # stack off, and the DNS proxy is usually the other half. Public
        # resolvers take over when it cannot answer.
        #
        # Without this the board routes over the cable and resolves over wifi,
        # which works until wifi goes off and then fails as "ping 8.8.8.8 works,
        # apt does not" - the symptom wifi.sh's renew kick exists to prevent.
        if [ "$ENABLED" = "1" ] && [ -r "$PROFILE_STATE" ]; then
          read -r _ _ router <"$PROFILE_STATE"
          if is_ipv4 "${router:-}" && usb_route_is_the_default; then
            write_resolv "" || log "no usable nameserver on this link"
          fi
        fi
        exit 0
      fi
      # It did not work out - the address was taken, or the gateway answered
      # and forwarded nothing. Undo it and fall through, so the board still ends
      # up reachable from the machine it is plugged into.
      "$HERE/usb-profile.sh" down "$profile" >/dev/null 2>&1
      log "$profile did not produce a working route - falling back to link-local"
    fi

    autoipd_start
    ;;
esac
exit 0
