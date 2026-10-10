#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Make the EFI system partition readable by root only.
#
#   sudo bash ~/two-computers-one-board/provision/85-esp-permissions.sh
#
# Idempotent: a second run reports "already correct" and changes nothing.
#
# NOT YET VALIDATED ON HARDWARE. Written from what the board reports and
# checked against faked commands only (tests/esp-permissions.bats).
#
# WHY
# ---
# systemd-boot complains on every boot, at priority 4:
#
#   ! Random seed file '/boot/efi/loader/random-seed' is world accessible,
#     which is a security hole! !
#
# and it is right: the file reads 755 root:root. The seed credits entropy
# early in boot, and what a local user can read, a local user can predict.
#
# WHY CHMOD IS NOT THE FIX
# ------------------------
# /boot/efi is FAT, which has no permission bits. Every file on it reads 755
# because the mount says fmask=0022,dmask=0022. `chmod 600` on the seed appears
# to succeed and changes nothing - the kind of fix that gets marked done and is
# not. The mode is a MOUNT OPTION, so the fix is in /etc/fstab:
#
#   fmask=0177,dmask=0077      files 600, directories 700, the whole partition
#
# WHY THIS IS CAREFUL, AND OPT-IN
# -------------------------------
# This edits the fstab entry for the partition the board BOOTS from, on a
# board with no screen. The entry has no `nofail`, so a line systemd cannot
# mount drops the board into emergency mode, which over SSH looks exactly like
# a dead board. So:
#
#   - only the one line whose mount point is /boot/efi is touched, and only its
#     options field; every other byte of the file is carried over and then
#     checked to have been
#   - the result is written beside fstab and verified with `findmnt --verify`
#     BEFORE it replaces anything; if that complains, nothing is installed
#   - it replaces fstab by rename, so there is no moment at which a reader
#     (or a power cut) finds half a file
#   - the new masks are then read back from the live mount, and if they cannot
#     be made live the file is put back as this run found it
#
# It tightens everything on the partition, not just the seed. Nothing on this
# image is known to read /boot/efi as a non-root user - fwupd is the usual
# candidate, it runs as root, and 10-optimize-board.sh masks it - but that is
# reasoning, not a measurement, which is the other reason bootstrap.sh runs
# this only with --with-esp-lockdown and --everything leaves it out.
#
# REMOUNT, THEN UNMOUNT IF THAT IS NOT ENOUGH
# -------------------------------------------
# `mount -o remount` is tried first because it is the gentle one. The FAT
# driver is known to accept a remount and quietly keep the masks it was first
# mounted with, so success is judged by what findmnt then reports and never by
# the exit status. If the masks did not change, the partition is unmounted and
# mounted again - never lazily, never forced: a busy ESP is reported and the
# edit undone.
#
# REVERT: put `defaults` (or whatever /etc/fstab.unoq-esp.bak shows) back in
#         the options field of the /boot/efi line, then
#         systemctl daemon-reload && umount /boot/efi && mount /boot/efi
#         Copying the backup over /etc/fstab does the same ONLY if nothing else
#         has edited fstab since - 70-learning-web.sh adds a line of its own.
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
need_root

FSTAB="${UNOQ_FSTAB:-/etc/fstab}"
BACKUP="$FSTAB.unoq-esp.bak"
ESP=/boot/efi
FMASK=0177
DMASK=0077

CANDIDATE=""
ORIGINAL=""
cleanup() { rm -f "$CANDIDATE" "$ORIGINAL"; }
trap cleanup EXIT

# has_masks <option list> - true if both masks are present with our values.
has_masks() {
  case ",$1," in *",fmask=$FMASK,"*) ;; *) return 1 ;; esac
  case ",$1," in *",dmask=$DMASK,"*) ;; *) return 1 ;; esac
  return 0
}

# with_masks <option list> - the same list with both masks set to our values:
# replaced where they stand if present, appended if not. Nothing else moves.
with_masks() {
  local out="" opt opts seen_f=0 seen_d=0
  # read -a, not an unquoted expansion: that would also expand globs.
  IFS=, read -ra opts <<<"$1"
  for opt in "${opts[@]}"; do
    case "$opt" in
      fmask=*)
        # A second fmask= would be a duplicate the kernel resolves by taking
        # the last one. Keep the first position and drop the rest.
        [ "$seen_f" = 1 ] && continue
        seen_f=1
        opt="fmask=$FMASK"
        ;;
      dmask=*)
        [ "$seen_d" = 1 ] && continue
        seen_d=1
        opt="dmask=$DMASK"
        ;;
    esac
    out="${out:+$out,}$opt"
  done
  [ "$seen_f" = 1 ] || out="${out:+$out,}fmask=$FMASK"
  [ "$seen_d" = 1 ] || out="${out:+$out,}dmask=$DMASK"
  printf '%s' "$out"
}

live_options() { findmnt -no OPTIONS "$ESP" 2>/dev/null; }

# --- find the one line ------------------------------------------------------

step "the $ESP entry in $FSTAB"
[ -r "$FSTAB" ] || fail "cannot read $FSTAB"

# By field, not by pattern: the mount point is the second whitespace-separated
# field of a line that is not a comment. The stock entry spells it with a
# trailing slash (/boot/efi/); both spellings are the same directory.
LINES="$(awk -v esp="$ESP" '$1 !~ /^#/ && ($2 == esp || $2 == esp "/") { print NR }' "$FSTAB")"
case "$(printf '%s' "$LINES" | grep -c .)" in
  0)
    skip "no $ESP entry in $FSTAB - nothing to tighten"
    summary
    exit 0
    ;;
  1) ;;
  *) fail "$FSTAB has more than one $ESP entry (lines $(echo "$LINES" | tr '\n' ' ')).
  Not guessing which one the board boots from. Nothing was changed." ;;
esac
N="$LINES"
LINE="$(sed -n "${N}p" "$FSTAB")"

# Four fields and whatever follows, with the separators kept exactly as they
# are: device, mount point, type, then the options - the only part rewritten.
RE='^([[:space:]]*[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+([^[:space:]]+)[[:space:]]+)([^[:space:]]+)(.*)$'
[[ "$LINE" =~ $RE ]] ||
  fail "line $N of $FSTAB has no options field to edit:
  $LINE
  Nothing was changed."
HEAD="${BASH_REMATCH[1]}"
FSTYPE="${BASH_REMATCH[2]}"
OPTIONS="${BASH_REMATCH[3]}"
TAIL="${BASH_REMATCH[4]}"

if [ "$FSTYPE" != vfat ]; then
  # fmask and dmask are FAT options. On anything else they are an unknown
  # option, and an unknown option is a failed mount at boot.
  skip "$ESP is $FSTYPE, not vfat - it has real permission bits; nothing to do here"
  summary
  exit 0
fi
skip "line $N: $FSTYPE, options: $OPTIONS"

# --- the fstab edit ---------------------------------------------------------

# REVERT: see the top of this file - restore the options field shown in
#         /etc/fstab.unoq-esp.bak, then daemon-reload and remount.
step "mount options in $FSTAB"
NEW_OPTIONS="$(with_masks "$OPTIONS")"
EDITED=0
if [ "$NEW_OPTIONS" = "$OPTIONS" ]; then
  skip "already fmask=$FMASK,dmask=$DMASK"
else
  # The backup is the file as it was before this script EVER touched it, kept
  # for a person to read. It is taken once and never overwritten: a second
  # backup would be a copy of our own edit, with the original gone.
  if [ -e "$BACKUP" ]; then
    skip "backup already exists: $BACKUP"
  else
    cp -p "$FSTAB" "$BACKUP" || fail "could not back up $FSTAB to $BACKUP - nothing was changed"
    did "backed up $FSTAB -> $BACKUP"
  fi

  # A second copy, of the file as THIS RUN found it, is what a failure below
  # rolls back to. Not the backup above: that may be months old, and restoring
  # it would silently drop every line added to fstab since.
  ORIGINAL="$(mktemp "$FSTAB.unoq-esp-orig.XXXXXX")" || fail "could not create a file beside $FSTAB"
  cp -p "$FSTAB" "$ORIGINAL" || fail "could not copy $FSTAB - nothing was changed"

  # Beside fstab, not in /tmp: the final step is a rename, and a rename is
  # only atomic within one filesystem. cp -p first so the candidate carries
  # fstab's owner and mode, then its content is replaced.
  CANDIDATE="$(mktemp "$FSTAB.unoq-esp-new.XXXXXX")" || fail "could not create a file beside $FSTAB"
  cp -p "$FSTAB" "$CANDIDATE" || fail "could not copy $FSTAB - nothing was changed"
  # The new line travels in the environment: `awk -v` would interpret
  # backslashes, and fstab uses them (\040 is a space in a path).
  NEW_LINE="$HEAD$NEW_OPTIONS$TAIL" awk -v n="$N" \
    'NR == n { print ENVIRON["NEW_LINE"]; next } { print }' "$FSTAB" >"$CANDIDATE" ||
    fail "could not write the candidate fstab - nothing was changed"
  # awk ends the last line with a newline whether or not the file did.
  if [ -n "$(tail -c1 "$FSTAB")" ]; then
    truncate -s -1 "$CANDIDATE" || fail "could not write the candidate fstab - nothing was changed"
  fi

  # Our own check first: delete line N from both and they must be identical.
  # This is the "every other byte" promise, tested rather than asserted.
  cmp -s <(sed "${N}d" "$FSTAB") <(sed "${N}d" "$CANDIDATE") ||
    fail "the edit changed more than line $N of $FSTAB - a bug in this script.
  Nothing was installed."
  [ "$(sed -n "${N}p" "$CANDIDATE")" = "$HEAD$NEW_OPTIONS$TAIL" ] ||
    fail "line $N of the candidate is not what was meant - a bug in this script.
  Nothing was installed."

  # Then util-linux's: the same parser mount itself uses.
  if ! VERIFY="$(findmnt --verify --tab-file "$CANDIDATE" 2>&1)"; then
    fail "findmnt --verify rejects the edited fstab, so it was NOT installed:
$VERIFY
  $FSTAB is unchanged. If these errors are about other lines, they are in
  the file already:  findmnt --verify"
  fi

  mv -f "$CANDIDATE" "$FSTAB" || fail "could not replace $FSTAB - it is unchanged"
  CANDIDATE=""
  sync
  # systemd mounts from units it generates out of fstab; without this it goes
  # on holding the old options and says so on every mount.
  systemctl daemon-reload
  EDITED=1
  did "line $N options: $OPTIONS -> $NEW_OPTIONS"
fi

# --- make it live, and prove it ---------------------------------------------

# roll_back <why> - put fstab back as this run found it and say so. Only ever
# called after an edit made by this run.
roll_back() {
  local why="$1" state
  if mv -f "$ORIGINAL" "$FSTAB"; then
    ORIGINAL=""
    sync
    systemctl daemon-reload
    state="$FSTAB has been put back as this run found it."
  else
    state="AND $FSTAB COULD NOT BE PUT BACK. The copy from before this script
  first ran is $BACKUP - compare the two before rebooting."
  fi
  fail "$why
  $state$(mounted_again)"
}

# mounted_again - if an unmount went through and the mount after it did not,
# the partition is off. Try once to bring it back, and print a line for the
# failure message only if that did not work.
mounted_again() {
  [ -n "$(live_options)" ] && return 0
  mount "$ESP" >/dev/null 2>&1 && return 0
  printf '\n  %s IS NOT MOUNTED NOW. The board keeps running without it; mount it by\n' "$ESP"
  printf '  hand (mount %s) and find out why it will not before you reboot.' "$ESP"
}

step "the live mount"
LIVE="$(live_options)"
if [ -z "$LIVE" ]; then
  # Nothing to remount and nothing to verify against. The entry is valid and
  # the options apply whenever it is next mounted.
  warn "$ESP is not mounted, so the new masks could not be seen working."
  warn "  They apply when it is next mounted. Check then:  findmnt -no OPTIONS $ESP"
elif has_masks "$LIVE"; then
  skip "$ESP is mounted with fmask=$FMASK,dmask=$DMASK"
else
  undo() {
    if [ "$EDITED" = 1 ]; then
      roll_back "$1"
    else
      fail "$1
  $FSTAB already has the masks and was not touched; they apply at the next boot.$(mounted_again)"
    fi
  }

  mount -o remount "$ESP" || undo "mount -o remount $ESP failed."
  if has_masks "$(live_options)"; then
    did "$ESP remounted with fmask=$FMASK,dmask=$DMASK"
  else
    # The remount was accepted and the masks did not move - FAT does that.
    # A real unmount is the only thing left, and it is never forced.
    umount "$ESP" || undo "$ESP kept its old masks across a remount, and it cannot be unmounted
  to apply the new ones - something has a file open on it:  fuser -vm $ESP"
    mount "$ESP" || undo "$ESP was unmounted and would not mount again with the new options."
    has_masks "$(live_options)" ||
      undo "$ESP is mounted, but not with fmask=$FMASK,dmask=$DMASK:
  $(live_options)"
    did "$ESP unmounted and mounted again with fmask=$FMASK,dmask=$DMASK"
  fi
fi

summary
echo "Check:   sudo stat -c '%a %U:%G' $ESP/loader/random-seed    (expect 600 root:root)"
echo "Before:  $BACKUP"
