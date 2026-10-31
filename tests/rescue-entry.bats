#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# provision/84-rescue-entry.sh adds a third boot entry, a rescue system with
# SSH over the USB cable and no root filesystem (issue #168, phase 2 of #93).
# A recovery path must never be the cause of an outage, so most of what is
# tested here is what it must NOT do: write loader.conf, touch another entry,
# change what an ordinary boot runs, or install an entry no one can log in to.
#
# What this cannot show: that the rescue kernel brings the USB port up as a
# device in an initramfs, that dropbear answers, or that systemd-boot falls
# through to the entry. That takes a boot; docs/reference/troubleshooting.md
# has the counted one-shot test.

setup() {
  load helpers/stub
  stub_setup
  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  STEP="$PROJECT/provision/84-rescue-entry.sh"
  PREMOUNT="$PROJECT/provision/rescue/premount.sh"
  HOOK="$PROJECT/provision/rescue/hook.sh"

  MID=f182f7e1bba34e8cba957f11b0f11612
  KVER=7.0.0-g122c2c22d838
  export KVER
  STOCK_OPTS="root=UUID=51ce1435 clk_ignore_unused pd_ignore_unused audit=0 deferred_probe_timeout=30 systemd.machine_id=$MID"

  export UNOQ_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$UNOQ_ROOT/etc" "$UNOQ_ROOT/proc" "$UNOQ_ROOT/boot" "$UNOQ_ROOT/lib/modules/$KVER"
  echo "$MID" >"$UNOQ_ROOT/etc/machine-id"
  echo "initrd=\\$MID\\$KVER\\initrd.img-$KVER $STOCK_OPTS" >"$UNOQ_ROOT/proc/cmdline"
  echo "kernel image" >"$UNOQ_ROOT/boot/vmlinuz-$KVER"
  # The modules the rescue system needs, as this kernel has them: some built
  # in, the rest modules.
  M="kernel/drivers"
  cat >"$UNOQ_ROOT/lib/modules/$KVER/modules.dep" <<EOF
$M/usb/gadget/libcomposite.ko:
$M/usb/gadget/function/u_ether.ko: $M/usb/gadget/libcomposite.ko
$M/usb/gadget/function/usb_f_ncm.ko: $M/usb/gadget/function/u_ether.ko $M/usb/gadget/libcomposite.ko
$M/phy/qualcomm/phy-qcom-qusb2.ko:
$M/phy/qualcomm/phy-qcom-qmp-usbc.ko: $M/usb/typec/typec.ko
$M/usb/typec/typec.ko:
$M/gpu/drm/bridge/analogix/anx7625.ko: $M/usb/typec/typec.ko
$M/regulator/qcom_usb_vbus-regulator.ko:
EOF
  cat >"$UNOQ_ROOT/lib/modules/$KVER/modules.builtin" <<EOF
$M/usb/dwc3/dwc3.ko
$M/usb/dwc3/dwc3-qcom-legacy.ko
$M/usb/gadget/udc/udc-core.ko
$M/usb/roles/roles.ko
kernel/fs/fat/vfat.ko
EOF

  # The EFI partition as the board has it: one kernel entry, the stock
  # loader.conf with its glob default.
  export UNOQ_ESP_DIR="$BATS_TEST_TMPDIR/esp"
  mkdir -p "$UNOQ_ESP_DIR/loader/entries" "$UNOQ_ESP_DIR/$MID/$KVER"
  printf '#timeout 3\n#console-mode keep\ndefault %s-*\n' "$MID" >"$UNOQ_ESP_DIR/loader/loader.conf"
  STOCK_ENTRY="$UNOQ_ESP_DIR/loader/entries/$MID-$KVER.conf"
  cat >"$STOCK_ENTRY" <<EOF
title      Debian GNU/Linux 13 (trixie)
version    $KVER
machine-id $MID
sort-key   debian
options     $STOCK_OPTS
linux      /$MID/$KVER/linux
initrd     /$MID/$KVER/initrd.img-$KVER
EOF
  echo "kernel image" >"$UNOQ_ESP_DIR/$MID/$KVER/linux"

  export UNOQ_HOME_DIR="$BATS_TEST_TMPDIR/home"
  mkdir -p "$UNOQ_HOME_DIR/.ssh"
  echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample someone@laptop" >"$UNOQ_HOME_DIR/.ssh/authorized_keys"
  UNOQ_USER="$(id -un)"
  export UNOQ_USER
  unset UNOQ_RESCUE_ADDR UNOQ_INITRAMFS_CONF_DIR UNOQ_DROPBEAR_DIR
  export UNOQ_RUN_DIR="$BATS_TEST_TMPDIR/run"
  mkdir -p "$UNOQ_RUN_DIR"

  FLAGS="$BATS_TEST_TMPDIR/flags"
  mkdir -p "$FLAGS"
  export FLAGS

  stub_body id <<'SH'
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
SH
  # Whose home the keys come from: lib.sh asks getent.
  stub_body getent <<'SH'
[ "$1" = passwd ] && { echo "$2:x:1000:1000::$UNOQ_HOME_DIR:/bin/bash"; exit 0; }
exit 2
SH
  stub_body uname <<'SH'
[ "${1:-}" = "-r" ] && { echo "$KVER"; exit 0; }
exec /usr/bin/uname "$@"
SH
  stub_body bootctl <<'SH'
case "$*" in
  "is-installed --quiet") [ -e "$FLAGS/no-systemd-boot" ] && exit 1; exit 0 ;;
  --version) echo "systemd 257 (257.13-1~deb13u1)" ;;
  status) echo "Current Entry: f182-7.0.0.conf" ;;
esac
exit 0
SH
  stub_body dpkg-query <<'SH'
[ -e "$FLAGS/installed" ] && { printf 'install ok installed'; exit 0; }
exit 1
SH
  stub_body apt-get <<'SH'
case "$1" in install) : >"$FLAGS/installed" ;; esac
exit 0
SH
  stub_body dropbearkey <<'SH'
case "$1" in
  -t) echo "PRIVATE ed25519" >"$4" ;;
  -y) printf 'Public key portion is:\nssh-ed25519 AAAA root@unoq\nFingerprint: SHA256:testprint\n' ;;
esac
exit 0
SH
  stub_body mkinitramfs <<'SH'
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift ;; esac
  shift
done
[ -e "$FLAGS/mkinitramfs-fails" ] && exit 1
echo "initrd $(date +%s%N)" >"$out"
SH
  # What a rescue initrd lists. With $FLAGS/hollow, what an ordinary one does:
  # the hook did nothing.
  stub_body lsinitramfs <<'SH'
echo "usr/lib/modules/$KVER/kernel/drivers/usb/gadget/libcomposite.ko"
echo "usr/lib/modules/$KVER/kernel/drivers/usb/gadget/function/usb_f_ncm.ko"
[ -e "$FLAGS/hollow" ] && exit 0
echo "scripts/init-premount/unoq-rescue"
echo "usr/sbin/dropbear"
echo "etc/dropbear/dropbear_ed25519_host_key"
echo "root/.ssh/authorized_keys"
echo "etc/unoq-rescue.conf"
SH
}

ENTRY() { echo "$UNOQ_ESP_DIR/loader/entries/$MID-rescue.conf"; }
RESCUE() { echo "$UNOQ_ESP_DIR/$MID/rescue"; }
CONF() { echo "$UNOQ_ROOT/etc/unoq-rescue/initramfs"; }
field() { sed -n "s/^$1  *//p" "$(ENTRY)"; }

@test "a fresh run builds the rescue initrd from a configuration of its own, and adds the entry" {
  run "$STEP"
  [ "$status" -eq 0 ]
  ran "mkinitramfs -d $(CONF) -o $(RESCUE)/initrd.img.new $KVER"
  [ -s "$(RESCUE)/initrd.img" ]
  [ ! -e "$(RESCUE)/initrd.img.new" ]
  cmp "$UNOQ_ROOT/boot/vmlinuz-$KVER" "$(RESCUE)/linux"
  [ -f "$(ENTRY)" ]
  [ -x "$(CONF)/hooks/unoq-rescue" ]
  [ -x "$(CONF)/scripts/init-premount/unoq-rescue" ]
  grep -qx "ADDR=169.254.77.1/16" "$(CONF)/unoq-rescue.conf"
  grep -qx "BUSYBOX=y" "$(CONF)/initramfs.conf"
}

@test "the host key is made for this board, and the keys that log in as you are the keys that log in to it" {
  run "$STEP"
  [ "$status" -eq 0 ]
  ran "dropbearkey -t ed25519 -f $UNOQ_ROOT/etc/unoq-rescue/dropbear/dropbear_ed25519_host_key"
  cmp "$UNOQ_HOME_DIR/.ssh/authorized_keys" "$UNOQ_ROOT/etc/unoq-rescue/dropbear/authorized_keys"
  [ "$(stat -c %a "$UNOQ_ROOT/etc/unoq-rescue/dropbear/authorized_keys")" = 600 ]
  [[ "$output" == *"SHA256:testprint"* ]]
}

@test "dropbear comes as the programs only, not as dropbear-initramfs" {
  # dropbear-initramfs puts its scripts into every initrd and rebuilds the
  # board's own initrd as it installs.
  run "$STEP"
  [ "$status" -eq 0 ]
  ran_like "^apt-get install .*dropbear-bin"
  refute ran_like "dropbear-initramfs"
}

@test "the entry: the rescue kernel and initrd, no root, and unoq.rescue=1" {
  run "$STEP"
  [ "$status" -eq 0 ]
  [ "$(field linux)" = "/$MID/rescue/linux" ]
  [ "$(field initrd)" = "/$MID/rescue/initrd.img" ]
  [ "$(field machine-id)" = "$MID" ]
  [ "$(field version)" = "$KVER" ]
  [ "$(field sort-key)" = "zz-unoq-rescue" ]
  [[ "$(field title)" == "Rescue: SSH over USB at 169.254.77.1"* ]]
  opts="$(field options)"
  [[ " $opts " == *" unoq.rescue=1 "* ]]
  # What the hardware needs stays; the root filesystem and systemd go.
  [[ " $opts " == *" clk_ignore_unused pd_ignore_unused "* ]]
  [[ " $opts " == *" deferred_probe_timeout=30 "* ]]
  refute grep -qE "(^| )(root=|initrd=|systemd\.)" <<<"$opts"
}

@test "the entry sorts below a kernel entry: its sort-key comes after debian, byte by byte" {
  # systemd-boot 257 orders good entries by sort-key with strcmp16 before
  # anything else (boot_entry_compare, src/boot/boot.c).
  run "$STEP"
  [ "$(printf '%s\n%s\n' "$(field sort-key)" debian | LC_ALL=C sort | head -1)" = debian ]
}

@test "loader.conf, the default and every other entry are left exactly as they were" {
  before="$(cd "$UNOQ_ESP_DIR" && find . -type f -not -path "./$MID/rescue/*" | sort | xargs sha256sum)"
  run "$STEP"
  [ "$status" -eq 0 ]
  after="$(cd "$UNOQ_ESP_DIR" && find . -type f -not -path "./$MID/rescue/*" \
    -not -path "./loader/entries/$MID-rescue.conf" | sort | xargs sha256sum)"
  [ "$before" = "$after" ]
  [ "$(find "$UNOQ_ESP_DIR/loader" -type f | sort)" = "$(printf '%s\n' "$(ENTRY)" "$STOCK_ENTRY" "$UNOQ_ESP_DIR/loader/loader.conf" | sort)" ]
  refute ran_like '^bootctl (set-default|set-oneshot|install|update|unlink)'
}

@test "the ordinary initrd is untouched: nothing is written to /etc/initramfs-tools" {
  run "$STEP"
  [ "$status" -eq 0 ]
  [ ! -e "$UNOQ_ROOT/etc/initramfs-tools" ]
  refute ran_like '^update-initramfs'
  # The one mkinitramfs is the rescue's, into the rescue directory.
  [ "$(grep -c '^mkinitramfs' "$STUB_LOG")" = 1 ]
  ran_like "^mkinitramfs -d $(CONF) "
}

@test "a second run changes nothing and builds nothing" {
  run "$STEP"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 changed,"* ]]
  [ "$(grep -c '^mkinitramfs' "$STUB_LOG")" = 1 ]
  [ "$(grep -c '^dropbearkey -t' "$STUB_LOG")" = 1 ]
}

@test "a new authorized key is a new initrd" {
  run "$STEP"
  echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAISecond other@desk" >>"$UNOQ_HOME_DIR/.ssh/authorized_keys"
  run "$STEP"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^mkinitramfs' "$STUB_LOG")" = 2 ]
}

@test "with no authorized key it refuses, says how to add one, and writes nothing" {
  for keys in absent comments-only; do
    rm -rf "$UNOQ_ROOT/etc/unoq-rescue"
    case "$keys" in
      absent) rm -f "$UNOQ_HOME_DIR/.ssh/authorized_keys" ;;
      comments-only) echo "# ssh-ed25519 AAAA old@key" >"$UNOQ_HOME_DIR/.ssh/authorized_keys" ;;
    esac
    run "$STEP"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ssh-copy-id"* ]]
    [ ! -e "$(ENTRY)" ]
    [ ! -e "$(RESCUE)" ]
    [ ! -e "$UNOQ_ROOT/etc/unoq-rescue" ]
    never_ran mkinitramfs
    never_ran apt-get
  done
}

@test "an entry that would sort below the rescue entry is refused, before anything is written" {
  for key in "" "zzz-other"; do
    rm -f "$UNOQ_ESP_DIR/loader/entries/other.conf"
    { echo "title other"; [ -n "$key" ] && echo "sort-key   $key"; echo "linux /x"; } \
      >"$UNOQ_ESP_DIR/loader/entries/other.conf"
    run "$STEP"
    [ "$status" -ne 0 ]
    [[ "$output" == *"other.conf"* ]]
    [ ! -e "$(ENTRY)" ]
    [ ! -e "$(RESCUE)" ]
  done
}

@test "an initrd the hook did nothing to is not installed" {
  # It would be an ordinary initrd, waiting for a root= the entry never gives.
  : >"$FLAGS/hollow"
  run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unoq-rescue"* ]]
  [ ! -e "$(RESCUE)/initrd.img" ]
  [ ! -e "$(RESCUE)/initrd.img.new" ]
  [ ! -e "$(ENTRY)" ]
}

@test "a failed mkinitramfs installs no entry" {
  : >"$FLAGS/mkinitramfs-fails"
  run "$STEP"
  [ "$status" -ne 0 ]
  [ ! -e "$(ENTRY)" ]
}

@test "a kernel without the gadget modules is refused" {
  sed -i '/usb_f_ncm/d' "$UNOQ_ROOT/lib/modules/$KVER/modules.dep"
  run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usb_f_ncm"* ]]
  [ ! -e "$(ENTRY)" ]
}

@test "an address that is not an address with a prefix is refused" {
  for bad in 169.254.77.1 169.254.77.1/0 169.254.77.1/33 999.1.1.1/16 "1.2.3.4/16;x" ""; do
    UNOQ_RESCUE_ADDR="$bad" run "$STEP"
    if [ -z "$bad" ]; then continue; fi # empty means the default
    [ "$status" -ne 0 ]
    [ ! -e "$(ENTRY)" ]
  done
  UNOQ_RESCUE_ADDR=10.77.0.1/24 run "$STEP"
  [ "$status" -eq 0 ]
  grep -qx "ADDR=10.77.0.1/24" "$(CONF)/unoq-rescue.conf"
}

@test "run from the rescue system itself, it refuses" {
  echo "clk_ignore_unused unoq.rescue=1" >"$UNOQ_ROOT/proc/cmdline"
  run "$STEP"
  [ "$status" -ne 0 ]
  [ ! -e "$(ENTRY)" ]
}

@test "a board without systemd-boot is left alone" {
  : >"$FLAGS/no-systemd-boot"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"systemd-boot is not installed here"* ]]
  [ ! -e "$UNOQ_ROOT/etc/unoq-rescue" ]
  [ ! -e "$(RESCUE)" ]
}

@test "the header says how to undo it, naming the entry and every directory" {
  grep -q "^# REVERT: rm /boot/efi/loader/entries/<machine-id>-rescue.conf" "$STEP"
  grep -q "^#  *rm -r /boot/efi/<machine-id>/rescue /etc/unoq-rescue" "$STEP"
}

# --- the hook ----------------------------------------------------------------

@test "the hook does nothing in any initrd but the rescue's" {
  mkdir -p "$BATS_TEST_TMPDIR/stock-conf" "$BATS_TEST_TMPDIR/dest"
  CONFDIR="$BATS_TEST_TMPDIR/stock-conf" DESTDIR="$BATS_TEST_TMPDIR/dest" run sh "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/dest")" ]
}

# --- the premount script -------------------------------------------------------
#
# It runs in every boot of the rescue initrd, and would do nothing in any
# other: without unoq.rescue=1 on the command line it returns before it has
# loaded a module or made a directory.

premount_stubs() {
  for c in modprobe mount dropbear ip; do stub "$c"; done
  stub_body pidof <<'SH'
[ -e "$FLAGS/session" ] && { echo "101 202"; exit 0; }
echo 101
SH
  # Stops the hold loop: the real reboot does not return either.
  stub_body reboot <<'SH'
kill -TERM "$PPID"
SH
  stub_body sleep <<'SH'
n=$(($(cat "$FLAGS/sleeps" 2>/dev/null || echo 0) + 1))
echo "$n" >"$FLAGS/sleeps"
[ "$n" -ge 6 ] && kill -TERM "$PPID"
exit 0
SH
  P="$BATS_TEST_TMPDIR/initramfs"
  mkdir -p "$P/proc" "$P/etc" "$P/run" "$P/dev" "$P/sys/kernel/config/usb_gadget" "$P/sys/class/udc/4e00000.usb" "$P/sys/class/net"
  echo "ADDR=169.254.77.1/16" >"$P/etc/unoq-rescue.conf"
}

@test "the premount script is inert without unoq.rescue=1" {
  premount_stubs
  for cmdline in "$STOCK_OPTS" "$STOCK_OPTS unoq.rescue=0" "$STOCK_OPTS unoq.rescue=10" \
    "$STOCK_OPTS xunoq.rescue=1" "$STOCK_OPTS unoq.rescue_timeout=5" ""; do
    echo "$cmdline" >"$P/proc/cmdline"
    UNOQ_ROOT="$P" run sh "$PREMOUNT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$STUB_LOG" ]
    [ ! -e "$P/sys/kernel/config/usb_gadget/unoq-rescue" ]
  done
}

@test "with unoq.rescue=1 it builds an NCM-only gadget, binds it and starts dropbear" {
  premount_stubs
  echo "$STOCK_OPTS unoq.rescue=1" >"$P/proc/cmdline"
  UNOQ_ROOT="$P" run sh "$PREMOUNT"
  G="$P/sys/kernel/config/usb_gadget/unoq-rescue"
  [ "$(ls "$G/functions")" = "ncm.usb0" ]
  [ -L "$G/configs/c.1/ncm.usb0" ]
  [ "$(cat "$G/UDC")" = "4e00000.usb" ]
  ran "modprobe usb_f_ncm"
  ran_like "^dropbear .*-s .*-r $P/etc/dropbear/dropbear_ed25519_host_key"
  # It holds; with no timeout it never reboots.
  never_ran reboot
}

@test "with a timeout and nobody logged in it reboots; with someone logged in it stays" {
  premount_stubs
  echo "$STOCK_OPTS unoq.rescue=1 unoq.rescue_timeout=4" >"$P/proc/cmdline"
  UNOQ_ROOT="$P" run sh "$PREMOUNT"
  ran "reboot -f"
  : >"$STUB_LOG"
  rm -f "$FLAGS/sleeps"
  : >"$FLAGS/session"
  UNOQ_ROOT="$P" run sh "$PREMOUNT"
  never_ran reboot
  [[ "$output" == *"someone is logged in"* ]]
}
