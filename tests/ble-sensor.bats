#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# provision/68-ble-sensor.sh installs unoq-ble-sensor.service, which serves the
# BME680's readings over Bluetooth LE. What is at stake: it refuses to install
# a unit whose program, or the D-Bus library that program needs, is not there
# yet; it switches Bluetooth back on, which TIER 2 of 10-optimize-board.sh had
# off, and says why; and it takes the serial port over from whichever of the
# other three owners the board runs - disabled, not only stopped, because two
# enabled units that conflict leave which one runs at boot to chance.
#
# What this cannot show: that BlueZ accepts the service, that the adapter
# advertises, or that a phone sees anything. That is the board's job, with a
# BME680 wired up.

setup() {
  load helpers/stub
  stub_setup

  # A copy of the checkout, so a test decides whether the venv has been built.
  # The unit names a document under docs/, which install_unit checks is there.
  REAL="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PROJECT="$BATS_TEST_TMPDIR/checkout"
  mkdir -p "$PROJECT/docs/reference"
  cp -r "$REAL/provision" "$REAL/python" "$PROJECT/"
  cp "$REAL/docs/reference/mpu.md" "$PROJECT/docs/reference/"
  STEP="$PROJECT/provision/68-ble-sensor.sh"

  export UNOQ_UNIT_DIR="$BATS_TEST_TMPDIR/etc/systemd/system"
  export UNOQ_RUNTIME_DIR="$BATS_TEST_TMPDIR/usr/local/lib/unoq"
  export UNOQ_ROOT="$BATS_TEST_TMPDIR/root"
  export UNOQ_IN_BOOTSTRAP=1
  UNOQ_USER="$(id -un)"
  export UNOQ_USER
  export FAKE_HOME="$BATS_TEST_TMPDIR/home"
  UNIT="$UNOQ_UNIT_DIR/unoq-ble-sensor.service"
  U=unoq-ble-sensor.service
  BT=bluetooth.service
  OTHERS="unoq-cpu-bars.service unoq-temp-log.service unoq-buildlight.service"

  FLAGS="$BATS_TEST_TMPDIR/flags"
  mkdir -p "$FLAGS"
  export FLAGS
  # BlueZ is installed and, as TIER 2 leaves it, disabled.
  : >"$FLAGS/unit-$BT"

  stub sleep
  stub_body id <<'SH'
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
SH
  stub_body getent <<'SH'
[ "$1" = passwd ] && { echo "$2:x:1000:1000::$FAKE_HOME:/bin/bash"; exit 0; }
exec /usr/bin/getent "$@"
SH
  # The same manager with a memory as tests/temp-log.bats, and a list of
  # installed units for unit_exists.
  stub_body systemctl <<'SH'
u="${*: -1}"
case "$1" in
  list-unit-files) [ -e "$FLAGS/unit-$2" ] && echo "$2 disabled"; exit 0 ;;
  cat) [ -e "$FLAGS/unit-$2" ]; exit ;;
  is-enabled) [ -e "$FLAGS/enabled-$u" ] ;;
  is-active) [ -e "$FLAGS/active-$u" ] ;;
  is-failed) [ -e "$FLAGS/failed-$u" ] ;;
  reset-failed) rm -f "$FLAGS/failed-$u"; exit 0 ;;
  show) echo 4242 ;;
  enable)
    [ -e "$FLAGS/wont-enable-$u" ] && exit 1
    : >"$FLAGS/enabled-$u"
    [ "$2" = --now ] && [ ! -e "$FLAGS/wont-start" ] && : >"$FLAGS/active-$u"
    exit 0
    ;;
  disable) rm -f "$FLAGS/enabled-$u"; [ "$2" = --now ] && rm -f "$FLAGS/active-$u"; exit 0 ;;
  *) exit 0 ;;
esac
SH
}

# with_venv - the entry point, and a python that can import jeepney unless
# $FLAGS/no-jeepney says otherwise.
with_venv() {
  mkdir -p "$PROJECT/.venv/bin"
  printf '#!/bin/bash\nexit 0\n' >"$PROJECT/.venv/bin/unoq-ble-sensor"
  printf '#!/bin/bash\n[ "$*" = "-c import jeepney" ] && [ ! -e "$FLAGS/no-jeepney" ]\n' \
    >"$PROJECT/.venv/bin/python"
  chmod +x "$PROJECT/.venv/bin/unoq-ble-sensor" "$PROJECT/.venv/bin/python"
}

# running <unit> - enabled and running, as its own step leaves it.
running() {
  : >"$FLAGS/enabled-$1"
  : >"$FLAGS/active-$1"
}

# rfkill <soft> - the board's Bluetooth radio, soft-blocked or not.
rfkill() {
  local r="$UNOQ_ROOT/sys/class/rfkill"
  mkdir -p "$r/rfkill0" "$r/rfkill1"
  echo bluetooth >"$r/rfkill0/type"
  echo hci0 >"$r/rfkill0/name"
  echo "$1" >"$r/rfkill0/soft"
  # The Wi-Fi radio, blocked: not this step's business.
  echo wlan >"$r/rfkill1/type"
  echo phy0 >"$r/rfkill1/name"
  echo 1 >"$r/rfkill1/soft"
}

# line <pattern> - the number of the first log line matching it.
line() { grep -nE "$1" "$STUB_LOG" | head -1 | cut -d: -f1; }

# reverts - the REVERT comments in the step's header, one command per line.
reverts() {
  awk '
    /^# REVERT:/ { if (buf != "") print buf; buf = substr($0, 11); inrev = 1; next }
    inrev && /^#  / { sub(/^# +/, ""); buf = buf " " $0; next }
    inrev { print buf; exit }
  ' "$STEP"
}

# --- before the venv --------------------------------------------------------

@test "no venv yet: the step stops, says which step builds it, and changes nothing" {
  running unoq-cpu-bars.service
  run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unoq-ble-sensor, or the jeepney it needs, missing"* ]]
  [[ "$output" == *"provision/user/35-python-venv.sh"* ]]
  [ ! -e "$UNIT" ]
  # Nothing switched: no Bluetooth, and the demo still has the port.
  [ ! -e "$FLAGS/enabled-$BT" ]
  [ -e "$FLAGS/active-unoq-cpu-bars.service" ]
  never_ran systemctl
}

@test "a venv without jeepney is the same refusal" {
  # An entry point from a venv built before the [ble] extra existed.
  with_venv
  : >"$FLAGS/no-jeepney"
  run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"jeepney it needs, missing"* ]]
  [[ "$output" == *"[ble] extra"* ]]
  [ ! -e "$UNIT" ]
  never_ran systemctl
}

@test "no BlueZ: the step stops and says what to install" {
  with_venv
  rm "$FLAGS/unit-$BT"
  run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"this needs BlueZ.  sudo apt install bluez"* ]]
  [ ! -e "$UNIT" ]
  refute ran_like '^systemctl (enable|disable)'
}

# --- the first run ----------------------------------------------------------

@test "a fresh board gets Bluetooth back and the unit, enabled and started" {
  with_venv
  run "$STEP"
  [ "$status" -eq 0 ]
  ran "systemctl enable --now $BT"
  [ -e "$FLAGS/active-$BT" ]
  [[ "$output" == *"bluetooth.service enabled and started: TIER 2 had it off"* ]]
  [ -f "$UNIT" ]
  ran "systemctl daemon-reload"
  ran "systemctl enable --now $U"
  [[ "$output" == *"running as PID 4242"* ]]
  # Bluetooth first: the unit Requires= it.
  [ "$(line "^systemctl enable --now $BT\$")" -lt "$(line "^systemctl enable --now $U\$")" ]
}

@test "Bluetooth already on is left alone" {
  with_venv
  running "$BT"
  run "$STEP"
  [ "$status" -eq 0 ]
  refute ran "systemctl enable --now $BT"
  [[ "$output" == *"bluetooth.service already enabled and running"* ]]
}

@test "Bluetooth enabled but stopped is started" {
  with_venv
  : >"$FLAGS/enabled-$BT"
  run "$STEP"
  [ "$status" -eq 0 ]
  ran "systemctl enable --now $BT"
  [ -e "$FLAGS/active-$BT" ]
}

@test "a Bluetooth that will not come up stops the step, before the sensor is installed" {
  with_venv
  : >"$FLAGS/wont-enable-$BT"
  running unoq-cpu-bars.service
  run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not enable bluetooth.service - check: journalctl -u bluetooth"* ]]
  [ ! -e "$UNIT" ]
  [ -e "$FLAGS/active-unoq-cpu-bars.service" ]
}

@test "a radio blocked with rfkill is a warning that says how to unblock it, and is not changed" {
  with_venv
  rfkill 1
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qE 'warn +hci0 is blocked by rfkill - unblock it: sudo rfkill unblock bluetooth' <<<"$output"
  [ "$(cat "$UNOQ_ROOT/sys/class/rfkill/rfkill0/soft")" = 1 ]
  # The blocked Wi-Fi radio is not mentioned.
  [[ "$output" != *"phy0"* ]]
}

@test "a radio that is not blocked is not mentioned" {
  with_venv
  rfkill 0
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" != *"rfkill"* ]]
}

@test "the unit runs the checkout's venv as the owner, needs BlueZ, and conflicts with every port owner" {
  with_venv
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qx "User=$UNOQ_USER" "$UNIT"
  grep -qx "Group=$UNOQ_USER" "$UNIT"
  grep -qx "ExecStart=$PROJECT/.venv/bin/unoq-ble-sensor" "$UNIT"
  grep -qx "EnvironmentFile=-/etc/unoq/ble-sensor.env" "$UNIT"
  grep -qx "Conflicts=unoq-cpu-bars.service unoq-temp-log.service unoq-buildlight.service" "$UNIT"
  grep -qx "Conflicts=unoq-mcu-serial.service" "$UNIT"
  grep -qx "Requires=unoq-link.service" "$UNIT"
  grep -qx "Requires=bluetooth.service" "$UNIT"
  grep -qx "After=bluetooth.service" "$UNIT"
  grep -qx "KillSignal=SIGINT" "$UNIT"
  refute grep -q "$UNOQ_RUNTIME_DIR" "$UNIT"
}

# --- the port ---------------------------------------------------------------

@test "each other port owner is disabled, not only stopped, before the sensor starts" {
  local other
  for other in $OTHERS; do
    with_venv
    rm -f "$FLAGS"/enabled-* "$FLAGS"/active-* "$UNIT"
    running "$other"
    : >"$STUB_LOG"
    run "$STEP"
    [ "$status" -eq 0 ]
    ran "systemctl disable --now $other"
    [ ! -e "$FLAGS/enabled-$other" ]
    [ ! -e "$FLAGS/active-$other" ]
    [ "$(line "^systemctl disable --now $other\$")" -lt "$(line "^systemctl enable --now $U\$")" ]
  done
}

@test "each owner taken off is named" {
  with_venv
  local other
  for other in $OTHERS; do running "$other"; done
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stopped and disabled the CPU-bars demo"* ]]
  [[ "$output" == *"stopped and disabled the temperature logger (its record is kept)"* ]]
  [[ "$output" == *"stopped and disabled the build light (its settings are kept)"* ]]
}

@test "a board with none of them has nothing of them touched" {
  with_venv
  run "$STEP"
  [ "$status" -eq 0 ]
  refute ran_like "^systemctl disable"
  [[ "$output" == *"unoq-cpu-bars is not enabled"* ]]
  [[ "$output" == *"unoq-temp-log is not enabled"* ]]
  [[ "$output" == *"unoq-buildlight is not enabled"* ]]
}

@test "an owner that will not stop stops the step, before the sensor is installed" {
  with_venv
  running unoq-temp-log.service
  stub_body systemctl <<'SH'
case "$1" in
  list-unit-files) echo "$2 disabled" ;;
  is-enabled) [ "${*: -1}" = unoq-temp-log.service ] ;;
  disable) exit 1 ;;
  *) exit 0 ;;
esac
SH
  run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not stop unoq-temp-log"* ]]
  [ ! -e "$UNIT" ]
}

@test "the way back is printed, and what to look for on a phone" {
  with_venv
  run "$STEP"
  [[ "$output" == *"sudo systemctl disable --now unoq-ble-sensor && sudo bash $PROJECT/provision/65-cpu-bars.sh"* ]]
  [[ "$output" == *"nRF Connect"* ]]
  [[ "$output" == *"Environmental Sensing: Temperature, Humidity, Pressure"* ]]
}

# --- the second run ---------------------------------------------------------

@test "a second run changes nothing" {
  with_venv
  running unoq-cpu-bars.service
  run "$STEP"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 changed,"* ]]
  refute ran "systemctl daemon-reload"
  refute ran_like '^systemctl (enable|start|restart|disable)'
}

@test "a sensor that gave up is cleared and started again, and says so" {
  with_venv
  run "$STEP"
  rm -f "$FLAGS/active-$U"
  : >"$FLAGS/failed-$U"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cleared the failed state unoq-ble-sensor was left in"* ]]
  reset="$(line "^systemctl reset-failed $U\$")"
  start="$(line "^systemctl enable --now $U\$")"
  [ -n "$reset" ] && [ -n "$start" ]
  [ "$reset" -lt "$start" ]
}

@test "a start that does not take is a warning that says where to look" {
  with_venv
  : >"$FLAGS/wont-start"
  running "$BT"
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qE 'warn +service is not running - check: journalctl -u unoq-ble-sensor' <<<"$output"
  [[ "$output" != *"running as PID"* ]]
}

# --- the way back -----------------------------------------------------------

@test "the REVERT lines stop the sensor, remove its unit, and switch Bluetooth off" {
  with_venv
  run "$STEP"
  [ -e "$FLAGS/enabled-$BT" ]
  mapfile -t cmds < <(reverts)
  [ "${#cmds[@]}" -eq 2 ]
  : >"$STUB_LOG"
  local cmd
  for cmd in "${cmds[@]}"; do
    cmd="${cmd//\/etc\/systemd\/system/$UNOQ_UNIT_DIR}"
    # The second carries a note in brackets; the command is before it.
    bash -c "${cmd%%(*}"
  done
  [ ! -e "$UNIT" ]
  [ ! -e "$FLAGS/enabled-$U" ]
  [ ! -e "$FLAGS/active-$U" ]
  ran "systemctl daemon-reload"
  [ ! -e "$FLAGS/enabled-$BT" ]
  [ ! -e "$FLAGS/active-$BT" ]
}
