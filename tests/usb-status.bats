#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# usb/status.sh - the one section of it that can be wrong without a board:
# "what root runs".
#
# The services do not run the scripts in the checkout. They run root-owned
# copies that a provisioning step makes, so that writing to a home directory
# is not the same as changing what root does. The cost is two copies, and two
# copies can differ: edit usb-dhcp.sh, plug the cable in, and the board does
# exactly what it did before. Nothing else shows that - the file is right, the
# unit is right, the journal has no error in it.
#
# status.sh is where the comparison is made, because it is what a person runs
# when the board is not doing what they expect. What is tested is that it says
# "same" only when they are, and names the file when they are not.
#
# Everything else status.sh prints is read straight out of sysfs and the
# journal, and is the board's to test.

setup() {
  load helpers/stub
  stub_setup

  REAL="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  # A checkout of our own, so a test can edit it. The real scripts, and the
  # real lib.sh - which works out where the checkout is from where IT is, so
  # the copies below are made from this directory and not from the repository.
  SRC="$BATS_TEST_TMPDIR/checkout"
  mkdir -p "$SRC/usb" "$SRC/status" "$SRC/mcu" "$SRC/provision"
  cp "$REAL"/usb/*.sh "$SRC/usb/"
  cp "$REAL/status/leds.sh" "$SRC/status/"
  cp "$REAL/mcu/link-up.sh" "$SRC/mcu/"
  cp "$REAL/provision/lib.sh" "$SRC/provision/"

  RT="$BATS_TEST_TMPDIR/unoq"
  export UNOQ_RUNTIME_DIR="$RT"
  export UNOQ_GADGET_DIR="$BATS_TEST_TMPDIR/gadget"
  export UNOQ_STATE_DIR="$BATS_TEST_TMPDIR/state"

  stub ip
  stub nmcli
  stub journalctl
  stub hostname 0 board
}

# What a provisioning step does to root's directory.
provision() {
  (
    # shellcheck disable=SC1091
    source "$SRC/provision/lib.sh"
    install_root_scripts
  ) >/dev/null || true # 1 only means "nothing changed"
}

# Only the section under test.
section() {
  awk '/^== what root runs ==$/ {on=1; next} /^== / {on=0} on' <<<"$output"
}

@test "copies that match the checkout are reported as the same" {
  provision
  run "$SRC/usb/status.sh"
  [ "$status" -eq 0 ]
  s="$(section)"
  [[ "$s" == *"root's copies"*"$RT"* ]]
  [[ "$s" == *"copied from"*"$SRC"* ]]
  [[ "$s" == *"same as $SRC"*"yes"* ]]
  [[ "$s" != *"DIFFERENT"* ]]
}

@test "a script edited since the last provisioning run is named" {
  provision
  echo "# an edit nobody has installed" >>"$SRC/usb/usb-dhcp.sh"
  run "$SRC/usb/status.sh"
  [ "$status" -eq 0 ]
  s="$(section)"
  [[ "$s" == *"DIFFERENT from $SRC"*"usb/usb-dhcp.sh"* ]]
  [[ "$s" != *"same as"* ]]
  # Only that one.
  [[ "$s" != *"usb/usb-route.sh"* ]]
  # And what to do about it: the step, with sudo, from this checkout.
  [[ "$s" == *"sudo bash $SRC/provision/35-status-leds.sh"* ]]
}

@test "running that step makes them the same again" {
  provision
  echo "# an edit" >>"$SRC/status/leds.sh"
  run "$SRC/usb/status.sh"
  [[ "$(section)" == *"DIFFERENT"*"status/leds.sh"* ]]
  provision
  run "$SRC/usb/status.sh"
  [[ "$(section)" == *"same as $SRC"*"yes"* ]]
}

@test "a script added to the checkout and not yet installed is named" {
  provision
  printf '#!/bin/bash\n' >"$SRC/usb/new-helper.sh"
  run "$SRC/usb/status.sh"
  [[ "$(section)" == *"DIFFERENT"*"usb/new-helper.sh"* ]]
}

@test "a script deleted from the checkout and still in root's directory is named" {
  provision
  rm "$SRC/usb/usb-profile.sh"
  run "$SRC/usb/status.sh"
  [[ "$(section)" == *"DIFFERENT"*"usb/usb-profile.sh"* ]]
}

@test "the env file is not one of the scripts being compared" {
  # It has no counterpart in the checkout, so comparing it would report a
  # difference on every board for ever.
  provision
  [ -f "$RT/env" ]
  run "$SRC/usb/status.sh"
  [[ "$(section)" != *"env"* ]]
}

@test "a board with no copies at all says so, and does not say 'same'" {
  # Never provisioned, or provisioned before the copies existed - in which
  # case the services are still running the checkout.
  run "$SRC/usb/status.sh"
  [ "$status" -eq 0 ]
  s="$(section)"
  [[ "$s" == *"<none at $RT>"* ]]
  [[ "$s" == *"Re-run the steps"* ]]
  [[ "$s" != *"same as"* ]]
}

@test "run as root's copy, it compares with the checkout the copies came from" {
  # `sudo /usr/local/lib/unoq/usb/status.sh` has no checkout beside it. The
  # env file says where one is.
  provision
  run "$RT/usb/status.sh"
  [ "$status" -eq 0 ]
  [[ "$(section)" == *"same as $SRC"*"yes"* ]]
  echo "# an edit" >>"$SRC/usb/wifi.sh"
  run "$RT/usb/status.sh"
  [[ "$(section)" == *"DIFFERENT from $SRC"*"usb/wifi.sh"* ]]
}

@test "run as root's copy with the checkout gone, it says there is nothing to compare" {
  provision
  mv "$SRC" "$SRC.moved"
  run "$RT/usb/status.sh"
  [ "$status" -eq 0 ]
  s="$(section)"
  [[ "$s" == *"not there to compare with"* ]]
  [[ "$s" != *"same as"* ]]
}

# --- a copy has to be a copy -------------------------------------------------
#
# The comparison used to list root's directory with `find -type f`. A script
# swapped for a symbolic link is not a regular file, so it was never listed,
# never compared, and the section said "same" about a board where root was
# running a file out of the checkout again.

@test "a script replaced by a link back to the checkout is not reported as the same" {
  provision
  rm "$RT/usb/usb-dhcp.sh"
  ln -s "$SRC/usb/usb-dhcp.sh" "$RT/usb/usb-dhcp.sh"
  run "$SRC/usb/status.sh"
  [ "$status" -eq 0 ]
  s="$(section)"
  [[ "$s" != *"same as"* ]]
  [[ "$s" == *"NOT ROOT'S OWN FILES"*"usb/usb-dhcp.sh(a-link)"* ]]
  # Only that one, and it is not passed off as merely out of date.
  [[ "$s" != *"usb/usb-route.sh"* ]]
  [[ "$s" != *"DIFFERENT"* ]]
}

@test "every script root runs is checked that way, not only the usb ones" {
  # The set here is spelled out in status.sh, which cannot source lib.sh when
  # it runs as root's copy. This is what goes red if the two lists part.
  provision
  mapfile -t set < <(
    # shellcheck disable=SC1091
    source "$SRC/provision/lib.sh"
    runtime_files
  )
  [ "${#set[@]}" -gt 3 ]
  for rel in "${set[@]}"; do
    rm "$RT/$rel"
    ln -s "$SRC/$rel" "$RT/$rel"
    run "$SRC/usb/status.sh"
    s="$(section)"
    [[ "$s" != *"same as"* ]]
    [[ "$s" == *"NOT ROOT'S OWN FILES"*"$rel(a-link)"* ]]
    provision
    run "$SRC/usb/status.sh"
    [[ "$(section)" == *"same as $SRC"*"yes"* ]]
  done
}

@test "a whole directory linked back to the checkout is not reported as the same" {
  # Every file under it is then a regular file with the right bytes.
  provision
  rm -r "$RT/usb"
  ln -s "$SRC/usb" "$RT/usb"
  run "$SRC/usb/status.sh"
  s="$(section)"
  [[ "$s" != *"same as"* ]]
  [[ "$s" == *"NOT ROOT'S OWN FILES"*"usb/usb-dhcp.sh(reached-through-a-link)"* ]]
  # The ones that are still real copies are not accused.
  [[ "$s" != *"status/leds.sh"* ]]
}

@test "a link to a file that is not there is not reported as the same either" {
  provision
  rm "$RT/status/leds.sh"
  ln -s "$BATS_TEST_TMPDIR/nowhere" "$RT/status/leds.sh"
  run "$SRC/usb/status.sh"
  s="$(section)"
  [[ "$s" != *"same as"* ]]
  [[ "$s" == *"status/leds.sh(a-link)"* ]]
}

@test "a directory where a script should be is not reported as the same" {
  provision
  rm "$RT/mcu/link-up.sh"
  mkdir "$RT/mcu/link-up.sh"
  run "$SRC/usb/status.sh"
  s="$(section)"
  [[ "$s" != *"same as"* ]]
  [[ "$s" == *"mcu/link-up.sh(not-a-file)"* ]]
}

@test "a stray link in root's directory that the checkout has no script for is named" {
  provision
  ln -s /bin/true "$RT/usb/left-behind.sh"
  run "$SRC/usb/status.sh"
  s="$(section)"
  [[ "$s" != *"same as"* ]]
  [[ "$s" == *"DIFFERENT"*"usb/left-behind.sh"* ]]
}
