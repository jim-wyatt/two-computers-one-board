#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# usb/gadget-down.sh is the way back: it unbinds the gadget, stops the DHCP
# client and removes the bridge. It runs as root, and what it stops it finds
# through pid files.
#
# It used to trust them. `kill -0 "$(cat pidfile)"` asks whether any process
# has that number, and the next line killed it: a stale file, left by a daemon
# that died without tidying up, got whatever had been given the pid since
# killed in its place. What is tested here is mostly what it must NOT kill.
#
# What cannot be tested here: that the kernel lets go of the controller, or
# that configfs allows the removals in the order the script makes them.

setup() {
  load helpers/stub
  stub_setup

  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DOWN="$PROJECT/usb/gadget-down.sh"

  export UNOQ_RUN_DIR="$BATS_TEST_TMPDIR/run"
  export UNOQ_PROC="$BATS_TEST_TMPDIR/proc"
  export UNOQ_GADGET_DIR="$BATS_TEST_TMPDIR/configfs/unoq"
  export UNOQ_AUTOIPD="$BATS_TEST_TMPDIR/no-autoipd"
  export UNOQ_USB_DHCP_STATE="$BATS_TEST_TMPDIR/dhcp.state"
  export UNOQ_STATE_DIR="$BATS_TEST_TMPDIR/state"
  mkdir -p "$UNOQ_RUN_DIR" "$UNOQ_PROC" "$UNOQ_STATE_DIR"

  stub_body id <<'SH'
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
SH
  # No bridge by default: `ip link show` fails, and nothing is deleted.
  stub ip 1
  stub logger
  stub nmcli
}

# bystander - a real process that must still be alive afterwards.
bystander() {
  sleep 30 &
  BYSTANDER=$!
}

# seen_as <pid> <comm> [argv...] - how that pid looks under /proc.
seen_as() {
  local pid="$1" comm="$2"
  shift 2
  mkdir -p "$UNOQ_PROC/$pid"
  echo "$comm" >"$UNOQ_PROC/$pid/comm"
  [ "$#" -gt 0 ] && printf '%s\0' "$@" >"$UNOQ_PROC/$pid/cmdline"
  return 0
}

teardown() {
  [ -n "${BYSTANDER:-}" ] && kill "$BYSTANDER" 2>/dev/null
  return 0
}

# --- what it must not kill -------------------------------------------------------

@test "a stale udhcpc pid file does not get whoever has that pid now killed" {
  bystander
  echo "$BYSTANDER" >"$UNOQ_RUN_DIR/unoq-usb-udhcpc.pid"
  seen_as "$BYSTANDER" sshd /usr/sbin/sshd -D
  run "$DOWN"
  [ "$status" -eq 0 ]
  kill -0 "$BYSTANDER"
  [[ "$output" == *"nothing was killed"* ]]
  [ ! -e "$UNOQ_RUN_DIR/unoq-usb-udhcpc.pid" ]
}

@test "another BusyBox applet with that pid is not taken for the DHCP client" {
  bystander
  echo "$BYSTANDER" >"$UNOQ_RUN_DIR/unoq-usb-udhcpc.pid"
  seen_as "$BYSTANDER" busybox busybox syslogd -n
  run "$DOWN"
  [ "$status" -eq 0 ]
  kill -0 "$BYSTANDER"
}

@test "a stale dnsmasq pid file does not get whoever has that pid now killed" {
  bystander
  echo "$BYSTANDER" >"$UNOQ_RUN_DIR/unoq-usb-dnsmasq.pid"
  seen_as "$BYSTANDER" sshd
  run "$DOWN"
  [ "$status" -eq 0 ]
  kill -0 "$BYSTANDER"
  [ ! -e "$UNOQ_RUN_DIR/unoq-usb-dnsmasq.pid" ]
}

@test "a pid file that does not hold a number kills nothing" {
  bystander
  echo "$BYSTANDER; reboot" >"$UNOQ_RUN_DIR/unoq-usb-udhcpc.pid"
  seen_as "$BYSTANDER" busybox busybox udhcpc
  run "$DOWN"
  [ "$status" -eq 0 ]
  kill -0 "$BYSTANDER"
}

# --- what it must stop -------------------------------------------------------------

@test "the real DHCP client is stopped" {
  bystander
  echo "$BYSTANDER" >"$UNOQ_RUN_DIR/unoq-usb-udhcpc.pid"
  seen_as "$BYSTANDER" busybox busybox udhcpc --interface=br-usb
  run "$DOWN"
  [ "$status" -eq 0 ]
  refute kill -0 "$BYSTANDER"
  [[ "$output" == *"udhcpc stopped"* ]]
  [ ! -e "$UNOQ_RUN_DIR/unoq-usb-udhcpc.pid" ]
}

@test "a real leftover dnsmasq is stopped" {
  bystander
  echo "$BYSTANDER" >"$UNOQ_RUN_DIR/unoq-usb-dnsmasq.pid"
  seen_as "$BYSTANDER" dnsmasq
  run "$DOWN"
  [ "$status" -eq 0 ]
  refute kill -0 "$BYSTANDER"
}

# --- the gadget ------------------------------------------------------------------------

@test "a bound gadget is unbound" {
  mkdir -p "$UNOQ_GADGET_DIR"
  echo "4e00000.usb" >"$UNOQ_GADGET_DIR/UDC"
  run "$DOWN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unbound from the UDC"* ]]
  [ -z "$(tr -d '\n' <"$UNOQ_GADGET_DIR/UDC")" ]
}

@test "a gadget that is not bound is not reported as having been unbound" {
  # An empty UDC file. On configfs it still has a size, which is what the old
  # `-s` test looked at.
  mkdir -p "$UNOQ_GADGET_DIR"
  : >"$UNOQ_GADGET_DIR/UDC"
  run "$DOWN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already unbound"* ]]
  [[ "$output" != *"unbound from the UDC"* ]]
}

@test "with no gadget at all it says so and still finishes" {
  run "$DOWN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no gadget at"* ]]
  [[ "$output" == *"done"* ]]
}

@test "the bridge is taken down and removed when there is one" {
  stub ip
  run "$DOWN"
  [ "$status" -eq 0 ]
  ran "ip link set br-usb down"
  ran "ip link delete br-usb type bridge"
}

@test "it refuses to run as anyone but root, before touching anything" {
  stub_body id <<'SH'
[ "${1:-}" = "-u" ] && { echo 1000; exit 0; }
exec /usr/bin/id "$@"
SH
  bystander
  echo "$BYSTANDER" >"$UNOQ_RUN_DIR/unoq-usb-udhcpc.pid"
  seen_as "$BYSTANDER" busybox busybox udhcpc
  run "$DOWN"
  [ "$status" -ne 0 ]
  kill -0 "$BYSTANDER"
  never_ran ip
}
