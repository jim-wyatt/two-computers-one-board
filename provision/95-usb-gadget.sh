#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# IP over USB, plus the fileshare drive, when the board is plugged into a PC.
#
#   sudo bash ~/two-computers-one-board/provision/95-usb-gadget.sh
#
# Idempotent, and safe to run over SSH or from `adb shell` - see the last step
# for what the second one takes. It does NOT change the USB role. On
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
#         (and unoq-usb-bind, unoq-usb-confirm, unoq-uplink-fallback and,
#         where UNOQ_GADGET_ACM=1 installed it, unoq-mcu-serial the same
#         way.) Then, once no other unoq-* unit that runs as root is left
#         installed (unoq-link, unoq-leds):  rm -r /usr/local/lib/unoq
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
need_root

IMG="${UNOQ_SHARE_IMG:-$TARGET_HOME/unoq-share.img}"
# The settings file the units read, which a person is expected to edit.
DEFAULTS="$SYSROOT/etc/default/unoq-usb"

# The serial port on the gadget (#9). gadget-up.sh gets it from that file,
# through EnvironmentFile= in its units, and nothing reads the file for this
# step - so the step reads it itself, as data, one line, never sourced. The
# environment wins, so `UNOQ_GADGET_ACM=1 ./bootstrap.sh` works too. Read up
# here because two steps below depend on it: the module, and the login.
FILE_ACM="$(sed -n 's/^UNOQ_GADGET_ACM=//p' "$DEFAULTS" 2>/dev/null | tail -1 | tr -d '"'"'"' ')"
ACM="${UNOQ_GADGET_ACM:-$FILE_ACM}"

step "kernel support"
MODULES="libcomposite usb_f_ncm usb_f_rndis usb_f_mass_storage bridge"
# Only asked for when it will be used, so a board without the setting is asked
# exactly what it was asked before.
[ "$ACM" = 1 ] && MODULES="$MODULES usb_f_acm"
for mod in $MODULES; do
  if modprobe "$mod" 2>/dev/null; then
    skip "$mod available"
  else
    warn "$mod could not be loaded - the gadget may not come up"
  fi
done
# Loaded on demand by the gadget, but listing them here means a board that
# lacks one says so now rather than at 2am with a cable in it.
if write_file 0644 "$SYSROOT/etc/modules-load.d/unoq-usb-gadget.conf" <<'MODS'
libcomposite
bridge
MODS
then
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
if [ -f "$DEFAULTS" ]; then
  skip "$DEFAULTS exists"
  # UNOQ_USB_MODE is gone: the board is always the DHCP client on this link.
  # Left in place it does nothing, which is worse than saying so - the file
  # would go on describing a server mode that no longer exists.
  if grep -q '^UNOQ_USB_MODE=' "$DEFAULTS" 2>/dev/null; then
    warn "$DEFAULTS still sets UNOQ_USB_MODE, which no longer does"
    warn "  anything - the board is always the DHCP client now. Safe to delete"
    warn "  that line: sudo sed -i '/^UNOQ_USB_MODE=/d' $DEFAULTS"
  fi
else
  write_file 0644 "$DEFAULTS" <<'CONF'
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

# If wifi has been turned off (net/wifi.sh off) and the USB link has produced no
# route to the internet this many seconds after boot, turn the radio back on and
# leave it on. Set UNOQ_UPLINK_FALLBACK=0 to let the board sit there with no
# uplink instead.
#UNOQ_UPLINK_FALLBACK=1
#UNOQ_UPLINK_DEADLINE=240

# Uncomment to add a serial port (CDC-ACM) to the gadget, with a login on it:
# a COM port on Windows, /dev/ttyACM0 on Linux. Off until a Windows host has
# been seen binding it beside the network and the drive. The gadget has to be
# rebuilt for it to take effect - the restart above is not enough. Run
# provision/95-usb-gadget.sh again for the login, then purge the gadget and
# rebuild it, or reboot. See "A serial login over the cable" in
# docs/reference/usb.md.
#UNOQ_GADGET_ACM=1
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

step "a way back in"
# The last step below takes the USB port away from adbd, and with it the
# `adb shell` that is the only way into a stock board. So before anything is
# taken away, the thing that replaces it has to be running - and if it cannot
# be started, this stops here, with adb untouched.
ensure_ssh

step "udev rule"
if write_file 0644 "$SYSROOT/etc/udev/rules.d/99-unoq-usb-gadget.rules" \
  <"$PROJECT/usb/99-unoq-usb-gadget.rules"; then
  udevadm control --reload-rules
  did "udev rules reloaded"
fi

step "the scripts root runs"
# All four units below run as root, so they run root's own copies of the usb/
# scripts and not the ones in this checkout - see "what root runs" in lib.sh.
# Copied before the units are installed, because install_unit checks that what
# a unit names is there. The directory is copied whole: these scripts call one
# another by relative path, and udhcpc is handed usb-dhcp.sh by usb-net-up.sh.
#
# A change to a script under usb/ reaches the board by running this step again.
# The restart further down is what puts it into effect - including for udhcpc,
# which was started with the path of its handler script and keeps that path
# until it is started again.
install_root_scripts

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
install_unit "$PROJECT/net/unoq-uplink-fallback.service"
# The status LEDs are NOT installed here any more. They report on the whole
# board, not just the USB link, and installing them from an optional feature
# meant a board provisioned without `--with-usb-gadget` had no way to say
# anything at all. See provision/50-status-leds.sh.
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
step "serial login over the cable"
# Off unless asked for, and then nothing at all is changed: a board that does
# not want the serial port must come out of this step exactly as before.
if [ "$ACM" != 1 ]; then
  skip "UNOQ_GADGET_ACM is not 1 - no serial port, no login on it"
else
  # Wanted by the DEVICE, not by getty.target, which is where a plain
  # `systemctl enable` would put it. serial-getty@.service is already
  # BindsTo=dev-%i.device and After= it, so it stops when /dev/ttyGS0 goes;
  # being wanted by the device is the other half, and starts it whenever
  # /dev/ttyGS0 appears - at boot, or after the gadget is rebuilt. Wanted by
  # getty.target, every boot would queue a job waiting up to 90 seconds for a
  # device that a gadget built without the port will never make, and a getty
  # that timed out once would not start when the device came later.
  GETTY=serial-getty@ttyGS0.service
  WANTS="${UNOQ_UNIT_DIR:-/etc/systemd/system}/dev-ttyGS0.device.wants"
  if [ -L "$WANTS/$GETTY" ]; then
    skip "$GETTY already wanted by dev-ttyGS0.device"
  else
    systemctl add-wants dev-ttyGS0.device "$GETTY" >/dev/null 2>&1 ||
      fail "could not make dev-ttyGS0.device want $GETTY"
    did "$GETTY starts whenever /dev/ttyGS0 appears"
  fi
  # Arduino's factory image watches the same device. arduino-router-serial.path
  # has PathExists=/dev/ttyGS0 and starts a socat proxy that Requires= the
  # router, so the serial port this adds would bring arduino-router back to
  # hold /dev/ttyHS1 - and fight the getty for /dev/ttyGS0. 15-dev-tools.sh
  # disables it, but not every board has run that.
  if unit_exists arduino-router-serial.path &&
    { systemctl is-enabled --quiet arduino-router-serial.path 2>/dev/null ||
      systemctl is-active --quiet arduino-router-serial.path 2>/dev/null; }; then
    warn "arduino-router-serial.path is ENABLED, and it watches /dev/ttyGS0."
    warn "  The serial port will start Arduino's router, which takes /dev/ttyHS1"
    warn "  from this project and /dev/ttyGS0 from the login. Turn it off:"
    warn "    sudo systemctl disable --now arduino-router-serial.path arduino-router-serial.service"
    warn "  or run provision/15-dev-tools.sh, which does that and more."
  fi
  # The units build the gadget from the file, not from this step's
  # environment, so a 1 that came only from the command line would enable a
  # login on a port the gadget never gets.
  if [ "$FILE_ACM" != 1 ]; then
    warn "UNOQ_GADGET_ACM=1 is set here but not in $DEFAULTS, which is what"
    warn "  the gadget is built from. Add it there:"
    warn "    echo UNOQ_GADGET_ACM=1 | sudo tee -a /etc/default/unoq-usb"
  fi
  # The MCU's shell on the same port, by hand: a relay that takes /dev/ttyGS0
  # from the login and /dev/ttyHS1 from the CPU-bars demo, through Conflicts=
  # in the unit. Installed and NEVER enabled or started here - there is one
  # owner of /dev/ttyHS1 at a time, and nothing should take it from the demo
  # without a person asking. Runs as the user, from the venv, so it needs no
  # copy under $RUNTIME_DIR. See "The MCU's shell over the cable" in
  # docs/reference/usb.md.
  # REVERT: rm /etc/systemd/system/unoq-mcu-serial.service &&
  #         systemctl daemon-reload
  #
  # Without the venv install_unit would stop the whole step here, before the
  # hand-over, over something nobody has asked to run yet - so it is said and
  # passed over instead.
  if [ -x "$PROJECT/.venv/bin/python" ]; then
    install_unit "$PROJECT/usb/unoq-mcu-serial.service"
  else
    warn "no venv at $PROJECT/.venv, so no unoq-mcu-serial.service: run"
    warn "  provision/user/35-python-venv.sh as $TARGET_USER, then this step again."
  fi
  # And an existing gadget is never rebuilt in place (gadget-up.sh).
  GADGET="${UNOQ_GADGET_DIR:-/sys/kernel/config/usb_gadget/unoq}"
  if [ -d "$GADGET" ] && [ ! -d "$GADGET/functions/acm.usb0" ]; then
    warn "the gadget on this board was built without the serial port. It gets"
    warn "  one when it is rebuilt: at the next boot, or by hand, which ends a"
    warn "  session on the cable - see 'A serial login over the cable' in"
    warn "  docs/reference/usb.md."
  fi
fi

step "hand the USB port over"
# adbd binds its OWN gadget to the first free UDC. With this installed there
# would be two gadgets racing for one controller, and which one wins is a coin
# toss, so adbd goes. That is done last, by usb/handover.sh, and after
# everything it leaves behind is installed - it used to be done half way down
# this file, which on a board reached over `adb shell` killed this script
# before it had installed a single unit: no adb, no gadget, no way in.
# REVERT: systemctl enable --now adbd
# usb_handover is in lib.sh: it calls the script, or - from `adb shell`, where
# calling it would kill this run - schedules it. HANDOVER_DEFERRED says which.
HANDOVER_FAILED=0
usb_handover || HANDOVER_FAILED=1
DEFERRED="$HANDOVER_DEFERRED"
HANDOVER_DELAY="${UNOQ_HANDOVER_DELAY:-20}"

step "verify"
G="${UNOQ_GADGET_DIR:-/sys/kernel/config/usb_gadget/unoq}"
names() { # basenames of a glob, space separated, "<none>" if it matched nothing
  local out=""
  for p in "$@"; do
    [ -e "$p" ] || continue
    out="$out $(basename "$p")"
  done
  echo "${out# }"
}
if [ "$DEFERRED" = 1 ]; then
  skip "nothing to verify yet - the gadget is built when the hand-over runs"
elif [ -d "$G" ]; then
  skip "gadget defined, configs: $(names "$G"/configs/*)"
  skip "functions: $(names "$G"/functions/*)"
  attached="$(cat "$G/functions/mass_storage.0/lun.0/file" 2>/dev/null)"
  skip "drive backing file: ${attached:-<none>}"
  # A controller being present is not the gadget being bound to it. What says
  # bound is the gadget's own UDC file naming a controller.
  udcs="$(names "${UNOQ_UDC_DIR:-/sys/class/udc}"/*)"
  bound="$(cat "$G/UDC" 2>/dev/null)"
  if [ -z "$udcs" ]; then
    skip "no UDC: the board is not plugged into a computer yet (expected)"
  elif [ -n "$bound" ]; then
    skip "bound to $bound"
  else
    warn "a controller is present ($udcs) and the gadget is not bound to it"
    warn "  check: journalctl -u unoq-usb-bind -n 40"
    HANDOVER_FAILED=1
  fi
else
  warn "no gadget at $G - check the journal"
fi

summary
# After the summary, so what was installed is still listed - and non-zero, so
# bootstrap.sh and anything else calling this step knows it did not finish.
[ "$HANDOVER_FAILED" = 0 ] ||
  fail "everything is installed, but the USB port was not handed over - see the warnings above.
        The board is still reachable the way you reached it. Run this step again once fixed."
if [ "$DEFERRED" = 1 ]; then
  cat <<EOF

${P_BOLD}This adb shell closes in about ${HANDOVER_DELAY} seconds.${P_OFF} That is the hand-over, not a
crash: adb's daemon gives up the USB port, and the board comes back on the same
cable as a network adapter and a drive. From then on the way in is SSH, with
the password you set for $TARGET_USER - the command is just below.

What the hand-over did is in the journal:  journalctl -t unoq-usb-handover
EOF
fi
# Said the way things are. The first version told someone whose board was
# already on the cable to plug it in, and offered a web page on port 8080 that
# does not exist on a board set up with --no-learning.
if [ "$DEFERRED" = 1 ] || [ -n "$(names "${UNOQ_UDC_DIR:-/sys/class/udc}"/*)" ]; then
  echo
  echo "The board is on the cable. From the computer at the other end:"
else
  echo
  echo "Plug the board's USB-C port into a computer, then on that computer:"
fi
echo
echo "  ssh $TARGET_USER@$(hostname).local"
if systemctl is-enabled --quiet unoq-learn.service 2>/dev/null; then
  echo "  http://$(hostname).local:8080/    the course, served by the board"
fi
echo "  the \"UNO-Q\" drive                 the course as files, no network needed"
cat <<EOF

The name is the address here. The board takes whatever address the computer
leases it - Windows and macOS both insist on their own numbering when they
share a connection - and falls back to link-local if nothing is serving DHCP
at all. mDNS is what makes that a single thing you can type: Windows 10+,
macOS and Linux all resolve it with nothing installed.

If you would rather have the number, ask the board:  usb/status.sh

The services run the copies in $RUNTIME_DIR, not the ones in the checkout.
After editing a script under usb/, run this step again for the board to use it;
usb/status.sh says when the two differ.
EOF
