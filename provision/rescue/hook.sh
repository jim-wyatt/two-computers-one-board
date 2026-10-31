#!/bin/sh
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# initramfs-tools hook for the rescue initrd: what the rescue system needs
# that an ordinary initrd does not have. Issue #168.
#
# Installed by provision/84-rescue-entry.sh as
#   /etc/unoq-rescue/initramfs/hooks/unoq-rescue
# and run by `mkinitramfs -d /etc/unoq-rescue/initramfs`, which runs the hooks
# in /usr/share/initramfs-tools/hooks and in the -d directory, and nowhere
# else. A hook in /etc/initramfs-tools/hooks would run for EVERY initrd,
# including the one the board boots from; this one cannot. It also checks, in
# case it is ever copied somewhere it does not belong.
#
# WHAT IT ADDS
# ------------
#   - modules: the gadget framework (libcomposite, u_ether, usb_f_ncm), and
#     the USB and Type-C drivers the running system has loaded for the port:
#     the two PHYs, the Type-C class, anx7625 (the Type-C controller, which is
#     what chooses host or device on this board) and the VBUS regulator.
#     dwc3 itself, dwc3-qcom, the role switch and udc-core are built into
#     this kernel, so there is nothing to copy for them. vfat and two
#     codepages, so the EFI partition can be mounted from the rescue shell.
#   - dropbear, with the host key and authorized_keys provisioning put in
#     the dropbear directory, and enough of /etc for it to find root.
#   - ip (iproute2), and sfdisk, resize2fs and e2fsck, which phase 3 of #93
#     needs to work on a root filesystem that is not mounted.
#   - /etc/unoq-rescue.conf, which the premount script reads.
#
# POSIX sh: mkinitramfs runs hooks with /bin/sh.

PREREQ=""
prereqs() { echo "$PREREQ"; }
case "${1:-}" in
  prereqs)
    prereqs
    exit 0
    ;;
esac

# Only for the rescue build. mkinitramfs exports CONFDIR, the -d directory;
# provisioning puts unoq-rescue.conf there and nowhere else.
[ -f "${CONFDIR:-}/unoq-rescue.conf" ] || exit 0

# shellcheck source=/dev/null # initramfs-tools' own, on the board
. /usr/share/initramfs-tools/hook-functions

conf() { sed -n "s/^$1=//p" "$CONFDIR/unoq-rescue.conf" | tail -1; }
KEYS="$(conf DROPBEAR_DIR)"

# Built in or missing is not an error for manual_add_modules: it skips a
# built-in module and warns about a missing one. provisioning checked
# modules.dep and modules.builtin before getting here.
manual_add_modules libcomposite u_ether usb_f_ncm \
  phy-qcom-qusb2 phy-qcom-qmp-usbc typec anx7625 qcom_usb_vbus-regulator \
  dwc3 dwc3-qcom dwc3-qcom-legacy \
  vfat nls_cp437 nls_iso8859-1

copy_exec /usr/sbin/dropbear /sbin
copy_exec /usr/bin/ip /sbin
copy_exec /usr/sbin/sfdisk /sbin
copy_exec /usr/sbin/resize2fs /sbin
copy_exec /usr/sbin/e2fsck /sbin

# dropbear looks root up through NSS, as the dropbear-initramfs hook does.
for so in $(ldconfig -p | sed -nr 's/^\s*libnss_files\.so\.[0-9]+\s.*=>\s*//p'); do
  copy_exec "$so"
done
grep -q '^passwd:' "$DESTDIR/etc/nsswitch.conf" 2>/dev/null ||
  echo "passwd: files" >>"$DESTDIR/etc/nsswitch.conf"
grep -q '^group:' "$DESTDIR/etc/nsswitch.conf" 2>/dev/null ||
  echo "group: files" >>"$DESTDIR/etc/nsswitch.conf"
grep -q '^root:' "$DESTDIR/etc/passwd" 2>/dev/null ||
  echo "root:*:0:0:root:/root:/bin/sh" >>"$DESTDIR/etc/passwd"
grep -q '^root:' "$DESTDIR/etc/group" 2>/dev/null ||
  echo "root:x:0:" >>"$DESTDIR/etc/group"
grep -qx '/bin/sh' "$DESTDIR/etc/shells" 2>/dev/null ||
  echo "/bin/sh" >>"$DESTDIR/etc/shells"

mkdir -p "$DESTDIR/etc/dropbear" "$DESTDIR/root/.ssh"
chmod 0700 "$DESTDIR/root" "$DESTDIR/root/.ssh"
cp "$KEYS/dropbear_ed25519_host_key" "$DESTDIR/etc/dropbear/"
cp "$KEYS/authorized_keys" "$DESTDIR/root/.ssh/authorized_keys"
chmod 0600 "$DESTDIR/etc/dropbear/dropbear_ed25519_host_key" \
  "$DESTDIR/root/.ssh/authorized_keys"

cp "$CONFDIR/unoq-rescue.conf" "$DESTDIR/etc/unoq-rescue.conf"
