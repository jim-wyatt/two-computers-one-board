#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# IP over USB, plus the fileshare drive, when the board is plugged into a PC.
#
#   sudo bash ~/two-computers-one-board/provision/60-usb-gadget.sh
#
# Idempotent, and safe to run over SSH: it does NOT change the USB role. On
# this board it cannot - dwc3 is dr_mode="otg" with no writable role switch,
# and the Type-C controller picks host or device from the CC lines. Installing
# this only arranges for a gadget to be bound IF a USB Device Controller shows
# up, which happens when you plug the USB-C port into a computer.
#
# WHAT YOU GET, once plugged into a computer
# ------------------------------------------
#   the board      reachable as <hostname>.local, over mDNS
#   its address    leased by the computer, or link-local if nothing serves DHCP
#   a USB drive    "UNO-Q", read-only, with the VS Code installers on it
#   the web page   http://<hostname>.local:8080/
#
# The board is always the DHCP client on this link. Windows Internet Connection
# Sharing and macOS Internet Sharing both pin their own address and run their
# own DHCP server, and neither will take a lease from us - so a board that wants
# internet over the cable has to accept their numbering. The fixed thing you
# type is the NAME, not an address. See usb/usb-net-up.sh.
#
# WHAT YOU GIVE UP
# ----------------
# The USB-C port is the board's only USB data port. While it is a device, it
# is not a host: anything plugged into a hub or dock on it - network dongles,
# storage, keyboards - is gone until you unplug from the computer.
#
# REVERT: systemctl disable --now unoq-usb-gadget.service &&
#         rm /etc/systemd/system/unoq-usb-gadget.service \
#            /etc/udev/rules.d/99-unoq-usb-gadget.rules &&
#         systemctl daemon-reload && udevadm control --reload
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
need_root

IMG="${UNOQ_SHARE_IMG:-$TARGET_HOME/unoq-share.img}"

step "kernel support"
for mod in libcomposite usb_f_ncm usb_f_rndis usb_f_mass_storage bridge; do
  if modprobe "$mod" 2>/dev/null; then
    skip "$mod available"
  else
    warn "$mod could not be loaded - the gadget may not come up"
  fi
done
# Loaded on demand by the gadget, but listing them here means a board that
# lacks one says so now rather than at 2am with a cable in it.
if write_file 0644 /etc/modules-load.d/unoq-usb-gadget.conf <<'MODS'; then
libcomposite
bridge
MODS
  skip "modules will load at boot"
fi

step "addressing"
# avahi-autoipd is what the board falls back to when no DHCP server answers on
# the cable - RFC 3927 link-local, the same 169.254/16 every desktop OS
# self-assigns in the same situation, so both ends meet with no configuration at
# either. It replaces a static 10.55.0.1 that needed a route added by hand on
# the host before anything could reach it.
# REVERT: apt-get purge avahi-autoipd
apt_install avahi-autoipd
# The packaged per-interface hooks are not used: usb-dhcp.sh starts and stops
# the daemon on br-usb from the lease events, which is the only place that knows
# whether a real lease has superseded it.
if unit_exists avahi-autoipd.service; then
  disable_unit avahi-autoipd.service
else
  skip "no packaged avahi-autoipd service to disable"
fi

step "mDNS"
# The board's name is the whole addressing story now, so the daemon publishing
# it is a dependency rather than a nicety. Windows 10+, macOS and Linux all
# resolve <hostname>.local with nothing installed at their end.
apt_install avahi-daemon
enable_unit avahi-daemon.service

# dnsmasq is no longer installed for this: the board does not serve DHCP on the
# USB link any more. A board provisioned before that change still has the
# package, which is harmless - usb-net-up.sh kills any instance left running on
# br-usb, and the packaged service was disabled here when it was installed.

step "link configuration"
# Written once and then left alone, unlike everything else here. It is the one
# file on this board a person is expected to edit, and a provisioning run that
# reset it every time would undo the change on the next bootstrap - most likely
# while the board is running on the very link the settings control.
# REVERT: rm /etc/default/unoq-usb  (every setting in it has a working default)
if [ -f /etc/default/unoq-usb ]; then
  skip "/etc/default/unoq-usb exists"
  # UNOQ_USB_MODE is gone: the board is always the DHCP client on this link.
  # Left in place it does nothing, which is worse than saying so - the file
  # would go on describing a server mode that no longer exists.
  if grep -q '^UNOQ_USB_MODE=' /etc/default/unoq-usb 2>/dev/null; then
    warn "/etc/default/unoq-usb still sets UNOQ_USB_MODE, which no longer does"
    warn "  anything - the board is always the DHCP client now. Safe to delete"
    warn "  that line: sudo sed -i '/^UNOQ_USB_MODE=/d' /etc/default/unoq-usb"
  fi
else
  write_file 0644 /etc/default/unoq-usb <<'CONF'
# Settings for the USB link. Read by unoq-usb-gadget.service and
# unoq-usb-bind.service. Every one of them has a working default; this file
# exists so they can be found and changed in one place.
#
# The board is always the DHCP CLIENT on this link - it asks the computer for an
# address, and falls back to link-local (169.254.x.y) if nothing answers. Either
# way it is reachable as <hostname>.local. There is no mode to choose: Windows
# ICS and macOS Internet Sharing both pin their own address and run their own
# DHCP server, so the board accepting their numbering is the only arrangement
# that works on every host.
#
# After changing:  sudo systemctl restart unoq-usb-gadget

# Uncomment to stop the gadget ever touching the board's default route. It is
# installed at metric 700, which loses to wifi (600) and ethernet (100), and is
# promoted ahead of wifi only once the internet has answered through the cable.
#UNOQ_USB_DEFAULT_ROUTE=0

# If wifi has been turned off (usb/wifi.sh off) and the USB link has produced no
# route to the internet this many seconds after boot, turn the radio back on and
# leave it on. Set UNOQ_UPLINK_FALLBACK=0 to let the board sit there with no
# uplink instead.
#UNOQ_UPLINK_FALLBACK=1
#UNOQ_UPLINK_DEADLINE=240
CONF
fi

step "fileshare image"
if [ -f "$IMG" ]; then
  skip "$IMG present ($(du -h "$IMG" | cut -f1) on disk)"
else
  warn "$IMG missing - the drive will appear empty."
  warn "  build it:  sudo bash $PROJECT/share/fetch-vscode.sh"
  warn "             sudo bash $PROJECT/share/build-image.sh"
fi

step "adbd"
# adbd's ExecStartPost binds its OWN gadget to the first free UDC. With this
# installed there would be two gadgets racing for one controller, and which
# one wins is a coin toss. adb over USB and this are mutually exclusive; the
# network link is the more useful of the two, and adb still works over TCP.
# REVERT: systemctl enable --now adbd
if unit_exists adbd.service; then
  disable_unit adbd.service
  skip "adb over TCP still works:  adb connect $(hostname).local:5555"
else
  skip "adbd not present"
fi

step "udev rule"
if write_file 0644 /etc/udev/rules.d/99-unoq-usb-gadget.rules \
  <"$PROJECT/usb/99-unoq-usb-gadget.rules"; then
  udevadm control --reload-rules
  did "udev rules reloaded"
fi

step "systemd units"
install_unit "$PROJECT/usb/unoq-usb-gadget.service"
# The bind half is a separate unit on purpose - see the comment in it.
install_unit "$PROJECT/usb/unoq-usb-bind.service"
# And the confirm half, which is what makes the bind guard's counter mean
# "boots survived" rather than just "boots attempted". Without this enabled the
# guard would trip after three normal boots and refuse to bind ever again.
install_unit "$PROJECT/usb/unoq-usb-confirm.service"
# The other half of turning wifi off: the guard covers a bind that kills the
# board, this covers a bind that works and still leaves it with no way out.
install_unit "$PROJECT/usb/unoq-uplink-fallback.service"
# The status LEDs are NOT installed here any more. They report on the whole
# board, not just the USB link, and installing them from an optional feature
# meant a board provisioned without `--with-usb-gadget` had no way to say
# anything at all. See provision/35-status-leds.sh.
# enable, but do not --now start it blindly: starting is harmless (no UDC
# means it builds the definition and exits) and proves the scripts run.
if systemctl is-enabled --quiet unoq-usb-gadget.service 2>/dev/null; then
  skip "already enabled"
else
  systemctl enable unoq-usb-gadget.service >/dev/null 2>&1 ||
    fail "could not enable unoq-usb-gadget.service"
  did "enabled at boot"
fi
# Enabled separately and unconditionally: a board that already had the gadget
# enabled from before the guard existed still needs the confirm unit turning
# on, or its counter would climb every boot until the guard refused to bind.
if systemctl is-enabled --quiet unoq-usb-confirm.service 2>/dev/null; then
  skip "bind guard confirm already enabled"
else
  systemctl enable unoq-usb-confirm.service >/dev/null 2>&1 ||
    fail "could not enable unoq-usb-confirm.service"
  did "bind guard confirm enabled at boot"
fi
# Harmless on a board whose wifi is on - it looks, sees a radio already up, and
# exits - so it is enabled unconditionally rather than only when someone has
# turned wifi off. The moment it is needed is the moment nobody can enable it.
if systemctl is-enabled --quiet unoq-uplink-fallback.service 2>/dev/null; then
  skip "wifi fallback already enabled"
else
  systemctl enable unoq-uplink-fallback.service >/dev/null 2>&1 ||
    fail "could not enable unoq-uplink-fallback.service"
  did "wifi fallback enabled at boot"
fi
step "build the gadget now (no bind without a host)"
if systemctl restart unoq-usb-gadget.service 2>/dev/null; then
  did "service ran"
else
  warn "service failed - check: journalctl -u unoq-usb-gadget -n 40"
fi

step "verify"
G=/sys/kernel/config/usb_gadget/unoq
names() { # basenames of a glob, space separated, "<none>" if it matched nothing
  local out=""
  for p in "$@"; do
    [ -e "$p" ] || continue
    out="$out $(basename "$p")"
  done
  echo "${out# }"
}
if [ -d "$G" ]; then
  skip "gadget defined, configs: $(names "$G"/configs/*)"
  skip "functions: $(names "$G"/functions/*)"
  attached="$(cat "$G/functions/mass_storage.0/lun.0/file" 2>/dev/null)"
  skip "drive backing file: ${attached:-<none>}"
else
  warn "no gadget at $G - check the journal"
fi
udcs="$(names /sys/class/udc/*)"
if [ -n "$udcs" ]; then
  skip "UDC present: $udcs - bound"
else
  skip "no UDC: the board is not plugged into a computer yet (expected)"
fi

summary
cat <<EOF

Plug the board's USB-C port into your computer, then on the computer:

  ssh $TARGET_USER@$(hostname).local
  http://$(hostname).local:8080/    learning content + installers
  the "UNO-Q" drive                 same files, no network needed

The name is the address here. The board takes whatever address the computer
leases it - Windows and macOS both insist on their own numbering when they
share a connection - and falls back to link-local if nothing is serving DHCP
at all. mDNS is what makes that a single thing you can type: Windows 10+,
macOS and Linux all resolve it with nothing installed.

If you would rather have the number, ask the board:  usb/status.sh
EOF
