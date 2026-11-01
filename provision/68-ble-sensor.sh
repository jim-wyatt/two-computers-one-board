#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Optional: the board as a Bluetooth sensor - a BME680's readings, to a phone.
#
#   sudo bash ~/two-computers-one-board/provision/68-ble-sensor.sh
#
# Idempotent. Installs unoq-ble-sensor.service, which reads the BME680 on the
# header's I2C through the MCU (`app env`) and serves temperature, humidity and
# pressure as the GATT Environmental Sensing Service. See docs/reference/mpu.md
# for the wiring and what a phone sees.
#
# IT TURNS BLUETOOTH BACK ON. TIER 2 of 10-optimize-board.sh disables
# bluetooth.service, because nothing else here uses it; this is the one thing
# that does, so this step enables it, and 10-optimize-board.sh leaves it on for
# as long as unoq-ble-sensor.service is enabled. That is the whole of the
# exception: blueman-mechanism stays off, and nothing pairs.
#
# Like 65, 66 and 67 it holds /dev/ttyHS1 while it runs, so it is their
# alternative: THIS STEP STOPS AND DISABLES THE CPU-BARS DEMO, THE TEMPERATURE
# LOGGER AND THE BUILD LIGHT, whichever the board runs. To go back to the demo:
#
#     sudo systemctl disable --now unoq-ble-sensor
#     sudo bash ~/two-computers-one-board/provision/65-cpu-bars.sh
#
# Settings, if you want other than the defaults: UNOQ_BLE_SENSOR_NAME ("UNO Q",
# the name a phone lists), UNOQ_BLE_SENSOR_INTERVAL (10 s) and
# UNOQ_BLE_SENSOR_ADAPTER (hci0), in /etc/unoq/ble-sensor.env, which nothing
# writes. Restart the unit after editing it.
#
# The firmware has to have `app env`, and a BME680 wired to the header. With
# an older firmware every start fails and the journal says to update it; with
# no BME680 the service stays up and a phone's read says there is no sensor.
#
# REVERT: systemctl disable --now unoq-ble-sensor.service &&
#         rm /etc/systemd/system/unoq-ble-sensor.service && systemctl daemon-reload
# REVERT: systemctl disable --now bluetooth.service   (Bluetooth off again, as TIER 2
#         has it; the next run of 10-optimize-board.sh does this by itself once
#         the sensor is no longer enabled)
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
need_root

U=unoq-ble-sensor.service

step "prerequisites"
if [ -x "$PROJECT/.venv/bin/unoq-ble-sensor" ] &&
  "$PROJECT/.venv/bin/python" -c 'import jeepney' 2>/dev/null; then
  skip "unoq-ble-sensor entry point and its D-Bus library (jeepney) present"
else
  fail "$PROJECT/.venv/bin/unoq-ble-sensor, or the jeepney it needs, missing.
  Build the venv first:  bash $PROJECT/provision/user/35-python-venv.sh
  (a new entry point and the [ble] extra, so an existing venv needs the
   editable install re-run, which that step does)"
fi
unit_exists bluetooth.service ||
  fail "bluetooth.service is not installed: this needs BlueZ.  sudo apt install bluez"

step "Bluetooth (the exception to TIER 2)"
# enable_unit's skip says "already enabled and running"; what is new is said
# here, so the journal of a provisioning run shows why Bluetooth came back.
if systemctl is-enabled --quiet bluetooth.service 2>/dev/null &&
  systemctl is-active --quiet bluetooth.service; then
  skip "bluetooth.service already enabled and running"
else
  systemctl enable --now bluetooth.service >/dev/null 2>&1 ||
    fail "could not enable bluetooth.service - check: journalctl -u bluetooth -n 30"
  did "bluetooth.service enabled and started: TIER 2 had it off, and the sensor needs it"
fi
# A radio switched off with rfkill comes up as an adapter that will not power
# on, and the sensor's start fails with BlueZ's "Blocked through rfkill". Only
# said, not changed: blocking it was somebody's decision.
for r in "$SYSROOT"/sys/class/rfkill/rfkill*; do
  [ "$(cat "$r/type" 2>/dev/null)" = bluetooth ] || continue
  if [ "$(cat "$r/soft" 2>/dev/null)" = 1 ]; then
    warn "$(cat "$r/name" 2>/dev/null) is blocked by rfkill - unblock it: sudo rfkill unblock bluetooth"
  fi
done

step "the serial port"
# The port has one owner. Off before this is started, so it is not the
# sensor that loses the port.
for other in unoq-cpu-bars.service unoq-temp-log.service unoq-buildlight.service; do
  if systemctl is-enabled --quiet "$other" 2>/dev/null; then
    systemctl disable --now "$other" >/dev/null 2>&1 ||
      fail "could not stop ${other%.service}, which holds the serial port"
    case "$other" in
      unoq-cpu-bars.service) did "stopped and disabled the CPU-bars demo: the port to the MCU has one owner" ;;
      unoq-temp-log.service) did "stopped and disabled the temperature logger (its record is kept): the port to the MCU has one owner" ;;
      *) did "stopped and disabled the build light (its settings are kept): the port to the MCU has one owner" ;;
    esac
  else
    skip "${other%.service} is not enabled"
  fi
done

step "$U"
install_unit "$PROJECT/python/$U"
# As in 65: a sensor that gave up on a silent MCU - or on a firmware without
# `app env`, which this step often follows the fix for - is in the failed
# state, and its count of recent starts outlives that state.
WAS_FAILED=0
systemctl is-failed --quiet "$U" 2>/dev/null && WAS_FAILED=1
systemctl reset-failed "$U" >/dev/null 2>&1 || true
[ "$WAS_FAILED" = 1 ] &&
  did "cleared the failed state unoq-ble-sensor was left in (it had stopped retrying)"
enable_unit "$U"

step "verify"
sleep 2
if systemctl is-active --quiet "$U"; then
  skip "running as PID $(systemctl show "$U" -p MainPID --value)"
else
  warn "service is not running - check: journalctl -u unoq-ble-sensor -n 30"
fi

summary
echo "Phone:  nRF Connect (or any BLE scanner): SCANNER, 'UNO Q' (or UNOQ_BLE_SENSOR_NAME),"
echo "        CONNECT, then Environmental Sensing: Temperature, Humidity, Pressure"
echo "Logs:   journalctl -u unoq-ble-sensor -f"
echo "Back to the CPU-bars demo:"
echo "        sudo systemctl disable --now unoq-ble-sensor && sudo bash $PROJECT/provision/65-cpu-bars.sh"
