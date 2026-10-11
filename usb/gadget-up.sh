#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Build and bind the composite USB gadget: network + the fileshare drive.
#
#   sudo ~/two-computers-one-board/usb/gadget-up.sh          # build, and bind if a UDC exists
#   sudo ~/two-computers-one-board/usb/gadget-up.sh --build  # build only, never bind
#
# Idempotent: an existing gadget is left alone and re-bound if it came unbound.
#
# WHEN THIS RUNS
# --------------
# Not at a fixed point in boot. This board's dwc3 is `dr_mode = "otg"` and has
# no writable role switch - the Type-C controller decides host vs device from
# the CC lines when you plug a cable in. So a USB Device Controller only exists
# while the board is plugged into a computer, and this script is driven by a
# udev rule that fires when one appears. See usb/99-unoq-usb-gadget.rules.
#
# WHAT THE HOST SEES
# ------------------
#   config 1   network + UNO-Q drive   <- the only configuration there is
#
# ONE configuration, not two. An earlier version of this script put NCM in c.1
# and RNDIS in c.2 and let each host pick the one it supported. That cost us
# the drive on Windows completely, and took a long time to see, because the
# half that broke was not the half that was clever.
#
# Windows only treats a device as composite - and so only loads usbccgp.sys,
# which is the thing that gives each function its own driver - when all three
# of these hold:
#
#   - bDeviceClass is 0, or class/subclass/protocol are 0xEF/0x02/0x01
#   - the device has multiple interfaces
#   - the device has a SINGLE configuration
#
# Two configurations failed the third. No USB\COMPOSITE compatible id was
# generated, no generic parent driver loaded, and one driver bound to the whole
# device: networking worked, and the mass storage interface was never
# enumerated at all. Not hidden, not unmountable - absent. Windows offers one
# way out, an INF naming the configuration for usbccgp in the registry, which
# means shipping a signed driver package for a device whose ids belong to the
# Linux Foundation.
#
# So the network function is chosen here at BUILD time rather than by the host
# at enumeration time - UNOQ_GADGET_PRIMARY decides what goes in the single
# config. That trades host autodetection for a drive that actually appears.
#
# BUILD time means exactly that: this script leaves an existing gadget alone, so
# setting UNOQ_GADGET_PRIMARY and re-running it does NOTHING on a board that
# already has one. Switching function means purging first:
#
#   sudo usb/gadget-down.sh --purge
#   sudo UNOQ_GADGET_PRIMARY=rndis usb/gadget-up.sh
#
# It says so at runtime too, rather than leaving that to be discovered - see the
# warning where the existing-gadget case is handled below.
set -uo pipefail

# Overridable for the tests only, like the other scripts that read this path:
# nothing on a running board sets it.
G="${UNOQ_GADGET_DIR:-/sys/kernel/config/usb_gadget/unoq}"
CONFIGFS="$(dirname "$G")"
# The image is in the home directory of whoever this board belongs to, which is
# where provision/95-usb-gadget.sh and share/build-image.sh put it. It used to
# be spelled /home/arduino here and worked out there, so under any other
# account provisioning reported the image present and the drive came up empty.
#
# WHOSE HOME, AND HOW THIS SCRIPT KNOWS
# -------------------------------------
# It used to ask who owned this file. That stopped being an answer when the
# units began running root's own copy of it from /usr/local/lib/unoq: the owner
# of that copy is root, the image is not in /root, and the result would have
# been the same empty drive for a different reason.
#
# So provisioning writes the answer down. install_runtime (provision/lib.sh)
# puts an `env` file at the top of the directory it copies these scripts into,
# and that is read here - as data, one line of it, not sourced. Run from a
# checkout there is no such file beside usb/, and the owner of the checkout is
# still the right person to ask.
RUNTIME_ENV="$(dirname "$0")/../env"
OWNER_HOME=""
if [ -r "$RUNTIME_ENV" ]; then
  OWNER_HOME="$(sed -n 's/^UNOQ_OWNER_HOME=//p' "$RUNTIME_ENV" | tail -1)"
fi
if [ -z "$OWNER_HOME" ]; then
  OWNER_HOME="$(getent passwd "$(stat -c %U "$0")" 2>/dev/null | cut -d: -f6)"
fi
IMG="${UNOQ_SHARE_IMG:-${OWNER_HOME:-/home/arduino}/unoq-share.img}"
BUILD_ONLY=0
[ "${1:-}" = "--build" ] && BUILD_ONLY=1

log() { echo "unoq-gadget: $*"; }
die() {
  echo "unoq-gadget: $*" >&2
  exit 1
}

[ "$(id -u)" = 0 ] || die "must run as root"

# --- prerequisites ---------------------------------------------------------

modprobe libcomposite 2>/dev/null
[ -d "$CONFIGFS" ] || die "no $CONFIGFS - is CONFIG_USB_CONFIGFS enabled?"

# --- build -----------------------------------------------------------------

if [ -d "$G" ]; then
  log "gadget already defined at $G"
  # Say so when UNOQ_GADGET_PRIMARY asks for something the built gadget is not.
  #
  # Being idempotent means an existing definition is left alone, which is right
  # - but it also means setting the variable and re-running this script looks
  # like it should switch NCM<->RNDIS and does absolutely nothing. Silently
  # ignoring the one setting somebody reaches for while troubleshooting a host
  # that will not bind is the worst possible time to be quiet about it.
  want_fn="ncm.usb0"
  [ "${UNOQ_GADGET_PRIMARY:-ncm}" = rndis ] && want_fn="rndis.usb0"
  if [ ! -d "$G/functions/$want_fn" ]; then
    log "WARNING: this gadget has no $want_fn, and an existing definition is"
    log "  never rebuilt. To actually switch, purge it first:"
    log "    sudo $(dirname "$0")/gadget-down.sh --purge"
    log "    sudo UNOQ_GADGET_PRIMARY=${UNOQ_GADGET_PRIMARY:-ncm} $0"
  fi
else
  mkdir -p "$G" || die "could not create $G"

  # 0x1d6b/0x0104 is the Linux Foundation "Multifunction Composite Gadget"
  # id, which is what a configfs gadget is supposed to use. Borrowing
  # Arduino's VID for a device Arduino did not build would be wrong, and
  # would collide with their own udev rules.
  echo 0x1d6b >"$G/idVendor"
  echo 0x0104 >"$G/idProduct"
  echo 0x0200 >"$G/bcdUSB" # USB 2.0
  echo 0x0100 >"$G/bcdDevice"

  # 0xEF/0x02/0x01 is "Miscellaneous / Common Class / Interface Association
  # Descriptor": the device saying its interfaces are grouped into functions by
  # IADs rather than being one function. A network function is two interfaces
  # by itself, so without this a host is entitled to read interface 0 as the
  # whole device - which is exactly what Windows did, reporting this board as
  # USB\Class_02&SubClass_02&Prot_FF, the RNDIS control interface. A plain 0x00
  # also satisfies Windows' first composite condition, but this one says what
  # is actually true.
  echo 0xEF >"$G/bDeviceClass"
  echo 0x02 >"$G/bDeviceSubClass"
  echo 0x01 >"$G/bDeviceProtocol"

  mkdir -p "$G/strings/0x409"
  echo "Arduino" >"$G/strings/0x409/manufacturer"
  echo "UNO Q hybrid dev board" >"$G/strings/0x409/product"
  # A stable serial matters more than it looks: Windows keys its per-adapter
  # network profile off it, so a serial that changes every boot leaves the
  # user with "Ethernet 2, 3, 4..." and a fresh unconfigured adapter each time.
  SERIAL="$(cat /sys/devices/soc0/serial_number 2>/dev/null ||
    sed 's/-//g' /etc/machine-id 2>/dev/null | cut -c1-16)"
  echo "${SERIAL:-0000000000000000}" >"$G/strings/0x409/serialnumber"

  # MACs derived from machine-id, for the same reason: a random MAC per boot
  # makes every host treat the board as a brand-new network.
  MAC_BASE="$(sed 's/-//g' /etc/machine-id 2>/dev/null | cut -c1-10)"
  MAC_BASE="${MAC_BASE:-0123456789}"
  fmt_mac() { # <local-bit-prefix> - build a locally-administered unicast MAC
    printf '%s:%s:%s:%s:%s:%s' "$1" \
      "${MAC_BASE:0:2}" "${MAC_BASE:2:2}" "${MAC_BASE:4:2}" \
      "${MAC_BASE:6:2}" "${MAC_BASE:8:2}"
  }
  DEV_MAC="$(fmt_mac 42)"  # the board's end
  HOST_MAC="$(fmt_mac 46)" # the host's end

  # --- which network function ---
  #
  # NCM is the default and RNDIS is not, which is the opposite of most gadget
  # recipes. Those recipes predate Windows 10 version 1903, which ships a
  # native NCM class driver (UsbNcm.sys) needing no driver and no INF. macOS
  # has had NCM since Catalina and Linux has always had it, so NCM is the right
  # default for every host that is not genuinely old. RNDIS is deprecated at
  # Microsoft's end and is the one to be leaving behind.
  #
  # Only the chosen function gets created. An unused function sitting in
  # configfs would bind to nothing and cost nothing, but building exactly what
  # we bind keeps the gadget the host sees the same as the gadget described
  # here - and this file has already been bitten once by a leftover that was
  # supposed to be inert.
  #
  # Set UNOQ_GADGET_PRIMARY=rndis for a host with no NCM driver: a Windows
  # older than 1903, or a newer one where NCM will not attach.
  PRIMARY="${UNOQ_GADGET_PRIMARY:-ncm}"
  case "$PRIMARY" in
    ncm) NET_FN=ncm.usb0 CFG_NAME="NCM + fileshare" ;;
    rndis) NET_FN=rndis.usb0 CFG_NAME="RNDIS + fileshare" ;;
    *) die "UNOQ_GADGET_PRIMARY must be ncm or rndis, not '$PRIMARY'" ;;
  esac

  # --- functions ---
  mkdir -p "$G/functions/$NET_FN"
  echo "$DEV_MAC" >"$G/functions/$NET_FN/dev_addr" 2>/dev/null
  echo "$HOST_MAC" >"$G/functions/$NET_FN/host_addr" 2>/dev/null

  mkdir -p "$G/functions/mass_storage.0"
  if [ -f "$IMG" ]; then
    # ro=1: the host and the board would otherwise both be writing the same
    # blocks with neither page cache aware of the other, which destroys a FAT
    # filesystem quickly. removable=1 so the host offers "eject" rather than
    # treating it as a fixed disk it should chkdsk.
    echo 1 >"$G/functions/mass_storage.0/lun.0/removable"
    echo 1 >"$G/functions/mass_storage.0/lun.0/ro"
    echo 0 >"$G/functions/mass_storage.0/lun.0/cdrom"
    echo "$IMG" >"$G/functions/mass_storage.0/lun.0/file" ||
      log "WARNING: could not attach $IMG - the drive will show as empty"
    # The inquiry string is two fixed-width fields run together: 8 characters
    # of vendor, then 16 of product. Written as plain "UNO-Q Share" it was cut
    # at the eighth character, and Windows showed the drive as "UNO-Q Sh are".
    printf '%-8s%-16s\n' "UNO-Q" "Share" \
      >"$G/functions/mass_storage.0/lun.0/inquiry_string" 2>/dev/null
  else
    log "WARNING: $IMG missing - build it with share/build-image.sh"
  fi

  # --- configuration ---
  #
  # Exactly one. WHAT THE HOST SEES at the top of this file explains why a
  # second one is not a free fallback but the loss of the drive.
  mkdir -p "$G/configs/c.1/strings/0x409"
  echo "$CFG_NAME" >"$G/configs/c.1/strings/0x409/configuration"
  echo 250 >"$G/configs/c.1/MaxPower" # mA, i.e. 500mA
  ln -sf "$G/functions/$NET_FN" "$G/configs/c.1/"
  ln -sf "$G/functions/mass_storage.0" "$G/configs/c.1/"

  # --- Microsoft OS descriptors ---
  #
  # These exist for one reason: Windows will not bind RNDIS without them. So
  # they are published only when RNDIS is what we actually built.
  #
  # Publishing them for an NCM gadget is not merely pointless, it is harmful,
  # and it was the other half of the bug above. The old code linked them to
  # whichever config held rndis and called that harmless "because Windows
  # simply never asks". Windows always asks: it follows b_vendor_code during
  # enumeration, and the compatible id it got back - USB\MS_COMP_RNDIS - came
  # back at the TOP of this board's compatible id list, ahead of everything
  # derived from the descriptors. That is what steered Windows onto the RNDIS
  # configuration, the one we had filed as the fallback nobody would choose.
  if [ "$PRIMARY" = rndis ]; then
    echo "RNDIS" >"$G/functions/rndis.usb0/os_desc/interface.rndis/compatible_id"
    echo "5162001" >"$G/functions/rndis.usb0/os_desc/interface.rndis/sub_compatible_id"
    echo 1 >"$G/os_desc/use"
    echo 0xcd >"$G/os_desc/b_vendor_code"
    echo MSFT100 >"$G/os_desc/qw_sign"
    ln -sf "$G/configs/c.1" "$G/os_desc/" 2>/dev/null
  fi

  log "gadget built (c.1 = $NET_FN + mass_storage)"
fi

[ "$BUILD_ONLY" = 1 ] && {
  log "built only, not binding (--build)"
  exit 0
}

# --- bind ------------------------------------------------------------------

# Glob rather than `ls`: there is normally exactly one UDC, and the first is
# the one dwc3 registered.
UDC_NAME=""
for udc in /sys/class/udc/*; do
  [ -e "$udc" ] || break
  UDC_NAME="$(basename "$udc")"
  break
done
if [ -z "$UDC_NAME" ]; then
  # Not an error. On this board a UDC only exists while a host is plugged into
  # the USB-C port; the udev rule will call us again when one appears.
  log "no UDC present - the board is not plugged into a computer. Nothing bound."
  exit 0
fi

CURRENT="$(tr -d ' \n' <"$G/UDC" 2>/dev/null)"
if [ "$CURRENT" = "$UDC_NAME" ]; then
  log "already bound to $UDC_NAME"
else
  echo "$UDC_NAME" >"$G/UDC" || die "could not bind to $UDC_NAME"
  log "bound to $UDC_NAME"
fi
