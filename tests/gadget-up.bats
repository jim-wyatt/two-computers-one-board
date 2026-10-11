#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# gadget-up.sh - one question only: WHICH FILE does it hand the host as the
# drive?
#
# The image lives in the home directory of the person the board belongs to,
# and this script used to find that person by asking who owned the script.
# That was right for as long as the units ran it out of the checkout. They now
# run a root-owned copy from /usr/local/lib/unoq, whose owner is root, and the
# same line would have looked for /root/unoq-share.img, not found it, and
# built a gadget with an empty drive - a failure that looks exactly like "the
# image was never built", on the one part of the gadget nobody checks until a
# student plugs the board in.
#
# So provisioning writes the owner's home into an `env` file beside the copies
# and the script reads it. Both layouts are run here, the real script each
# time: from the checkout, and as the copy install_root_scripts makes.
#
# Everything else this script does is writes into configfs, which is the
# kernel's to interpret and the board's to test.

# lib.sh is sourced in a subshell below, and it assigns PROJECT; shellcheck
# reads that as this file's PROJECT being lost.
# shellcheck disable=SC2030,SC2031

setup() {
  load helpers/stub
  stub_setup

  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  # A configfs that is a directory. The gadget must not exist yet: an existing
  # one is left alone, and the image is only looked at on the way to building.
  mkdir -p "$BATS_TEST_TMPDIR/usb_gadget"
  export UNOQ_GADGET_DIR="$BATS_TEST_TMPDIR/usb_gadget/unoq"
  LUN="$UNOQ_GADGET_DIR/functions/mass_storage.0/lun.0"
  unset UNOQ_SHARE_IMG

  # The script refuses to run as anyone but root. Everything else id is asked
  # goes to the real one.
  stub_body id <<'SH'
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
SH
  stub modprobe

  # The kernel makes lun.0 when the mass storage function is created. A plain
  # directory does not, so the fake does it: without that the script could not
  # attach any image and every test would pass on the warning alone.
  stub_body mkdir <<'SH'
/bin/mkdir "$@" || exit 1
for a in "$@"; do
  case "$a" in */functions/mass_storage.0) /bin/mkdir -p "$a/lun.0" ;; esac
done
exit 0
SH

  # Two homes, so the wrong one is distinguishable from the right one.
  OWNER="$BATS_TEST_TMPDIR/home/owner"
  ROOTHOME="$BATS_TEST_TMPDIR/home/root"
  mkdir -p "$OWNER" "$ROOTHOME"
  : >"$OWNER/unoq-share.img"
  export OWNER ROOTHOME
  ME="$(/usr/bin/id -un)"
  export ME
  stub_body getent <<'SH'
[ "$1" = passwd ] || exit 2
case "$2" in
  root) echo "root:x:0:0:root:$ROOTHOME:/bin/bash" ;;
  "$ME") echo "$ME:x:1000:1000::$OWNER:/bin/bash" ;;
  *) exit 2 ;;
esac
SH
}

# The copies a provisioning step would make, for a board whose owner lives in
# <home>. Made by the real install_root_scripts, so the env file under test is
# the one lib.sh writes and not a fixture that agrees with the script by
# construction.
root_copies() {
  RT="$BATS_TEST_TMPDIR/unoq"
  (
    export UNOQ_RUNTIME_DIR="$RT"
    # shellcheck disable=SC1091
    source "$PROJECT/provision/lib.sh"
    TARGET_HOME="$1"
    install_root_scripts
  ) >/dev/null
  [ -x "$RT/usb/gadget-up.sh" ]
}

# As on the board: the copy belongs to root, whoever the suite runs as.
owned_by_root() {
  stub_body stat <<'SH'
[ "$1 $2" = "-c %U" ] && { echo root; exit 0; }
exec /usr/bin/stat "$@"
SH
}

# --- from the checkout ------------------------------------------------------

@test "from the checkout, the drive is the image in the checkout owner's home" {
  run "$PROJECT/usb/gadget-up.sh" --build
  [ "$status" -eq 0 ]
  [ "$(cat "$LUN/file")" = "$OWNER/unoq-share.img" ]
  [[ "$output" != *"WARNING"* ]]
  ran "getent passwd $ME"
}

# --- as root's copy ---------------------------------------------------------

@test "as root's copy, the drive is the image in the home provisioning recorded" {
  root_copies "$OWNER"
  owned_by_root
  run "$RT/usb/gadget-up.sh" --build
  [ "$status" -eq 0 ]
  [ "$(cat "$LUN/file")" = "$OWNER/unoq-share.img" ]
  [[ "$output" != *"WARNING"* ]]
  [[ "$output" != *"$ROOTHOME"* ]]
}

@test "the recorded home is used even when the file's owner has an image too" {
  # The env file is not a fallback for when asking the owner fails. Asking the
  # owner is the thing that is wrong for a root-owned copy, so it must not be
  # asked first.
  : >"$ROOTHOME/unoq-share.img"
  root_copies "$OWNER"
  owned_by_root
  run "$RT/usb/gadget-up.sh" --build
  [ "$status" -eq 0 ]
  [ "$(cat "$LUN/file")" = "$OWNER/unoq-share.img" ]
}

@test "without the env file, root's copy looks in root's home - which is the bug" {
  # Not behavior anyone wants: this is what the env file prevents, pinned so
  # that the two tests above cannot pass for some other reason. Delete the
  # file and the old answer comes back, and it is loud about the missing image.
  root_copies "$OWNER"
  owned_by_root
  rm "$RT/env"
  run "$RT/usb/gadget-up.sh" --build
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: $ROOTHOME/unoq-share.img missing"* ]]
  [ ! -e "$LUN/file" ]
}

@test "an env file with no home in it falls back to asking, not to nothing" {
  root_copies "$OWNER"
  echo "# emptied" >"$RT/env"
  run "$RT/usb/gadget-up.sh" --build
  [ "$status" -eq 0 ]
  # The copy here really is owned by whoever runs the suite, so asking works.
  [ "$(cat "$LUN/file")" = "$OWNER/unoq-share.img" ]
}

# --- the setting still wins -------------------------------------------------

@test "UNOQ_SHARE_IMG overrides the home directory in both layouts" {
  # It reaches the units through /etc/default/unoq-usb, and a board that moved
  # its image there must not have it moved back by a provisioning run.
  : >"$BATS_TEST_TMPDIR/elsewhere.img"
  export UNOQ_SHARE_IMG="$BATS_TEST_TMPDIR/elsewhere.img"
  run "$PROJECT/usb/gadget-up.sh" --build
  [ "$status" -eq 0 ]
  [ "$(cat "$LUN/file")" = "$BATS_TEST_TMPDIR/elsewhere.img" ]

  rm -rf "$UNOQ_GADGET_DIR"
  root_copies "$OWNER"
  owned_by_root
  run "$RT/usb/gadget-up.sh" --build
  [ "$status" -eq 0 ]
  [ "$(cat "$LUN/file")" = "$BATS_TEST_TMPDIR/elsewhere.img" ]
}

@test "a missing image is named, so the empty drive has an explanation" {
  rm "$OWNER/unoq-share.img"
  root_copies "$OWNER"
  owned_by_root
  run "$RT/usb/gadget-up.sh" --build
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: $OWNER/unoq-share.img missing - build it with share/build-image.sh"* ]]
}

# --- what the drive calls itself ---------------------------------------------

@test "the drive's name fills the vendor and product fields it is split into" {
  # 8 characters of vendor, 16 of product. "UNO-Q Share" written straight in
  # was cut after the eighth, and Windows listed the drive as "UNO-Q Sh are".
  run "$PROJECT/usb/gadget-up.sh" --build
  [ "$status" -eq 0 ]
  name="$(cat "$LUN/inquiry_string")"
  [ "${#name}" -eq 24 ]
  [ "${name:0:8}" = "UNO-Q   " ]
  [ "${name:8:5}" = "Share" ]
}
