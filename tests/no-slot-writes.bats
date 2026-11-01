#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# Nothing this project tracks may write the Qualcomm boot chain.
#
# Layer 4 of issue #93: the _a/_b firmware partitions (xbl, tz, hyp, boot,
# which holds U-Boot, uefi, abl, ...) and the slot marks qbootctl keeps in
# the partition table are looked at and never touched. They sit below
# everything else this project can recover from: a bad kernel falls back to
# the previous one, a bad root will fall back to the other root, but a bad
# write here is a board that does not reach U-Boot, and only Arduino's
# flasher brings that back. docs/reference/hardware.md has the evidence.
#
# This is a cheap guard, not a proof. It greps every tracked file except the
# Markdown (the docs show the read-only commands and name the ones never to
# run) and itself, skipping comment lines, for the ways a script would write
# there. A determined write can get past a grep; an absent-minded one, which
# is the likely kind, cannot.
#
# The partition table is the boot chain's too, and the one change to it this
# project plans - splitting `rootfs` in two, by hand, from the rescue shell
# (#169, phase 2) - finds its disk at run time. So no partition, filesystem or
# resize tool may name /dev/mmcblk0 literally on its line, even to read.
#
# Each pattern is tried against a planted write in a scratch repository, so
# that "the repository passes" means something.

load helpers/stub

setup() {
  # For refute, and for what it unsets: run from the pre-commit hook, git's
  # GIT_DIR would point the scratch repository's commands at the real one.
  stub_setup
  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRATCH="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$SCRATCH"
  git -C "$SCRATCH" init -q
}

# The firmware partitions that come as an _a/_b pair on this board.
FIRMWARE='(xbl|xbl_config|tz|rpm|hyp|boot|uefi|uefi_dtb|abl|ddr|keymaster|mdtp|mdtpsecapp|imagefv|uefisecapp|devcfg|featenabler|qupfw|multiimgoem)_[ab]'
RAW='/dev/(mmcblk|disk/by-)'
DISK_TOOLS='sfdisk|sgdisk|parted|mkfs[.a-z0-9]*|resize2fs'

PATTERNS=(
  # dd, or anything else that takes of=, aimed at the raw eMMC
  "of=[\"']?$RAW"
  # a shell redirect or tee into it
  "(>|\\btee( -a)?) *[\"']?$RAW"
  # a partition-table or erase tool named on the same line as a firmware slot
  "\\b(sfdisk|sgdisk|gdisk|parted|wipefs|blkdiscard|flash_erase|mkfs[.a-z0-9]*)\\b.*/dev/disk/by-partlabel/$FIRMWARE"
  # qbootctl's set-active, mark-successful, mark-unbootable (and -i, which
  # only matters to those). Its queries, -a -b -c -n -x and none, are fine.
  "\\bqbootctl\\b[^|;&]*[[:space:]]-[smui]\\b"
  # stopping the stock service that marks the slot good leaves it unmarked
  "\\bsystemctl\\b.*\\b(mask|disable|stop)\\b.*\\bqbootctl"
  # fastboot's slot and flash commands
  "\\bfastboot\\b.*(set_active|--set-active|\\bflash\\b|\\berase\\b)"
  # Python opening the raw eMMC for writing
  "open\\( *[rbf]?[\"']${RAW}[^\"']*[\"'] *, *[\"'][^\"']*[wa+]"
  # a partition-table, filesystem or resize tool on the same line as the eMMC
  # by its kernel name, either way round. The root disk is found at run time
  # (findmnt /, then sysfs: recovery/unoq-root.sh), never written in: a
  # literal is right on one board and a different disk on the next (#169).
  "\\b($DISK_TOOLS)\\b.*/dev/mmcblk0"
  "/dev/mmcblk0.*\\b($DISK_TOOLS)\\b"
)

# scan <repo> - print every tracked, non-Markdown, non-comment line that
# writes the boot chain, as file:line:text. Prints nothing when there is none.
scan() {
  local args=() p
  for p in "${PATTERNS[@]}"; do args+=(-e "$p"); done
  git -C "$1" ls-files -z |
    grep -zvE '(\.md$|^tests/no-slot-writes\.bats$)' |
    (cd "$1" && xargs -0 -r grep -nIHE "${args[@]}" --) |
    grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' || true
}

# plant <file> <line> - one tracked file in the scratch repository.
plant() {
  mkdir -p "$SCRATCH/$(dirname "$1")"
  printf '%s\n' "$2" >"$SCRATCH/$1"
  git -C "$SCRATCH" add "$1"
}

@test "the repository as it stands writes no firmware partition or slot mark" {
  run scan "$PROJECT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "dd onto a firmware partition is caught" {
  plant provision/99-bad.sh 'dd if=u-boot.img of=/dev/disk/by-partlabel/boot_a bs=1M'
  run scan "$SCRATCH"
  [[ "$output" == "provision/99-bad.sh:1:"* ]]
}

@test "dd onto a raw eMMC partition by number is caught" {
  plant provision/99-bad.sh 'sudo dd if=xbl.elf of="/dev/mmcblk0p1" conv=fsync'
  run scan "$SCRATCH"
  [[ "$output" == "provision/99-bad.sh:1:"* ]]
}

@test "a redirect or tee into a firmware partition is caught" {
  plant a.sh 'cat abl.elf > /dev/disk/by-partlabel/abl_b'
  plant b.sh 'cat tz.mbn | sudo tee /dev/disk/by-partlabel/tz_a >/dev/null'
  run scan "$SCRATCH"
  [[ "$output" == *"a.sh:1:"* ]]
  [[ "$output" == *"b.sh:1:"* ]]
}

@test "erasing a firmware partition is caught" {
  plant a.sh 'blkdiscard /dev/disk/by-partlabel/uefi_b'
  run scan "$SCRATCH"
  [[ "$output" == "a.sh:1:"* ]]
}

@test "qbootctl set-active, mark-good and mark-bad are caught" {
  plant a.sh 'qbootctl -s b'
  plant b.sh '  /usr/bin/qbootctl -m'
  plant c.sh 'sudo qbootctl -u _a && echo done'
  run scan "$SCRATCH"
  [[ "$output" == *"a.sh:1:"* ]]
  [[ "$output" == *"b.sh:1:"* ]]
  [[ "$output" == *"c.sh:1:"* ]]
}

@test "turning off the service that marks the slot good is caught" {
  plant a.sh 'systemctl mask qbootctl.service'
  plant b.service 'ExecStart=/usr/bin/systemctl disable --now qbootctl'
  run scan "$SCRATCH"
  [[ "$output" == *"a.sh:1:"* ]]
  [[ "$output" == *"b.service:1:"* ]]
}

@test "fastboot slot and flash commands are caught" {
  plant a.sh 'fastboot --set-active=b'
  plant b.sh 'fastboot flash boot_a u-boot.img'
  run scan "$SCRATCH"
  [[ "$output" == *"a.sh:1:"* ]]
  [[ "$output" == *"b.sh:1:"* ]]
}

@test "Python opening the raw eMMC for writing is caught" {
  plant python/bad.py 'with open("/dev/disk/by-partlabel/xbl_a", "r+b") as f:'
  run scan "$SCRATCH"
  [[ "$output" == "python/bad.py:1:"* ]]
}

@test "a partition or filesystem tool naming the eMMC literally is caught" {
  # Even to read: the disk is found at run time, so a literal is a mistake
  # whatever the flags. tests/root-slots.bats feeds the tool a second disk.
  plant a.sh 'sfdisk --dump /dev/mmcblk0'
  plant b.sh 'sudo resize2fs /dev/mmcblk0p68 2621656'
  plant c.sh 'mkfs.ext4 -L rootfs-b /dev/mmcblk0p70'
  plant d.sh 'parted -s /dev/mmcblk0 resizepart 68 11GiB'
  plant e.sh 'sgdisk -n 70:0:0 /dev/mmcblk0'
  plant f.sh 'echo "/dev/mmcblk0p70 : start=23007232" | sfdisk --append'
  run scan "$SCRATCH"
  for f in a b c d e f; do
    [[ "$output" == *"$f.sh:1:"* ]]
  done
}

@test "the eMMC named without a disk tool, or a disk tool without it, is not flagged" {
  # status/leds.sh reads the eMMC's sysfs name; the root tool hands sfdisk a
  # disk it worked out.
  plant a.sh 'cat /sys/block/mmcblk0/stat'
  # shellcheck disable=SC2016 # planted text, not code to expand
  plant b.sh 'DUMP="$(sfdisk --dump "$1")"'
  plant c.sh 'findmnt -no SOURCE / # /dev/mmcblk0p68 here'
  run scan "$SCRATCH"
  [ -z "$output" ]
}

@test "reading the boot chain, and writing the EFI partition's files, are not flagged" {
  # What hardware.md does to find U-Boot's GPIO names, what the docs run to
  # see the slots, and what boot counting does on the ESP. Flagging these
  # would teach people to ignore the test.
  plant a.sh 'sudo dd if=/dev/disk/by-partlabel/boot_a bs=1M count=16 2>/dev/null | strings'
  plant b.sh 'sudo qbootctl; sudo qbootctl -a; sudo qbootctl -n _b'
  # shellcheck disable=SC2016 # planted text, not code to expand
  plant c.sh 'printf "default %s\n" "$id" >/boot/efi/loader/loader.conf'
  plant d.sh 'systemctl status qbootctl.service'
  run scan "$SCRATCH"
  [ -z "$output" ]
}

@test "comments and Markdown may name the commands" {
  plant a.sh '# never: qbootctl -s b, or dd of=/dev/disk/by-partlabel/boot_b'
  # shellcheck disable=SC2016 # planted text, not code to expand
  plant docs/x.md 'Do not run `qbootctl -s b`.'
  run scan "$SCRATCH"
  [ -z "$output" ]
}

@test "an untracked file is not scanned, a tracked one is" {
  # The guard is about what this project ships, which is what git tracks.
  printf 'qbootctl -s b\n' >"$SCRATCH/loose.sh"
  run scan "$SCRATCH"
  [ -z "$output" ]
  git -C "$SCRATCH" add loose.sh
  run scan "$SCRATCH"
  refute [ -z "$output" ]
}
