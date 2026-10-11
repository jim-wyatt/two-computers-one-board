#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# usb/usb-profile.sh is the fallback that runs when the host will not lease the
# board an address. It is the only thing in this project that assigns the board
# an address on somebody else's subnet without being asked, which makes it the
# one most able to break a network it was plugged into politely.
#
# So most of what is tested here is refusal: it must not claim an address that
# is taken, must not claim one on a host it has not positively identified, and
# must give back anything it took that did not turn out to route.
#
# The board this was written on is the case it exists for: ICS NAT-ing at
# 192.168.137.1 at 17ms, and answering no DHCP discover at all.

setup() {
  load helpers/stub
  stub_setup

  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PROFILE="$PROJECT/usb/usb-profile.sh"

  export UNOQ_USB_PROFILE_STATE="$BATS_TEST_TMPDIR/profile.state"
  export UNOQ_USB_PROFILE_CONF="$BATS_TEST_TMPDIR/profiles.conf"

  stub logger
  stub ip
  stub ping 0
  stub curl 0

  # usb-route.sh is a real script with its own suite; here it is a stub, so
  # these tests assert what this script DECIDES to ask of it.
  stub_body usb-route.sh <<'SH'
exit 0
SH
  # The script calls it by path, so shadow the path rather than the name.
  ROUTE_LOG="$BATS_TEST_TMPDIR/route.log"
  export ROUTE_LOG
}

# The gateway probe and the free-address probe are both busybox arping, told
# apart by -D. Almost every test needs to say "this host is there, that address
# is free", so it gets a helper.
#
#   arping_answers <ip>...   - these gateways reply to a plain arping
#   any address probed with -D is free unless named in TAKEN.
fake_arping() {
  stub_body busybox <<SH
[ "\$1" = arping ] || exit 0
shift
dup=0
for a in "\$@"; do [ "\$a" = "-D" ] && dup=1; done
target="\${@: -1}"
if [ "\$dup" = 1 ]; then
  case " ${TAKEN:-} " in *" \$target "*) exit 1 ;; esac
  exit 0
fi
case " ${ANSWERS:-} " in *" \$target "*) exit 0 ;; esac
exit 1
SH
}

# Run the script with a fake usb-route.sh next to it, in a copy of usb/.
run_profile() {
  run env PATH="$STUB_DIR:$PATH" bash "$PROFILE" "$@"
}

# --- detect: identifying the host by asking the wire ------------------------

@test "a Windows ICS host is recognized by its gateway answering ARP" {
  ANSWERS="192.168.137.1" fake_arping
  run_profile detect
  [ "$status" -eq 0 ]
  [ "$output" = "windows-ics" ]
}

@test "a macOS sharing host is recognized by its own gateway" {
  ANSWERS="192.168.2.1" fake_arping
  run_profile detect
  [ "$status" -eq 0 ]
  [ "$output" = "macos-sharing" ]
}

@test "nothing on the other end means no profile, and no guessing" {
  # The important half. A board that invented a subnet here would claim an
  # address on a network it had not identified, which is how you take down
  # somebody else's LAN with a USB cable.
  ANSWERS="" fake_arping
  run_profile detect
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "detection uses ARP, not ping" {
  # Windows blocks ICMP to the ICS adapter by default, so a ping-based check
  # would report "no host" for the single most common host this will meet.
  # That is not hypothetical - it is what every ping in the diagnosis did.
  ANSWERS="192.168.137.1" fake_arping
  run_profile detect
  ran_like 'busybox arping .*192\.168\.137\.1'
  never_ran ping
}

@test "detect changes nothing" {
  # It runs on every leasefail, which is every 35 seconds while the cable sits
  # in a machine that is not sharing. It has to stay free of side effects.
  ANSWERS="192.168.137.1" fake_arping
  run_profile detect
  never_ran ip
  [ ! -e "$UNOQ_USB_PROFILE_STATE" ]
}

@test "an operator can add a host the built-in table does not know" {
  # A Linux host with its own numbering is a line in a file, not a patch.
  cat >"$UNOQ_USB_PROFILE_CONF" <<'CONF'
# name        gateway     address       plen
my-linux-box  10.9.0.1    10.9.0.210    24
CONF
  ANSWERS="10.9.0.1" fake_arping
  run_profile detect
  [ "$status" -eq 0 ]
  [ "$output" = "my-linux-box" ]
}

@test "the built-in profiles are tried before the operator's" {
  cat >"$UNOQ_USB_PROFILE_CONF" <<'CONF'
my-linux-box  10.9.0.1    10.9.0.210    24
CONF
  ANSWERS="192.168.137.1 10.9.0.1" fake_arping
  run_profile detect
  [ "$output" = "windows-ics" ]
}

@test "a malformed line in the operator's file cannot reach ip(8)" {
  cat >"$UNOQ_USB_PROFILE_CONF" <<'CONF'
evil  ;reboot  ../etc/passwd  notanumber
CONF
  ANSWERS=";reboot" fake_arping
  run_profile detect
  # It may not be selected, and if the gateway is not address-shaped it is not
  # even probed.
  [ "$output" != "evil" ]
}

# --- up: claiming an address, and the proofs required -----------------------

@test "a recognized host gets its address claimed" {
  ANSWERS="192.168.137.1" fake_arping
  run_profile up windows-ics
  [ "$status" -eq 0 ]
  ran "ip addr replace 192.168.137.210/24 dev br-usb"
}

@test "the address is ARP-probed for a duplicate before it is taken" {
  # RFC 5227. The board must never collide with the host it is plugged into,
  # or with a second board on the same machine.
  ANSWERS="192.168.137.1" fake_arping
  run_profile up windows-ics
  ran_like 'busybox arping .*-D .*192\.168\.137\.210'
}

@test "an address already in use is NOT claimed" {
  # The load-bearing refusal. Link-local is the right answer here: it has
  # collision detection of its own and will find a free address by itself.
  ANSWERS="192.168.137.1" TAKEN="192.168.137.210" fake_arping
  run_profile up windows-ics
  [ "$status" -ne 0 ]
  refute ran_like 'ip addr replace'
  [[ "$output" == *"already in use"* ]]
}

@test "the address is given back when nothing routes through the gateway" {
  # A gateway that answers ARP but forwards nothing - ICS half on, or shared to
  # the wrong adapter. Keeping the address would leave the board looking
  # configured and reaching nothing.
  ANSWERS="192.168.137.1" fake_arping
  stub ping 1
  stub curl 1
  run_profile up windows-ics
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing routes through it"* ]]
}

@test "an up that cannot prove itself takes its own address back off" {
  # "Giving the address back" has to be something this script DOES, not
  # something it says while relying on the caller to do it. usb-dhcp.sh does
  # call `down` on this path - and a caller that has to remember is a caller
  # that can forget, which running this by hand is the case nobody covers.
  ANSWERS="192.168.137.1" fake_arping
  stub ping 1
  stub curl 1
  run_profile up windows-ics
  [ "$status" -ne 0 ]
  ran "ip addr del 192.168.137.210/24 dev br-usb"
  [ ! -e "$UNOQ_USB_PROFILE_STATE" ]
}

@test "the reachability probe goes through the bridge" {
  ANSWERS="192.168.137.1" fake_arping
  run_profile up windows-ics
  ran_like 'ping .*-I br-usb'
}

@test "the TCP half of the probe does not turn on certificate validation" {
  # It asks whether packets reach the internet, not whether a certificate is
  # valid for a bare IP. Without -k, a probe address whose certificate does not
  # name it fails TLS and is read here as "the host is not NAT-ing" - which
  # hands back a perfectly good address.
  ANSWERS="192.168.137.1" fake_arping
  stub ping 1
  stub curl 0
  run_profile up windows-ics
  [ "$status" -eq 0 ]
  ran_like 'curl .*-k'
}

@test "a working profile asks for the route to be promoted" {
  # The point of the whole exercise: plugging the cable in is enough, without
  # turning wifi off by hand. The proof has just been made, so the promotion is
  # allowed to happen.
  ANSWERS="192.168.137.1" fake_arping
  run_profile up windows-ics
  [ "$status" -eq 0 ]
  [[ "$output" == *"internet reachable"* ]]
}

@test "state is written so the address can be found and removed later" {
  ANSWERS="192.168.137.1" fake_arping
  run_profile up windows-ics
  [ -r "$UNOQ_USB_PROFILE_STATE" ]
  read -r name cidr gw <"$UNOQ_USB_PROFILE_STATE"
  [ "$name" = "windows-ics" ]
  [ "$cidr" = "192.168.137.210/24" ]
  [ "$gw" = "192.168.137.1" ]
}

@test "state is written before the route, so a killed up can still be undone" {
  # The graceful failure above cleans up after itself. This is the ungraceful
  # one: if the script is killed between claiming the address and proving the
  # route - a power cut on a board that is powered over the cable it is
  # configuring - the address is on the bridge with nothing running that knows
  # it. The state file written before the route is what the next `down`
  # recovers from, so it has to be complete by then.
  printf 'windows-ics 192.168.137.210/24 192.168.137.1\n' >"$UNOQ_USB_PROFILE_STATE"
  run_profile down
  [ "$status" -eq 0 ]
  ran "ip addr del 192.168.137.210/24 dev br-usb"
}

@test "an unknown profile name is refused" {
  ANSWERS="192.168.137.1" fake_arping
  run_profile up not-a-profile
  [ "$status" -ne 0 ]
  refute ran_like 'ip addr replace'
}

@test "UNOQ_USB_PROFILE_FALLBACK=0 disables the whole mechanism" {
  # The escape hatch, for anyone who wants link-local and nothing cleverer.
  export UNOQ_USB_PROFILE_FALLBACK=0
  ANSWERS="192.168.137.1" fake_arping
  run_profile detect
  [ "$status" -ne 0 ]
  run_profile up windows-ics
  [ "$status" -ne 0 ]
  refute ran_like 'ip addr replace'
}

# --- down: giving it back ---------------------------------------------------

@test "down removes exactly the address that was claimed" {
  printf 'windows-ics 192.168.137.210/24 192.168.137.1\n' >"$UNOQ_USB_PROFILE_STATE"
  run_profile down
  [ "$status" -eq 0 ]
  ran "ip addr del 192.168.137.210/24 dev br-usb"
  [ ! -e "$UNOQ_USB_PROFILE_STATE" ]
}

@test "down with nothing claimed is a no-op, not an error" {
  # usb-dhcp.sh calls this on every `bound`, whether a profile was up or not.
  run_profile down
  [ "$status" -eq 0 ]
  never_ran ip
}

@test "down refuses to remove a profile other than the one that is up" {
  # Removing the wrong name would delete the state file while leaving the
  # address on the bridge - the one state nothing could recover from, because
  # afterwards nothing knows the address is there.
  printf 'macos-sharing 192.168.2.210/24 192.168.2.1\n' >"$UNOQ_USB_PROFILE_STATE"
  run_profile down windows-ics
  [ "$status" -ne 0 ]
  refute ran_like 'ip addr del'
  [ -r "$UNOQ_USB_PROFILE_STATE" ]
}

@test "down does not flush the interface" {
  # `ip addr flush` would take the link-local address with it, and on the path
  # where a profile failed that is the address about to keep the board
  # reachable. usb-dhcp.sh's deconfig has the same rule for the same reason.
  printf 'windows-ics 192.168.137.210/24 192.168.137.1\n' >"$UNOQ_USB_PROFILE_STATE"
  run_profile down
  refute ran_like 'ip addr flush'
}
