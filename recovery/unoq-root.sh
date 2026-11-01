#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Two root filesystems on one eMMC: A (`rootfs`) and B (`rootfs-b`). Issue #169.
#
#   sudo /usr/local/lib/unoq/recovery/unoq-root.sh plan     # the split, as a dry run
#   sudo /usr/local/lib/unoq/recovery/unoq-root.sh status   # which root is running
#
# THIS RELEASE IS PHASE 1, AND IT WRITES NOTHING. `plan` and `status` only read:
# the partition table (`sfdisk --dump`), the root filesystem's minimum size
# (`resize2fs -P`, which estimates and changes nothing), `df`, and the files on
# the EFI partition. The subcommands that would act - split, init, sync, stage,
# commit - are phases 2 and 3 of #169 and say so instead of running.
#
# WHY THE SPLIT HAS TO TAKE SPACE FROM A
# --------------------------------------
# `userdata` (/home/arduino) ends on the eMMC's last usable sector, and the
# only free space is 63 MiB in front of the first partition. A second root can
# only come out of the first, so phase 2 shrinks `rootfs` to 10 GiB and puts
# `rootfs-b` in the 10 GiB it frees, between it and `userdata`. Every other
# partition keeps its start, size, type, UUID and name. `plan` shows exactly
# that table, and the sfdisk script phase 2 would hand to the rescue shell.
#
# THE NUMBERS
# -----------
# A keeps its start. Its new end is the last sector before the first 1 MiB
# boundary at or after start + 10 GiB, so that B starts on a 1 MiB boundary,
# as every tool that makes partitions does it. B runs from there to the sector
# before the next partition's start. On this board that makes A 10 GiB and
# 864 KiB, and B 10 GiB less 864 KiB: A's start is not aligned, so one of the
# two has to absorb it.
#
# THE HEADROOM RULE: AT LEAST 1 GiB
# ---------------------------------
# `plan` refuses unless the filesystem's minimum size (resize2fs -P) leaves at
# least 1 GiB of the SMALLER slot, because B has to hold everything A holds.
# 1 GiB, because the space between that minimum and the slot is not all free
# to use:
#
#   - ext4 keeps about 5% of its blocks for root alone (this filesystem: 4.3%,
#     which on 10 GiB is about 450 MiB). An ordinary user sees the disk full
#     that much sooner;
#   - an apt upgrade with a new kernel holds two kernels' modules and two
#     initrds in /boot until the old package goes (86 MiB and 23 MiB each here),
#     and its downloads in /var/cache/apt meanwhile (209 MiB on this board at
#     the time of writing).
#
# That is about 900 MiB before anything is written on purpose. With 7.4 GB
# used and /srv/arduino-home (2.9 GB, the Zephyr SDK and workspace) staying on
# the root, the owner's choice in #169, this board has 1.39 GiB: enough, and
# not by much. A root that has grown to the point where 1 GiB is not left
# should move something off it first, not be split into a slot it fills.
#
# SEAMS FOR THE TESTS
# -------------------
# Every program it asks is found on PATH (sfdisk, resize2fs, tune2fs, findmnt,
# blkid, df, bootctl), so tests/root-slots.bats puts fakes in front of them.
# UNOQ_ROOT is put in front of /etc, /sys and /dev, and UNOQ_ESP_DIR replaces
# the EFI partition's path, as for provision/84-rescue-entry.sh. The disk is
# never named here: it is the one holding whatever `findmnt /` says is mounted.
set -uo pipefail

SYSROOT="${UNOQ_ROOT:-}"
LABEL_A=rootfs
LABEL_B=rootfs-b
SLOT_BYTES=$((10 * 1024 * 1024 * 1024))
HEADROOM_BYTES=$((1024 * 1024 * 1024))

die() {
  printf 'unoq-root: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
usage: unoq-root.sh plan | status

  plan     this board's partitions, the two-root layout proposed for it, and
           the exact sfdisk script phase 2 would use; refuses if the root
           filesystem would not fit a 10 GiB slot with 1 GiB to spare
  status   which root is running, and the boot entries for each

Both only read. split, init, sync, stage and commit are not in this release
(issue #169).
EOF
}

# gib <bytes> - for people, two decimals.
gib() { awk -v b="$1" 'BEGIN { printf "%.2f GiB", b / 1073741824 }'; }
mib() { awk -v b="$1" 'BEGIN { printf "%.0f MiB", b / 1048576 }'; }

# --- where things are ------------------------------------------------------

# root_source - the block device mounted at /, as findmnt says.
root_source() {
  local src
  src="$(findmnt -no SOURCE / 2>/dev/null | head -1)"
  [ -n "$src" ] || die "findmnt says nothing is mounted at /"
  printf '%s\n' "$src"
}

# disk_of <partition node> - the whole disk it is a partition of, from sysfs.
disk_of() {
  local name="${1##*/}" link
  link="$SYSROOT/sys/class/block/$name"
  [ -e "$link/partition" ] || die "$1 is not a partition (no $link/partition)"
  link="$(readlink -f "$link")" || die "cannot resolve $SYSROOT/sys/class/block/$name"
  printf '/dev/%s\n' "$(basename "$(dirname "$link")")"
}

# esp_dir - the EFI partition, as bootctl says, or UNOQ_ESP_DIR.
esp_dir() {
  local esp="${UNOQ_ESP_DIR:-}"
  if [ -z "$esp" ]; then
    esp="$(bootctl --print-esp-path 2>/dev/null)"
    [ -n "$esp" ] && esp="$SYSROOT$esp"
  fi
  printf '%s\n' "$esp"
}

machine_id() {
  local mid
  mid="$(cat "$SYSROOT/etc/machine-id" 2>/dev/null)"
  [ "${#mid}" = 32 ] && printf '%s\n' "$mid"
}

# --- the partition table ---------------------------------------------------

# read_table <disk> - the dump into DUMP, its header into the H_* variables,
# and one TAB-separated line per partition into PARTS:
#   node start size type uuid name attrs
# sorted by start.
read_table() {
  DUMP="$(sfdisk --dump "$1" 2>/dev/null)" ||
    die "could not read the partition table of $1 (sfdisk --dump; run with sudo)"
  H_LABEL="$(sed -n 's/^label: *//p' <<<"$DUMP")"
  H_SS="$(sed -n 's/^sector-size: *//p' <<<"$DUMP")"
  H_LAST="$(sed -n 's/^last-lba: *//p' <<<"$DUMP")"
  H_LEN="$(sed -n 's/^table-length: *//p' <<<"$DUMP")"
  H_SS="${H_SS:-512}"
  [ "$H_LABEL" = gpt ] || die "$1 has a '${H_LABEL:-?}' partition table, not GPT"
  PARTS="$(awk '
    / : start=/ {
      node = $1; start = size = type = uuid = name = attrs = ""
      line = substr($0, index($0, ":") + 1)
      n = split(line, f, ",")
      for (i = 1; i <= n; i++) {
        kv = f[i]; gsub(/^ +| +$/, "", kv)
        k = kv; sub(/=.*/, "", k); v = kv; sub(/^[^=]*= */, "", v); gsub(/"/, "", v)
        if (k == "start") start = v; else if (k == "size") size = v
        else if (k == "type") type = v; else if (k == "uuid") uuid = v
        else if (k == "name") name = v; else if (k == "attrs") attrs = v
      }
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", node, start, size, type, uuid, name, attrs
    }' <<<"$DUMP" | sort -t "$(printf '\t')" -k2,2n)"
  [ -n "$PARTS" ] || die "no partitions in the table of $1"
}

# part_field <name> <column> - a column of the partition with that GPT name.
part_field() {
  awk -F '\t' -v n="$1" -v c="$2" '$6 == n { print $c; exit }' <<<"$PARTS"
}

# --- plan ------------------------------------------------------------------

plan() {
  local src disk sep a_node a_start a_size a_type a_attrs a_num
  local next_node next_start next_name b_num align slot a_end b_start b_size
  local new_a_size max_num

  src="$(root_source)"
  disk="$(disk_of "$src")"
  read_table "$disk"

  echo "== the disk =="
  printf '  %-22s %s\n' "root filesystem" "$src (findmnt /)"
  printf '  %-22s %s, GPT, %s-byte sectors, last usable sector %s\n' "disk" "$disk" "$H_SS" "$H_LAST"

  a_node="$(part_field "$LABEL_A" 1)"
  [ -n "$a_node" ] || die "no partition named '$LABEL_A' on $disk"
  [ "$a_node" = "$src" ] ||
    die "/ is $src, not $a_node (the partition named '$LABEL_A'): plan from an ordinary boot of A"

  echo
  echo "== today =="
  awk -F '\t' -v a="$LABEL_A" -v b="$LABEL_B" '
    $6 == a || $6 == b || $6 == "userdata" || $6 == "efi" {
      printf "  %-18s %-10s start %10s  size %10s  end %10s\n", $1, $6, $2, $3, $2 + $3 - 1
    }' <<<"$PARTS"
  # What df says the root holds, beside what the table says it is.
  df -B1 --output=size,used,avail / 2>/dev/null | awk 'NR == 2 {
    printf "  %-22s %.2f GiB used of %.2f GiB, %.2f GiB free\n", "df /", $2 / 2^30, $1 / 2^30, $3 / 2^30 }'

  if [ -n "$(part_field "$LABEL_B" 1)" ]; then
    echo
    echo "== $LABEL_B =="
    b_state
    echo
    echo "The disk is already split: there is nothing to plan."
    return 0
  fi
  echo "  no $LABEL_B: nothing to split yet"

  # The arithmetic, in sectors.
  align=$((1048576 / H_SS))
  slot=$((SLOT_BYTES / H_SS))
  a_start="$(part_field "$LABEL_A" 2)"
  a_size="$(part_field "$LABEL_A" 3)"
  a_type="$(part_field "$LABEL_A" 4)"
  a_attrs="$(part_field "$LABEL_A" 7)"
  # The partition after A, by start: what B fills up to.
  read -r next_node next_start next_name < <(awk -F '\t' -v s="$a_start" '
    $2 > s { print $1, $2, $6; exit }' <<<"$PARTS")
  [ -n "${next_start:-}" ] || die "nothing after $a_node on $disk to fill up to"
  a_end=$(((a_start + slot + align - 1) / align * align - 1))
  new_a_size=$((a_end - a_start + 1))
  b_start=$((a_end + 1))
  b_size=$((next_start - b_start))
  [ $((a_start + a_size)) -le "$next_start" ] || die "$a_node overlaps $next_node"
  [ "$b_size" -ge $((slot - align)) ] ||
    die "$a_node is $(gib $((a_size * H_SS))): too small to split into two 10 GiB roots"

  # The partition number B gets: the next one free, within the table.
  max_num="$(awk -F '\t' '{ n = $1; sub(/.*[^0-9]/, "", n); if (n + 0 > m) m = n + 0 } END { print m }' <<<"$PARTS")"
  b_num=$((max_num + 1))
  [ "$b_num" -le "${H_LEN:-128}" ] ||
    die "the table has room for ${H_LEN} partitions and $max_num are used: no entry for $LABEL_B"
  a_num="${a_node##*[!0-9]}"
  sep="${a_node%"$a_num"}"

  echo
  echo "== proposed =="
  printf '  %-18s %-10s start %10s  size %10s  end %10s  (%s, was %s)\n' \
    "$a_node" "$LABEL_A" "$a_start" "$new_a_size" "$a_end" "$(gib $((new_a_size * H_SS)))" "$(gib $((a_size * H_SS)))"
  printf '  %-18s %-10s start %10s  size %10s  end %10s  (%s, new)\n' \
    "$sep$b_num" "$LABEL_B" "$b_start" "$b_size" "$((next_start - 1))" "$(gib $((b_size * H_SS)))"
  printf '  %-18s %-10s start %10s  unchanged\n' "$next_node" "$next_name" "$next_start"
  echo "  every other partition: unchanged"

  # --- will the filesystem fit? ---
  local min_blocks bs min_bytes small slot_bytes headroom
  min_blocks="$(resize2fs -P "$a_node" 2>/dev/null | sed -n 's/.*minimum size of the filesystem: *\([0-9]\{1,\}\).*/\1/p' | tail -1)"
  [ -n "$min_blocks" ] || die "resize2fs -P $a_node gave no minimum size"
  bs="$(tune2fs -l "$a_node" 2>/dev/null | sed -n 's/^Block size: *\([0-9]\{1,\}\).*/\1/p' | head -1)"
  [ -n "$bs" ] || die "tune2fs -l $a_node gave no block size"
  min_bytes=$((min_blocks * bs))
  small=$((new_a_size < b_size ? new_a_size : b_size))
  slot_bytes=$((small * H_SS))
  headroom=$((slot_bytes - min_bytes))

  echo
  echo "== will the root fit a slot? =="
  printf '  %-22s %s blocks of %s = %s (resize2fs -P, an estimate)\n' "smallest it can be" "$min_blocks" "$bs" "$(gib "$min_bytes")"
  printf '  %-22s %s (the smaller of the two; B has to hold all of A)\n' "slot" "$(gib "$slot_bytes")"
  printf '  %-22s %s; at least %s is required\n' "headroom" "$(gib "$headroom")" "$(gib "$HEADROOM_BYTES")"
  if [ "$headroom" -lt "$HEADROOM_BYTES" ]; then
    die "REFUSED: the root filesystem needs at least $(gib "$min_bytes"), which leaves $(gib "$headroom") of a $(gib "$slot_bytes") slot, under the $(gib "$HEADROOM_BYTES") it must leave: root's reserved blocks and one kernel upgrade would fill it. Move something off the root first (du -xh / --max-depth=2)."
  fi

  # --- the EFI partition ---
  local esp mid pair=0 e f lin sz free need
  esp="$(esp_dir)"
  mid="$(machine_id)"
  echo
  echo "== the EFI partition =="
  if [ -z "$esp" ] || [ ! -d "$esp/loader/entries" ] || [ -z "$mid" ]; then
    die "no EFI partition with loader/entries, or no machine-id, at '${esp:-?}'"
  fi
  # The largest kernel and initrd any of A's entries boots. B gets a pair of
  # its own under $mid-b/, and staging writes the next pair beside it: two.
  for e in "$esp"/loader/entries/*.conf; do
    [ -f "$e" ] || continue
    lin="$(sed -n 's/^linux[[:space:]]\{1,\}//p' "$e" | head -1)"
    case "$lin" in "/$mid/rescue/"*) continue ;; "/$mid/"*) ;; *) continue ;; esac
    sz=0
    for f in "$lin" $(sed -n 's/^initrd[[:space:]]\{1,\}//p' "$e"); do
      [ -f "$esp$f" ] && sz=$((sz + $(stat -c %s "$esp$f")))
    done
    [ "$sz" -gt "$pair" ] && pair="$sz"
  done
  [ "$pair" -gt 0 ] || die "no kernel entry for machine-id $mid on $esp to size B's kernel by"
  free="$(df -B1 --output=avail "$esp" 2>/dev/null | awk 'NR == 2 { print $1 }')"
  [ -n "$free" ] || die "df could not say how much of $esp is free"
  need=$((2 * pair))
  printf '  %-22s %s\n' "kernel + initrd" "$(mib "$pair") (the largest of A's entries)"
  printf '  %-22s %s, for B'\''s pair in /%s-b/ and the next one staged beside it\n' "B needs" "$(mib "$need")" "$mid"
  printf '  %-22s %s on %s\n' "free" "$(mib "$free")" "$esp"
  [ "$free" -ge "$need" ] ||
    die "REFUSED: the EFI partition has $(mib "$free") free and B's kernels need $(mib "$need")"

  # --- the script ---
  echo
  echo "== the sfdisk script phase 2 would use (NOT RUN; not in this release) =="
  echo "# Today's table, with $LABEL_A's size changed and $LABEL_B added. Every"
  echo "# other line is today's, byte for byte. sfdisk makes $LABEL_B's UUID."
  awk -v node="$a_node" -v size="$new_a_size" '
    $1 == node && / : start=/ { sub(/size= *[0-9]+/, "size=" size) }
    { print }' <<<"$DUMP"
  printf '%s : start=%s, size=%s, type=%s, name="%s"%s\n' "$sep$b_num" "$b_start" "$b_size" "$a_type" "$LABEL_B" \
    "${a_attrs:+, attrs=\"$a_attrs\"}"

  echo
  echo "== phase 2, from the rescue shell (NOT RUN; not in this release) =="
  echo "  e2fsck -f $a_node"
  echo "  resize2fs $a_node $((new_a_size * H_SS / bs))    # blocks of $bs: the new size of $LABEL_A"
  echo "  sfdisk --no-reread $disk < the script above"
  echo "  then 'unoq-root init': B's filesystem (issue #169, phase 2, which has its own approval)"
}

# b_state - what is in rootfs-b, if there is one.
b_state() {
  local node size fs
  node="$(part_field "$LABEL_B" 1)"
  size="$(part_field "$LABEL_B" 3)"
  printf '  %-22s %s, %s sectors (%s)\n' "partition" "$node" "$size" "$(gib $((size * H_SS)))"
  fs="$(blkid -o value -s TYPE "$node" 2>/dev/null)"
  printf '  %-22s %s\n' "filesystem" "${fs:-none}"
  if findmnt -no TARGET "$node" >/dev/null 2>&1; then
    printf '  %-22s %s\n' "mounted at" "$(findmnt -no TARGET "$node" | head -1)"
  fi
}

# --- status ----------------------------------------------------------------

# by_link <dir> <name> - the device node a /dev/disk/by-* link names, or nothing.
by_link() {
  local l="$SYSROOT/dev/disk/$1/$2"
  [ -L "$l" ] || return 0
  printf '/dev/%s\n' "$(basename "$(readlink "$l")")"
}

status() {
  local src uuid node a b slot esp mid e name lin key ver tries s
  src="$(root_source)"
  uuid="$(findmnt -no UUID / 2>/dev/null | head -1)"
  node="$(by_link by-uuid "$uuid")"
  node="${node:-$src}"
  a="$(by_link by-partlabel "$LABEL_A")"
  b="$(by_link by-partlabel "$LABEL_B")"
  case "$node" in
    "") slot="unknown" ;;
    "$a") slot="A ($LABEL_A)" ;;
    "$b") slot="B ($LABEL_B)" ;;
    *) slot="neither" ;;
  esac
  echo "== running =="
  printf '  %-22s %s\n' "root" "$node, UUID ${uuid:-?}"
  printf '  %-22s %s\n' "slot" "$slot"
  printf '  %-22s %s\n' "$LABEL_A" "${a:-<none>}"
  printf '  %-22s %s\n' "$LABEL_B" "${b:-<none: nothing to split yet>}"

  esp="$(esp_dir)"
  mid="$(machine_id)"
  echo
  echo "== boot entries, by the slot their kernel is in =="
  if [ -z "$esp" ] || [ ! -d "$esp/loader/entries" ] || [ -z "$mid" ]; then
    echo "  no EFI partition with loader/entries, or no machine-id, at '${esp:-?}'"
    return 0
  fi
  for e in "$esp"/loader/entries/*.conf; do
    [ -f "$e" ] || continue
    name="${e##*/}"
    lin="$(sed -n 's/^linux[[:space:]]\{1,\}//p' "$e" | head -1)"
    key="$(sed -n 's/^sort-key[[:space:]]\{1,\}//p' "$e" | head -1)"
    ver="$(sed -n 's/^version[[:space:]]\{1,\}//p' "$e" | head -1)"
    case "$lin" in
      "/$mid-b/"*) s=B ;;
      "/$mid/rescue/"*) s=rescue ;;
      "/$mid/"*) s=A ;;
      *) s=other ;;
    esac
    # Boot counting's counter is in the name: +LEFT or +LEFT-DONE.
    if [[ "$name" =~ \+([0-9]+)(-([0-9]+))?\.conf$ ]]; then
      tries="${BASH_REMATCH[1]} left${BASH_REMATCH[3]:+, ${BASH_REMATCH[3]} done}"
    else
      tries="not counted"
    fi
    printf '  %-7s %-58s sort-key %-15s %s, %s\n' "$s" "$name" "${key:-<none>}" "${ver:-?}" "$tries"
  done
  printf '  %-22s %s\n' "loader.conf default" \
    "$(sed -n 's/^default[[:space:]]\{1,\}//p' "$esp/loader/loader.conf" 2>/dev/null | head -1)"
}

# --- not in this release ---------------------------------------------------

case "${1:-}" in
  plan) plan ;;
  status) status ;;
  split | init | sync | stage | commit)
    printf 'unoq-root: %s is not in this release; see #169\n' "$1" >&2
    exit 2
    ;;
  -h | --help | help) usage ;;
  *)
    usage >&2
    exit 2
    ;;
esac
