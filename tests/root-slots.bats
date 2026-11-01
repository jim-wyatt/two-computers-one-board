#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# recovery/unoq-root.sh and provision/86-root-slots.sh: two root filesystems,
# phase 1 of issue #169. Nothing in this phase may write the disk, so most of
# what is tested is what it must not do: hand sfdisk anything but a request to
# read, call qbootctl, or touch the EFI partition. The rest is that the plan's
# numbers are right for this board, read from the board's own partition table
# (tests/fixtures/sfdisk-dump.txt, `sfdisk --dump` of the eMMC on 2026-11-01).
#
# The arithmetic, worked out by hand from that dump, sectors of 512 bytes:
#
#   rootfs   start 2033984, which is not on a 1 MiB (2048-sector) boundary
#   + 10 GiB = 2033984 + 20971520 = 23005504
#   next 1 MiB boundary at or after it: ceil(23005504 / 2048) * 2048 = 23007232
#   rootfs   ends at 23007231: size 23007232 - 2033984 = 20973248
#   rootfs-b starts at 23007232 and ends before userdata's 43977024:
#            size 43977024 - 23007232 = 20969792
#
# What this cannot show: that sfdisk would accept the script, or that resize2fs
# would shrink this filesystem. That is phase 2, from the rescue shell.

setup() {
  load helpers/stub
  stub_setup
  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TOOL="$PROJECT/recovery/unoq-root.sh"
  STEP="$PROJECT/provision/86-root-slots.sh"
  FIXTURE="$BATS_TEST_DIRNAME/fixtures/sfdisk-dump.txt"

  MID=f182f7e1bba34e8cba957f11b0f11612
  KVER=7.0.0-g122c2c22d838
  UUID=51ce1435-ba40-4ace-9886-9bba24fb434f
  DISK=/dev/mmcblk0
  ROOTDEV="${DISK}p68"

  # The board, as far as the tool looks at it: sysfs to find the disk from
  # the partition, the by-partlabel and by-uuid links, the machine-id.
  export UNOQ_ROOT="$BATS_TEST_TMPDIR/root"
  unset UNOQ_ESP_DIR
  mkdir -p "$UNOQ_ROOT/etc" "$UNOQ_ROOT/sys/class/block" \
    "$UNOQ_ROOT/dev/disk/by-partlabel" "$UNOQ_ROOT/dev/disk/by-uuid"
  echo "$MID" >"$UNOQ_ROOT/etc/machine-id"
  board_disk mmcblk0

  # The EFI partition where bootctl says it is, under UNOQ_ROOT: the kernel
  # entry, the rescue entry, loader.conf as the image has it. The kernel and
  # initrd are this board's sizes, as sparse files.
  ESP="$UNOQ_ROOT/boot/efi"
  mkdir -p "$ESP/loader/entries" "$ESP/$MID/$KVER" "$ESP/$MID/rescue"
  printf '#timeout 3\n#console-mode keep\ndefault %s-*\n' "$MID" >"$ESP/loader/loader.conf"
  truncate -s 15843840 "$ESP/$MID/$KVER/linux"
  truncate -s 23168511 "$ESP/$MID/$KVER/initrd.img-$KVER"
  truncate -s 15843840 "$ESP/$MID/rescue/linux"
  truncate -s 24662780 "$ESP/$MID/rescue/initrd.img"
  cat >"$ESP/loader/entries/$MID-$KVER.conf" <<EOF
title      Debian GNU/Linux 13 (trixie)
version    $KVER
machine-id $MID
sort-key   debian
options    root=UUID=$UUID clk_ignore_unused
linux      /$MID/$KVER/linux
initrd     /$MID/$KVER/initrd.img-$KVER
EOF
  cat >"$ESP/loader/entries/$MID-rescue.conf" <<EOF
title      Rescue
version    $KVER
machine-id $MID
sort-key   zz-unoq-rescue
linux      /$MID/rescue/linux
initrd     /$MID/rescue/initrd.img
EOF

  # The commands. Each answers as the board did, and records how it was asked.
  export DUMP="$FIXTURE" MIN_BLOCKS=2256505 ROOT_SOURCE="$ROOTDEV" ROOT_UUID="$UUID"
  export ESP_FREE=$((308 * 1048576))
  stub_body sfdisk <<'SH'
case "$1" in
  --dump | -l) cat "$DUMP" ;;
esac
exit 0
SH
  stub_body resize2fs <<'SH'
echo "resize2fs 1.47.2 (1-Jan-2025)"
[ "$1" = -P ] && echo "Estimated minimum size of the filesystem: $MIN_BLOCKS"
exit 0
SH
  stub_body tune2fs <<'SH'
printf 'Block count:              5242880\nBlock size:               4096\n'
SH
  stub_body findmnt <<'SH'
case "$*" in
  "-no SOURCE /") echo "$ROOT_SOURCE" ;;
  "-no UUID /") echo "$ROOT_UUID" ;;
  *) exit 1 ;;
esac
SH
  stub_body df <<'SH'
echo "  1B-blocks         Used        Avail"
case "${*: -1}" in
  /) echo "21034209280 7934926848 12152070144" ;;
  *) echo "$ESP_FREE" ;;
esac
SH
  stub_body bootctl <<'SH'
[ "$1" = --print-esp-path ] && echo /boot/efi
exit 0
SH
  stub blkid
  stub qbootctl
}

# board_disk <name> - sysfs and /dev/disk links for <name>p68 (rootfs) and
# <name>p69 (userdata), as the kernel lays them out.
board_disk() {
  local d="$UNOQ_ROOT/sys/devices/platform/soc/mmc0/block/$1" p
  for p in 68 69; do
    mkdir -p "$d/$1p$p"
    echo "$p" >"$d/$1p$p/partition"
    ln -sfn "../../devices/platform/soc/mmc0/block/$1/$1p$p" "$UNOQ_ROOT/sys/class/block/$1p$p"
  done
  ln -sfn "../../$1p68" "$UNOQ_ROOT/dev/disk/by-partlabel/rootfs"
  ln -sfn "../../$1p69" "$UNOQ_ROOT/dev/disk/by-partlabel/userdata"
  ln -sfn "../../$1p68" "$UNOQ_ROOT/dev/disk/by-uuid/$UUID"
}

# script_part - the sfdisk script the plan printed, without its comments.
script_part() {
  awk '/^== the sfdisk script/ {on = 1; next} /^== / {on = 0} on' <<<"$output" |
    grep -v '^#' | sed '/^$/{$d}'
}

# tree <dir> - every file under it with its bytes and mtime, to compare.
tree() {
  (cd "$1" && find . \( -type f -o -type l \) | sort | while read -r f; do
    if [ -L "$f" ]; then
      printf '%s -> %s\n' "$f" "$(readlink "$f")"
    else
      printf '%s %s %s\n' "$f" "$(stat -c %Y "$f")" "$(sha256sum <"$f" | cut -d' ' -f1)"
    fi
  done)
}

# --- the numbers -------------------------------------------------------------

@test "plan shrinks rootfs to 20973248 sectors, ending at 23007231" {
  run "$TOOL" plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"no rootfs-b: nothing to split yet"* ]]
  line="$(grep -E '^  /dev/mmcblk0p68 +rootfs ' <<<"$(awk '/^== proposed ==/,/^$/' <<<"$output")")"
  [[ "$line" =~ start\ +2033984\ +size\ +20973248\ +end\ +23007231 ]]
  [[ "$(script_part)" == *"p68 : start=     2033984, size=20973248, type=B921B045-1DF0-41C3-AF44-4C6F280D3FAE, uuid=A7F9056B-0EEF-F6CD-E379-EFE2DC875FC2, name=\"rootfs\", attrs=\"GUID:60\""* ]]
}

@test "plan puts rootfs-b at 23007232 with 20969792 sectors, up to userdata" {
  run "$TOOL" plan
  [ "$status" -eq 0 ]
  line="$(grep -E '^  /dev/mmcblk0p70 +rootfs-b ' <<<"$output")"
  [[ "$line" =~ start\ +23007232\ +size\ +20969792\ +end\ +43977023 ]]
  [[ "$(script_part)" == *"p70 : start=23007232, size=20969792, type=B921B045-1DF0-41C3-AF44-4C6F280D3FAE, name=\"rootfs-b\", attrs=\"GUID:60\"" ]]
  # userdata is where it was.
  [[ "$output" =~ p69\ +userdata\ +start\ +43977024\ +unchanged ]]
}

@test "the sfdisk script is today's table with two lines changed, and no other" {
  run "$TOOL" plan
  [ "$status" -eq 0 ]
  run diff "$FIXTURE" <(script_part)
  [ "$status" -eq 1 ]
  changed="$(grep -E '^[<>]' <<<"$output")"
  [ "$(wc -l <<<"$changed")" -eq 3 ]
  [[ "$(grep '^<' <<<"$changed")" == "< "*"p68 : start=     2033984, size=    41943040,"* ]]
  [[ "$(grep -c '^>' <<<"$changed")" -eq 2 ]]
  [[ "$changed" == *"> "*"p68 : start=     2033984, size=20973248,"* ]]
  [[ "$changed" == *"> "*"p70 : start=23007232,"* ]]
}

@test "plan prints the fs minimum against the slot, with the headroom" {
  run "$TOOL" plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"2256505 blocks of 4096 = 8.61 GiB"* ]]
  [[ "$output" == *"slot"*"10.00 GiB"* ]]
  [[ "$output" == *"headroom"*"1.39 GiB; at least 1.00 GiB is required"* ]]
  [[ "$output" == *"resize2fs $ROOTDEV 2621656"* ]]
}

@test "plan prints the EFI partition's budget, for two of B's kernels" {
  run "$TOOL" plan
  [ "$status" -eq 0 ]
  # The kernel entry's pair, not the rescue entry's larger one.
  [[ "$output" == *"kernel + initrd"*"37 MiB"* ]]
  [[ "$output" == *"B needs"*"74 MiB"*"/$MID-b/"* ]]
  [[ "$output" == *"free"*"308 MiB on $ESP"* ]]
}

# --- what it refuses ---------------------------------------------------------

@test "plan refuses a filesystem whose minimum leaves under 1 GiB of the slot" {
  # The smaller slot is B, 20969792 sectors = 10736533504 bytes. 1 GiB short
  # of that is 9662791680 bytes, 2359080 blocks of 4096: just enough.
  MIN_BLOCKS=2359080 run "$TOOL" plan
  [ "$status" -eq 0 ]
  MIN_BLOCKS=2359081 run "$TOOL" plan
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED"*"1.00 GiB"* ]]
  [[ "$output" != *"the sfdisk script"* ]]
}

@test "plan refuses when the EFI partition cannot take B's kernels" {
  ESP_FREE=$((70 * 1048576)) run "$TOOL" plan
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED: the EFI partition has 70 MiB free"* ]]
  [[ "$output" != *"the sfdisk script"* ]]
}

@test "plan refuses when / is not the partition named rootfs" {
  ROOT_SOURCE="${DISK}p69" run "$TOOL" plan
  [ "$status" -ne 0 ]
  [[ "$output" == *"/ is ${DISK}p69, not $ROOTDEV"* ]]
}

@test "plan finds the disk from findmnt and sysfs, not by name" {
  # The same table on another disk: every node in it, and the disk sfdisk is
  # asked about, follow.
  sed 's/mmcblk0/mmcblk1/g' "$FIXTURE" >"$BATS_TEST_TMPDIR/dump1"
  board_disk mmcblk1
  DUMP="$BATS_TEST_TMPDIR/dump1" ROOT_SOURCE=/dev/mmcblk1p68 run "$TOOL" plan
  [ "$status" -eq 0 ]
  ran "sfdisk --dump /dev/mmcblk1"
  refute ran_like "mmcblk0"
  [[ "$output" == *"/dev/mmcblk1p70 : start=23007232"* ]]
}

@test "with a rootfs-b already there, plan states it and proposes nothing" {
  {
    cat "$FIXTURE"
    echo "${DISK}p70 : start=    23007232, size=    20969792, type=B921B045-1DF0-41C3-AF44-4C6F280D3FAE, uuid=11111111-2222-3333-4444-555555555555, name=\"rootfs-b\""
  } >"$BATS_TEST_TMPDIR/split"
  stub blkid 0 ext4
  DUMP="$BATS_TEST_TMPDIR/split" run "$TOOL" plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"partition"*"${DISK}p70, 20969792 sectors"* ]]
  [[ "$output" == *"filesystem"*"ext4"* ]]
  [[ "$output" == *"already split"* ]]
  [[ "$output" != *"nothing to split yet"* ]]
  [[ "$output" != *"the sfdisk script"* ]]
}

# --- what it must never do ---------------------------------------------------

@test "plan never calls sfdisk with anything but --dump or -l" {
  run "$TOOL" plan
  [ "$status" -eq 0 ]
  MIN_BLOCKS=99999999 run "$TOOL" plan
  run "$TOOL" status
  grep -q '^sfdisk' "$STUB_LOG"
  refute grep -vE '^sfdisk (--dump|-l) /dev/[a-z0-9]+$' < <(grep '^sfdisk' "$STUB_LOG")
  # resize2fs only to ask; tune2fs only to list.
  refute grep -vE '^resize2fs -P /dev/' < <(grep '^resize2fs' "$STUB_LOG")
  refute grep -vE '^tune2fs -l /dev/' < <(grep '^tune2fs' "$STUB_LOG")
}

@test "nothing calls qbootctl or changes the EFI partition or the root" {
  before_esp="$(tree "$ESP")"
  before_root="$(tree "$UNOQ_ROOT")"
  for cmd in plan status split init sync stage commit; do
    run "$TOOL" "$cmd"
  done
  never_ran qbootctl
  never_ran mkfs
  never_ran e2fsck
  [ "$(tree "$ESP")" = "$before_esp" ]
  [ "$(tree "$UNOQ_ROOT")" = "$before_root" ]
  # And in the source: no write to loader.conf, no qbootctl at all.
  refute grep -nE '^[^#]*(>|\btee\b|\bcp\b|\bmv\b|\binstall\b|\bsed -i)[^|;#]*loader\.conf' "$TOOL" "$STEP"
  refute grep -nE '^[^#]*\bqbootctl\b' "$TOOL" "$STEP"
}

@test "the later phases are not in this release, and do nothing" {
  for cmd in split init sync stage commit; do
    : >"$STUB_LOG"
    run "$TOOL" "$cmd"
    [ "$status" -eq 2 ]
    [ "$output" = "unoq-root: $cmd is not in this release; see #169" ]
    [ ! -s "$STUB_LOG" ]
  done
}

# --- status ------------------------------------------------------------------

@test "status says A is running, and sorts the entries by slot" {
  mkdir -p "$ESP/$MID-b/$KVER"
  cat >"$ESP/loader/entries/$MID-b-$KVER+2-1.conf" <<EOF
title      Debian (B, on trial)
sort-key   aa-unoq-trial
version    $KVER
linux      /$MID-b/$KVER/linux
EOF
  ln -sfn ../../mmcblk0p70 "$UNOQ_ROOT/dev/disk/by-partlabel/rootfs-b"
  run "$TOOL" status
  [ "$status" -eq 0 ]
  [[ "$output" =~ slot\ +A\ \(rootfs\) ]]
  [[ "$output" =~ A\ +$MID-$KVER\.conf\ +sort-key\ debian\ +$KVER,\ not\ counted ]]
  [[ "$output" =~ B\ +$MID-b-$KVER\+2-1\.conf\ +sort-key\ aa-unoq-trial\ +$KVER,\ 2\ left,\ 1\ done ]]
  [[ "$output" =~ rescue\ +$MID-rescue\.conf ]]
  [[ "$output" == *"loader.conf default"*"$MID-*"* ]]
}

@test "status says B when the root's UUID is on rootfs-b" {
  ln -sfn ../../mmcblk0p70 "$UNOQ_ROOT/dev/disk/by-partlabel/rootfs-b"
  ln -sfn ../../mmcblk0p70 "$UNOQ_ROOT/dev/disk/by-uuid/bbbb"
  ROOT_SOURCE="${DISK}p70" ROOT_UUID=bbbb run "$TOOL" status
  [ "$status" -eq 0 ]
  [[ "$output" =~ slot\ +B\ \(rootfs-b\) ]]
}

@test "status before the split says there is no rootfs-b" {
  run "$TOOL" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"rootfs-b"*"<none: nothing to split yet>"* ]]
}

# --- the provisioning step ---------------------------------------------------

@test "86 installs root's copy of the tool, and nothing else on the board" {
  export UNOQ_RUNTIME_DIR="$BATS_TEST_TMPDIR/unoq"
  UNOQ_USER="$(id -un)"
  export UNOQ_USER
  stub_body id <<'SH'
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
SH
  before_root="$(tree "$UNOQ_ROOT")"
  run bash "$STEP"
  [ "$status" -eq 0 ]
  cmp "$TOOL" "$UNOQ_RUNTIME_DIR/recovery/unoq-root.sh"
  [ -x "$UNOQ_RUNTIME_DIR/recovery/unoq-root.sh" ]
  [[ "$output" == *"the split is a separate step, by hand"* ]]
  [[ "$output" == *"sudo $UNOQ_RUNTIME_DIR/recovery/unoq-root.sh plan"* ]]
  [ "$(tree "$UNOQ_ROOT")" = "$before_root" ]
  # No disk tool, no unit, no boot loader.
  refute ran_like '^(sfdisk|resize2fs|systemctl|bootctl|qbootctl|mkfs)'
  # Again: nothing changes.
  run bash "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 changed"* ]]
}

@test "86 has REVERT lines, and installs no unit" {
  grep -q '^# REVERT:' "$STEP"
  refute grep -nE '^[^#]*\b(install_unit|enable_unit|systemctl)\b' "$STEP"
}
