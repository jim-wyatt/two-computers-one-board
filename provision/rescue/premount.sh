#!/bin/sh
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# The rescue system: SSH over the USB cable, from the initramfs, with no root
# filesystem mounted. Phase 2 of issue #93, issue #168.
#
# Installed by provision/84-rescue-entry.sh as
#   /etc/unoq-rescue/initramfs/scripts/init-premount/unoq-rescue
# and so built into the rescue initrd only. It is not in /etc/initramfs-tools,
# and no ordinary initrd ever contains it.
#
# INERT UNLESS ASKED FOR
# ----------------------
# It does nothing at all unless the kernel command line has unoq.rescue=1,
# which only the rescue entry's `options` line carries. That is a second
# guard, behind the first one of being in a rescue-only initrd: copied into an
# ordinary initrd by mistake, it would still return at once and the boot would
# go on to mount root as if it were not there. tests/rescue-entry.bats runs it
# under a fake /proc/cmdline to show that.
#
# WHAT IT DOES WHEN ASKED
# -----------------------
#   1. Loads libcomposite and the NCM function, and mounts configfs.
#   2. Builds a gadget with ONE function, NCM, the network the running system's
#      usb/gadget-up.sh puts first. No drive: its image lives on the root
#      filesystem this system never mounts. Same ids, serial and MACs as the
#      running gadget, so the computer at the other end finds the adapter it
#      already knows.
#   3. Waits for a USB Device Controller and binds to it, the way the running
#      system does (usb/99-unoq-usb-gadget.rules, usb/handover.sh): on this
#      board the Type-C controller, anx7625, picks host or device from the CC
#      lines, and dwc3 registers a UDC only once it has been told "device". So
#      nothing is forced while that may still happen. If no UDC has appeared
#      after a while and the kernel offers a writable role switch, "device" is
#      written to it, once, as a last resort. Whether that is ever needed in an
#      initramfs is one of the unknowns this was built with.
#   4. Puts UNOQ_RESCUE_ADDR (169.254.77.1/16 unless provisioning set another)
#      on the gadget's network interface. Link-local and fixed: no DHCP on
#      either side, and nothing to remember but the one address.
#   5. Starts dropbear with the board's rescue host key, root's authorized
#      keys and no passwords.
#   6. Holds there for good, never mounting root, re-binding when the cable
#      comes back and restarting dropbear if it dies.
#
# unoq.rescue_timeout=<seconds> on the command line makes it give up: if
# nobody has logged in by then, it reboots. The counted test entry in
# docs/reference/troubleshooting.md uses it, so that a rescue system that
# boots but never shows up on the cable hands the board back without anyone
# pulling the power. The installed rescue entry does not: reached by
# fallback, there is no good kernel left to reboot into.
#
# POSIX sh, for BusyBox: it runs in the initramfs, not under bash.
#
# REVERT: removing the rescue entry removes this with it; see
#         provision/84-rescue-entry.sh.

PREREQ=""
prereqs() { echo "$PREREQ"; }
case "${1:-}" in
  prereqs)
    prereqs
    exit 0
    ;;
esac

# For the tests only, as everywhere in this project: nothing in an initramfs
# sets it.
R="${UNOQ_ROOT:-}"

rescue=0
timeout=0
# Word by word, not grep: "unoq.rescue=1" must be a whole argument, so that
# unoq.rescue=10 or xunoq.rescue=1 do not count. The command line is one
# line of words, and words are what is wanted.
# shellcheck disable=SC2013
for arg in $(cat "$R/proc/cmdline" 2>/dev/null); do
  case "$arg" in
    unoq.rescue=1) rescue=1 ;;
    unoq.rescue_timeout=*) timeout="${arg#unoq.rescue_timeout=}" ;;
  esac
done
[ "$rescue" = 1 ] || exit 0

case "$timeout" in '' | *[!0-9]*) timeout=0 ;; esac

log() {
  echo "unoq-rescue: $*"
  # Into the kernel's ring buffer too, so `dmesg` over SSH tells the story of
  # the boot. Nothing else here keeps a log.
  echo "unoq-rescue: $*" >"$R/dev/kmsg" 2>/dev/null || true
}

# Written by the hook when the image was built: the address, and the ids the
# running gadget derives from /etc/machine-id, which is on the root
# filesystem this never mounts. Read as data, one key at a time, not sourced.
CONF="$R/etc/unoq-rescue.conf"
conf() { sed -n "s/^$1=//p" "$CONF" 2>/dev/null | tail -1; }
ADDR="$(conf ADDR)"
ADDR="${ADDR:-169.254.77.1/16}"
DEV_MAC="$(conf DEV_MAC)"
HOST_MAC="$(conf HOST_MAC)"
SERIAL="$(cat "$R/sys/devices/soc0/serial_number" 2>/dev/null)"
SERIAL="${SERIAL:-$(conf SERIAL)}"

CONFIGFS="$R/sys/kernel/config"
G="$CONFIGFS/usb_gadget/unoq-rescue"
UDC_DIR="$R/sys/class/udc"
NET_DIR="$R/sys/class/net"
PIDFILE="$R/run/unoq-rescue-dropbear.pid"
HOSTKEY="$R/etc/dropbear/dropbear_ed25519_host_key"

log "rescue system: no root filesystem will be mounted"
log "  SSH over the USB cable at ${ADDR%/*}"

# --- 1. the gadget framework -------------------------------------------------

modprobe libcomposite 2>/dev/null || log "WARNING: could not load libcomposite"
modprobe usb_f_ncm 2>/dev/null || log "WARNING: could not load usb_f_ncm"
if [ ! -d "$CONFIGFS/usb_gadget" ]; then
  mount -t configfs configfs "$CONFIGFS" 2>/dev/null ||
    log "WARNING: could not mount configfs at $CONFIGFS"
fi

# --- 2. the gadget: NCM, alone -------------------------------------------------

# The same ids and strings as usb/gadget-up.sh, for its reasons, which are
# written down there. bcdDevice differs, 0x0200 against 0x0100: Windows keeps
# what it learned about a device per vendor, product and bcdDevice, and this
# one has a different set of interfaces from the gadget it would otherwise
# take it for.
if [ ! -d "$G" ]; then
  mkdir -p "$G"
  echo 0x1d6b >"$G/idVendor"
  echo 0x0104 >"$G/idProduct"
  echo 0x0200 >"$G/bcdUSB"
  echo 0x0200 >"$G/bcdDevice"
  echo 0xEF >"$G/bDeviceClass"
  echo 0x02 >"$G/bDeviceSubClass"
  echo 0x01 >"$G/bDeviceProtocol"
  mkdir -p "$G/strings/0x409"
  echo "Arduino" >"$G/strings/0x409/manufacturer"
  echo "UNO Q rescue" >"$G/strings/0x409/product"
  echo "${SERIAL:-0000000000000000}" >"$G/strings/0x409/serialnumber"
  mkdir -p "$G/functions/ncm.usb0"
  [ -n "$DEV_MAC" ] && echo "$DEV_MAC" >"$G/functions/ncm.usb0/dev_addr" 2>/dev/null
  [ -n "$HOST_MAC" ] && echo "$HOST_MAC" >"$G/functions/ncm.usb0/host_addr" 2>/dev/null
  mkdir -p "$G/configs/c.1/strings/0x409"
  echo "NCM rescue" >"$G/configs/c.1/strings/0x409/configuration"
  echo 500 >"$G/configs/c.1/MaxPower"
  ln -sf "$G/functions/ncm.usb0" "$G/configs/c.1/"
  log "gadget built (c.1 = ncm.usb0)"
fi

# --- 3 to 6: bind, address, dropbear, and hold ---------------------------------

dropbear_running() {
  pid="$(cat "$PIDFILE" 2>/dev/null)"
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  [ "$(cat "$R/proc/$pid/comm" 2>/dev/null)" = dropbear ]
}

start_dropbear() {
  # -s and -g: keys only, for everyone including root. -j -k: no forwarding;
  # this is a shell for repairs, not a tunnel. -E: its messages go to the
  # console, the only place they can go.
  if dropbear -E -s -g -j -k -p 22 -r "$HOSTKEY" -P "$PIDFILE"; then
    log "dropbear started"
  else
    log "WARNING: dropbear did not start"
  fi
}

# A session is a second dropbear process: the listener forks one per login.
logged_in() {
  # shellcheck disable=SC2046 # one pid per word is the point
  set -- $(pidof dropbear 2>/dev/null)
  [ "$#" -gt 1 ]
}

address_up() {
  ifname="$(cat "$G/functions/ncm.usb0/ifname" 2>/dev/null)"
  [ -n "$ifname" ] && [ -e "$NET_DIR/$ifname" ] || return 0
  if ! ip -o addr show dev "$ifname" 2>/dev/null | grep -q " ${ADDR%/*}/"; then
    ip addr add "$ADDR" dev "$ifname" 2>/dev/null &&
      log "$ifname has ${ADDR%/*}"
  fi
  ip link set "$ifname" up 2>/dev/null
}

waited=0
role_tried=0
start_dropbear
while :; do
  udc=""
  for u in "$UDC_DIR"/*; do
    [ -e "$u" ] || break
    udc="${u##*/}"
    break
  done
  if [ -n "$udc" ]; then
    current="$(cat "$G/UDC" 2>/dev/null)"
    if [ "$current" != "$udc" ]; then
      if echo "$udc" >"$G/UDC" 2>/dev/null; then
        log "bound to $udc"
      else
        log "WARNING: could not bind to $udc"
      fi
    fi
    address_up
  elif [ "$role_tried" = 0 ] && [ "$waited" -ge 30 ]; then
    # Thirty seconds is the kernel's own deferred_probe_timeout on this
    # board: by then anx7625 has had its chance to say "device".
    role_tried=1
    for role in "$R"/sys/class/usb_role/*/role; do
      [ -w "$role" ] || continue
      if echo device >"$role" 2>/dev/null; then
        log "no USB controller after ${waited}s: set ${role%/role} to device"
      fi
    done
  fi

  dropbear_running || start_dropbear

  if [ "$timeout" -gt 0 ] && [ "$waited" -ge "$timeout" ]; then
    if logged_in; then
      log "someone is logged in: staying, past unoq.rescue_timeout"
      timeout=0
    else
      log "nobody logged in within ${timeout}s (unoq.rescue_timeout): rebooting"
      reboot -f
    fi
  fi

  sleep 2
  waited=$((waited + 2))
done
