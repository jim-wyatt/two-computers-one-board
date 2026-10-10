#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Build the FAT32 image the board hands out as a USB drive.
#
#   sudo bash ~/two-computers-one-board/share/build-image.sh            # create/refresh
#   sudo bash ~/two-computers-one-board/share/build-image.sh --rw       # leave it writable
#
# Idempotent: an image that is already correct is reused and its content synced.
#
# THE IMAGE IS THE ONLY COPY
# --------------------------
# It would be simpler to keep a staging directory and copy it into an image,
# but that means storing ~2 GB of VS Code installers twice on a board with a
# 10 GB rootfs. Instead the image IS the store: it is mounted read-only at
# $MOUNT for the web server to serve, and the same file is what
# usb_f_mass_storage exports. One copy, one source of truth, no chance of the
# USB drive and the web page disagreeing about what is on the board.
#
# WHY A PARTITION TABLE
# ---------------------
# The obvious thing is to mkfs the image file directly, giving a filesystem
# that starts at sector 0 - a "superfloppy". Linux mounts that happily, which
# is exactly why it survives testing on the board.
#
# Windows does not. A real USB stick has an MBR with a partition inside it, and
# Windows is unreliable about assigning a drive letter to removable media
# without one: the device enumerates, the mass-storage function binds, the
# file-storage thread runs, and no drive ever appears - with nothing logged on
# the Linux side, because from the board's point of view everything worked.
#
# So: MBR, one primary partition of type 0x0c (FAT32 LBA) starting at 1 MiB.
# Everything below has to account for that offset, including the fstab entry.
#
# FAT32 because it is the one filesystem Windows, macOS and Linux all mount
# with no driver and no prompting. Its 4 GB per-file limit is not a constraint
# here - the largest installer is ~530 MB.
#
# WHY READ-ONLY
# -------------
# The host and the board would otherwise both be writing the same blocks with
# neither one's page cache knowing about the other, which corrupts the
# filesystem in short order. The gadget exports it with ro=1 and the board
# mounts it ro; --rw is for updating content and is not how it normally runs.
#
# THE WEB SERVER IS STOPPED WHILE THE IMAGE IS REMOUNTED
# ------------------------------------------------------
# A read-only loop mount cannot be flipped to rw in place, so updating means
# unmounting - and unoq-learn.service serves from $MOUNT, so on a provisioned
# board the mount is always busy. If that unit is running when the unmount is
# needed, this script stops it and starts it again on the way out, on every
# exit path including a failure. A unit that was not running is left alone.
#
# Anything else holding the mount (a shell that has cd'd into it) is named,
# using fuser, and the script stops there. It never uses `umount -l`: a lazy
# unmount succeeds in exactly the case where something is still writing.
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")/.." && pwd)/provision/lib.sh"
need_root

IMG="${UNOQ_SHARE_IMG:-$TARGET_HOME/unoq-share.img}"
MOUNT="${UNOQ_SHARE_MOUNT:-/srv/unoq-share}"
SIZE_MB="${UNOQ_SHARE_SIZE_MB:-2600}"
STAGING="${UNOQ_SHARE:-/var/lib/unoq-share}"
GADGET_LUN=/sys/kernel/config/usb_gadget/unoq/functions/mass_storage.0/lun.0/file
# 2048 sectors x 512 bytes. The conventional first-partition offset, and what
# every partitioning tool picks by default.
PART_OFFSET=1048576
# The unit that serves $MOUNT over HTTP, and whether this run stopped it.
LEARN_UNIT=unoq-learn.service
LEARN_STOPPED=0
LEAVE_RW=0
[ "${1:-}" = "--rw" ] && LEAVE_RW=1

# --- helpers ---------------------------------------------------------------

# partitioned <file> - true if the image has an MBR we wrote, rather than a
# filesystem sitting directly on sector 0.
partitioned() {
  [ "$(blkid -p -o value -s PTTYPE "$1" 2>/dev/null)" = dos ]
}

# eject_gadget / insert_gadget - the mass-storage function keeps the backing
# file open. Swapping the file underneath it is a media change, which is a
# supported thing to do to a removable LUN and does not need a re-bind - so
# the network half of the gadget, and any ssh session running over it, stays
# up while the drive is replaced.
eject_gadget() {
  [ -w "$GADGET_LUN" ] || return 0
  [ -s "$GADGET_LUN" ] || return 0
  echo "" >"$GADGET_LUN" 2>/dev/null && did "gadget: medium ejected while we work"
}
insert_gadget() {
  [ -w "$GADGET_LUN" ] || return 0
  # The whole attribute set, not just the file.
  #
  # gadget-up.sh sets these when it builds the gadget, but ONLY inside
  # `if [ -f "$IMG" ]` - and on a board provisioned in the documented order the
  # image does not exist yet at that point, so the block is skipped and the LUN
  # keeps kernel defaults. Attaching the medium here without them left the drive
  # exported ro=0: read-WRITE, on a filesystem the board has mounted and cached.
  # docs/usb.md is emphatic that this is how a FAT filesystem gets destroyed,
  # and the protection it describes was absent on every board that built its
  # image after the gadget - which is every board that follows the instructions.
  #
  # ro cannot be changed while a medium is attached, which is why this runs
  # after eject_gadget and not on its own.
  local lun
  lun="$(dirname "$GADGET_LUN")"
  echo 1 >"$lun/removable" 2>/dev/null
  echo 1 >"$lun/ro" 2>/dev/null
  echo 0 >"$lun/cdrom" 2>/dev/null
  echo "UNO-Q Share" >"$lun/inquiry_string" 2>/dev/null
  echo "$IMG" >"$GADGET_LUN" 2>/dev/null &&
    did "gadget: medium re-inserted read-only ($IMG)"
}

# format_and_mount <image> <mountpoint> - partition, mkfs, mount rw.
format_and_mount() {
  local img="$1" mnt="$2"
  # One primary FAT32-LBA partition filling the image from 1 MiB on.
  printf 'label: dos\nstart=2048, type=0c\n' | sfdisk -q "$img" >/dev/null ||
    fail "could not write a partition table to $img"
  local loop
  loop="$(losetup -P -f --show "$img")" || fail "losetup failed for $img"
  # -P asks the kernel to scan the table; the partition node appears as p1.
  [ -b "${loop}p1" ] || {
    losetup -d "$loop"
    fail "no partition node ${loop}p1 - did the partition table not take?"
  }
  mkfs.vfat -F 32 -n "UNO-Q" "${loop}p1" >/dev/null || {
    losetup -d "$loop"
    fail "mkfs.vfat failed"
  }
  losetup -d "$loop"
  mkdir -p "$mnt"
  mount -o loop,rw,offset="$PART_OFFSET",umask=0022,utf8 "$img" "$mnt" ||
    fail "could not mount $img at $mnt"
}

# pause_learn / resume_learn - the web server serves from $MOUNT, so it holds
# the mount busy for as long as it runs. Stop it for the unmount, and put it
# back afterwards - but only if it was running and it was us that stopped it.
#
# resume_learn is called once on the way through and again from the EXIT trap,
# which is what covers `fail` (it exits) and a signal. The flag is cleared
# before the start is attempted so the two calls cannot both act.
#
# REVERT: systemctl start unoq-learn.service
pause_learn() {
  systemctl is-active --quiet "$LEARN_UNIT" 2>/dev/null || return 0
  # Set before the stop, not after: a stop that fails half-way leaves the unit
  # in an unknown state, and starting it again is right in every one of them.
  LEARN_STOPPED=1
  systemctl stop "$LEARN_UNIT" || fail "could not stop $LEARN_UNIT, which holds $MOUNT open"
  did "$LEARN_UNIT stopped while $MOUNT is remounted"
}
resume_learn() {
  [ "$LEARN_STOPPED" = 1 ] || return 0
  LEARN_STOPPED=0
  if systemctl start "$LEARN_UNIT"; then
    did "$LEARN_UNIT started again"
  else
    warn "$LEARN_UNIT was stopped by this script and did not start again:"
    warn "  sudo systemctl start $LEARN_UNIT"
    return 1
  fi
}
trap resume_learn EXIT

# unmount_share - unmount $MOUNT, or say who is in the way.
#
# `umount: target is busy` names the mount and not the process, which sends you
# looking at the image when the cause is a shell sitting in the directory.
unmount_share() {
  pause_learn
  umount "$MOUNT" && return 0
  local holders=""
  if command -v fuser >/dev/null 2>&1; then
    # -v writes its table to stderr; that table is the part worth showing.
    holders="$(fuser -vm "$MOUNT" 2>&1)"
  fi
  if [ -n "$holders" ]; then
    fail "could not unmount $MOUNT to remount it rw - still held open by:
$holders
  Close those (a shell that has cd'd into $MOUNT counts), then run this again."
  fi
  fail "could not unmount $MOUNT to remount it rw - something still holds it open.
  Find it with:  sudo fuser -vm $MOUNT   (apt install psmisc)
  Close it (a shell that has cd'd into $MOUNT counts), then run this again."
}

# --- tools -----------------------------------------------------------------

step "tools"
apt_install dosfstools fdisk rsync

# --- migrate a superfloppy image, keeping its contents ---------------------

if [ -f "$IMG" ] && ! partitioned "$IMG"; then
  step "repartitioning (image has no partition table)"
  warn "this image was built without an MBR, which is why Windows shows no drive"
  NEW="$IMG.new"
  OLDMNT="$(mktemp -d)"
  rm -f "$NEW"
  truncate -s "${SIZE_MB}M" "$NEW" || fail "could not create $NEW"
  format_and_mount "$NEW" "$MOUNT.new"

  # Read the old one exactly as it is now - read-only, and via its own mount so
  # we do not disturb $MOUNT or care whether it is currently mounted.
  mount -o loop,ro "$IMG" "$OLDMNT" || fail "could not mount the old image"
  did "copying $(du -sh "$OLDMNT" | cut -f1) across (no re-download)"
  cp -a "$OLDMNT/." "$MOUNT.new/" || fail "copy failed - $NEW left in place, $IMG untouched"
  sync
  umount "$OLDMNT" && rmdir "$OLDMNT"
  umount "$MOUNT.new" && rmdir "$MOUNT.new"

  # Only now let go of the old file: everything above could have failed with
  # the original still the one the gadget and the web server were using.
  eject_gadget
  mountpoint -q "$MOUNT" && umount "$MOUNT"
  mv "$NEW" "$IMG" || fail "could not replace $IMG"
  chown "$TARGET_USER" "$IMG"
  did "repartitioned in place, contents preserved"
fi

# --- image file ------------------------------------------------------------

step "image file"
mkdir -p "$(dirname "$IMG")"
if [ -f "$IMG" ]; then
  skip "$IMG exists ($(($(stat -c %s "$IMG") / 1024 / 1024)) MB)"
else
  # Sparse: the file reads as $SIZE_MB but only occupies the blocks actually
  # written, so an image sized for future content costs nothing until used.
  truncate -s "${SIZE_MB}M" "$IMG" || fail "could not create $IMG"
  chown "$TARGET_USER" "$IMG"
  did "created $IMG (${SIZE_MB} MB, sparse)"
fi

step "partition table + filesystem"
if partitioned "$IMG" && blkid -o value -s TYPE "$IMG" 2>/dev/null | grep -q . 2>/dev/null; then
  skip "MBR present, partition formatted"
elif partitioned "$IMG"; then
  skip "MBR present"
else
  eject_gadget
  mountpoint -q "$MOUNT" && umount "$MOUNT"
  format_and_mount "$IMG" "$MOUNT"
  did "MBR + FAT32 partition, label UNO-Q"
fi

# --- mount -----------------------------------------------------------------

step "mount"
if mountpoint -q "$MOUNT"; then
  mount -o remount,rw "$MOUNT" 2>/dev/null || {
    unmount_share
    mount -o loop,rw,offset="$PART_OFFSET",umask=0022,utf8 "$IMG" "$MOUNT" ||
      fail "could not remount $MOUNT rw"
  }
  skip "$MOUNT remounted rw for the update"
else
  mkdir -p "$MOUNT"
  mount -o loop,rw,offset="$PART_OFFSET",umask=0022,utf8 "$IMG" "$MOUNT" ||
    fail "could not mount $IMG at $MOUNT"
  did "mounted $IMG (partition at +$PART_OFFSET) at $MOUNT"
fi

# --- content ---------------------------------------------------------------

step "content"
# Render the documentation first, so the drive cannot ship a stale copy.
#
# The markdown in docs/ is the single source: GitHub reads it directly, and this
# renders it to share/learn/ for the web server and for the drive. Building it
# here rather than trusting whatever happens to be checked in is what stops the
# three copies drifting - which is the same reason the image itself is the only
# store rather than a staging directory.
#
# share/learn/ is NOT in the repository any more, so a failure here is a drive
# with no content rather than a drive with stale content. That is the right way
# round: an empty drive is obviously broken, a stale one is quietly wrong.
if as_user "$PROJECT/tools/build-docs.sh" >/dev/null 2>&1; then
  did "documentation rendered from docs/ into share/learn/"
else
  warn "tools/build-docs.sh failed - run it directly to see why:"
  warn "  $PROJECT/tools/build-docs.sh"
fi

if [ -d "$PROJECT/share/learn" ]; then
  # --delete, because a copy that only ever grows is a copy that lies.
  #
  # This was a plain `rsync -a` while the generator wrote one flat directory of
  # pages, where the file set never shrank and stale files could not accumulate.
  # The moment the site grew subdirectories, the drive ended up carrying BOTH
  # layouts - twenty pages from the old build sitting beside the new tree, all
  # still reachable, all quietly out of date. Exactly the disagreement between
  # the three copies that rebuilding here is supposed to prevent.
  #
  # --exclude protects the installers, which are on the drive and are NOT in
  # share/learn: rsync does not delete excluded paths, so this deletes stale
  # documentation without touching the ~2 GB that took an hour to download.
  #
  # -rlt, NOT -a. The target is FAT32, which has no owners, no groups and no
  # permission bits, and -a implies -o -g -p. Every chown fails with EPERM even
  # as root - there is nothing on the filesystem to write them to - so rsync
  # exits non-zero and this step reported FAILED while having copied every byte
  # correctly:
  #
  #   rsync: [generator] chown "/srv/unoq-share/." failed: Operation not permitted
  #
  # Ownership and permissions on this mount come from the fmask/dmask/umask
  # mount options instead, which is the only place FAT can express them.
  rsync -rlt --delete --exclude '/vscode/' "$PROJECT/share/learn/" "$MOUNT/" ||
    fail "could not sync the documentation onto $MOUNT"
  did "learning content synced from share/learn/ (stale pages removed)"
else
  warn "$PROJECT/share/learn missing - no landing page on the drive"
fi

# Installers are downloaded, not in the repo (they are Microsoft's, and ~2 GB).
if [ -d "$STAGING/vscode" ] && compgen -G "$STAGING/vscode/*" >/dev/null; then
  mkdir -p "$MOUNT/vscode"
  # Move rather than copy: the staging copy is on the small rootfs and there is
  # not room for both. After this the image is the only copy, as intended.
  if mv "$STAGING"/vscode/* "$MOUNT/vscode/" 2>/dev/null; then
    rmdir "$STAGING/vscode" "$STAGING" 2>/dev/null
    did "installers moved into the image ($(du -sh "$MOUNT/vscode" | cut -f1))"
  else
    cp -n "$STAGING"/vscode/* "$MOUNT/vscode/" && did "installers copied into the image"
  fi
elif [ -d "$MOUNT/vscode" ] && compgen -G "$MOUNT/vscode/*" >/dev/null; then
  skip "installers already in the image ($(du -sh "$MOUNT/vscode" | cut -f1))"
else
  warn "no installers found - run share/fetch-vscode.sh first"
fi

sync

# --- back to read-only, and hand the drive back ----------------------------

step "remount read-only"
if [ "$LEAVE_RW" = 1 ]; then
  warn "left mounted rw (--rw). Do NOT let the host mount the drive while it is."
else
  mount -o remount,ro "$MOUNT" || fail "could not remount $MOUNT read-only"
  did "$MOUNT is read-only"
fi

step "gadget"
insert_gadget || skip "gadget not bound - nothing to re-insert"

if [ "$LEARN_STOPPED" = 1 ]; then
  step "web server"
  resume_learn || fail "$LEARN_UNIT is not running - the image itself is built and in place"
fi

step "result"
skip "image:   $IMG ($(du -h --apparent-size "$IMG" | cut -f1) apparent, $(du -h "$IMG" | cut -f1) on disk)"
skip "layout:  $(blkid -p -o value -s PTTYPE "$IMG" 2>/dev/null || echo none) partition table, FAT32 at +$PART_OFFSET"
skip "mounted: $MOUNT"
skip "free:    $(df -h "$MOUNT" | awk 'NR==2 {print $4}') left in the image"

summary
cat <<EOF

If the fstab entry predates this, it needs the partition offset adding:
  $IMG $MOUNT vfat loop,ro,nofail,offset=$PART_OFFSET,umask=0022,utf8 0 0
provision/70-learning-web.sh writes it correctly.
EOF
