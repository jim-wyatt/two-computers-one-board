#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# usb/bind-guard.sh is the component with the worst failure mode in the
# project. It exists to stop a USB bind that browns the board out from becoming
# a permanent reboot loop - and if its own counting is wrong it causes exactly
# the outage it prevents, on a board that then cannot be reached over USB to
# fix it.
#
# That has already happened once. udev triggers the bind unit three times on a
# healthy plug-in (once for the UDC, once per gadget netdev), so an earlier
# version counting invocations reached its limit of 3 during the first
# SUCCESSFUL plug-in and refused to bind ever again.
#
# The fix - only the first check of any boot counts - is the thing these tests
# are here to hold in place.

setup() {
  load helpers/stub
  stub_setup

  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GUARD="$PROJECT/usb/bind-guard.sh"

  export UNOQ_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export UNOQ_USB_BIND_MAX_ATTEMPTS=3
  # The rescue path shells out to nmcli and is tested separately; off by
  # default so an unrelated assertion cannot depend on radio state.
  export UNOQ_GUARD_WIFI_RESCUE=0

  COUNTER="$UNOQ_STATE_DIR/usb-bind-attempts"
  BOOT_ID="$(cat /proc/sys/kernel/random/boot_id)"

  stub logger
  stub sync
}

# A counter file as some EARLIER boot would have left it: a boot id that is not
# this one, so the guard treats it as a previous, unconfirmed boot.
seed_previous_boots() {
  mkdir -p "$UNOQ_STATE_DIR"
  echo "00000000-0000-0000-0000-000000000000 $1" >"$COUNTER"
}

@test "a first bind on a clean board is allowed and counted" {
  run "$GUARD" check
  [ "$status" -eq 0 ]
  [ "$(cat "$COUNTER")" = "$BOOT_ID 1" ]
}

@test "udev's repeat triggers in one boot do not advance the counter" {
  # The regression that motivated all of this: three checks in a single boot is
  # NORMAL, and must leave the counter at 1 rather than at the limit.
  run "$GUARD" check
  run "$GUARD" check
  run "$GUARD" check
  [ "$status" -eq 0 ]
  [ "$(cat "$COUNTER")" = "$BOOT_ID 1" ]
}

@test "the counter advances once per boot that never confirmed" {
  seed_previous_boots 1
  run "$GUARD" check
  [ "$status" -eq 0 ]
  [ "$(cat "$COUNTER")" = "$BOOT_ID 2" ]
}

@test "binding is refused after MAX unconfirmed boots" {
  seed_previous_boots 3
  run "$GUARD" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSING to bind"* ]]
  # And it says how to undo it - a guard you cannot clear is a brick.
  [[ "$output" == *"rm -f $COUNTER"* ]]
}

@test "refusing does not overwrite the evidence" {
  seed_previous_boots 3
  run "$GUARD" check
  [ "$(cat "$COUNTER")" = "00000000-0000-0000-0000-000000000000 3" ]
}

@test "MAX is configurable, and one below it still binds" {
  export UNOQ_USB_BIND_MAX_ATTEMPTS=5
  seed_previous_boots 4
  run "$GUARD" check
  [ "$status" -eq 0 ]
}

@test "confirm clears the counter" {
  run "$GUARD" check
  run "$GUARD" confirm
  [ "$status" -eq 0 ]
  [[ "$output" == *"confirmed healthy"* ]]
  [ ! -f "$COUNTER" ]
}

@test "confirm on an already-clean board is a no-op, not an error" {
  run "$GUARD" confirm
  [ "$status" -eq 0 ]
  [[ "$output" == *"already confirmed"* ]]
}

@test "confirm rescues a board that had reached the limit" {
  # The whole recovery path: the guard has tripped, one good boot confirms, and
  # the next check is allowed again.
  seed_previous_boots 3
  run "$GUARD" check
  [ "$status" -eq 1 ]
  run "$GUARD" confirm
  run "$GUARD" check
  [ "$status" -eq 0 ]
}

@test "the counter is written BEFORE the bind, so a board that dies still counted" {
  # There is no "after" in which to record an attempt that killed the board.
  # Asserting the file exists once check returns is the closest a host test can
  # get to that; the ordering itself is a one-line read of the script.
  run "$GUARD" check
  [ -s "$COUNTER" ]
  ran "sync -f $COUNTER"
}

# --- a truncated or corrupt counter must not wedge the guard ---------------
#
# The file is written during a boot that may be about to lose power. Every one
# of these has to be a clean slate rather than a permanent refusal OR a
# permanent free pass.

@test "an empty counter file reads as zero" {
  mkdir -p "$UNOQ_STATE_DIR"
  : >"$COUNTER"
  run "$GUARD" check
  [ "$status" -eq 0 ]
  [ "$(cat "$COUNTER")" = "$BOOT_ID 1" ]
}

@test "a garbage counter file reads as zero" {
  mkdir -p "$UNOQ_STATE_DIR"
  printf 'not a counter at all' >"$COUNTER"
  run "$GUARD" check
  [ "$status" -eq 0 ]
}

@test "the old bare-number format is treated as a previous boot" {
  # Before the boot id was recorded the file held just a count. Reading it as
  # "some earlier boot" is what lets an existing board upgrade without either
  # losing its history or being refused immediately.
  mkdir -p "$UNOQ_STATE_DIR"
  echo "2" >"$COUNTER"
  run "$GUARD" check
  [ "$status" -eq 0 ]
  [ "$(cat "$COUNTER")" = "$BOOT_ID 3" ]
}

@test "a count at the limit in the old format still refuses" {
  mkdir -p "$UNOQ_STATE_DIR"
  echo "3" >"$COUNTER"
  run "$GUARD" check
  [ "$status" -eq 1 ]
}

# --- verbs ------------------------------------------------------------------

@test "status reports the count without changing it" {
  seed_previous_boots 2
  run "$GUARD" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"attempts: 2/3"* ]]
  [ "$(cat "$COUNTER")" = "00000000-0000-0000-0000-000000000000 2" ]
}

@test "status says when this boot is already counted" {
  run "$GUARD" check
  run "$GUARD" status
  [[ "$output" == *"already counted in the current boot"* ]]
}

@test "an unknown verb is a usage error, not a silent success" {
  run "$GUARD" frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

@test "no verb at all is a usage error" {
  run "$GUARD"
  [ "$status" -eq 2 ]
}

# --- the wifi rescue --------------------------------------------------------

@test "refusing to bind turns the radio back on, so the board stays reachable" {
  # If the guard has given up on USB, wifi is the only way back in. Off by
  # default in these tests, so this is the one that opts in.
  export UNOQ_GUARD_WIFI_RESCUE=1
  stub nmcli 0 "disabled"
  seed_previous_boots 3
  run "$GUARD" check
  [ "$status" -eq 1 ]
  ran "nmcli radio wifi on"
}

@test "a successful bind does not touch the radio" {
  export UNOQ_GUARD_WIFI_RESCUE=1
  stub nmcli 0 "disabled"
  run "$GUARD" check
  [ "$status" -eq 0 ]
  never_ran nmcli
}

@test "the rescue can be switched off for a board that must stay dark" {
  export UNOQ_GUARD_WIFI_RESCUE=0
  stub nmcli 0 "disabled"
  seed_previous_boots 3
  run "$GUARD" check
  [ "$status" -eq 1 ]
  never_ran nmcli
}

# --- a count it cannot write -------------------------------------------------
#
# The write before the bind went to /dev/null if it failed, and the bind went
# ahead. Repeated brownouts are a good way to get a filesystem remounted
# read-only, and then the count never advanced, the guard never tripped, and
# the reboot loop it exists to stop ran for ever (#115).

@test "a bind whose attempt cannot be recorded is refused" {
  [ "$(id -u)" != 0 ] || skip "root can write to a read-only directory"
  mkdir -p "$UNOQ_STATE_DIR"
  chmod 555 "$UNOQ_STATE_DIR"
  run "$GUARD" check
  chmod 755 "$UNOQ_STATE_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSING to bind: could not record this attempt"* ]]
}

@test "the count is replaced whole, never left half written" {
  seed_previous_boots 1
  run "$GUARD" check
  [ "$status" -eq 0 ]
  [ "$(cat "$COUNTER")" = "$BOOT_ID 2" ]
  [ ! -e "$COUNTER.tmp" ]
}

@test "a count that cannot be written turns wifi back on, as a trip does" {
  [ "$(id -u)" != 0 ] || skip "root can write to a read-only directory"
  export UNOQ_GUARD_WIFI_RESCUE=1
  stub_body nmcli <<'SH'
case "$*" in "radio wifi") echo disabled ;; esac
exit 0
SH
  mkdir -p "$UNOQ_STATE_DIR"
  chmod 555 "$UNOQ_STATE_DIR"
  run "$GUARD" check
  chmod 755 "$UNOQ_STATE_DIR"
  [ "$status" -ne 0 ]
  ran "nmcli radio wifi on"
}
