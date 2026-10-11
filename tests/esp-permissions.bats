#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# provision/85-esp-permissions.sh edits one field of one line of /etc/fstab:
# the mount options of the partition the board boots from. The entry has no
# `nofail`, so a line systemd cannot mount is emergency mode on a board with no
# screen - which over SSH is indistinguishable from a dead board.
#
# So the suite is mostly about what must NOT happen: no byte outside the
# options field moves, nothing is installed that `findmnt --verify` rejects,
# the backup is never overwritten with our own edit, and every way the live
# mount can refuse ends with fstab back as the run found it.
#
# The fake `mount` below ignores mask changes on a remount unless told
# otherwise, because that is what the FAT driver does: on the one board this
# step has run on, a plain remount kept the old masks and the step went on to
# unmount and mount again. A fake that applied them would leave that path - the
# one a board actually takes - with nothing exercising it here.
#
# The fake also reports the masks the way the driver arrives at them: options
# read left to right, umask= setting both, and what is printed being what is in
# effect. A fake that looked only for the text "fmask=0177" in fstab would call
# a line working that mounts world-readable.
#
# What this cannot show: that a kernel behaves the way the fakes do. One board
# (kernel 7.0.0) has been watched doing the remount-then-unmount part, come up
# with the seed file at 600, and rebooted with it. Nobody has put a umask= line
# through a board, and nothing here or there shows that no non-root program
# reads /boot/efi. One board is an observation, not a guarantee.

# The entry exactly as the board has it today: tabs, and a trailing slash on
# the mount point.
REAL_LINE=$'UUID=68CE-99C4\t/boot/efi/\tvfat\tdefaults\t0\t2'
REAL_FIXED=$'UUID=68CE-99C4\t/boot/efi/\tvfat\tdefaults,fmask=0177,dmask=0077\t0\t2'

setup() {
  load helpers/stub
  stub_setup

  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  ESP="$PROJECT/provision/85-esp-permissions.sh"

  export UNOQ_FSTAB="$BATS_TEST_TMPDIR/etc/fstab"
  mkdir -p "$BATS_TEST_TMPDIR/etc"
  BACKUP="$UNOQ_FSTAB.unoq-esp.bak"
  UNOQ_USER="$(id -un)"
  export UNOQ_USER

  FLAGS="$BATS_TEST_TMPDIR/flags"
  mkdir -p "$FLAGS"
  export FLAGS

  # need_root asks `id -u`. Everything else id is asked goes to the real one.
  stub_body id <<'SH'
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
SH

  # The live mount is a file: its content is what `findmnt -no OPTIONS` says,
  # and its absence means "not mounted". --verify passes unless flagged.
  stub_body findmnt <<'SH'
case "$1" in
  --verify)
    if [ -e "$FLAGS/verify-fails" ]; then
      echo "/boot/efi/"
      echo "   [E] the fake verifier was told to object"
      exit 1
    fi
    exit 0
    ;;
  -no) [ -e "$FLAGS/live" ] && cat "$FLAGS/live" ;;
esac
exit 0
SH

  # What a fresh mount of the ESP would report, given fstab as it is now. The
  # options are applied in the order written, as the FAT driver applies them:
  # umask= sets both masks, so whichever of the three comes last wins. Then
  # both masks are printed, whether or not fstab named them, and umask never is.
  cat >"$STUB_DIR/esp-from-fstab" <<'SH'
#!/bin/bash
opts="$(awk '$1 !~ /^#/ && $2 ~ /^\/boot\/efi\/?$/ { print $4 }' "$UNOQ_FSTAB")"
f=0022
d=0022
IFS=, read -ra list <<<"$opts"
for o in "${list[@]}"; do
  case "$o" in
    fmask=*) f="${o#fmask=}" ;;
    dmask=*) d="${o#dmask=}" ;;
    umask=*)
      f="${o#umask=}"
      d="$f"
      ;;
  esac
done
echo "rw,relatime,fmask=$f,dmask=$d,codepage=437"
SH
  chmod +x "$STUB_DIR/esp-from-fstab"

  stub_body mount <<'SH'
case "$*" in
  "-o remount /boot/efi")
    [ -e "$FLAGS/remount-fails" ] && exit 32
    # FAT keeps its masks across a remount unless a test says otherwise.
    [ -e "$FLAGS/remount-applies-masks" ] && esp-from-fstab >"$FLAGS/live"
    exit 0
    ;;
  "/boot/efi")
    # "The new options will not mount": only the edited fstab is refused.
    if [ -e "$FLAGS/new-options-will-not-mount" ] && [[ "$(esp-from-fstab)" == *fmask=0177* ]]; then
      exit 32
    fi
    esp-from-fstab >"$FLAGS/live"
    exit 0
    ;;
esac
exit 64
SH
  stub_body umount <<'SH'
if [ -e "$FLAGS/esp-busy" ]; then
  echo "umount: /boot/efi: target is busy." >&2
  exit 32
fi
[ "$*" = "/boot/efi" ] || exit 64
rm -f "$FLAGS/live"
exit 0
SH
  stub systemctl
  stub sync
}

# refute <command...> - the command must fail. Not `! command`: bash exempts a
# negated command from `set -e`, so a bare `!` anywhere but the last line of a
# test asserts nothing.
refute() {
  if "$@"; then return 1; fi
}

# fstab_with <efi line> - a realistic file around the line under test: a root
# entry in spaces, comments that mention the mount point, an escaped space,
# and the line 75-learning-web.sh adds. None of it may move.
fstab_with() {
  {
    printf '# /etc/fstab: static file system information.\n'
    printf '# The ESP is mounted at /boot/efi vfat defaults - this is a comment.\n'
    printf 'UUID=0f3a1c2e-aaaa-bbbb-cccc-1234567890ab /               ext4    errors=remount-ro 0       1\n'
    printf '%s\n' "$1"
    printf '\n'
    printf '/srv/with\\040space/img /mnt/x vfat loop,ro,nofail 0 0\n'
    printf '# Arduino UNO Q learning content + installers (share/build-image.sh)\n'
    printf '/home/arduino/unoq-share.img /srv/unoq-share vfat loop,ro,nofail,offset=1048576,umask=0022,utf8 0 0\n'
  } >"$UNOQ_FSTAB"
  chmod 644 "$UNOQ_FSTAB"
  cp "$UNOQ_FSTAB" "$BATS_TEST_TMPDIR/fstab.before"
}

# Mounted the way the board has it today.
mounted_stock() { echo "rw,relatime,fmask=0022,dmask=0022,codepage=437" >"$FLAGS/live"; }

# The file under test, with the one line swapped by a tool that is not the
# script's own: what the result must equal, byte for byte.
expect_only_line_changed() {
  local old="$1" new="$2"
  OLD="$old" NEW="$new" python3 -c '
import os, sys
b = open(sys.argv[1], "rb").read()
old, new = os.environb[b"OLD"], os.environb[b"NEW"]
assert b.count(old + b"\n") == 1, "fixture should contain the line exactly once"
sys.stdout.buffer.write(b.replace(old + b"\n", new + b"\n"))
' "$BATS_TEST_TMPDIR/fstab.before" >"$BATS_TEST_TMPDIR/fstab.expected"
  cmp "$UNOQ_FSTAB" "$BATS_TEST_TMPDIR/fstab.expected"
}

unchanged() { cmp "$UNOQ_FSTAB" "$BATS_TEST_TMPDIR/fstab.before"; }

no_strays() { [ -z "$(find "$BATS_TEST_TMPDIR/etc" -name 'fstab.unoq-esp-*')" ]; }

# --- the edit ---------------------------------------------------------------

@test "the board's real line: defaults gains the masks, and no other byte of the file moves" {
  fstab_with "$REAL_LINE"
  mounted_stock
  run bash "$ESP"
  [ "$status" -eq 0 ]
  expect_only_line_changed "$REAL_LINE" "$REAL_FIXED"
  # Said twice, the second time without any helper: tabs, trailing slash.
  grep -qxF "$REAL_FIXED" "$UNOQ_FSTAB"
  [ "$(stat -c %a "$UNOQ_FSTAB")" = 644 ]
  no_strays
}

@test "a mount point without the trailing slash is the same entry" {
  line=$'UUID=68CE-99C4\t/boot/efi\tvfat\tdefaults\t0\t2'
  fstab_with "$line"
  mounted_stock
  run bash "$ESP"
  [ "$status" -eq 0 ]
  expect_only_line_changed "$line" $'UUID=68CE-99C4\t/boot/efi\tvfat\tdefaults,fmask=0177,dmask=0077\t0\t2'
}

@test "an existing option list is appended to, and space separators stay spaces" {
  line='UUID=68CE-99C4  /boot/efi/   vfat  rw,noatime,utf8   0 2'
  fstab_with "$line"
  mounted_stock
  run bash "$ESP"
  [ "$status" -eq 0 ]
  expect_only_line_changed "$line" 'UUID=68CE-99C4  /boot/efi/   vfat  rw,noatime,utf8,fmask=0177,dmask=0077   0 2'
}

@test "existing fmask and dmask are taken out and the pair goes last, not duplicated" {
  # They used to be replaced where they stood. Where they stand is not ours to
  # trust: see the umask tests below. Everything else keeps its order.
  line=$'UUID=68CE-99C4\t/boot/efi/\tvfat\tumask=0077,fmask=0022,dmask=0022,utf8\t0\t2'
  fstab_with "$line"
  mounted_stock
  run bash "$ESP"
  [ "$status" -eq 0 ]
  expect_only_line_changed "$line" $'UUID=68CE-99C4\t/boot/efi/\tvfat\tumask=0077,utf8,fmask=0177,dmask=0077\t0\t2'
  [ "$(grep -o 'fmask=' <<<"$(grep 'boot/efi/' "$UNOQ_FSTAB" | grep -v '^#')" | wc -l)" -eq 1 ]
  [ "$(grep -o 'dmask=' <<<"$(grep 'boot/efi/' "$UNOQ_FSTAB" | grep -v '^#')" | wc -l)" -eq 1 ]
}

@test "a line with only one of the two masks ends with both, and the old one is gone" {
  line=$'UUID=68CE-99C4\t/boot/efi/\tvfat\tdmask=0022,defaults\t0\t2'
  fstab_with "$line"
  mounted_stock
  run bash "$ESP"
  [ "$status" -eq 0 ]
  expect_only_line_changed "$line" $'UUID=68CE-99C4\t/boot/efi/\tvfat\tdefaults,fmask=0177,dmask=0077\t0\t2'
}

@test "masks given twice are all taken out: one pair is left, at the end" {
  line=$'UUID=68CE-99C4\t/boot/efi/\tvfat\tfmask=0022,rw,fmask=0133,dmask=0022,dmask=0022\t0\t2'
  fstab_with "$line"
  mounted_stock
  run bash "$ESP"
  [ "$status" -eq 0 ]
  expect_only_line_changed "$line" $'UUID=68CE-99C4\t/boot/efi/\tvfat\trw,fmask=0177,dmask=0077\t0\t2'
}

# --- a umask= that comes after the masks -----------------------------------
#
# FAT reads its options in order and umask= sets both masks, so in
# fmask=0177,dmask=0077,umask=0022 the partition mounts 0022 whatever the first
# two say. Replacing the masks where they stood produced exactly that line.

@test "a umask after the masks cannot override them: the pair is written after it" {
  line=$'UUID=68CE-99C4\t/boot/efi/\tvfat\tfmask=0022,dmask=0022,umask=0022\t0\t2'
  fstab_with "$line"
  mounted_stock
  run bash "$ESP"
  [ "$status" -eq 0 ]
  expect_only_line_changed "$line" $'UUID=68CE-99C4\t/boot/efi/\tvfat\tumask=0022,fmask=0177,dmask=0077\t0\t2'
  # And it mounts that way, by the fake's reading of the same rule.
  [[ "$(cat "$FLAGS/live")" == *"fmask=0177,dmask=0077"* ]]
}

@test "the same line with the ESP not mounted is still written right, with nothing to check it against" {
  # The case the live check cannot save: no mount to read back, so the run ends
  # in a warning and exit 0 whatever was written.
  line=$'UUID=68CE-99C4\t/boot/efi/\tvfat\tfmask=0022,dmask=0022,umask=0022\t0\t2'
  fstab_with "$line"
  run bash "$ESP"
  [ "$status" -eq 0 ]
  expect_only_line_changed "$line" $'UUID=68CE-99C4\t/boot/efi/\tvfat\tumask=0022,fmask=0177,dmask=0077\t0\t2'
  [ "$("$STUB_DIR/esp-from-fstab")" = "rw,relatime,fmask=0177,dmask=0077,codepage=437" ]
}

@test "our own values followed by a umask are not mistaken for already correct" {
  # What the earlier version of this step left behind on such a line.
  line=$'UUID=68CE-99C4\t/boot/efi/\tvfat\tdefaults,fmask=0177,dmask=0077,umask=0022\t0\t2'
  fstab_with "$line"
  mounted_stock
  run bash "$ESP"
  [ "$status" -eq 0 ]
  expect_only_line_changed "$line" $'UUID=68CE-99C4\t/boot/efi/\tvfat\tdefaults,umask=0022,fmask=0177,dmask=0077\t0\t2'
  [[ "$(cat "$FLAGS/live")" == *"fmask=0177,dmask=0077"* ]]
}

@test "a line with no dump and pass fields, and a file with no final newline, both survive" {
  printf 'UUID=1 / ext4 defaults 0 1\nUUID=68CE-99C4 /boot/efi vfat defaults' >"$UNOQ_FSTAB"
  mounted_stock
  run bash "$ESP"
  [ "$status" -eq 0 ]
  # No newline was added at the end, and none in the middle went missing.
  printf 'UUID=1 / ext4 defaults 0 1\nUUID=68CE-99C4 /boot/efi vfat defaults,fmask=0177,dmask=0077' |
    cmp - "$UNOQ_FSTAB"
}

# --- idempotence ------------------------------------------------------------

@test "the line this step wrote on the board is already correct: a re-run there is a no-op" {
  # Byte for byte what /etc/fstab holds on the board that has run this. Moving
  # the masks to the end must not make that a line to rewrite.
  fstab_with $'UUID=68CE-99C4\t/boot/efi/\tvfat\tdefaults,fmask=0177,dmask=0077\t0\t2'
  echo "rw,relatime,fmask=0177,dmask=0077,codepage=437" >"$FLAGS/live"
  run bash "$ESP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 changed"* ]]
  unchanged
  [ ! -e "$BACKUP" ]
  never_ran mount
  never_ran umount
  never_ran systemctl
}

@test "already correct: nothing changes, no backup, no remount, no reload" {
  fstab_with "$REAL_FIXED"
  echo "rw,relatime,fmask=0177,dmask=0077,codepage=437" >"$FLAGS/live"
  run bash "$ESP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 changed"* ]]
  unchanged
  [ ! -e "$BACKUP" ]
  never_ran mount
  never_ran umount
  never_ran systemctl
  no_strays
}

@test "a second run after the first changes nothing" {
  fstab_with "$REAL_LINE"
  mounted_stock
  run bash "$ESP"
  [ "$status" -eq 0 ]
  cp "$UNOQ_FSTAB" "$BATS_TEST_TMPDIR/after-first"
  mounts="$(grep -c '^mount ' "$STUB_LOG")"

  run bash "$ESP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 changed"* ]]
  cmp "$UNOQ_FSTAB" "$BATS_TEST_TMPDIR/after-first"
  [ "$(grep -c '^mount ' "$STUB_LOG")" -eq "$mounts" ]
}

# --- nothing to do ----------------------------------------------------------

@test "no /boot/efi entry: skipped cleanly, nothing touched" {
  printf 'UUID=1 / ext4 defaults 0 1\n# /boot/efi is not here\nUUID=2 /boot/efi-old vfat defaults 0 2\n' >"$UNOQ_FSTAB"
  cp "$UNOQ_FSTAB" "$BATS_TEST_TMPDIR/fstab.before"
  run bash "$ESP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no /boot/efi entry"* ]]
  unchanged
  [ ! -e "$BACKUP" ]
  never_ran mount
  never_ran systemctl
}

@test "an ESP that is not vfat is left alone: the masks would be an unknown option" {
  fstab_with $'UUID=68CE-99C4\t/boot/efi/\text4\tdefaults\t0\t2'
  run bash "$ESP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not vfat"* ]]
  unchanged
  [ ! -e "$BACKUP" ]
  never_ran mount
}

@test "two /boot/efi entries: refused, not guessed at" {
  fstab_with "$REAL_LINE"
  printf '%s\n' "$REAL_LINE" >>"$UNOQ_FSTAB"
  cp "$UNOQ_FSTAB" "$BATS_TEST_TMPDIR/fstab.before"
  run bash "$ESP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"more than one"* ]]
  unchanged
  never_ran mount
}

# --- validation before installation -----------------------------------------

@test "the candidate is verified with findmnt before fstab is replaced" {
  fstab_with "$REAL_LINE"
  mounted_stock
  run bash "$ESP"
  [ "$status" -eq 0 ]
  ran_like "^findmnt --verify --tab-file $UNOQ_FSTAB\.unoq-esp-new\.[A-Za-z0-9]+\$"
  verify="$(grep -n '^findmnt --verify' "$STUB_LOG" | head -1 | cut -d: -f1)"
  reload="$(grep -n '^systemctl daemon-reload' "$STUB_LOG" | head -1 | cut -d: -f1)"
  [ "$verify" -lt "$reload" ]
}

@test "a candidate findmnt rejects is not installed: fstab untouched, output shown" {
  fstab_with "$REAL_LINE"
  mounted_stock
  : >"$FLAGS/verify-fails"
  run bash "$ESP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the fake verifier was told to object"* ]]
  [[ "$output" == *"NOT installed"* ]]
  unchanged
  never_ran mount
  never_ran systemctl
  no_strays
}

# --- the backup -------------------------------------------------------------

@test "fstab is backed up first, byte for byte, and the output says where" {
  fstab_with "$REAL_LINE"
  mounted_stock
  run bash "$ESP"
  [ "$status" -eq 0 ]
  cmp "$BACKUP" "$BATS_TEST_TMPDIR/fstab.before"
  [[ "$output" == *"backed up $UNOQ_FSTAB -> $BACKUP"* ]]
}

@test "the backup is made once: a later run that edits again does not overwrite it" {
  fstab_with "$REAL_LINE"
  mounted_stock
  run bash "$ESP"
  [ "$status" -eq 0 ]

  # Someone puts the line back by hand, differently, and re-runs.
  fstab_with $'UUID=68CE-99C4\t/boot/efi/\tvfat\tdefaults,noatime\t0\t2'
  mounted_stock
  run bash "$ESP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup already exists"* ]]
  grep -qxF "$REAL_LINE" "$BACKUP"
  refute grep -q noatime "$BACKUP"
}

# --- making it live ---------------------------------------------------------

@test "a remount that applies the masks is enough: no unmount" {
  fstab_with "$REAL_LINE"
  mounted_stock
  : >"$FLAGS/remount-applies-masks"
  run bash "$ESP"
  [ "$status" -eq 0 ]
  ran "mount -o remount /boot/efi"
  never_ran umount
  ran "systemctl daemon-reload"
}

@test "a remount that silently keeps the old masks is not believed: unmount and mount" {
  fstab_with "$REAL_LINE"
  mounted_stock
  run bash "$ESP"
  [ "$status" -eq 0 ]
  ran "mount -o remount /boot/efi"
  ran "umount /boot/efi"
  ran "mount /boot/efi"
  [[ "$(cat "$FLAGS/live")" == *"fmask=0177,dmask=0077"* ]]
  [[ "$output" == *"unmounted and mounted again"* ]]
}

@test "fstab already right but the live mount stale: made live without editing anything" {
  fstab_with "$REAL_FIXED"
  mounted_stock
  run bash "$ESP"
  [ "$status" -eq 0 ]
  unchanged
  [ ! -e "$BACKUP" ]
  [[ "$(cat "$FLAGS/live")" == *"fmask=0177"* ]]
}

@test "not mounted at all: fstab is edited, nothing is mounted, and it says it could not check" {
  fstab_with "$REAL_LINE"
  run bash "$ESP"
  [ "$status" -eq 0 ]
  expect_only_line_changed "$REAL_LINE" "$REAL_FIXED"
  never_ran mount
  [[ "$output" == *"is not mounted"* ]]
}

# --- every refusal ends with fstab back as it was ---------------------------

@test "remount fails: fstab is restored, systemd reloaded again, and it fails loudly" {
  fstab_with "$REAL_LINE"
  mounted_stock
  : >"$FLAGS/remount-fails"
  run bash "$ESP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED"* ]]
  [[ "$output" == *"mount -o remount /boot/efi failed"* ]]
  [[ "$output" == *"put back"* ]]
  unchanged
  [ "$(grep -cx 'systemctl daemon-reload' "$STUB_LOG")" -eq 2 ]
  no_strays
}

@test "busy ESP: never forced, never lazy - fstab restored and the holder pointed at" {
  fstab_with "$REAL_LINE"
  mounted_stock
  : >"$FLAGS/esp-busy"
  run bash "$ESP"
  [ "$status" -ne 0 ]
  unchanged
  ran "umount /boot/efi"
  refute ran_like '^umount( .*)? (-[a-zA-Z]*[lf][a-zA-Z]*|--lazy|--force)( |$)'
  [[ "$output" == *"fuser -vm /boot/efi"* ]]
  # Still mounted, with what it had.
  [[ "$(cat "$FLAGS/live")" == *"fmask=0022"* ]]
}

@test "unmounted and the new options will not mount: fstab restored AND the ESP mounted again" {
  fstab_with "$REAL_LINE"
  mounted_stock
  : >"$FLAGS/new-options-will-not-mount"
  run bash "$ESP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"would not mount again"* ]]
  unchanged
  [ -e "$FLAGS/live" ]
  [[ "$(cat "$FLAGS/live")" == *"fmask=0022"* ]]
  [[ "$output" != *"IS NOT MOUNTED NOW"* ]]
}

@test "a rollback restores what THIS run found, not a months-old backup" {
  fstab_with "$REAL_LINE"
  mounted_stock
  # A backup from an earlier life of the board, before the learning line.
  printf 'UUID=old / ext4 defaults 0 1\n%s\n' "$REAL_LINE" >"$BACKUP"
  cp "$BACKUP" "$BATS_TEST_TMPDIR/backup.before"
  : >"$FLAGS/remount-fails"
  run bash "$ESP"
  [ "$status" -ne 0 ]
  unchanged
  grep -q unoq-share "$UNOQ_FSTAB"
  cmp "$BACKUP" "$BATS_TEST_TMPDIR/backup.before"
}

@test "it refuses to run without root" {
  fstab_with "$REAL_LINE"
  stub_body id <<'SH'
[ "${1:-}" = "-u" ] && { echo 1000; exit 0; }
exec /usr/bin/id "$@"
SH
  run bash "$ESP"
  [ "$status" -ne 0 ]
  unchanged
}
