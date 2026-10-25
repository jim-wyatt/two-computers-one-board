#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# usb/usb-dhcp.sh is udhcpc's handler script. These tests cover two things it
# does.
#
# THE REMEMBERED ADDRESS in /var/lib/unoq/usb-dhcp-last, which is what
# `udhcpc --request` asks for at startup so the numeric address survives a
# reboot.
#
# The interesting case is the cable moving between a PC and a Mac. Windows ICS
# shares from 192.168.137.0/24 and macOS Internet Sharing from 192.168.2.0/24,
# and neither will lease an address out of the other's subnet - so the first
# request after a swap is refused. The running client recovers by itself, which
# is why this was easy to miss: the file is read ONCE, at startup, so a refusal
# left on disk is one the board repeats after every reboot until a lease
# happens to overwrite it.
#
# Three tests, because "a NAK deletes a file" is satisfiable by deleting the
# file at every opportunity. What makes it a behavior is that `bound` writes
# it and `deconfig` - which runs on every stop and every start - leaves it
# alone.
#
# AND RESOLV.CONF, which is the other thing a lease hands over and the one that
# fails least visibly. The host that this link most often meets is a Windows box
# sharing its connection with half the stack running: it NATs, and it answers
# neither DHCP nor DNS. Writing its gateway down as the nameserver on that
# evidence produces a board that routes and cannot resolve - `ping 8.8.8.8`
# works, `apt` hangs - so the nameserver is asked a question first and DNS goes
# public when it cannot answer.

setup() {
  load helpers/stub
  stub_setup

  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DHCP="$PROJECT/usb/usb-dhcp.sh"

  stub logger
  stub ip

  # Everything the script touches outside its own directory, redirected into
  # the test's tmpdir: the remembered address, the volatile lease state, and
  # resolv.conf. UNOQ_AUTOIPD points at a file that does not exist, so the
  # link-local helpers take their "not installed" path rather than reaching for
  # a real daemon.
  export UNOQ_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export UNOQ_USB_DHCP_STATE="$BATS_TEST_TMPDIR/lease.state"
  export UNOQ_RESOLV_CONF="$BATS_TEST_TMPDIR/resolv.conf"
  export UNOQ_AUTOIPD="$BATS_TEST_TMPDIR/no-such-autoipd"
  export interface=br-usb

  export UNOQ_USB_PROFILE_STATE="$BATS_TEST_TMPDIR/profile.state"

  LAST="$UNOQ_STATE_DIR/usb-dhcp-last"
  mkdir -p "$UNOQ_STATE_DIR"
  : >"$UNOQ_RESOLV_CONF"
}

# --- the DNS half -----------------------------------------------------------
#
# resolv.conf is only written when the USB link is the default route, so the
# routing table has to say so. `stub ip` answers nothing, which reads as "no
# default route at all" - correct for the tests above, useless for these.
usb_is_the_uplink() {
  stub_body ip <<'SH'
case "$*" in
  "-4 route show default") echo "default via 192.168.137.1 dev br-usb metric 550" ;;
esac
exit 0
SH
  # usb-route.sh runs for real here, and its `prefer` probes the internet.
  stub ping 0
  stub curl 0
}

# The nameserver probe: `timeout <n> nslookup <name> <server>`.
#
# timeout is shadowed by a passthrough rather than stubbed out, so the decision
# still reaches the nslookup stub and the argv of both is on record.
#
#   DNS_ANSWERS="a.b.c.d ..."  - these servers resolve; anything else does not.
fake_dns() {
  stub_body timeout <<'SH'
shift
exec "$@"
SH
  stub_body nslookup <<SH
case " ${DNS_ANSWERS:-} " in *" \${2:-} "*) exit 0 ;; esac
exit 1
SH
}

# The nameservers actually written, in order.
resolvers() {
  sed -n 's/^nameserver //p' "$UNOQ_RESOLV_CONF" | tr '\n' ' '
}

lease() {
  run env ip=192.168.137.210 subnet=255.255.255.0 router=192.168.137.1 "$@" "$DHCP" bound
}

@test "a lease is written down for the next startup to ask for" {
  run env ip=192.168.137.42 subnet=255.255.255.0 "$DHCP" bound
  [ "$status" -eq 0 ]
  [ "$(cat "$LAST")" = "192.168.137.42" ]
}

@test "a NAK forgets the remembered address" {
  # The Windows address, refused by the Mac the cable was just moved to.
  echo "192.168.137.42" >"$LAST"
  run "$DHCP" nak
  [ "$status" -eq 0 ]
  [ ! -e "$LAST" ]
}

@test "the NAK log names the address it gave up on" {
  # Not decoration. A board that quietly stopped asking for the address someone
  # had written on a sticky note should say so where `app logs` will show it.
  echo "192.168.137.42" >"$LAST"
  run "$DHCP" nak
  [[ "$output" == *"192.168.137.42"* ]]
}

@test "a NAK that cannot forget says so" {
  # The failure mode is silence: the file stays, the board keeps asking for the
  # refused address after every reboot, and the only sign was a log line that
  # did not appear. Whatever went wrong with the filesystem, this has to say
  # which file it could not remove.
  [ "$(id -u)" -eq 0 ] && skip "root writes through a read-only directory"
  echo "192.168.137.42" >"$LAST"
  chmod a-w "$UNOQ_STATE_DIR"
  run "$DHCP" nak
  chmod u+w "$UNOQ_STATE_DIR"
  [ "$status" -eq 0 ]
  [ -e "$LAST" ]
  [[ "$output" == *"could not remove"* ]]
  [[ "$output" == *"$LAST"* ]]
}

@test "a NAK with nothing remembered is still a clean exit" {
  # The ordinary case on a board that has never held a lease on this link.
  [ ! -e "$LAST" ]
  run "$DHCP" nak
  [ "$status" -eq 0 ]
}

@test "deconfig keeps the remembered address" {
  # deconfig runs at every udhcpc startup and every shutdown. If it forgot the
  # address, the sticky address would never survive the one thing it exists to
  # survive - a reboot.
  echo "192.168.137.42" >"$LAST"
  run "$DHCP" deconfig
  [ "$status" -eq 0 ]
  [ "$(cat "$LAST")" = "192.168.137.42" ]
}

@test "a fresh lease after the refusal is the one remembered" {
  # The whole sequence: Windows address on disk, cable moved to a Mac, its
  # server refuses, its lease lands. What is left is the Mac's address, with no
  # trace of the PC's.
  echo "192.168.137.42" >"$LAST"
  run "$DHCP" nak
  [ "$status" -eq 0 ]
  run env ip=192.168.2.7 subnet=255.255.255.0 "$DHCP" bound
  [ "$status" -eq 0 ]
  [ "$(cat "$LAST")" = "192.168.2.7" ]
}

# --- resolv.conf: the nameserver has to answer ------------------------------

@test "a gateway that resolves is the nameserver written down" {
  # The ordinary case, and the reason the gateway is a candidate at all: ICS
  # proxies DNS on the same address it NATs from, so a lease with no option 6
  # is still perfectly usable.
  usb_is_the_uplink
  DNS_ANSWERS="192.168.137.1" fake_dns
  lease
  [ "$status" -eq 0 ]
  [ "$(resolvers)" = "192.168.137.1 " ]
}

@test "a gateway that does NOT answer DNS is replaced by public resolvers" {
  # The load-bearing one. A host NAT-ing with its DNS proxy off gives a board
  # that routes and cannot resolve, which reads at the terminal as "the network
  # is fine but apt is broken" - the single most misleading state this link has.
  usb_is_the_uplink
  DNS_ANSWERS="1.1.1.1 8.8.8.8" fake_dns
  lease
  [ "$status" -eq 0 ]
  [ "$(resolvers)" = "1.1.1.1 8.8.8.8 " ]
  [[ "$output" == *"answers no DNS"* ]]
}

@test "the public fallback is not taken while the link's own resolver works" {
  # It is a fallback, not a preference. Sending every lookup off the board when
  # the host is willing to answer them would be a change nobody asked for.
  usb_is_the_uplink
  DNS_ANSWERS="192.168.137.1 1.1.1.1" fake_dns
  lease
  [[ "$(resolvers)" != *"1.1.1.1"* ]]
}

@test "a lease's own DNS servers are checked, not just the gateway" {
  # Option 6 is a claim like any other. A host that hands out a nameserver
  # address it cannot reach itself is the same failure one step removed.
  usb_is_the_uplink
  DNS_ANSWERS="1.1.1.1 8.8.8.8" fake_dns
  lease dns=192.168.137.1
  [ "$(resolvers)" = "1.1.1.1 8.8.8.8 " ]
}

@test "a working lease nameserver is kept ahead of the gateway" {
  usb_is_the_uplink
  DNS_ANSWERS="10.0.0.53" fake_dns
  lease dns=10.0.0.53
  [ "$(resolvers)" = "10.0.0.53 " ]
}

@test "the whole public list is written, not just the one that answered" {
  # The probe is a spot check on one server. What ends up in the file should
  # still have a second entry to fall to when the first one stops answering.
  usb_is_the_uplink
  DNS_ANSWERS="8.8.8.8" fake_dns
  lease
  [ "$(resolvers)" = "1.1.1.1 8.8.8.8 " ]
}

@test "the public resolvers can be changed" {
  usb_is_the_uplink
  DNS_ANSWERS="9.9.9.9" fake_dns
  lease UNOQ_USB_DNS_PUBLIC=9.9.9.9
  [ "$(resolvers)" = "9.9.9.9 " ]
}

@test "UNOQ_USB_DNS_PUBLIC= refuses to send lookups off the board at all" {
  # For anyone who would rather have no DNS than DNS somebody else can see.
  # What is left is what the link offered, which is what it would have been
  # before any of this existed.
  usb_is_the_uplink
  DNS_ANSWERS="" fake_dns
  lease UNOQ_USB_DNS_PUBLIC=
  [ "$(resolvers)" = "192.168.137.1 " ]
}

@test "when nothing answers, the link's nameserver is kept rather than nothing" {
  # A resolv.conf with no nameserver in it resolves nothing at all, which is
  # strictly worse than one that might be early. This is rewritten on every
  # lease event, so a resolver that starts working is picked up on the next one.
  usb_is_the_uplink
  DNS_ANSWERS="" fake_dns
  lease
  [ "$(resolvers)" = "192.168.137.1 " ]
  [[ "$output" == *"no nameserver answers"* ]]
}

@test "the probe is bounded in time" {
  # udhcpc runs this script synchronously and will not process the next lease
  # event until it returns. An unbounded lookup against a host that drops packets
  # is a lease handler that never finishes.
  usb_is_the_uplink
  DNS_ANSWERS="192.168.137.1" fake_dns
  lease
  ran_like '^timeout [0-9]+ nslookup example\.com 192\.168\.137\.1$'
}

@test "a board with no nslookup writes what the link offered" {
  # No way to ask the question is not the same as an answer of no. Without this
  # the fallback would fire on every board that has no dnsutils and no busybox
  # nslookup, sending DNS public on links whose own resolver was fine.
  usb_is_the_uplink
  DNS_ANSWERS="1.1.1.1" fake_dns
  lease UNOQ_NSLOOKUP="$BATS_TEST_TMPDIR/no-such-nslookup"
  [ "$(resolvers)" = "192.168.137.1 " ]
  never_ran nslookup
}

@test "no resolv.conf is written when the USB link is not the uplink" {
  # NetworkManager owns the file. Taking it while wifi is carrying the traffic
  # would leave the board pointing at a gateway it loses when the cable comes
  # out - which is the regression the device check exists to prevent.
  stub_body ip <<'SH'
case "$*" in
  "-4 route show default") echo "default via 192.168.0.1 dev wlan0 metric 600" ;;
esac
exit 0
SH
  stub ping 0
  stub curl 0
  DNS_ANSWERS="1.1.1.1" fake_dns
  lease
  [ -z "$(resolvers)" ]
  never_ran nslookup
}

@test "a default route with no metric is metric 0, and beats ours" {
  # `ip route add default via X dev eth0` prints no metric, and for IPv4 that
  # means 0 - the kernel prefers it to anything. This ranked it as 1024, which
  # is IPv6's default, decided br-usb was the uplink, and took resolv.conf for
  # a link that was carrying nothing (#115).
  stub_body ip <<'SH'
case "$*" in
  "-4 route show default") printf '%s\n' \
    "default via 192.168.0.1 dev eth0" \
    "default via 192.168.137.1 dev br-usb metric 550" ;;
esac
exit 0
SH
  stub ping 0
  stub curl 0
  DNS_ANSWERS="1.1.1.1 192.168.137.1" fake_dns
  lease
  [ -z "$(resolvers)" ]
}

@test "a lease address that only looks like one is not written down" {
  # Digits and dots: 999.1.1.1 passed the check here and went into the file
  # the next startup hands to udhcpc as --request.
  run env ip=999.1.1.1 subnet=255.255.255.0 "$DHCP" bound
  [ ! -e "$LAST" ] || [ "$(cat "$LAST")" != "999.1.1.1" ]
}
