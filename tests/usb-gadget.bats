#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# provision/95-usb-gadget.sh installs the USB link: kernel modules, mDNS, the
# settings file, a udev rule, root's copies of usb/, four units, and last the
# hand-over that takes the port from adbd. usb-handover.bats covers the
# hand-over itself and the order the step does things in. This is the rest:
# what a run installs, that a second run installs nothing again, that the
# settings file a person edits is never rewritten, and that the step does not
# report success when the port was not handed over.
#
# usb/handover.sh is replaced, in a copy of the checkout, with a stand-in that
# builds a gadget directory and binds it when a test says there is a cable.
# The board's /etc is under UNOQ_ROOT.
#
# What this cannot show: that the host sees a network adapter and a drive.
# That is the board's job, with a cable.

setup() {
  load helpers/stub
  stub_setup

  REAL="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PROJECT="$BATS_TEST_TMPDIR/checkout"
  mkdir -p "$PROJECT/docs/reference"
  cp -r "$REAL/provision" "$REAL/mcu" "$REAL/usb" "$REAL/net" "$REAL/status" "$PROJECT/"
  cp "$REAL/docs/reference/usb.md" "$PROJECT/docs/reference/"
  STEP="$PROJECT/provision/95-usb-gadget.sh"
  # The venv the relay's unit runs from, which install_unit checks is there.
  mkdir -p "$PROJECT/.venv/bin"
  printf '#!/bin/sh\n' >"$PROJECT/.venv/bin/python"
  chmod +x "$PROJECT/.venv/bin/python"

  FLAGS="$BATS_TEST_TMPDIR/flags"
  mkdir -p "$FLAGS"
  export FLAGS

  export UNOQ_ROOT="$BATS_TEST_TMPDIR/root"
  # The getty template Debian ships, which the login on ttyGS0 is made from.
  mkdir -p "$UNOQ_ROOT/usr/lib/systemd/system"
  : >"$UNOQ_ROOT/usr/lib/systemd/system/serial-getty@.service"
  export UNOQ_UNIT_DIR="$BATS_TEST_TMPDIR/etc/systemd/system"
  RELAY="$UNOQ_UNIT_DIR/unoq-mcu-serial.service"
  export UNOQ_RUNTIME_DIR="$BATS_TEST_TMPDIR/usr/local/lib/unoq"
  export UNOQ_RUN_DIR="$BATS_TEST_TMPDIR/run"
  export UNOQ_GADGET_DIR="$BATS_TEST_TMPDIR/configfs/unoq"
  export UNOQ_UDC_DIR="$BATS_TEST_TMPDIR/udc"
  export UNOQ_SSH_DIR="$BATS_TEST_TMPDIR/ssh"
  export UNOQ_CGROUP_FILE="$BATS_TEST_TMPDIR/cgroup"
  export UNOQ_IN_BOOTSTRAP=1
  mkdir -p "$UNOQ_RUN_DIR" "$UNOQ_UDC_DIR" "$UNOQ_SSH_DIR"
  : >"$UNOQ_SSH_DIR/ssh_host_ed25519_key"
  # Reached over SSH, so the hand-over runs rather than being scheduled.
  echo "0::/user.slice/user-1000.slice/session-3.scope" >"$UNOQ_CGROUP_FILE"
  UNOQ_USER="$(id -un)"
  export UNOQ_USER
  export FAKE_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$FAKE_HOME"
  IMG="$FAKE_HOME/unoq-share.img"
  head -c 4096 /dev/zero >"$IMG"
  DEFAULTS="$UNOQ_ROOT/etc/default/unoq-usb"
  RULE="$UNOQ_ROOT/etc/udev/rules.d/99-unoq-usb-gadget.rules"
  MODS="$UNOQ_ROOT/etc/modules-load.d/unoq-usb-gadget.conf"
  UNITS="unoq-usb-gadget unoq-usb-bind unoq-usb-confirm unoq-uplink-fallback"

  # The hand-over: builds the gadget, and binds it if a cable is in.
  cat >"$PROJECT/usb/handover.sh" <<'SH'
#!/bin/bash
echo ran >>"$FLAGS/handover-ran"
[ -e "$FLAGS/handover-fails" ] && exit 1
mkdir -p "$UNOQ_GADGET_DIR/configs/c.1" "$UNOQ_GADGET_DIR/functions/ncm.usb0" \
  "$UNOQ_GADGET_DIR/functions/mass_storage.0/lun.0"
: >"$UNOQ_GADGET_DIR/UDC"
[ -e "$FLAGS/binds" ] && ls "$UNOQ_UDC_DIR" >"$UNOQ_GADGET_DIR/UDC"
exit 0
SH
  chmod +x "$PROJECT/usb/handover.sh"

  stub udevadm
  stub ssh-keygen
  stub systemd-run
  stub hostname 0 uno-q
  stub_body id <<'SH'
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
SH
  stub_body getent <<'SH'
[ "$1" = passwd ] && { echo "$2:x:1000:1000::$FAKE_HOME:/bin/bash"; exit 0; }
exec /usr/bin/getent "$@"
SH
  stub_body modprobe <<'SH'
[ ! -e "$FLAGS/no-module-$1" ]
SH
  stub_body dpkg-query <<'SH'
[ -e "$FLAGS/pkg-${*: -1}" ] && echo "install ok installed"
exit 0
SH
  stub_body apt-get <<'SH'
[ "$1" = install ] || exit 0
for a in "$@"; do case "$a" in -* | install) ;; *) : >"$FLAGS/pkg-$a" ;; esac; done
SH
  # A manager with a memory. A unit exists while $FLAGS/unit-<u> does; the
  # units this step installs exist once their file is in UNOQ_UNIT_DIR.
  stub_body systemctl <<'SH'
u="${*: -1}"
exists() { [ -e "$FLAGS/unit-$1" ] || [ -e "$UNOQ_UNIT_DIR/$1" ]; }
case "$1" in
  list-unit-files) exists "$2" && echo "$2 enabled"; exit 0 ;;
  cat) exists "$2"; exit ;;
  is-enabled)
    [ -e "$FLAGS/enabled-$u" ] && { echo enabled; exit 0; }
    echo disabled
    exit 1
    ;;
  is-active) [ -e "$FLAGS/active-$u" ]; exit ;;
  is-failed) exit 1 ;;
  enable)
    [ -e "$FLAGS/wont-start-$u" ] && exit 1
    : >"$FLAGS/enabled-$u"
    [ "$2" = --now ] && : >"$FLAGS/active-$u"
    ;;
  disable)
    rm -f "$FLAGS/enabled-$u"
    [ "$2" = --now ] && rm -f "$FLAGS/active-$u"
    ;;
  add-wants)
    # As the real one does while /dev/ttyGS0 is absent, which on a board is
    # every time this step needs it.
    echo "Failed to add dependency: Unit $2 does not exist" >&2
    exit 1
    ;;
esac
exit 0
SH
  # sshd is there, as on a stock board, but off.
  : >"$FLAGS/unit-ssh.service"
}

# cable - a USB controller present, as when the port is plugged into a
# computer, and the gadget binding to it.
cable() {
  mkdir -p "$UNOQ_UDC_DIR/4e00000.usb"
  : >"$FLAGS/binds"
}

# revert - the REVERT comment in the step's header, as one line: "# REVERT:"
# and the "#" and backslash of each continuation dropped.
revert() {
  awk '
    /^# REVERT:/ { buf = substr($0, 11); inrev = 1; next }
    inrev && /^#  / { sub(/^# +/, ""); buf = buf " " $0; next }
    inrev { print buf; exit }
  ' "$STEP" | tr -d '\134'
}

# --- the first run ----------------------------------------------------------

@test "a fresh board gets the modules, mDNS, the settings, the rule and the units" {
  run "$STEP"
  [ "$status" -eq 0 ]
  [ "$(cat "$MODS")" = "$(printf 'libcomposite\nbridge')" ]
  ran_like '^apt-get install -y --no-install-recommends avahi-autoipd$'
  ran_like '^apt-get install -y --no-install-recommends avahi-daemon$'
  ran "systemctl enable --now avahi-daemon.service"
  [ -f "$DEFAULTS" ]
  cmp -s "$RULE" "$PROJECT/usb/99-unoq-usb-gadget.rules"
  ran "udevadm control --reload-rules"
  local u
  for u in $UNITS; do [ -f "$UNOQ_UNIT_DIR/$u.service" ]; done
  ran "systemctl enable unoq-usb-gadget.service"
  ran "systemctl enable unoq-usb-confirm.service"
  ran "systemctl enable unoq-uplink-fallback.service"
  [ -e "$FLAGS/handover-ran" ]
}

@test "every unit runs root's copies of the usb scripts, never the checkout" {
  run "$STEP"
  [ "$status" -eq 0 ]
  local u
  for u in $UNITS; do
    refute grep -qE "^Exec[A-Za-z]*=.*$PROJECT" "$UNOQ_UNIT_DIR/$u.service"
  done
  grep -qx "ExecStart=$UNOQ_RUNTIME_DIR/usb/gadget-up.sh" "$UNOQ_UNIT_DIR/unoq-usb-bind.service"
  cmp -s "$PROJECT/usb/usb-net-up.sh" "$UNOQ_RUNTIME_DIR/usb/usb-net-up.sh"
}

@test "the units are enabled for boot, not started by the step" {
  # Starting them is the hand-over's job, and it is the last thing done.
  run "$STEP"
  [ "$status" -eq 0 ]
  refute ran_like '^systemctl (enable --now|start|restart) unoq-usb'
  refute ran_like '^systemctl (enable --now|start|restart) unoq-uplink'
}

@test "the packaged link-local daemon is switched off, where there is one" {
  # usb-dhcp.sh starts and stops avahi-autoipd on br-usb from the lease
  # events; the packaged per-interface service would fight it.
  : >"$FLAGS/unit-avahi-autoipd.service"
  : >"$FLAGS/enabled-avahi-autoipd.service"
  run "$STEP"
  [ "$status" -eq 0 ]
  ran "systemctl disable --now avahi-autoipd.service"
}

@test "sshd is switched on before the port is handed over" {
  run "$STEP"
  [ "$status" -eq 0 ]
  ran "systemctl enable --now ssh.service"
}

@test "with no cable in, it says to plug one in, and that is not an error" {
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no UDC: the board is not plugged into a computer yet (expected)"* ]]
  [[ "$output" == *"Plug the board's USB-C port into a computer"* ]]
  [[ "$output" == *"ssh $UNOQ_USER@uno-q.local"* ]]
}

# --- the second run ---------------------------------------------------------

@test "a second run installs nothing again" {
  run "$STEP"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  never_ran apt-get
  never_ran udevadm
  refute ran "systemctl daemon-reload"
  refute ran_like '^systemctl enable'
  [[ "$output" == *"$DEFAULTS exists"* ]]
}

# --- the settings file ------------------------------------------------------

@test "the settings file is written once, and an edited one is never rewritten" {
  # It is the one file here a person is expected to change, quite possibly
  # while the board is running on the link it controls.
  run "$STEP"
  grep -q '^#UNOQ_USB_DEFAULT_ROUTE=0$' "$DEFAULTS"
  echo "UNOQ_USB_DEFAULT_ROUTE=0" >"$DEFAULTS"
  run "$STEP"
  [ "$status" -eq 0 ]
  [ "$(cat "$DEFAULTS")" = "UNOQ_USB_DEFAULT_ROUTE=0" ]
}

@test "a settings file still choosing a DHCP mode is told that the line does nothing" {
  mkdir -p "$(dirname "$DEFAULTS")"
  echo "UNOQ_USB_MODE=server" >"$DEFAULTS"
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qE "warn +$DEFAULTS still sets UNOQ_USB_MODE, which no longer does" <<<"$output"
  [ "$(cat "$DEFAULTS")" = "UNOQ_USB_MODE=server" ]
}

# --- what it warns about, and carries on ------------------------------------

@test "a module that will not load is a warning, and the step goes on" {
  : >"$FLAGS/no-module-usb_f_rndis"
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qE 'warn +usb_f_rndis could not be loaded - the gadget may not come up' <<<"$output"
  [ -e "$FLAGS/handover-ran" ]
}

@test "no drive image is a warning that says how to build one" {
  rm "$IMG"
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qE "warn +$IMG missing - the drive will appear empty" <<<"$output"
  [[ "$output" == *"share/build-image.sh"* ]]
}

# --- what it refuses to call success ----------------------------------------

@test "no sshd to switch on: it stops before the hand-over, with adb untouched" {
  rm "$FLAGS/unit-ssh.service"
  run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no ssh.service on this board"* ]]
  [ ! -e "$FLAGS/handover-ran" ]
}

@test "a hand-over that fails fails the step, after saying what was installed" {
  : >"$FLAGS/handover-fails"
  run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"everything is installed, but the USB port was not handed over"* ]]
  [ -f "$UNOQ_UNIT_DIR/unoq-usb-gadget.service" ]
}

@test "a cable in and the gadget bound is reported as bound" {
  cable
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bound to 4e00000.usb"* ]]
  [[ "$output" == *"The board is on the cable."* ]]
}

@test "a cable in and the gadget not bound is a failure, not 'ok'" {
  # A controller being there is not the gadget being bound to it.
  cable
  rm "$FLAGS/binds"
  run "$STEP"
  [ "$status" -ne 0 ]
  grep -qE 'warn +a controller is present \(4e00000.usb\) and the gadget is not bound to it' <<<"$output"
}

# --- from adb shell ---------------------------------------------------------

@test "from adb shell the hand-over is scheduled, and the step says the shell will close" {
  echo "0::/system.slice/adbd.service" >"$UNOQ_CGROUP_FILE"
  run "$STEP"
  [ "$status" -eq 0 ]
  ran_like '^systemd-run .*--unit=unoq-usb-handover --on-active=20 '
  [ ! -e "$FLAGS/handover-ran" ]
  [[ "$output" == *"nothing to verify yet"* ]]
  [[ "$output" == *"This adb shell closes in about 20 seconds."* ]]
  [[ "$output" == *"The board is on the cable."* ]]
}

# --- the way back -----------------------------------------------------------

@test "the REVERT line removes the gadget's unit and its udev rule" {
  run "$STEP"
  text="$(revert)"
  [ -n "$text" ]
  # Up to the bracket is commands; the rest is for a person.
  cmd="${text%% (and*}"
  cmd="${cmd//\/etc\/systemd\/system/$UNOQ_UNIT_DIR}"
  cmd="${cmd//\/etc\/udev/$UNOQ_ROOT/etc/udev}"
  : >"$STUB_LOG"
  bash -c "$cmd"
  [ ! -e "$UNOQ_UNIT_DIR/unoq-usb-gadget.service" ]
  [ ! -e "$RULE" ]
  ran "systemctl daemon-reload"
  ran "udevadm control --reload"
}

@test "the REVERT line names every other unit installed the same way, and every other root unit" {
  text="$(revert)"
  # The units this step installs, other than the gadget, are in the first
  # bracket; the root units installed elsewhere are in the second.
  local src name
  for src in "$REAL"/usb/unoq-*.service; do
    name="$(basename "$src" .service)"
    [ "$name" = unoq-usb-gadget ] && continue
    [[ "$text" == *"$name"* ]] || {
      echo "$name is installed by this step and not in its REVERT line"
      false
    }
  done
  for src in "$REAL"/*/unoq-*.service; do
    name="$(basename "$src" .service)"
    case "$src" in "$REAL"/usb/*) continue ;; esac
    grep -qE '^User=' "$src" && continue
    grep -qE '^Exec[A-Za-z]*=[-@:+!]*/home/arduino/two-computers-one-board/' "$src" || continue
    [[ "$text" == *"$name"* ]] || {
      echo "$name runs root's scripts and is not in the REVERT line"
      false
    }
  done
}

# --- the serial login (UNOQ_GADGET_ACM) ---------------------------------------
#
# The getty is wanted by the device, so it starts whenever /dev/ttyGS0 appears
# and, being BindsTo= it already, stops when it goes. What is asserted is the
# argv, and the link the stub manager makes for it where systemd would.

GETTY_LINK_REL="dev-ttyGS0.device.wants/serial-getty@ttyGS0.service"

acm_in_file() {
  mkdir -p "$(dirname "$DEFAULTS")"
  echo "UNOQ_GADGET_ACM=1" >"$DEFAULTS"
}

router_path() { # enabled|disabled - Arduino's watcher of /dev/ttyGS0 is there
  : >"$FLAGS/unit-arduino-router-serial.path"
  [ "$1" = enabled ] && : >"$FLAGS/enabled-arduino-router-serial.path"
  return 0
}

@test "without UNOQ_GADGET_ACM nothing about a serial login is touched" {
  unset UNOQ_GADGET_ACM
  router_path enabled
  run "$STEP"
  [ "$status" -eq 0 ]
  refute ran_like '^systemctl add-wants'
  refute ran "modprobe usb_f_acm"
  [ ! -e "$UNOQ_UNIT_DIR/dev-ttyGS0.device.wants" ]
  [[ "$output" == *"UNOQ_GADGET_ACM is not 1 - no serial port, no login on it"* ]]
  # Not this setting's business when it is off.
  [[ "$output" != *"arduino-router-serial.path"* ]]
}

@test "the settings file offers UNOQ_GADGET_ACM, commented out, and says to rebuild" {
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qx '#UNOQ_GADGET_ACM=1' "$DEFAULTS"
  grep -q '^# rebuilt for it to take effect' "$DEFAULTS"
  # Commented out is off.
  refute ran_like '^systemctl add-wants'
}

@test "UNOQ_GADGET_ACM=1 in the settings file wants the getty from the device" {
  acm_in_file
  run "$STEP"
  [ "$status" -eq 0 ]
  [ "$(readlink "$UNOQ_UNIT_DIR/$GETTY_LINK_REL")" = /usr/lib/systemd/system/serial-getty@.service ]
  ran "systemctl daemon-reload"
  ran "modprobe usb_f_acm"
  # Not wanted by getty.target: a boot would wait for a device that may not come.
  refute ran_like '^systemctl enable.*serial-getty'
  [ -L "$UNOQ_UNIT_DIR/$GETTY_LINK_REL" ]
  [[ "$output" != *"is set here but not in"* ]]
}

@test "a second run with UNOQ_GADGET_ACM=1 does not add the getty again" {
  acm_in_file
  run "$STEP"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  refute ran_like '^systemctl add-wants'
  [[ "$output" == *"serial-getty@ttyGS0.service already wanted by dev-ttyGS0.device"* ]]
}

@test "UNOQ_GADGET_ACM=1 on the command line only is warned about: the units read the file" {
  UNOQ_GADGET_ACM=1 run "$STEP"
  [ "$status" -eq 0 ]
  [ -L "$UNOQ_UNIT_DIR/$GETTY_LINK_REL" ]
  grep -qE "warn +UNOQ_GADGET_ACM=1 is set here but not in $DEFAULTS" <<<"$output"
}

@test "a 0 in the environment wins over a 1 in the file" {
  acm_in_file
  UNOQ_GADGET_ACM=0 run "$STEP"
  [ "$status" -eq 0 ]
  refute ran_like '^systemctl add-wants'
}

@test "an enabled arduino-router-serial.path is warned about when the port is on" {
  # It has PathExists=/dev/ttyGS0, and would bring Arduino's router back.
  acm_in_file
  router_path enabled
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qE 'warn +arduino-router-serial.path is ENABLED, and it watches /dev/ttyGS0' <<<"$output"
  [[ "$output" == *"systemctl disable --now arduino-router-serial.path"* ]]
}

@test "a disabled or absent arduino-router-serial.path is not warned about" {
  acm_in_file
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" != *"arduino-router-serial.path is ENABLED"* ]]

  rm -rf "$UNOQ_GADGET_DIR"
  router_path disabled
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" != *"arduino-router-serial.path is ENABLED"* ]]
}

@test "a gadget already built without the port is said to need rebuilding" {
  # The hand-over stand-in builds one with no acm.usb0, as an older board has.
  acm_in_file
  run "$STEP"
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qE 'warn +the gadget on this board was built without the serial port' <<<"$output"
}

# --- the MCU's shell over the cable (unoq-mcu-serial) ------------------------
#
# Installed with the port and never started: /dev/ttyHS1 has one owner, and
# the unit's Conflicts= are what hand it over, so they are checked in the file
# as installed.

@test "without UNOQ_GADGET_ACM the MCU relay is not installed" {
  run "$STEP"
  [ "$status" -eq 0 ]
  [ ! -e "$RELAY" ]
}

@test "UNOQ_GADGET_ACM=1 installs the MCU relay, and never enables or starts it" {
  acm_in_file
  run "$STEP"
  [ "$status" -eq 0 ]
  [ -f "$RELAY" ]
  refute ran_like '^systemctl .*unoq-mcu-serial'
  refute grep -q '^\[Install\]' "$RELAY"
}

@test "the installed relay gives way to the demo and the login, and runs the venv as the user" {
  acm_in_file
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qx 'Conflicts=unoq-cpu-bars.service' "$RELAY"
  grep -qx 'Conflicts=serial-getty@ttyGS0.service' "$RELAY"
  grep -qx 'After=unoq-cpu-bars.service serial-getty@ttyGS0.service' "$RELAY"
  grep -qx 'Requires=unoq-link.service' "$RELAY"
  grep -qx 'BindsTo=dev-ttyGS0.device' "$RELAY"
  grep -qx "ExecStart=$PROJECT/.venv/bin/python -m unoq.mcuserial" "$RELAY"
  grep -qx "User=$UNOQ_USER" "$RELAY"
}

@test "a second run with UNOQ_GADGET_ACM=1 leaves the relay's unit alone" {
  acm_in_file
  run "$STEP"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  refute ran "systemctl daemon-reload"
}

@test "no venv is a warning, not a failed step, and no relay is installed" {
  acm_in_file
  rm -rf "$PROJECT/.venv"
  run "$STEP"
  [ "$status" -eq 0 ]
  [ ! -e "$RELAY" ]
  grep -qE 'warn +no venv at .*, so no unoq-mcu-serial.service' <<<"$output"
  # The rest of the step still ran.
  [ -e "$FLAGS/handover-ran" ]
}

@test "the login is wanted by a device that does not exist yet" {
  # systemctl add-wants refuses a device unit until /dev/ttyGS0 exists, and
  # it only exists once this very run has given the gadget a serial port.
  acm_in_file
  run "$STEP"
  [ "$status" -eq 0 ]
  refute ran_like '^systemctl add-wants'
  [ -L "$UNOQ_UNIT_DIR/$GETTY_LINK_REL" ]
}

@test "no getty template is a clear failure, not a broken link" {
  acm_in_file
  rm "$UNOQ_ROOT/usr/lib/systemd/system/serial-getty@.service"
  run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no /usr/lib/systemd/system/serial-getty@.service on this board"* ]]
  [ ! -e "$UNOQ_UNIT_DIR/$GETTY_LINK_REL" ]
}

@test "the relay gives ttyGS0 back to dialout before it opens it" {
  # A login on the port leaves it root:tty 0600, and the relay runs as the
  # owner. Seen on the board: Permission denied, restarting to its limit.
  acm_in_file
  run "$STEP"
  [ "$status" -eq 0 ]
  unit="$UNOQ_UNIT_DIR/unoq-mcu-serial.service"
  grep -qx 'ExecStartPre=+/bin/chgrp dialout /dev/ttyGS0' "$unit"
  grep -qx 'ExecStartPre=+/bin/chmod 0660 /dev/ttyGS0' "$unit"
  # Before the relay itself, which still runs as the owner.
  pre="$(grep -n '^ExecStartPre=+/bin/chmod' "$unit" | cut -d: -f1)"
  start="$(grep -n '^ExecStart=' "$unit" | cut -d: -f1)"
  [ "$pre" -lt "$start" ]
  grep -qE "^User=$(id -un)\$" "$unit"
}
