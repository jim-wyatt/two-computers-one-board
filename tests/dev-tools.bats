#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# provision/15-dev-tools.sh installs what building needs (gcc, make, wget,
# clangd) and switches off what holds the MCU's serial port: Arduino's
# services, Arduino's bootloader burner, and Docker. What is at stake is the
# port. A service reported as stopped that something started again, or one
# still enabled for the next boot, leaves /dev/ttyHS1 held and every MCU tool
# failing with "device busy", so the step says so instead of reporting `ok`.
#
# The board's paths are under UNOQ_ROOT here, so the step sees this test's
# /dev/ttyHS1 and writes this test's /usr/bin.
#
# What this cannot show: that apt installs a working compiler, or that the
# port is free on a real board. That is the board's job.

setup() {
  load helpers/stub
  stub_setup

  REAL="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  STEP="$REAL/provision/15-dev-tools.sh"

  export UNOQ_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$UNOQ_ROOT/usr/bin" "$UNOQ_ROOT/dev"
  : >"$UNOQ_ROOT/dev/ttyHS1"
  TTY="$UNOQ_ROOT/dev/ttyHS1"
  export UNOQ_RUN_DIR="$BATS_TEST_TMPDIR/run"
  mkdir -p "$UNOQ_RUN_DIR"
  export UNOQ_IN_BOOTSTRAP=1
  UNOQ_USER="$(id -un)"
  export UNOQ_USER
  export FAKE_HOME="$BATS_TEST_TMPDIR/home"

  FLAGS="$BATS_TEST_TMPDIR/flags"
  mkdir -p "$FLAGS"
  export FLAGS

  stub_body id <<'SH'
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
SH
  stub_body getent <<'SH'
[ "$1" = passwd ] && { echo "$2:x:1000:1000::$FAKE_HOME:/bin/bash"; exit 0; }
exec /usr/bin/getent "$@"
SH
  # A package database with a memory. Installing clangd-N puts the binary
  # where Debian's package does, versioned, under the test's /usr/bin.
  stub_body dpkg-query <<'SH'
[ -e "$FLAGS/pkg-${*: -1}" ] && echo "install ok installed"
exit 0
SH
  stub_body apt-get <<'SH'
[ "$1" = install ] || exit 0
for a in "$@"; do
  case "$a" in
    -*) ;;
    install) ;;
    *)
      : >"$FLAGS/pkg-$a"
      case "$a" in clangd*)
        printf '#!/bin/bash\n' >"$UNOQ_ROOT/usr/bin/$a"
        chmod +x "$UNOQ_ROOT/usr/bin/$a"
        ;;
      esac
      ;;
  esac
done
SH
  stub_body apt-cache <<'SH'
[ -e "$FLAGS/avail-$2" ]
SH
  # Who holds the port: $FLAGS/holders is "pid name" per line.
  stub_body fuser <<'SH'
[ -s "$FLAGS/holders" ] || exit 1
printf ' %s' $(cut -d' ' -f1 "$FLAGS/holders")
SH
  stub_body ps <<'SH'
cut -d' ' -f2 "$FLAGS/holders"
SH
  # A manager with a memory. A unit exists while $FLAGS/unit-<u> does.
  # sticky-<u>: something starts it again. stays-enabled-<u>: disable does
  # not take, as when a unit is enabled from somewhere disable cannot reach.
  stub_body systemctl <<'SH'
u="${*: -1}"
case "$1" in
  list-unit-files) [ -e "$FLAGS/unit-$2" ] && echo "$2 enabled"; exit 0 ;;
  cat) [ -e "$FLAGS/unit-$2" ]; exit ;;
  is-enabled)
    [ -e "$FLAGS/enabled-$u" ] && { echo enabled; exit 0; }
    echo disabled
    exit 1
    ;;
  is-active) [ -e "$FLAGS/active-$u" ]; exit ;;
  is-failed) [ -e "$FLAGS/failed-$u" ]; exit ;;
  reset-failed) rm -f "$FLAGS/failed-$u" ;;
  disable)
    [ -e "$FLAGS/stays-enabled-$u" ] || rm -f "$FLAGS/enabled-$u"
    [ "$2" = --now ] && [ ! -e "$FLAGS/sticky-$u" ] && rm -f "$FLAGS/active-$u"
    ;;
  enable)
    shift
    now=0
    [ "$1" = --now ] && { now=1; shift; }
    for v in "$@"; do
      : >"$FLAGS/enabled-$v"
      [ "$now" = 1 ] && : >"$FLAGS/active-$v"
    done
    ;;
esac
exit 0
SH
}

ARDUINO="arduino-router-serial.path arduino-router-serial.service arduino-router.service arduino-app-cli.service arduino-avahi-serial.service"
DOCKER="docker.service docker.socket containerd.service"
BURNER="arduino-burn-bootloader.service"

# stock_board - every unit the step switches off, there, enabled and running,
# and clangd-19 to be had from apt.
stock_board() {
  local u
  for u in $ARDUINO $DOCKER $BURNER; do
    : >"$FLAGS/unit-$u"
    : >"$FLAGS/enabled-$u"
    : >"$FLAGS/active-$u"
  done
  : >"$FLAGS/avail-clangd-19"
}

# with_clangd - a clangd on PATH, as a board that already has one.
with_clangd() {
  stub clangd 0 "Debian clangd version 19.1.7"
}

# without_clangd - PATH with every program the machine has, except clangd.
# The board running these tests has one in /usr/bin, which would otherwise
# answer `command -v clangd` for the step.
without_clangd() {
  local d f n
  SYSBIN="$BATS_TEST_TMPDIR/sysbin"
  mkdir -p "$SYSBIN"
  for d in /usr/local/bin /usr/bin /bin; do
    for f in "$d"/*; do
      n="${f##*/}"
      case "$n" in clangd*) continue ;; esac
      [ -e "$SYSBIN/$n" ] || ln -s "$f" "$SYSBIN/$n"
    done
  done
  PATH="$STUB_DIR:$SYSBIN"
}

# revert <step heading> - the REVERT comment above that part of the step, as
# one line: "# REVERT:" and the "#" and backslash of each continuation dropped.
revert() {
  awk -v want="$1" '
    /^# REVERT:/ { buf = substr($0, 11); inrev = 1; next }
    inrev && /^#  / { sub(/^# +/, ""); buf = buf " " $0; next }
    { inrev = 0 }
    /^step "/ && buf != "" { if (index($0, "\"" want "\"")) { print buf; exit } buf = "" }
  ' "$STEP" | tr -d '\134'
}

# --- the first run ----------------------------------------------------------

@test "a stock board gets its compiler and wget, and everything holding the port switched off" {
  stock_board
  with_clangd
  run "$STEP"
  [ "$status" -eq 0 ]
  ran_like '^apt-get install -y --no-install-recommends gcc make$'
  ran_like '^apt-get install -y --no-install-recommends wget$'
  local u
  for u in $ARDUINO $DOCKER $BURNER; do
    ran "systemctl disable --now $u"
    [ ! -e "$FLAGS/enabled-$u" ]
    [ ! -e "$FLAGS/active-$u" ]
  done
  [[ "$output" == *"$TTY is free"* ]]
}

@test "the trigger is switched off before what it starts, and that before what it needs" {
  # The path unit starts arduino-router-serial, which Requires= the router.
  # Stop the router first and the pair is running again before the next line.
  stock_board
  with_clangd
  run "$STEP"
  path="$(grep -n '^systemctl disable --now arduino-router-serial.path$' "$STUB_LOG" | cut -d: -f1)"
  serial="$(grep -n '^systemctl disable --now arduino-router-serial.service$' "$STUB_LOG" | cut -d: -f1)"
  router="$(grep -n '^systemctl disable --now arduino-router.service$' "$STUB_LOG" | cut -d: -f1)"
  [ -n "$path" ] && [ -n "$serial" ] && [ -n "$router" ]
  [ "$path" -lt "$serial" ]
  [ "$serial" -lt "$router" ]
}

# --- clangd -----------------------------------------------------------------

@test "a clangd already on PATH is left alone" {
  stock_board
  with_clangd
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"clangd present: Debian clangd version 19.1.7"* ]]
  refute ran_like '^apt-get install .*clangd'
  [ ! -e "$UNOQ_ROOT/usr/bin/clangd" ]
}

@test "no clangd: the newest versioned one is installed, under the name editors look for" {
  stock_board
  : >"$FLAGS/avail-clangd-17"
  : >"$FLAGS/avail-clangd-18"
  rm "$FLAGS/avail-clangd-19"
  without_clangd
  run "$STEP"
  [ "$status" -eq 0 ]
  ran_like '^apt-get install -y --no-install-recommends clangd-18$'
  [ "$(readlink "$UNOQ_ROOT/usr/bin/clangd")" = /usr/bin/clangd-18 ]
  [[ "$output" == *"/usr/bin/clangd -> clangd-18"* ]]
}

@test "no versioned clangd to be had: the unversioned package, and no link" {
  # A later image ships some other version, or only the plain name. Asking
  # for a pinned name there is a 404 that stops the step.
  stock_board
  rm "$FLAGS/avail-clangd-19"
  without_clangd
  run "$STEP"
  [ "$status" -eq 0 ]
  ran_like '^apt-get install -y --no-install-recommends clangd$'
  [ ! -L "$UNOQ_ROOT/usr/bin/clangd" ]
}

# --- the second run ---------------------------------------------------------

@test "a second run changes nothing" {
  stock_board
  with_clangd
  run "$STEP"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 changed,"* ]]
  refute ran_like '^apt-get install'
  refute ran_like '^systemctl disable'
}

@test "a board without Arduino's services or Docker says so, and is not an error" {
  with_clangd
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"arduino-router.service not present"* ]]
  [[ "$output" == *"docker.service not present"* ]]
  refute ran_like '^systemctl disable'
}

@test "Docker purged by 56-slim-root.sh is not an error, and a re-run is still clean" {
  # 56 removes the packages, unit files and all. This step still asks for
  # the units to be switched off on every run, so it must take their absence
  # as done, on the first run after the purge and every one after it.
  stock_board
  with_clangd
  for u in $DOCKER; do rm -f "$FLAGS/unit-$u" "$FLAGS/enabled-$u" "$FLAGS/active-$u"; done
  run "$STEP"
  [ "$status" -eq 0 ]
  for u in $DOCKER; do
    [[ "$output" == *"$u not present"* ]]
    refute ran "systemctl disable --now $u"
  done
  ran "systemctl disable --now arduino-router.service"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 changed,"* ]]
  [[ "$output" == *"docker.service not present"* ]]
}

# --- when switching off does not take ---------------------------------------

@test "a router something starts again is a warning about the port, not 'stopped'" {
  stock_board
  with_clangd
  : >"$FLAGS/sticky-arduino-router.service"
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qE 'warn +arduino-router.service is still running after being stopped' <<<"$output"
  grep -qE 'warn +the MCU.s serial port \(/dev/ttyHS1\) may still be held' <<<"$output"
  [[ "$output" != *"arduino-router.service stopped and disabled"* ]]
}

@test "a bootloader burner still enabled is a warning that it may replace the firmware" {
  # It is a oneshot. Stopping it does nothing to the chip; only disabling it
  # keeps it from burning Arduino's bootloader over this firmware at the next
  # boot.
  stock_board
  with_clangd
  : >"$FLAGS/stays-enabled-$BURNER"
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qE "warn +$BURNER stopped, but is still enabled" <<<"$output"
  grep -qE 'warn +it may run at the next boot and replace the firmware on the MCU' <<<"$output"
}

# --- the port ---------------------------------------------------------------

@test "something else holding the port is a warning that names it" {
  stock_board
  with_clangd
  echo "4242 tio" >"$FLAGS/holders"
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qE "warn +$TTY held by PID\(s\) 4242: tio" <<<"$output"
}

@test "the port held by this project's demo alone is not a warning" {
  stock_board
  with_clangd
  echo "4242 unoq-cpu-bars" >"$FLAGS/holders"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$TTY is held by unoq-cpu-bars, this project's demo, and by nothing else"* ]]
  refute grep -qE 'warn .*held by PID' <<<"$output"
}

@test "no serial port at all is a warning" {
  stock_board
  with_clangd
  rm "$TTY"
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qE "warn +$TTY does not exist - is this an UNO Q\?" <<<"$output"
}

# --- the way back -----------------------------------------------------------

@test "the REVERT line for the Arduino services brings back every one the step switches off" {
  stock_board
  with_clangd
  run "$STEP"
  cmd="$(revert "Arduino services")"
  [ -n "$cmd" ]
  : >"$STUB_LOG"
  bash -c "$cmd"
  local u
  for u in $ARDUINO; do
    if [ ! -e "$FLAGS/enabled-$u" ] && [ ! -e "$FLAGS/enabled-${u%.service}" ]; then
      echo "the REVERT line leaves $u switched off: $cmd"
      false
    fi
  done
}

@test "the REVERT line for Docker brings back every unit the step switches off" {
  stock_board
  with_clangd
  run "$STEP"
  cmd="$(revert "Docker")"
  [ -n "$cmd" ]
  bash -c "$cmd"
  local u
  for u in $DOCKER; do
    if [ ! -e "$FLAGS/enabled-$u" ] && [ ! -e "$FLAGS/enabled-${u%.service}" ]; then
      echo "the REVERT line leaves $u switched off: $cmd"
      false
    fi
  done
}

@test "the REVERT lines for the packages remove what the step installed" {
  [ "$(revert "host C compiler")" = "apt-get remove -y gcc make" ]
  [ "$(revert "wget (the Zephyr SDK installer needs it)")" = "apt-get remove -y wget" ]
}
