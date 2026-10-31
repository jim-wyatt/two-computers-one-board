#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# A rescue boot entry: SSH over the USB cable, from an initramfs that mounts
# no root filesystem at all.
#
#   sudo bash ~/two-computers-one-board/provision/84-rescue-entry.sh
#
# Idempotent: a second run reports "already correct" and changes nothing. It is
# not in bootstrap.sh's default run: it takes --with-rescue-entry, or
# --with-recovery (boot counting and this together).
#
# Phase 2 of issue #93, "a recovery path no matter what", built in #168. Boot
# counting (82-boot-counting.sh) falls back from a bad kernel to the previous
# one. This is what is there when there is no good one left, or when the root
# filesystem itself is what is broken: a third entry that brings the board up
# far enough to be reached over the cable, and no further.
#
# NEVER BOOTED ON A BOARD YET. Everything here is checked against faked
# commands (tests/rescue-entry.bats). Booting it once, safely, is a separate
# step the owner takes: docs/reference/troubleshooting.md, "Booting the rescue
# entry once".
#
# WHAT IT WRITES
# --------------
#   /etc/unoq-rescue/dropbear/         the rescue host key (generated here, per
#                                      board) and a copy of your authorized_keys
#   /etc/unoq-rescue/initramfs/        an initramfs-tools configuration
#                                      directory of its own: initramfs.conf, the
#                                      hook, the premount script, unoq-rescue.conf
#   <ESP>/<machine-id>/rescue/linux    the running kernel, copied
#   <ESP>/<machine-id>/rescue/initrd.img  built with mkinitramfs -d from the above
#   <ESP>/loader/entries/<machine-id>-rescue.conf
#
# It never writes loader.conf, never touches another entry, never changes the
# default, and never writes /etc/initramfs-tools: the ordinary initrd is built
# exactly as before, with nothing of this in it.
#
# WHY NOT dropbear-initramfs
# --------------------------
# The obvious package installs its hook and its premount script into
# /usr/share/initramfs-tools, where they go into EVERY initrd, and its postinst
# runs `update-initramfs -u` there and then. The board's own initrd would be
# rebuilt on the spot, start dropbear and try to configure a network on every
# boot. So this installs dropbear-bin, which is only the programs, and its own
# hook copies dropbear into the rescue initrd alone.
#
# HOW THE ENTRY SORTS, AND WHY THAT IS THE POINT
# ----------------------------------------------
# systemd-boot 257 sorts entries with boot_entry_compare() in
# src/boot/boot.c (https://github.com/systemd/systemd/blob/v257/src/boot/boot.c):
#
#   1. entries with no tries left (+0) go to the end;
#   2. entries with a sort-key come before entries without one;
#   3. between two with a sort-key: by sort-key (strcmp16, so byte order),
#      then machine-id, then version, newest first;
#   4. then by id.
#
# and config_select_default_entry() takes the default as the FIRST entry, in
# that order, whose id matches loader.conf's `default` pattern (efi_fnmatch;
# the id is the file name, counter and all), or the first entry when nothing
# matches. Every entry kernel-install writes has `sort-key debian`. This one
# has `sort-key zz-unoq-rescue`, which sorts after it by rule 3, so:
#
#   - while any kernel entry is good, a kernel is first, and it is the one the
#     stock `default <machine-id>-*` picks. The rescue entry matches that
#     pattern too, and is never the first match;
#   - when every kernel entry is at +0, rule 1 puts them all below the rescue
#     entry, and it is the first match: the board falls through to it;
#   - or someone picks it on purpose.
#
# This step checks rule 3 against every other entry on the ESP, and refuses if
# one has no sort-key or one that sorts after this one: that entry would sort
# BELOW the rescue entry, and the rescue entry could become the default.
#
# Today the running kernel's entry has no counter (owner's decision, #168: not
# this round), so it is never set aside, and the fall-through cannot happen
# until it does. Until then the rescue entry is reached only on purpose.
#
# REVERT: rm /boot/efi/loader/entries/<machine-id>-rescue.conf &&
#         rm -r /boot/efi/<machine-id>/rescue /etc/unoq-rescue
#         (and apt-get remove dropbear-bin, if nothing else wants it)
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
# is_ipv4, one copy for the whole project. Sourced by path, read-only.
# shellcheck source=usb/common.sh
. "$PROJECT/usb/common.sh"
need_root

SORT_KEY="zz-unoq-rescue"
ADDR="${UNOQ_RESCUE_ADDR:-169.254.77.1/16}"
CONF_DIR="${UNOQ_INITRAMFS_CONF_DIR:-$SYSROOT/etc/unoq-rescue/initramfs}"
KEYS_DIR="${UNOQ_DROPBEAR_DIR:-$SYSROOT/etc/unoq-rescue/dropbear}"
HOSTKEY="$KEYS_DIR/dropbear_ed25519_host_key"

# The modules the rescue system needs, by their file names in modules.dep. The
# running system has every one of them for the USB-C port (lsmod, and
# /sys/bus/platform/drivers: dwc3, dwc3-qcom-legacy, qcom-qusb2-phy,
# qcom-qmp-usbc-phy, anx7625 on i2c-1). Built-in is as good as a module.
MODULES="libcomposite u_ether usb_f_ncm phy-qcom-qusb2 phy-qcom-qmp-usbc typec
anx7625 qcom_usb_vbus-regulator dwc3 dwc3-qcom-legacy udc-core roles vfat"

# lt <a> <b> - does a sort strictly before b, byte by byte, as strcmp16 does?
lt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | LC_ALL=C sort | head -1)" = "$1" ]
}

step "boot loader"
if ! command -v bootctl >/dev/null 2>&1 || ! bootctl is-installed --quiet 2>/dev/null; then
  skip "systemd-boot is not installed here - nothing to add an entry to, nothing written"
  summary
  exit 0
fi
skip "systemd-boot installed: $(bootctl --version 2>/dev/null | head -1)"

ESP="${UNOQ_ESP_DIR:-$(bootctl --print-esp-path 2>/dev/null)}"
[ -n "$ESP" ] && [ -d "$ESP/loader/entries" ] ||
  fail "no EFI partition with loader/entries at '${ESP:-?}'"
MID="$(cat "$SYSROOT/etc/machine-id" 2>/dev/null)"
case "$MID" in
  [0-9a-f]*) [ "${#MID}" = 32 ] || fail "/etc/machine-id is not 32 hex digits" ;;
  *) fail "no /etc/machine-id to name the entry by" ;;
esac
KVER="$(uname -r)"
RESCUE_DIR="$ESP/$MID/rescue"
ENTRY="$ESP/loader/entries/$MID-rescue.conf"
skip "EFI partition $ESP, machine-id $MID, kernel $KVER"

step "settings"
# Checked before anything is written, so a typo costs nothing.
is_ipv4 "${ADDR%/*}" ||
  fail "UNOQ_RESCUE_ADDR must be an IPv4 address with a prefix length, like 169.254.77.1/16, not '$ADDR'"
case "$ADDR" in
  */[1-9] | */[12][0-9] | */3[0-2]) ;;
  *) fail "UNOQ_RESCUE_ADDR needs a prefix length from 1 to 32, like 169.254.77.1/16, not '$ADDR'" ;;
esac
skip "the rescue system answers at ${ADDR%/*}"

# Who may log in: the keys that already log in to this board as you. Copied,
# not linked: the rescue system has no home directory to read them from.
KEYS_FROM="$TARGET_HOME/.ssh/authorized_keys"
if ! grep -qE '^[^#]*(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) ' \
  "$KEYS_FROM" 2>/dev/null; then
  fail "no SSH public key in $KEYS_FROM.
        The rescue system takes no passwords, so with no key nobody could log in
        to it. From the computer you use, put your key on the board first:
            ssh-copy-id $TARGET_USER@<board>
        check that 'ssh $TARGET_USER@<board>' no longer asks for a password, and
        run this again. Nothing written."
fi
skip "the keys in $KEYS_FROM will be let in"

# The command line the rescue kernel gets: this one's, less everything about
# the root filesystem and systemd, which the rescue system has neither of.
# What is left is what the hardware needs (clk_ignore_unused,
# pd_ignore_unused, deferred_probe_timeout=30 on this image).
CMDLINE="$(cat "$SYSROOT/proc/cmdline" 2>/dev/null)"
case " $CMDLINE " in
  *" unoq.rescue=1 "*) fail "this is the rescue system - run this from an ordinary boot" ;;
esac
OPTIONS=""
for arg in $CMDLINE; do
  case "$arg" in
    initrd=* | BOOT_IMAGE=* | root=* | rootflags=* | rootfstype=* | ro | rw | \
      resume=* | init=* | systemd.* | quiet | splash | unoq.*) ;;
    *) OPTIONS="${OPTIONS:+$OPTIONS }$arg" ;;
  esac
done
OPTIONS="${OPTIONS:+$OPTIONS }unoq.rescue=1"

step "entries already there"
# Rule 3 of HOW THE ENTRY SORTS, checked rather than assumed: every other
# entry must sort above this one while it is good.
for e in "$ESP"/loader/entries/*.conf; do
  [ -e "$e" ] || continue
  case "${e##*/}" in "$MID"-rescue.conf | "$MID"-rescue-test*.conf) continue ;; esac
  key="$(sed -n 's/^sort-key[[:space:]]\{1,\}//p' "$e" | head -1 | tr -d '[:space:]')"
  [ -n "$key" ] ||
    fail "${e##*/} has no sort-key, so it sorts BELOW the rescue entry, which could
        then be the default. Nothing written."
  lt "$key" "$SORT_KEY" ||
    fail "${e##*/} has sort-key '$key', which sorts after '$SORT_KEY': the rescue
        entry would sort above it. Nothing written."
  skip "${e##*/} (sort-key $key) sorts above the rescue entry"
done

step "kernel modules"
MODDIR="$SYSROOT/lib/modules/$KVER"
[ -f "$MODDIR/modules.dep" ] || fail "no $MODDIR/modules.dep"
absent=""
for m in $MODULES; do
  if grep -qE "(^|/)$m\.ko(\.[a-z]+)?:" "$MODDIR/modules.dep" ||
    grep -qE "(^|/)$m\.ko$" "$MODDIR/modules.builtin" 2>/dev/null; then
    continue
  fi
  absent="$absent $m"
done
[ -z "$absent" ] ||
  fail "kernel $KVER has none of:$absent - the rescue system could not reach the USB port"
skip "kernel $KVER has every module the USB port needs"

# REVERT: apt-get remove dropbear-bin
step "packages"
apt_install dropbear-bin initramfs-tools busybox

# REVERT: rm -r /etc/unoq-rescue/dropbear
step "keys"
# Copied, so the rescue initrd is built from a root-owned snapshot.
install -d -m 0700 "$KEYS_DIR" || fail "could not create $KEYS_DIR"
write_file 0600 "$KEYS_DIR/authorized_keys" <"$KEYS_FROM" || true
# A host key of its own, made here, once. Not a copy of the board's OpenSSH
# key: that would put root's private key on the EFI partition, which is FAT
# and readable by anything that mounts it. The price is that ssh warns the
# first time, because the rescue system is a different host; the fingerprint
# below is what to compare.
if [ -s "$HOSTKEY" ]; then
  skip "rescue host key exists"
else
  dropbearkey -t ed25519 -f "$HOSTKEY" >/dev/null 2>&1 ||
    fail "dropbearkey could not make a host key"
  chmod 0600 "$HOSTKEY"
  did "rescue host key made: $HOSTKEY"
fi
FP="$(dropbearkey -y -f "$HOSTKEY" 2>/dev/null | sed -n 's/^Fingerprint: //p' | head -1)"
skip "rescue host key fingerprint: ${FP:-unknown}"

# REVERT: rm -r /etc/unoq-rescue/initramfs
step "initramfs configuration (its own, not /etc/initramfs-tools)"
mkdir -p "$CONF_DIR/hooks" "$CONF_DIR/scripts/init-premount" "$CONF_DIR/conf.d" ||
  fail "could not create $CONF_DIR"
# The stock settings, with two differences. BUSYBOX=y: the rescue shell is
# BusyBox. UMASK=0077: the image holds a private key.
write_file 0644 "$CONF_DIR/initramfs.conf" <<'EOF' || true
# Written by provision/84-rescue-entry.sh, for the rescue initrd only.
MODULES=most
BUSYBOX=y
KEYMAP=n
COMPRESS=zstd
DEVICE=
NFSROOT=auto
RUNSIZE=10%
FSTYPE=auto
UMASK=0077
EOF
write_file 0644 "$CONF_DIR/modules" <<<"# Written by provision/84-rescue-entry.sh; the hook adds what it needs." || true
write_file 0755 "$CONF_DIR/hooks/unoq-rescue" <"$PROJECT/provision/rescue/hook.sh" || true
write_file 0755 "$CONF_DIR/scripts/init-premount/unoq-rescue" <"$PROJECT/provision/rescue/premount.sh" || true
# The same MACs usb/gadget-up.sh derives from /etc/machine-id, which the
# rescue system cannot read, so the computer sees the adapter it knows.
MAC_BASE="$(tr -d '-' <<<"$MID" | cut -c1-10)"
mac() { printf '%s:%s:%s:%s:%s:%s' "$1" "${MAC_BASE:0:2}" "${MAC_BASE:2:2}" "${MAC_BASE:4:2}" "${MAC_BASE:6:2}" "${MAC_BASE:8:2}"; }
write_file 0644 "$CONF_DIR/unoq-rescue.conf" <<EOF || true
# Written by provision/84-rescue-entry.sh. Read by the hook at build time and
# by the rescue system at boot, as data.
ADDR=$ADDR
DEV_MAC=$(mac 42)
HOST_MAC=$(mac 46)
SERIAL=${MID:0:16}
DROPBEAR_DIR=$KEYS_DIR
EOF

# REVERT: rm -r /boot/efi/<machine-id>/rescue
step "kernel and initrd on the EFI partition"
VMLINUZ="$SYSROOT/boot/vmlinuz-$KVER"
[ -f "$VMLINUZ" ] || fail "no $VMLINUZ to copy"
mkdir -p "$RESCUE_DIR" || fail "could not create $RESCUE_DIR"
# A copy of its own, beside its own initrd, so that removing the kernel package
# cannot take the rescue entry's kernel with it. The two are a matched pair.
if cmp -s "$VMLINUZ" "$RESCUE_DIR/linux"; then
  skip "$RESCUE_DIR/linux is kernel $KVER"
else
  if ! cp "$VMLINUZ" "$RESCUE_DIR/linux.new" || ! mv -f "$RESCUE_DIR/linux.new" "$RESCUE_DIR/linux"; then
    fail "could not copy the kernel to $RESCUE_DIR"
  fi
  did "copied kernel $KVER to $RESCUE_DIR/linux"
fi

# Rebuilt only when something that goes into it has changed. mkinitramfs never
# makes the same bytes twice, so "is it different" cannot be asked of the
# image itself; it is asked of what the image is made from.
inputs() {
  echo "$KVER"
  cat "$CONF_DIR/initramfs.conf" "$CONF_DIR/hooks/unoq-rescue" \
    "$CONF_DIR/scripts/init-premount/unoq-rescue" "$CONF_DIR/unoq-rescue.conf" \
    "$HOSTKEY" "$KEYS_DIR/authorized_keys" "$VMLINUZ" | sha256sum | cut -d' ' -f1
}
WANT="$(inputs)"
if [ -s "$RESCUE_DIR/initrd.img" ] && [ "$(cat "$RESCUE_DIR/inputs" 2>/dev/null)" = "$WANT" ]; then
  skip "$RESCUE_DIR/initrd.img is up to date"
else
  rm -f "$RESCUE_DIR/initrd.img.new"
  mkinitramfs -d "$CONF_DIR" -o "$RESCUE_DIR/initrd.img.new" "$KVER" ||
    fail "mkinitramfs failed - the previous rescue initrd, if any, is untouched"
  # What it must contain to be a rescue system at all. A hook that silently
  # did nothing would otherwise produce a perfectly good ORDINARY initrd,
  # which would wait for a root= the entry does not give it.
  listing="$(lsinitramfs "$RESCUE_DIR/initrd.img.new" 2>/dev/null)"
  for want in 'scripts/init-premount/unoq-rescue' '(usr/)?sbin/dropbear' \
    'etc/dropbear/dropbear_ed25519_host_key' 'root/\.ssh/authorized_keys' \
    'etc/unoq-rescue\.conf' 'libcomposite\.ko' 'usb_f_ncm\.ko'; do
    grep -qE "(^|/)$want(\.[a-z]+)?$" <<<"$listing" || {
      rm -f "$RESCUE_DIR/initrd.img.new"
      fail "the new rescue initrd has no $want - not installed"
    }
  done
  mv -f "$RESCUE_DIR/initrd.img.new" "$RESCUE_DIR/initrd.img" ||
    fail "could not put the rescue initrd in place"
  echo "$WANT" >"$RESCUE_DIR/inputs"
  did "built $RESCUE_DIR/initrd.img"
fi

# REVERT: rm /boot/efi/loader/entries/<machine-id>-rescue.conf
step "boot entry"
# Last, so that it never names a kernel or an initrd that is not there yet.
write_file 0644 "$ENTRY" <<EOF || true
# Rescue entry, written by provision/84-rescue-entry.sh (issue #168).
# Sorts below every good kernel; see that script for why and how.
title      Rescue: SSH over USB at ${ADDR%/*}, no root mounted
version    $KVER
machine-id $MID
sort-key   $SORT_KEY
options    $OPTIONS
linux      /$MID/rescue/linux
initrd     /$MID/rescue/initrd.img
EOF

step "now"
skip "booted from: $(bootctl status 2>/dev/null | sed -n 's/^ *Current Entry: //p' | head -1); loader.conf and the default are as they were"
skip "booting it once, safely: docs/reference/troubleshooting.md, 'Booting the rescue entry once'"

summary
