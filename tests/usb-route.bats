#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# usb/usb-route.sh is the lease hook usb-dhcp.sh calls. It runs as root, with an
# address that came off the wire, and it decides whether to move the board's
# DEFAULT ROUTE - which is the setting most able to break a machine remotely
# while leaving it looking fine.
#
# It has broken one already. The metric was 500, which BEAT NetworkManager's
# 600 for wifi, so plugging the board into a computer silently handed that
# computer the default route. SSH survived (a connected route on the LAN, not
# the default), so nothing looked wrong, while apt, git and every other
# outbound connection went to a host that was not NAT-ing.
#
# The metric test below is that bug, written down.

setup() {
  load helpers/stub
  stub_setup

  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  ROUTE="$PROJECT/usb/usb-route.sh"

  stub logger
  # `ip link show br-usb` is the "is the bridge still there" probe; everything
  # else is the action under test.
  stub_body ip <<'SH'
exit 0
SH
}

# The hook's argv: <action> <gateway-ip>. There was a <mac> between them while
# this was a dnsmasq --dhcp-script; dropping the DHCP server took the caller
# that supplied it with it.
lease() { run "$ROUTE" "$1" "${2-}"; }

@test "a new lease points the default route at the host that issued it" {
  lease add 192.168.137.1
  [ "$status" -eq 0 ]
  ran "ip route replace default via 192.168.137.1 dev br-usb metric 700"
}

@test "the metric is 700, so a real uplink keeps winning" {
  # 700 loses to wifi (600) and ethernet (100) and beats the kernel's 1024.
  # If this number ever drops below 600 again, the board will quietly route
  # the internet down a USB cable to a machine that may not be forwarding.
  lease add 192.168.137.1
  ran_like 'ip route replace default via [0-9.]+ dev br-usb metric 700$'
}

@test "a renewal re-asserts the route" {
  # `old` is what usb-dhcp.sh passes on a renew rather than a fresh bind.
  # Treating it as an event is what re-installs the route if something else
  # removed it between renewals, without waiting for a new lease.
  lease old 192.168.137.1
  [ "$status" -eq 0 ]
  ran "ip route replace default via 192.168.137.1 dev br-usb metric 700"
}

@test "replace, not add, so a renewing host does not stack routes or fail" {
  lease add 192.168.137.1
  refute ran_like 'ip route add default'
}

@test "a released lease withdraws only our own route" {
  # Matched on via, dev AND metric together, so a default route someone else
  # installed is never removed.
  lease del 192.168.137.1
  [ "$status" -eq 0 ]
  ran "ip route del default via 192.168.137.1 dev br-usb metric 700"
}

@test "the metric can be overridden" {
  export UNOQ_USB_ROUTE_METRIC=900
  lease add 192.168.137.1
  ran "ip route replace default via 192.168.137.1 dev br-usb metric 900"
}

@test "the bridge name can be overridden" {
  export UNOQ_USB_BRIDGE=br-test
  lease add 192.168.137.1
  ran "ip route replace default via 192.168.137.1 dev br-test metric 700"
}

# --- the escape hatch -------------------------------------------------------

@test "UNOQ_USB_DEFAULT_ROUTE=0 means the route is never touched" {
  # The documented way to say "give me the link, keep my routing". If this
  # regresses, the setting silently stops working, which is worse than not
  # offering it.
  export UNOQ_USB_DEFAULT_ROUTE=0
  lease add 192.168.137.1
  [ "$status" -eq 0 ]
  never_ran ip
}

@test "the escape hatch also covers lease release" {
  export UNOQ_USB_DEFAULT_ROUTE=0
  lease del 192.168.137.1
  never_ran ip
}

# --- events and inputs that must be ignored ---------------------------------

@test "actions we do not recognize are ignored" {
  # These were dnsmasq's - it called the same script for tftp and arp-* events.
  # The allowlist stays now that it has one caller, because the failure it
  # prevents is running ip(8) with an argument that is not an address at all.
  for action in tftp arp-add arp-del init ""; do
    : >"$STUB_LOG"
    lease "$action" 192.168.137.1
    [ "$status" -eq 0 ]
    never_ran ip
  done
}

@test "a missing address is ignored rather than passed to ip" {
  lease add
  [ "$status" -eq 0 ]
  never_ran ip
}

@test "an address-shaped check rejects obvious rubbish" {
  for bad in "hello" "-Version" "../etc/passwd" ";reboot"; do
    : >"$STUB_LOG"
    lease add "$bad"
    [ "$status" -eq 0 ]
    never_ran ip
  done
}

@test "nothing runs when the bridge has already gone" {
  # On shutdown the bridge may be torn down before the lease is released. Every
  # ip(8) call would then just print failures into the journal.
  stub_body ip <<'SH'
case "$1 $2" in "link show") exit 1 ;; esac
exit 0
SH
  lease add 192.168.137.1
  [ "$status" -eq 0 ]
  refute ran_like 'ip route'
}

@test "a route that cannot be set is reported, not swallowed" {
  stub_body ip <<'SH'
case "$1 $2" in
  "link show") exit 0 ;;
  "route replace") exit 2 ;;
esac
exit 0
SH
  lease add 192.168.137.1
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not set default route"* ]]
}

# --- prefer: the promotion, and why it needs proof --------------------------
#
# `prefer` is what makes plugging the cable in enough to use it, instead of
# having to turn wifi off by hand. It installs metric 550, which BEATS wifi's
# 600 - the same side of the line as the 500 that caused the bug this file
# opens with.
#
# The difference, and the only thing making it safe, is that it happens after a
# packet has reached the internet through the bridge. These tests are that
# condition. If promotion ever stops depending on the probe, the 500 bug is
# back with a different number on it.

@test "prefer promotes ahead of wifi once the internet answers" {
  stub ping 0
  lease prefer 192.168.137.1
  [ "$status" -eq 0 ]
  ran "ip route replace default via 192.168.137.1 dev br-usb metric 550"
}

@test "the promoted metric beats NetworkManager's 600 for wifi" {
  # 550 < 600 is the entire point of the action. Ethernet's 100 still wins.
  stub ping 0
  lease prefer 192.168.137.1
  ran_like 'ip route replace default via [0-9.]+ dev br-usb metric 550$'
}

@test "promoting removes the unpromoted route, so there is only one" {
  stub ping 0
  lease prefer 192.168.137.1
  ran "ip route del default via 192.168.137.1 dev br-usb metric 700"
}

@test "NO promotion when nothing answers through the bridge" {
  # The load-bearing test. A gateway that is present but not forwarding must
  # never get the default route ahead of a working wifi connection.
  stub ping 1
  stub curl 1
  lease prefer 192.168.137.1
  [ "$status" -eq 0 ]
  refute ran_like 'ip route replace default via [0-9.]+ dev br-usb metric 550'
}

@test "a link that stops working is demoted again" {
  # Promotion is not permanent. Every lease event re-runs this, so a host that
  # goes away loses the default route it was promoted to instead of keeping it
  # on the strength of having worked once.
  stub ping 1
  stub curl 1
  lease prefer 192.168.137.1
  ran "ip route del default via 192.168.137.1 dev br-usb metric 550"
  ran "ip route replace default via 192.168.137.1 dev br-usb metric 700"
}

@test "the probe is bound to the bridge, not just to the internet at large" {
  # Without -I br-usb this would answer "yes" whenever the board has wifi,
  # which is exactly when the question is being asked. It would promote the
  # USB route on the strength of the wifi it is about to overtake.
  stub ping 0
  lease prefer 192.168.137.1
  ran_like 'ping .*-I br-usb'
}

@test "TCP is tried when ICMP is dropped but the host still NATs" {
  # Windows firewalls outbound ping on some profiles while forwarding TCP
  # perfectly. Refusing to promote on that basis would refuse the common case.
  stub ping 1
  stub curl 0
  lease prefer 192.168.137.1
  ran_like 'curl .*--interface br-usb'
  # -k, because the question is whether packets got there and back, not whether
  # a certificate is valid for an address. Without it the first probe IP whose
  # certificate does not name it fails TLS and reads as "no internet", which
  # refuses to promote a link that works.
  ran_like 'curl .*-k'
  ran "ip route replace default via 192.168.137.1 dev br-usb metric 550"
}

@test "UNOQ_USB_PREFER_OVER_WIFI=0 keeps the old fallback-only behavior" {
  # The route is left exactly as `add` installed it. `ip link show` still runs -
  # that is the "is the bridge there" probe every action does first - so this
  # asserts on the routing table rather than on ip(8) being untouched.
  export UNOQ_USB_PREFER_OVER_WIFI=0
  stub ping 0
  lease prefer 192.168.137.1
  [ "$status" -eq 0 ]
  refute ran_like 'ip route'
  never_ran ping
}

@test "the promoted metric can be overridden" {
  export UNOQ_USB_ROUTE_METRIC_PREFERRED=120
  stub ping 0
  lease prefer 192.168.137.1
  ran "ip route replace default via 192.168.137.1 dev br-usb metric 120"
}

@test "releasing a lease withdraws the promoted route too" {
  # A promoted route left behind on release is a default route pointing at a
  # host that has gone away, at a priority that beats wifi. That is the worst
  # of the states this file exists to prevent.
  lease del 192.168.137.1
  ran "ip route del default via 192.168.137.1 dev br-usb metric 700"
  ran "ip route del default via 192.168.137.1 dev br-usb metric 550"
}

@test "prefer rejects rubbish addresses like every other action" {
  stub ping 0
  for bad in "hello" ";reboot" ""; do
    : >"$STUB_LOG"
    lease prefer "$bad"
    [ "$status" -eq 0 ]
    never_ran ip
  done
}

@test "an address-shaped string that is not an address is refused too" {
  # The pattern was [0-9]*.[0-9]*.[0-9]*.[0-9]*, which every one of these
  # matches. They come off the wire and go to ip(8) as root (#115).
  for bad in 999.1.1.1 1.2.3.4.5 256.0.0.1 010.0.0.1 1.2.3.4x; do
    : >"$STUB_LOG"
    lease add "$bad"
    [ "$status" -eq 0 ]
    never_ran ip
  done
}
