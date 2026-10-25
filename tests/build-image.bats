#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# share/build-image.sh has to unmount /srv/unoq-share to make it writable, and
# on a provisioned board something is always holding it: unoq-learn.service
# serves from that directory. The script used to stop at
#
#   umount: /srv/unoq-share: target is busy.
#     FAILED  could not remount /srv/unoq-share rw
#
# which reads as a broken build and is a lock. It now stops the web server
# itself and starts it again, and the thing that must never happen is the
# second half being skipped: a build that fails half-way and leaves the web
# server down, on a board whose landing page is how people find their way in.
#
# The other half is a holder the script cannot move - a shell that has cd'd
# into the mount. That one has to be NAMED, and must never be papered over with
# `umount -l`, which succeeds in exactly the case where something is writing.
#
# What this cannot show: that a stopped unoq-learn really lets go of the mount,
# or that fuser's table looks like the one faked here. That is the board's job.

setup() {
  load helpers/stub
  stub_setup

  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BUILD="$PROJECT/share/build-image.sh"

  # The script's own overrides, pointed away from /srv and /var/lib.
  export UNOQ_SHARE_IMG="$BATS_TEST_TMPDIR/unoq-share.img"
  export UNOQ_SHARE_MOUNT="$BATS_TEST_TMPDIR/mnt"
  export UNOQ_SHARE="$BATS_TEST_TMPDIR/staging"
  UNOQ_USER="$(id -un)"
  export UNOQ_USER
  : >"$UNOQ_SHARE_IMG"
  mkdir -p "$UNOQ_SHARE_MOUNT"

  # Each fake below answers from a flag file, so a test changes the board's
  # state by touching a file rather than by rewriting a stub.
  FLAGS="$BATS_TEST_TMPDIR/flags"
  mkdir -p "$FLAGS"
  export FLAGS

  # need_root asks `id -u`. Everything else id is asked goes to the real one.
  stub_body id <<'SH'
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
SH

  # Packages present, image already partitioned and formatted: the run goes
  # straight to the mount step, which is the one under test.
  #
  # TYPE is answered only for the partition (-O, an offset). The whole image
  # has nothing at sector 0 but the partition table, so real blkid prints no
  # TYPE for it - and a stub that answered vfat for the whole file is how the
  # script's "already formatted" check passed here while never once being true
  # on a board.
  stub dpkg-query 0 "install ok installed"
  stub_body blkid <<'SH'
case "$*" in
  *PTTYPE*) [ -e "$FLAGS/no-partition-table" ] || echo dos ;;
  *-O*TYPE*)
    [ -e "$FLAGS/probe-fails" ] && exit 8
    [ -e "$FLAGS/no-filesystem" ] && exit 2
    echo vfat
    ;;
  *TYPE*) exit 2 ;;
esac
exit 0
SH
  stub mountpoint

  # A read-only loop mount cannot be flipped to rw in place - that refusal is
  # what sends the script down the unmount path at all.
  stub_body mount <<'SH'
case "$*" in
  "-o remount,rw "*) [ -e "$FLAGS/remount-rw-works" ] && exit 0 || exit 32 ;;
  "-o remount,ro "*) [ -e "$FLAGS/remount-ro-fails" ] && exit 32 || exit 0 ;;
esac
exit 0
SH
  # Busy means the share's own mountpoint. The scratch mounts a migration makes
  # for itself are nobody else's to hold.
  stub_body umount <<'SH'
if [ -e "$FLAGS/mount-busy" ] && [ "${*: -1}" = "$UNOQ_SHARE_MOUNT" ]; then
  echo "umount: ${*: -1}: target is busy." >&2
  exit 32
fi
exit 0
SH
  stub_body systemctl <<'SH'
case "$1" in
  is-active) [ -e "$FLAGS/learn-active" ] && exit 0 || exit 3 ;;
  start) [ -e "$FLAGS/learn-start-fails" ] && exit 1 || exit 0 ;;
esac
exit 0
SH
  # fuser -v writes its table to stderr and the bare pids to stdout.
  stub_body fuser <<'SH'
{
  echo "                     USER        PID ACCESS COMMAND"
  echo "${*: -1}:  arduino    4242 ..c.. byobu-shell"
} >&2
echo " 4242"
exit 0
SH

  stub runuser
  stub rsync
  stub sync
  stub chown
  stub du 0 "1.0M	x"
  stub df
}

# line_of <extended regex> - where in the call log the first match is, so two
# calls can be put in order.
line_of() { grep -nE "$1" "$STUB_LOG" | head -1 | cut -d: -f1; }

learn_active() { : >"$FLAGS/learn-active"; }

# --- the service is ours to move -------------------------------------------

@test "a running unoq-learn is stopped before the unmount and started after the update" {
  learn_active
  run bash "$BUILD"
  [ "$status" -eq 0 ]

  stop="$(line_of '^systemctl stop unoq-learn\.service$')"
  unmount="$(line_of "^umount $UNOQ_SHARE_MOUNT\$")"
  rw="$(line_of '^mount -o loop,rw,')"
  ro="$(line_of '^mount -o remount,ro ')"
  start="$(line_of '^systemctl start unoq-learn\.service$')"
  [ -n "$stop" ] && [ -n "$unmount" ] && [ -n "$rw" ] && [ -n "$ro" ] && [ -n "$start" ]
  [ "$stop" -lt "$unmount" ]
  [ "$unmount" -lt "$rw" ]
  [ "$rw" -lt "$ro" ]
  [ "$ro" -lt "$start" ]
}

@test "both halves are reported in the script's own vocabulary" {
  learn_active
  run bash "$BUILD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"changed  unoq-learn.service stopped while $UNOQ_SHARE_MOUNT is remounted"* ]]
  [[ "$output" == *"changed  unoq-learn.service started again"* ]]
}

@test "it is started exactly once, not again by the exit trap" {
  learn_active
  run bash "$BUILD"
  [ "$status" -eq 0 ]
  [ "$(grep -cx 'systemctl start unoq-learn.service' "$STUB_LOG")" -eq 1 ]
}

@test "a unoq-learn that was not running is neither stopped nor started" {
  # An unprovisioned board, or one where it was stopped on purpose. Starting a
  # service somebody stopped is not this script's decision to make.
  run bash "$BUILD"
  [ "$status" -eq 0 ]
  ran "systemctl is-active --quiet unoq-learn.service"
  refute ran_like '^systemctl (stop|start|restart) '
  [[ "$output" != *"unoq-learn"* ]]
}

@test "a mount that goes rw in place leaves the web server running" {
  # No unmount needed, so nothing is holding anything: the old behavior,
  # unchanged, including not asking systemd anything at all.
  learn_active
  : >"$FLAGS/remount-rw-works"
  run bash "$BUILD"
  [ "$status" -eq 0 ]
  never_ran umount
  never_ran systemctl
}

# --- and has to come back, whatever happens --------------------------------

@test "a later step failing still starts unoq-learn again" {
  learn_active
  : >"$FLAGS/remount-ro-fails"
  run bash "$BUILD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED  could not remount $UNOQ_SHARE_MOUNT read-only"* ]]

  stop="$(line_of '^systemctl stop unoq-learn\.service$')"
  start="$(line_of '^systemctl start unoq-learn\.service$')"
  [ -n "$stop" ] && [ -n "$start" ]
  [ "$stop" -lt "$start" ]
  [[ "$output" == *"unoq-learn.service started again"* ]]
}

@test "a later step failing does not start a unoq-learn that was never running" {
  : >"$FLAGS/remount-ro-fails"
  run bash "$BUILD"
  [ "$status" -ne 0 ]
  refute ran_like '^systemctl (stop|start) '
}

@test "a unoq-learn that will not start again fails the run and says how to start it" {
  learn_active
  : >"$FLAGS/learn-start-fails"
  run bash "$BUILD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sudo systemctl start unoq-learn.service"* ]]
  [[ "$output" == *"FAILED  unoq-learn.service is not running"* ]]
  # One attempt: the trap must not retry what the main path just reported.
  [ "$(grep -cx 'systemctl start unoq-learn.service' "$STUB_LOG")" -eq 1 ]
}

# --- a holder that is not ours to move -------------------------------------

@test "a mount still busy after that fails and names the holder from fuser" {
  learn_active
  : >"$FLAGS/mount-busy"
  run bash "$BUILD"
  [ "$status" -ne 0 ]
  ran "fuser -vm $UNOQ_SHARE_MOUNT"
  [[ "$output" == *"FAILED  could not unmount $UNOQ_SHARE_MOUNT"* ]]
  [[ "$output" == *"4242"* ]]
  [[ "$output" == *"byobu-shell"* ]]
  [[ "$output" == *"then run this again"* ]]
}

@test "a busy mount is never unmounted lazily or by force" {
  learn_active
  : >"$FLAGS/mount-busy"
  run bash "$BUILD"
  [ "$status" -ne 0 ]
  # Exactly the one plain attempt, and no flag on it of any kind.
  [ "$(grep -c '^umount' "$STUB_LOG")" -eq 1 ]
  ran "umount $UNOQ_SHARE_MOUNT"
  refute ran_like '^umount( .*)? (-[a-zA-Z]*[lf][a-zA-Z]*|--lazy|--force)( |$)'
  # And nothing written to an image that could not be remounted.
  refute ran_like '^mount -o loop,rw'
  never_ran rsync
}

@test "a busy mount still gets unoq-learn started again" {
  # The failure is the shell in the directory, not the web server - so the web
  # server goes back up, serving the read-only mount that never went away.
  learn_active
  : >"$FLAGS/mount-busy"
  run bash "$BUILD"
  [ "$status" -ne 0 ]
  [ "$(grep -cx 'systemctl start unoq-learn.service' "$STUB_LOG")" -eq 1 ]
}

@test "a busy mount with nothing to restart says so without touching systemd further" {
  : >"$FLAGS/mount-busy"
  run bash "$BUILD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"byobu-shell"* ]]
  refute ran_like '^systemctl (stop|start) '
}

# --- the two branches that replace what is under the mount -------------------
#
# Remounting was the only unmount that stopped the web server and the only one
# whose failure was looked at. An image with no partition table is replaced
# (when it has content) or formatted (when it is new), and both of those called
# umount themselves and carried on whatever it said - so with unoq-learn running
# the unmount failed as busy, every time, and the image was swapped or formatted
# underneath a mount that was still being served.

# What format_and_mount shells out to. It also insists that "${loop}p1" is a
# block device, with a test no fake on PATH can answer - so losetup hands back
# the name of a real one with its "p1" taken off (/dev/loop1 -> /dev/loo), and
# a machine that has no such node skips the tests that get that far. Nothing
# is ever done to the device: every command that would touch it is a stub.
formatting_tools() {
  local dev
  LOOP_STEM=""
  for dev in /dev/*p1; do
    [ -b "$dev" ] && LOOP_STEM="${dev%p1}" && break
  done
  export LOOP_STEM
  stub sfdisk
  stub mkfs.vfat
  stub_body losetup <<'SH'
case "$*" in *--show*) echo "$LOOP_STEM" ;; esac
exit 0
SH
  # The script's own default is 2600 MB of sparse file; nothing here needs it.
  export UNOQ_SHARE_SIZE_MB=1
}

needs_a_partition_node() {
  [ -n "$LOOP_STEM" ] || skip "no block device named *p1 in /dev to stand in for the loop partition"
}

@test "a new image is not formatted under a mount that will not let go" {
  formatting_tools
  rm "$UNOQ_SHARE_IMG"
  : >"$FLAGS/no-partition-table"
  : >"$FLAGS/mount-busy"
  learn_active
  run bash "$BUILD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED  could not unmount $UNOQ_SHARE_MOUNT before formatting"* ]]
  [[ "$output" == *"byobu-shell"* ]]
  # The web server was moved out of the way first, and put back.
  stop="$(line_of '^systemctl stop unoq-learn\.service$')"
  unmount="$(line_of "^umount $UNOQ_SHARE_MOUNT\$")"
  [ -n "$stop" ] && [ -n "$unmount" ] && [ "$stop" -lt "$unmount" ]
  [ "$(grep -cx 'systemctl start unoq-learn.service' "$STUB_LOG")" -eq 1 ]
  # And nothing was written to the image.
  never_ran sfdisk
  never_ran losetup
  never_ran mkfs.vfat
  refute ran_like '^umount( .*)? (-[a-zA-Z]*[lf][a-zA-Z]*|--lazy|--force)( |$)'
}

@test "formatting a new image stops unoq-learn before the unmount, like the remount does" {
  formatting_tools
  needs_a_partition_node
  rm "$UNOQ_SHARE_IMG"
  : >"$FLAGS/no-partition-table"
  learn_active
  run bash "$BUILD"
  [ "$status" -eq 0 ]
  stop="$(line_of '^systemctl stop unoq-learn\.service$')"
  unmount="$(line_of "^umount $UNOQ_SHARE_MOUNT\$")"
  table="$(line_of '^sfdisk ')"
  [ -n "$stop" ] && [ -n "$unmount" ] && [ -n "$table" ]
  [ "$stop" -lt "$unmount" ]
  [ "$unmount" -lt "$table" ]
  [ "$(grep -cx 'systemctl start unoq-learn.service' "$STUB_LOG")" -eq 1 ]
}

@test "an image is not replaced under a mount that will not let go" {
  formatting_tools
  needs_a_partition_node
  echo "the image the board is serving" >"$UNOQ_SHARE_IMG"
  : >"$FLAGS/no-partition-table"
  : >"$FLAGS/mount-busy"
  learn_active
  run bash "$BUILD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED  could not unmount $UNOQ_SHARE_MOUNT before replacing"* ]]
  [[ "$output" == *"byobu-shell"* ]]
  # The whole point: the file under the live mount is the one that was there.
  [ "$(cat "$UNOQ_SHARE_IMG")" = "the image the board is serving" ]
  [ -f "$UNOQ_SHARE_IMG.new" ]
  [ "$(grep -cx "umount $UNOQ_SHARE_MOUNT" "$STUB_LOG")" -eq 1 ]
  refute ran_like '^umount( .*)? (-[a-zA-Z]*[lf][a-zA-Z]*|--lazy|--force)( |$)'
  [ "$(grep -cx 'systemctl start unoq-learn.service' "$STUB_LOG")" -eq 1 ]
}

@test "replacing an image stops unoq-learn first, and only then swaps the file" {
  formatting_tools
  needs_a_partition_node
  echo "the image the board is serving" >"$UNOQ_SHARE_IMG"
  : >"$FLAGS/no-partition-table"
  learn_active
  run bash "$BUILD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"repartitioned in place, contents preserved"* ]]
  stop="$(line_of '^systemctl stop unoq-learn\.service$')"
  unmount="$(line_of "^umount $UNOQ_SHARE_MOUNT\$")"
  [ -n "$stop" ] && [ -n "$unmount" ] && [ "$stop" -lt "$unmount" ]
  [ "$(cat "$UNOQ_SHARE_IMG")" != "the image the board is serving" ]
  [ ! -e "$UNOQ_SHARE_IMG.new" ]
  [ "$(grep -cx 'systemctl start unoq-learn.service' "$STUB_LOG")" -eq 1 ]
}

# --- the drive on a running gadget -------------------------------------------

@test "refreshing the image on a running gadget keeps the drive's name in its two fields" {
  # usb/gadget-up.sh writes the name when the gadget is built; this script
  # writes it again whenever it puts a refreshed image back. It wrote plain
  # "UNO-Q Share", which is cut after eight characters, and Windows went back
  # to listing "UNO-Q Sh are" until the next reboot.
  export UNOQ_GADGET_DIR="$BATS_TEST_TMPDIR/gadget"
  lun="$UNOQ_GADGET_DIR/functions/mass_storage.0/lun.0"
  mkdir -p "$lun"
  echo "$UNOQ_SHARE_IMG" >"$lun/file"
  run bash "$BUILD"
  [ "$status" -eq 0 ]
  name="$(cat "$lun/inquiry_string")"
  [ "${#name}" -eq 24 ]
  [ "${name:0:8}" = "UNO-Q   " ]
  [ "${name:8:5}" = "Share" ]
  # And the image is back in the drive, read-only.
  [ "$(cat "$lun/file")" = "$UNOQ_SHARE_IMG" ]
  [ "$(cat "$lun/ro")" = 1 ]
}

@test "a drive without the optional installers is not a warning" {
  # The VS Code installers are a separate download. Their absence was printed
  # as a warning on every default run, to someone who had done nothing wrong.
  run bash "$BUILD"
  [ "$status" -eq 0 ]
  [[ "$output" != *"no installers found"* ]]
  refute grep -q 'warn.*installers' <<<"$output"
  [[ "$output" == *"no VS Code installers on the drive (optional"* ]]
}

# --- an image left half-built -------------------------------------------------
#
# A run that stops between sfdisk and mkfs.vfat leaves a partition table with
# nothing in it. The check for "already formatted" asked blkid about the whole
# file, where no filesystem ever is, so it was never true; the half-built image
# took the "MBR present" branch on every later run and failed to mount, and
# re-running bootstrap - the documented way back - could not repair it.

@test "the filesystem is looked for inside the partition, not at sector 0" {
  run bash "$BUILD"
  [ "$status" -eq 0 ]
  ran "blkid -p -O 1048576 -o value -s TYPE $UNOQ_SHARE_IMG"
  [[ "$output" == *"MBR present, partition formatted (vfat)"* ]]
  never_ran mkfs.vfat
}

@test "a partition table with no filesystem in it is formatted, not mounted as it is" {
  formatting_tools
  needs_a_partition_node
  : >"$FLAGS/no-filesystem"
  run bash "$BUILD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no filesystem in it - an earlier run stopped part way"* ]]
  table="$(line_of '^sfdisk ')"
  fs="$(line_of '^mkfs\.vfat ')"
  [ -n "$table" ] && [ -n "$fs" ] && [ "$table" -lt "$fs" ]
}

@test "a probe that cannot tell is never a reason to format" {
  # blkid's 8 is "ambivalent", and anything but 0 or 2 is not an answer. The
  # image may hold the 2 GB of installers.
  formatting_tools
  : >"$FLAGS/probe-fails"
  run bash "$BUILD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED  could not tell whether the partition in $UNOQ_SHARE_IMG is formatted (blkid exit 8)"* ]]
  never_ran sfdisk
  never_ran mkfs.vfat
  never_ran rsync
}

# --- the drive is out of the computer while it is written --------------------

# a_gadget [forced_eject] - a LUN holding the image, as gadget-up.sh leaves it.
a_gadget() {
  export UNOQ_GADGET_DIR="$BATS_TEST_TMPDIR/gadget"
  LUN="$UNOQ_GADGET_DIR/functions/mass_storage.0/lun.0"
  mkdir -p "$LUN"
  echo "$UNOQ_SHARE_IMG" >"$LUN/file"
  [ "${1:-}" = forced_eject ] && : >"$LUN/forced_eject"
  export LUN
  # What the LUN held when the written content was flushed. sync, not rsync:
  # rsync runs only when share/learn has been built, and a clean checkout has
  # not built it.
  stub_body sync <<'SH'
cat "$LUN/file" >"$FLAGS/lun-during-write"
exit 0
SH
}

@test "a refresh takes the drive out of the computer before writing to it" {
  # The board was rewriting the documentation under a computer that had the
  # drive open. FAT has no way to tell the host its blocks moved.
  a_gadget
  : >"$FLAGS/remount-rw-works"
  run bash "$BUILD"
  [ "$status" -eq 0 ]
  [ -f "$FLAGS/lun-during-write" ]
  [ -z "$(tr -d '\n' <"$FLAGS/lun-during-write")" ]
  [[ "$output" == *"gadget: medium ejected while we work"* ]]
  # And back in, read-only, at the end.
  [ "$(cat "$LUN/file")" = "$UNOQ_SHARE_IMG" ]
  [ "$(cat "$LUN/ro")" = 1 ]
}

@test "forced_eject is used where the kernel has it" {
  # A plain write to `file` is refused while the host has the medium locked in,
  # which a mounted drive usually has.
  a_gadget forced_eject
  run bash "$BUILD"
  [ "$status" -eq 0 ]
  [ "$(cat "$LUN/forced_eject")" = 1 ]
}

@test "with --rw the drive is not handed back to the computer" {
  # The board has it mounted read-write. Two writers is the one thing the
  # whole read-only arrangement is there to prevent.
  a_gadget
  run bash "$BUILD" --rw
  [ "$status" -eq 0 ]
  [ -z "$(tr -d '\n' <"$LUN/file")" ]
  [[ "$output" == *"drive left ejected while $UNOQ_SHARE_MOUNT is writable"* ]]
}

@test "no gadget is reported as no gadget" {
  # The message was on the wrong side of the ||: printed when the medium did
  # not go back into a bound gadget, and never when there was no gadget.
  export UNOQ_GADGET_DIR="$BATS_TEST_TMPDIR/no-gadget"
  run bash "$BUILD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gadget not bound - nothing to re-insert"* ]]
  [[ "$output" != *"did not go back in"* ]]
}

@test "a bound gadget that will not take the medium back says so, and not that it is unbound" {
  # A directory where the attribute should be: writable, and refuses a write.
  export UNOQ_GADGET_DIR="$BATS_TEST_TMPDIR/gadget"
  mkdir -p "$UNOQ_GADGET_DIR/functions/mass_storage.0/lun.0/file"
  run bash "$BUILD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"the drive did not go back in"* ]]
  [[ "$output" != *"gadget not bound"* ]]
}
