#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# usb/uplink-fallback.sh is the last automatic way back onto a network. It runs
# once per boot, on a board whose wifi somebody turned off, and decides whether
# the USB link really reaches the internet - and if it does not, turns the
# radio back on.
#
# Both ways of getting that wrong are bad, and they pull in opposite directions:
#
#   says "fine" when it is not     a board that boots, looks healthy, and can
#                                  reach nothing, with wifi off and nobody near
#   says "broken" when it is not   the radio comes back on every boot, and the
#                                  power budget wifi.sh exists for is gone
#
# So the tests are mostly about the decision, and about the cases where it must
# not touch the radio at all.

setup() {
  load helpers/stub
  stub_setup

  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FALLBACK="$PROJECT/usb/uplink-fallback.sh"

  stub logger
  stub sleep
  # Short enough that a test which waits out the deadline takes no time: the
  # sleeps are stubbed, so this is three trips round the loop.
  export UNOQ_UPLINK_DEADLINE=45 UNOQ_UPLINK_INTERVAL=15
}

# nmcli answers `radio wifi` with the state, and records anything else.
wifi_is() {
  export WIFI_STATE="$1"
  stub_body nmcli <<'SH'
[ "$*" = "radio wifi" ] && echo "$WIFI_STATE"
exit 0
SH
}

# Nothing answers over the cable, by ping or by TCP.
cable_is_dead() {
  stub ping 1
  stub curl 7
}

@test "wifi already on: nothing is probed and nothing is changed" {
  wifi_is enabled
  cable_is_dead
  run "$FALLBACK"
  [ "$status" -eq 0 ]
  never_ran ping
  refute ran "nmcli radio wifi on"
}

@test "wifi off and the cable reaches the internet: the radio stays off" {
  wifi_is disabled
  stub ping 0
  run "$FALLBACK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wifi stays off"* ]]
  refute ran "nmcli radio wifi on"
}

@test "wifi off and nothing reachable by the deadline: the radio comes back on" {
  wifi_is disabled
  cable_is_dead
  run "$FALLBACK"
  [ "$status" -eq 0 ]
  ran "nmcli radio wifi on"
}

@test "it waits out the whole deadline before giving up, not one probe" {
  wifi_is disabled
  cable_is_dead
  run "$FALLBACK"
  [ "$(grep -c '^sleep 15$' "$STUB_LOG")" -eq 3 ]
}

@test "the probe goes through the bridge, not whatever else is up" {
  wifi_is disabled
  stub ping 0
  run "$FALLBACK"
  ran "ping -c1 -W3 -I br-usb 1.1.1.1"
}

@test "a host that drops ping but passes TCP is not condemned" {
  wifi_is disabled
  stub ping 1
  stub curl 0
  run "$FALLBACK"
  [ "$status" -eq 0 ]
  ran_like '^curl --interface br-usb '
  refute ran "nmcli radio wifi on"
}

@test "a link that comes up late, inside the deadline, still keeps the radio off" {
  wifi_is disabled
  stub curl 7
  # Fails until the second sleep has happened, then answers.
  stub_body ping <<'SH'
[ "$(grep -c '^sleep ' "$STUB_LOG")" -ge 2 ]
SH
  run "$FALLBACK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"after 30s"* ]]
  refute ran "nmcli radio wifi on"
}

@test "UNOQ_UPLINK_FALLBACK=0 means hands off, even with no uplink at all" {
  wifi_is disabled
  cable_is_dead
  UNOQ_UPLINK_FALLBACK=0 run "$FALLBACK"
  [ "$status" -eq 0 ]
  never_ran nmcli
  never_ran ping
}

@test "a radio that will not turn on is a failure, and says so" {
  export WIFI_STATE=disabled
  stub_body nmcli <<'SH'
[ "$*" = "radio wifi" ] && echo "$WIFI_STATE" && exit 0
exit 1
SH
  cable_is_dead
  run "$FALLBACK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"may have no uplink at all"* ]]
}
