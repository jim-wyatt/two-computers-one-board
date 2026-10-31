#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# net/wifi.sh decides whether it is safe to turn off the radio you are probably
# connected over. Its preflight is the whole safety story, and the question it
# has to answer is narrow: is there a computer on the other end of the cable
# that will still be able to reach this board once wifi is gone?
#
# It got that wrong by asking only IPv4.
#
# With no DHCP server on the host, the board autoconfigures 169.254/16 and so
# does the host, but neither ARPs for the other until something sends v4
# traffic. IPv6 link-local needs no such prompting - it comes up by itself and
# is what actually carries the ssh session. So on a live board the v4 neighbor
# table held a single FAILED entry with no lladdr, the v6 table held the host
# REACHABLE, and `wifi.sh check` told a person connected through that very link
# that there was "no computer on br-usb".
#
# Failing safe is not the same as being right: the refusal made `off` unusable
# in precisely the configuration it was written for. These tests are that bug.

setup() {
  load helpers/stub
  stub_setup

  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  WIFI="$PROJECT/net/wifi.sh"

  # A bound gadget, without reaching into configfs. wifi.sh reads this path
  # directly rather than through a command, so it is redirected, not stubbed.
  export UNOQ_GADGET_DIR="$BATS_TEST_TMPDIR/gadget"
  mkdir -p "$UNOQ_GADGET_DIR"
  echo "4e00000.usb" >"$UNOQ_GADGET_DIR/UDC"

  stub nmcli
  stub ping 0
  stub hostname 0 "board"
}

# The board as it actually was when this bug was found: bridge up with an
# autoconf v4 address, no lease, no gateway, one dead v4 neighbor, and the
# host sitting in the v6 table.
ip_v6_only_host() {
  stub_body ip <<'SH'
case "$*" in
  "link show br-usb")            exit 0 ;;
  "-4 route show default dev br-usb") exit 0 ;;
  "-4 neigh show dev br-usb")    echo "169.254.169.254 FAILED "; exit 0 ;;
  "-6 neigh show dev br-usb")    echo "fe80::200:5eff:fe10:2030 lladdr 02:00:5e:10:20:30 REACHABLE "; exit 0 ;;
  "neigh show fe80::200:5eff:fe10:2030 dev br-usb")
    echo "fe80::200:5eff:fe10:2030 lladdr 02:00:5e:10:20:30 REACHABLE "; exit 0 ;;
  "-4 -br addr show br-usb")     echo "br-usb UP 169.254.13.209/16"; exit 0 ;;
esac
exit 0
SH
}

# --- the bug ----------------------------------------------------------------

@test "a host reachable only over IPv6 link-local counts as a computer" {
  ip_v6_only_host
  run "$WIFI" check
  [ "$status" -eq 0 ]
  [[ "$output" == *"fe80::200:5eff:fe10:2030 answers on br-usb"* ]]
}

@test "the v6 host is not reported as no computer at all" {
  # The exact wording that was wrong on a board someone was logged into.
  ip_v6_only_host
  run "$WIFI" check
  [[ "$output" != *"no computer on br-usb"* ]]
}

@test "a v6 peer is pinged with -6 and the interface scope" {
  # A fe80:: address without a scope is not routable. Letting ping guess the
  # family fails on an address that is perfectly reachable, which would send
  # this straight back to the neighbor-table fallback for the wrong reason.
  ip_v6_only_host
  run "$WIFI" check
  ran_like 'ping -6 -c1 -W2 -I br-usb fe80::200:5eff:fe10:2030'
}

# --- what must not become a peer --------------------------------------------

@test "a v4 neighbor with no lladdr is not a peer" {
  # 169.254.169.254 FAILED is the cloud-metadata probe going nowhere. It has an
  # address and no hardware behind it, so treating it as the host would strand
  # the board on the say-so of a failed lookup.
  stub_body ip <<'SH'
case "$*" in
  "link show br-usb")            exit 0 ;;
  "-4 neigh show dev br-usb")    echo "169.254.169.254 FAILED "; exit 0 ;;
esac
exit 0
SH
  run "$WIFI" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"no computer on br-usb"* ]]
}

@test "multicast is not a way back in" {
  stub_body ip <<'SH'
case "$*" in
  "link show br-usb")            exit 0 ;;
  "-6 neigh show dev br-usb")    echo "ff02::1 lladdr 33:33:00:00:00:01 REACHABLE "; exit 0 ;;
esac
exit 0
SH
  run "$WIFI" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"no computer on br-usb"* ]]
}

@test "an empty neighbor table in both families still refuses" {
  stub_body ip <<'SH'
case "$*" in "link show br-usb") exit 0 ;; esac
exit 0
SH
  run "$WIFI" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"no IPv4 or IPv6 neighbor"* ]]
}

# --- ordering ---------------------------------------------------------------

@test "an IPv4 gateway still wins over any neighbor" {
  # An address the host routes with is a better answer than one it merely
  # answers on, so the v6 fallback must not displace a real default route.
  stub_body ip <<'SH'
case "$*" in
  "link show br-usb")            exit 0 ;;
  "-4 route show default dev br-usb") echo "default via 192.168.137.1 dev br-usb metric 700"; exit 0 ;;
  "-6 neigh show dev br-usb")    echo "fe80::200:5eff:fe10:2030 lladdr 02:00:5e:10:20:30 REACHABLE "; exit 0 ;;
  "neigh show 192.168.137.1 dev br-usb")
    echo "192.168.137.1 lladdr 02:00:5e:10:20:30 REACHABLE "; exit 0 ;;
  "-4 -br addr show br-usb")     echo "br-usb UP 192.168.137.42/24"; exit 0 ;;
esac
exit 0
SH
  run "$WIFI" check
  [ "$status" -eq 0 ]
  [[ "$output" == *"192.168.137.1 answers on br-usb"* ]]
}

@test "IPv4 neighbors are preferred to IPv6 ones" {
  stub_body ip <<'SH'
case "$*" in
  "link show br-usb")            exit 0 ;;
  "-4 neigh show dev br-usb")    echo "169.254.5.5 lladdr 02:00:5e:10:20:30 REACHABLE "; exit 0 ;;
  "-6 neigh show dev br-usb")    echo "fe80::200:5eff:fe10:2030 lladdr 02:00:5e:10:20:30 REACHABLE "; exit 0 ;;
  "neigh show 169.254.5.5 dev br-usb")
    echo "169.254.5.5 lladdr 02:00:5e:10:20:30 REACHABLE "; exit 0 ;;
  "-4 -br addr show br-usb")     echo "br-usb UP 169.254.13.209/16"; exit 0 ;;
esac
exit 0
SH
  run "$WIFI" check
  [ "$status" -eq 0 ]
  [[ "$output" == *"169.254.5.5 answers on br-usb"* ]]
}

# --- the refusal that must survive ------------------------------------------

@test "a peer that is on the table but does not answer is still refused" {
  # The one state where turning the radio off strands the board: configured and
  # not working. Widening the search to v6 must not widen this.
  stub ping 1
  stub_body ip <<'SH'
case "$*" in
  "link show br-usb")            exit 0 ;;
  "-6 neigh show dev br-usb")    echo "fe80::dead lladdr 02:00:5e:10:20:30 STALE "; exit 0 ;;
  "neigh show fe80::dead dev br-usb") echo "fe80::dead FAILED "; exit 0 ;;
esac
exit 0
SH
  run "$WIFI" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not answer on br-usb"* ]]
}

@test "an unbound gadget is refused before any neighbor is consulted" {
  : >"$UNOQ_GADGET_DIR/UDC"
  ip_v6_only_host
  run "$WIFI" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"not bound to a UDC"* ]]
  never_ran ip
}

# --- the renew kick ----------------------------------------------------------
#
# `off` sends udhcpc SIGUSR1 so DNS comes back on this link. It asked only
# whether the pid file's process was called busybox or udhcpc - and every
# applet started as `busybox <name>` is called busybox. With a stale pid file
# whose pid had gone to another applet, root sent it SIGUSR1, which ends most
# of them (#115).

@test "off does not signal a BusyBox process that is not udhcpc" {
  export UNOQ_RUN_DIR="$BATS_TEST_TMPDIR/run"
  mkdir -p "$UNOQ_RUN_DIR"
  # A real process the kernel calls "busybox", running something else.
  cp "$(command -v sleep)" "$BATS_TEST_TMPDIR/busybox"
  "$BATS_TEST_TMPDIR/busybox" 30 &
  victim=$!
  echo "$victim" >"$UNOQ_RUN_DIR/unoq-usb-udhcpc.pid"
  stub_body id <<'SH'
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
SH
  stub sleep
  ip_v6_only_host
  run "$WIFI" off --force
  alive=0
  kill -0 "$victim" 2>/dev/null && alive=1
  kill "$victim" 2>/dev/null || true
  [ "$alive" = 1 ]
  [[ "$output" != *"asked udhcpc to renew"* ]]
}
