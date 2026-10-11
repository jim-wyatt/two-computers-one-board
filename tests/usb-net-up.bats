#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# usb/usb-net-up.sh is what turns a bound gadget into a network link: it makes
# the bridge, puts the gadget's interface on it, and starts the DHCP client.
# It runs at every boot, on every plug-in, and - since the hand-over from adb
# binds with the cable already in - at the one moment in a first setup when
# the USB port is the only way to tell whether anything worked.
#
# It had no tests. What can go wrong with it, and is tested here:
#
#   - it is run again and again, so it must not duplicate what is there: a
#     second bridge, a second DHCP client on the same interface
#   - it asks for the last address again, from a file - and what is in that
#     file ends up on a command line
#   - it must still bring the link up when there is nothing on it yet
#
# What cannot be tested here is the link: that the bridge forwards, that
# udhcpc gets a lease from Windows or macOS, that the address works. `ip`
# being asked the right thing is not the kernel having done it.

setup() {
  load helpers/stub
  stub_setup

  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  NETUP="$PROJECT/usb/usb-net-up.sh"

  export UNOQ_RUN_DIR="$BATS_TEST_TMPDIR/run"
  export UNOQ_NET_SYSFS="$BATS_TEST_TMPDIR/net"
  export UNOQ_STATE_DIR="$BATS_TEST_TMPDIR/state"
  mkdir -p "$UNOQ_RUN_DIR" "$UNOQ_NET_SYSFS" "$UNOQ_STATE_DIR"
  FLAGS="$BATS_TEST_TMPDIR/flags"
  mkdir -p "$FLAGS"
  export FLAGS
  unset UNOQ_USB_BRIDGE

  stub_body id <<'SH'
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
SH
  stub modprobe
  stub hostname 0 "uno-q"
  stub busybox

  # An `ip` that knows whether the bridge exists ($FLAGS/bridge), what
  # addresses are on it ($FLAGS/addrs, in `ip -4 -o addr` form), and can be
  # told to refuse to enslave an interface ($FLAGS/no-enslave).
  stub_body ip <<'SH'
case "$*" in
  "link show br-usb") [ -e "$FLAGS/bridge" ]; exit ;;
  "link add name br-usb type bridge") touch "$FLAGS/bridge" ;;
  "-4 -o addr show dev br-usb") [ -e "$FLAGS/addrs" ] && cat "$FLAGS/addrs" ;;
  "link set usb"*" master br-usb") [ -e "$FLAGS/no-enslave" ] && exit 1 ;;
esac
exit 0
SH
}

# gadget_iface <name> [on-bridge] - a network interface the gadget made.
gadget_iface() {
  mkdir -p "$UNOQ_NET_SYSFS/$1"
  if [ "${2:-}" = on-bridge ]; then
    mkdir -p "$UNOQ_NET_SYSFS/br-usb"
    ln -s "$UNOQ_NET_SYSFS/br-usb" "$UNOQ_NET_SYSFS/$1/master"
  fi
}

# --- the bridge ------------------------------------------------------------------

@test "the bridge is created when there is none, with spanning tree off" {
  run "$NETUP"
  [ "$status" -eq 0 ]
  ran "ip link add name br-usb type bridge"
  ran "ip link set br-usb type bridge stp_state 0 forward_delay 0"
  ran "ip link set br-usb up"
}

@test "a bridge that is already there is not created again" {
  touch "$FLAGS/bridge"
  run "$NETUP"
  [ "$status" -eq 0 ]
  refute ran "ip link add name br-usb type bridge"
  ran "ip link set br-usb up"
}

@test "an address left over from the old server mode is removed, and no other" {
  touch "$FLAGS/bridge"
  cat >"$FLAGS/addrs" <<'A'
5: br-usb    inet 10.55.0.1/24 brd 10.55.0.255 scope global br-usb
5: br-usb    inet 192.168.137.44/24 brd 192.168.137.255 scope global br-usb
A
  run "$NETUP"
  [ "$status" -eq 0 ]
  ran "ip addr del 10.55.0.1/24 dev br-usb"
  refute ran_like '^ip addr del 192\.168'
}

# --- the gadget's interface ---------------------------------------------------------

@test "a gadget interface is put on the bridge and brought up" {
  gadget_iface usb0
  run "$NETUP"
  [ "$status" -eq 0 ]
  ran "ip addr flush dev usb0"
  ran "ip link set usb0 master br-usb"
  ran "ip link set usb0 up"
}

@test "an interface already on the bridge is left alone" {
  gadget_iface usb0 on-bridge
  run "$NETUP"
  [ "$status" -eq 0 ]
  refute ran "ip link set usb0 master br-usb"
  # Flushing it would drop the address of a link that is in use.
  refute ran "ip addr flush dev usb0"
}

@test "an interface that will not join the bridge is a warning, and DHCP still starts" {
  gadget_iface usb0
  touch "$FLAGS/no-enslave"
  run "$NETUP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: could not enslave usb0"* ]]
  refute ran "ip link set usb0 up"
  ran_like '^busybox udhcpc '
}

@test "with nothing plugged in the bridge still comes up and waits" {
  run "$NETUP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"waiting"* ]]
  ran_like '^busybox udhcpc '
}

@test "only the gadget's interfaces are touched, not the board's others" {
  gadget_iface usb0
  mkdir -p "$UNOQ_NET_SYSFS/wlan0" "$UNOQ_NET_SYSFS/eth0"
  run "$NETUP"
  [ "$status" -eq 0 ]
  refute ran_like '^ip .*(wlan0|eth0)'
}

# --- the DHCP client -------------------------------------------------------------------

@test "the DHCP client is started on the bridge, with this script's own handler beside it" {
  run "$NETUP"
  [ "$status" -eq 0 ]
  ran_like "^busybox udhcpc --interface=br-usb --script=$PROJECT/usb/usb-dhcp.sh --pidfile=$UNOQ_RUN_DIR/unoq-usb-udhcpc.pid -x hostname:uno-q "
  ran_like '^busybox udhcpc .*--background --release'
}

@test "a DHCP client that is already running is not started a second time" {
  echo "$$" >"$UNOQ_RUN_DIR/unoq-usb-udhcpc.pid"
  run "$NETUP"
  [ "$status" -eq 0 ]
  refute ran_like '^busybox udhcpc'
}

@test "a pid file whose process has gone does not stop a new client starting" {
  echo 999999 >"$UNOQ_RUN_DIR/unoq-usb-udhcpc.pid"
  run "$NETUP"
  [ "$status" -eq 0 ]
  ran_like '^busybox udhcpc '
}

@test "the last address on this link is asked for again" {
  echo "192.168.137.44" >"$UNOQ_STATE_DIR/usb-dhcp-last"
  run "$NETUP"
  [ "$status" -eq 0 ]
  ran_like '^busybox udhcpc .*--request=192\.168\.137\.44 '
}

@test "with no last address, none is asked for" {
  run "$NETUP"
  [ "$status" -eq 0 ]
  refute ran_like '^busybox udhcpc .*--request'
}

@test "a last-address file that does not hold an address is ignored" {
  # What is in this file ends up on udhcpc's command line. It is written by
  # this project's own DHCP handler, as root - but a file is a file.
  for bad in '--script=/tmp/evil' '1.2.3.4;reboot' 'not-an-address' '1234' ''; do
    : >"$STUB_LOG"
    printf '%s\n' "$bad" >"$UNOQ_STATE_DIR/usb-dhcp-last"
    run "$NETUP"
    [ "$status" -eq 0 ]
    refute ran_like '^busybox udhcpc .*--request'
    refute ran_like 'evil|reboot'
  done
}

@test "a DHCP client that will not start is a failure" {
  stub busybox 1
  run "$NETUP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"udhcpc failed to start"* ]]
}

# --- leftovers and refusals -----------------------------------------------------------

@test "a dnsmasq left running by the old server mode is stopped" {
  sleep 30 &
  old=$!
  echo "$old" >"$UNOQ_RUN_DIR/unoq-usb-dnsmasq.pid"
  run "$NETUP"
  [ "$status" -eq 0 ]
  refute kill -0 "$old"
  [ ! -e "$UNOQ_RUN_DIR/unoq-usb-dnsmasq.pid" ]
}

@test "the bridge name can be changed, and everything follows it" {
  stub ip
  UNOQ_USB_BRIDGE=br-test run "$NETUP"
  [ "$status" -eq 0 ]
  ran "ip link set br-test up"
  ran_like '^busybox udhcpc --interface=br-test '
  refute ran_like 'br-usb'
}

@test "it refuses to run as anyone but root, before touching the network" {
  stub_body id <<'SH'
[ "${1:-}" = "-u" ] && { echo 1000; exit 0; }
exec /usr/bin/id "$@"
SH
  run "$NETUP"
  [ "$status" -ne 0 ]
  never_ran ip
  never_ran busybox
}
