#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# provision/55-purge-arduino.sh removes Arduino's Debian packages. Its packages
# come back with one apt-get, but two things do not: /opt/openocd, which no
# package owns and is the only way to flash the MCU, and the stock MCU
# firmware, which is Arduino's build and is in neither this repo nor apt. So
# the step refuses before it removes anything when either is missing, and
# checks openocd again afterwards.
#
# What this cannot show: that apt really leaves /opt/openocd alone. That was
# measured on a board (`dpkg -S /opt/openocd` finds nothing); here apt is a stub.

setup() {
  load helpers/stub
  stub_setup

  REAL="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  STEP="$REAL/provision/55-purge-arduino.sh"

  UNOQ_USER="$(id -un)"
  export UNOQ_USER
  export FAKE_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$FAKE_HOME"
  export UNOQ_IN_BOOTSTRAP=1
  export UNOQ_RUN_DIR="$BATS_TEST_TMPDIR/run"
  mkdir -p "$UNOQ_RUN_DIR"
  BACKUP="$FAKE_HOME/uno-q-backup"
  CORE="$FAKE_HOME/.arduino15/packages/arduino/hardware/zephyr/0.55.2"

  FLAGS="$BATS_TEST_TMPDIR/flags"
  mkdir -p "$FLAGS"
  export FLAGS

  # openocd that works until a test says the purge broke it.
  export OCD_ROOT="$BATS_TEST_TMPDIR/opt/openocd"
  mkdir -p "$OCD_ROOT/bin"
  cat >"$OCD_ROOT/bin/openocd" <<'SH'
#!/bin/bash
[ -e "$FLAGS/ocd-broken" ] && exit 127
echo "Open On-Chip Debugger 0.12.0+dev-arduino" >&2
SH
  chmod +x "$OCD_ROOT/bin/openocd"

  stub_body id <<'SH'
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
SH
  stub_body getent <<'SH'
[ "$1" = passwd ] && { echo "$2:x:1000:1000::$FAKE_HOME:/bin/bash"; exit 0; }
exec /usr/bin/getent "$@"
SH
  stub_body runuser <<'SH'
while [ "$1" != "--" ]; do shift; done
shift
exec "$@"
SH
  # A package database with a memory: a package is installed while its flag
  # file exists. Removing one can break openocd, when a test says it does.
  stub_body dpkg-query <<'SH'
[ -e "$FLAGS/pkg-${*: -1}" ] && echo "install ok installed"
exit 0
SH
  stub_body apt-get <<'SH'
case "$1" in
  remove)
    for a in "$@"; do rm -f "$FLAGS/pkg-$a"; done
    [ -e "$FLAGS/purge-breaks-ocd" ] && : >"$FLAGS/ocd-broken"
    ;;
  -s) [ -e "$FLAGS/orphans" ] && echo "Remv libfoo [1.0]" ;;
  autoremove) rm -f "$FLAGS/orphans" ;;
esac
exit 0
SH
}

PKGS=(arduino-app-cli arduino-app-lab arduino-router arduino-cli)

# installed <pkg>... - mark packages installed.
installed() {
  local p
  for p in "$@"; do : >"$FLAGS/pkg-$p"; done
}

# stock_firmware - the .hex where core 0.55.2 keeps it.
stock_firmware() {
  mkdir -p "$CORE/firmwares"
  echo ":00000001FF" >"$CORE/firmwares/zephyr-arduino_uno_q_stm32u585xx.hex"
}

# --- what it refuses --------------------------------------------------------

@test "no openocd: it refuses, and removes nothing" {
  installed "${PKGS[@]}"
  stock_firmware
  rm "$OCD_ROOT/bin/openocd"
  run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already missing - refusing to purge"* ]]
  [[ "$output" == *"build-openocd.sh --promote"* ]]
  never_ran apt-get
  [ -e "$FLAGS/pkg-arduino-cli" ]
}

@test "no stock firmware anywhere: it refuses, removes nothing, and says how to find it" {
  installed "${PKGS[@]}"
  run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no stock MCU firmware found"* ]]
  [[ "$output" == *"UNOQ_ALLOW_NO_STOCK_FW=1"* ]]
  never_ran apt-get
  [ -e "$FLAGS/pkg-arduino-cli" ]
}

@test "UNOQ_ALLOW_NO_STOCK_FW=1 purges without it, and warns that it is gone for good" {
  installed "${PKGS[@]}"
  UNOQ_ALLOW_NO_STOCK_FW=1 run "$STEP"
  [ "$status" -eq 0 ]
  grep -qE 'warn +no stock .hex found, and UNOQ_ALLOW_NO_STOCK_FW=1' <<<"$output"
  [[ "$output" == *"permanently"* ]]
  ran "apt-get remove -y ${PKGS[*]}"
}

# --- the first run ----------------------------------------------------------

@test "the stock firmware is copied aside before anything is removed" {
  installed "${PKGS[@]}"
  stock_firmware
  run "$STEP"
  [ "$status" -eq 0 ]
  cmp -s "$CORE/firmwares/zephyr-arduino_uno_q_stm32u585xx.hex" \
    "$BACKUP/zephyr-arduino_uno_q_stm32u585xx.hex"
  ran "apt-get remove -y ${PKGS[*]}"
  [[ "$output" == *"removed: ${PKGS[*]}"* ]]
}

@test "a copy already in the backup is enough, with the original gone" {
  # A factory restore puts the original back; until then the copy is all
  # there is, and it is what the refusal is protecting.
  installed "${PKGS[@]}"
  mkdir -p "$BACKUP"
  echo ":00000001FF" >"$BACKUP/stock.hex"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stock MCU firmware already saved in $BACKUP"* ]]
  ran "apt-get remove -y ${PKGS[*]}"
}

@test "only the packages that are installed are removed" {
  installed arduino-app-cli arduino-cli
  stock_firmware
  run "$STEP"
  [ "$status" -eq 0 ]
  ran "apt-get remove -y arduino-app-cli arduino-cli"
}

@test "orphaned dependencies are autoremoved, and only when there are some" {
  installed "${PKGS[@]}"
  stock_firmware
  : >"$FLAGS/orphans"
  run "$STEP"
  [ "$status" -eq 0 ]
  ran "apt-get autoremove -y"
  [[ "$output" == *"autoremoved orphaned dependencies"* ]]
}

# --- the second run ---------------------------------------------------------

@test "a second run finds nothing to remove and changes nothing" {
  installed "${PKGS[@]}"
  stock_firmware
  run "$STEP"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 changed,"* ]]
  [[ "$output" == *"already absent"* ]]
  [[ "$output" == *"nothing to autoremove"* ]]
  refute ran_like '^apt-get (remove|autoremove)'
}

# --- afterwards -------------------------------------------------------------

@test "openocd broken by the purge is a failure that says how to restore it" {
  installed "${PKGS[@]}"
  stock_firmware
  : >"$FLAGS/purge-breaks-ocd"
  run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"openocd is GONE"* ]]
  [[ "$output" == *"$BACKUP/openocd"* ]]
}

@test "openocd still working afterwards is reported, with its version" {
  installed "${PKGS[@]}"
  stock_firmware
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"flashing capability intact: Open On-Chip Debugger 0.12.0+dev-arduino"* ]]
}

# --- the way back -----------------------------------------------------------

@test "the way back reinstalls exactly the packages the step removes" {
  # A package removed and missing from that line is one nobody gets back.
  back="$(awk '
    /^# TO GO BACK:/ { inb = 1 }
    inb && /^#/ { print; next }
    inb { exit }
  ' "$STEP" | grep -v 'restore-arduino-firmware' | grep -oE 'arduino-[a-z-]+' | sort | tr '\n' ' ')"
  removed="$(grep -E '^apt_remove ' "$STEP" | cut -d' ' -f2- | tr ' ' '\n' | sort | tr '\n' ' ')"
  [ -n "$removed" ]
  [ "$back" = "$removed" ]
}
