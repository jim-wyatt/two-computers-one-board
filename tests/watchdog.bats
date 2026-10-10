#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# provision/80-watchdog.sh arms the hardware watchdog by writing one systemd
# drop-in and re-executing PID 1. What is at stake is a board that resets
# itself: armed when nobody asked, armed with a timeout too short to survive a
# busy moment, or re-executing the manager on every run for no reason.
#
# So most of what is tested is restraint - nothing written when there is no
# device, nothing written for a timeout that would loop the board, no re-exec
# when nothing changed - plus the one piece of honesty the step owes: it reads
# the manager's own answer back, and says so when the answer is "not armed".
#
# What this cannot show: that qcom_wdt accepts the timeout, that the board
# actually resets when PID 1 stops, or - the question the issue leaves open -
# that it does NOT reset during a long build in deep swap. That is the board's
# job, and nobody has done it yet.

setup() {
  load helpers/stub
  stub_setup

  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  WATCHDOG="$PROJECT/provision/80-watchdog.sh"

  # The script's own overrides, pointed away from /etc and /sys.
  export UNOQ_WATCHDOG_CONF_DIR="$BATS_TEST_TMPDIR/system.conf.d"
  export UNOQ_WATCHDOG_SYSFS="$BATS_TEST_TMPDIR/sys/class/watchdog"
  UNOQ_USER="$(id -un)"
  export UNOQ_USER
  unset UNOQ_WATCHDOG_SEC
  CONF="$UNOQ_WATCHDOG_CONF_DIR/50-unoq-watchdog.conf"

  FLAGS="$BATS_TEST_TMPDIR/flags"
  mkdir -p "$FLAGS"
  export FLAGS

  # need_root asks `id -u`. Everything else id is asked goes to the real one.
  stub_body id <<'SH'
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
SH

  # A manager with a memory: it reports 0 until it has been re-executed, as
  # the board does today, and the re-exec is what arms it. A test changes
  # that by touching a flag, not by rewriting the fake.
  stub_body systemctl <<'SH'
case "$1" in
  show)
    [ -e "$FLAGS/armed" ] && echo 30s || echo 0
    ;;
  daemon-reexec)
    [ -e "$FLAGS/reexec-fails" ] && exit 1
    [ -e "$FLAGS/reexec-has-no-effect" ] || : >"$FLAGS/armed"
    ;;
esac
exit 0
SH
}

# The device as the board reports it today.
have_device() {
  mkdir -p "$UNOQ_WATCHDOG_SYSFS/watchdog0"
  echo qcom_wdt >"$UNOQ_WATCHDOG_SYSFS/watchdog0/identity"
  echo 30 >"$UNOQ_WATCHDOG_SYSFS/watchdog0/timeout"
  echo inactive >"$UNOQ_WATCHDOG_SYSFS/watchdog0/state"
}

# refute <command...> - the command must fail. Not `! command`: bash exempts a
# negated command from `set -e`, so a bare `!` anywhere but the last line of a
# test asserts nothing.
refute() {
  if "$@"; then return 1; fi
}

reexecs() { grep -cx 'systemctl daemon-reexec' "$STUB_LOG" || true; }

# --- the drop-in ------------------------------------------------------------

@test "the drop-in sets RuntimeWatchdogSec=30s under [Manager], and nothing else" {
  have_device
  run bash "$WATCHDOG"
  [ "$status" -eq 0 ]
  [ -f "$CONF" ]
  # Comments aside, the file is exactly these two lines.
  [ "$(grep -v '^#' "$CONF")" = "[Manager]
RuntimeWatchdogSec=30s" ]
  [ "$(stat -c %a "$CONF")" = 644 ]
}

@test "systemd is re-executed, once, and the result is read back" {
  have_device
  run bash "$WATCHDOG"
  [ "$status" -eq 0 ]
  [ "$(reexecs)" -eq 1 ]
  refute ran_like '^systemctl daemon-reload'
  [[ "$output" == *"RuntimeWatchdogUSec=30s"* ]]
  [[ "$output" == *"2 changed"* ]]
}

@test "a second run changes nothing and does not re-execute" {
  have_device
  run bash "$WATCHDOG"
  [ "$status" -eq 0 ]
  before="$(stat -c %Y.%i "$CONF")"

  run bash "$WATCHDOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 changed"* ]]
  [ "$(reexecs)" -eq 1 ]
  [ "$(stat -c %Y.%i "$CONF")" = "$before" ]
}

@test "the issue's warning is in the output every time" {
  have_device
  run bash "$WATCHDOG"
  [[ "$output" == *"swapped hard is worse than none"* ]]
  [[ "$output" == *"not been tested under that load"* ]]
  run bash "$WATCHDOG"
  [[ "$output" == *"swapped hard is worse than none"* ]]
}

# --- restraint --------------------------------------------------------------

@test "no watchdog device: skipped cleanly, nothing written, systemd left alone" {
  mkdir -p "$UNOQ_WATCHDOG_SYSFS"
  run bash "$WATCHDOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no hardware watchdog"* ]]
  [[ "$output" == *"0 changed"* ]]
  [ ! -e "$UNOQ_WATCHDOG_CONF_DIR" ]
  never_ran systemctl
}

@test "no sysfs directory at all is the same clean skip" {
  run bash "$WATCHDOG"
  [ "$status" -eq 0 ]
  [ ! -e "$UNOQ_WATCHDOG_CONF_DIR" ]
  never_ran systemctl
}

@test "a timeout short enough to loop the board is refused, and nothing is written" {
  have_device
  UNOQ_WATCHDOG_SEC=5 run bash "$WATCHDOG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"under 10s"* ]]
  [ ! -e "$CONF" ]
  never_ran systemctl
}

@test "0 and 'off' are refused: disarming is what the revert is for" {
  have_device
  UNOQ_WATCHDOG_SEC=0 run bash "$WATCHDOG"
  [ "$status" -ne 0 ]
  UNOQ_WATCHDOG_SEC=off run bash "$WATCHDOG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"whole number of seconds"* ]]
  [ ! -e "$CONF" ]
  never_ran systemctl
}

@test "it refuses to run without root" {
  have_device
  stub_body id <<'SH'
[ "${1:-}" = "-u" ] && { echo 1000; exit 0; }
exec /usr/bin/id "$@"
SH
  run bash "$WATCHDOG"
  [ "$status" -ne 0 ]
  [ ! -e "$CONF" ]
}

# --- the tunable ------------------------------------------------------------

@test "UNOQ_WATCHDOG_SEC is honoured" {
  have_device
  UNOQ_WATCHDOG_SEC=45 run bash "$WATCHDOG"
  [ "$status" -eq 0 ]
  grep -qx 'RuntimeWatchdogSec=45s' "$CONF"
  refute grep -q '30s' "$CONF"
}

@test "changing the timeout on a later run rewrites the file and re-executes again" {
  have_device
  run bash "$WATCHDOG"
  [ "$status" -eq 0 ]
  UNOQ_WATCHDOG_SEC=60 run bash "$WATCHDOG"
  [ "$status" -eq 0 ]
  grep -qx 'RuntimeWatchdogSec=60s' "$CONF"
  [ "$(reexecs)" -eq 2 ]
}

# --- the result is read back, not assumed -----------------------------------

@test "file in place but manager not armed: the re-exec an interrupted run missed is done" {
  have_device
  run bash "$WATCHDOG"
  [ "$status" -eq 0 ]
  rm "$FLAGS/armed" # as if the first run had died before the re-exec

  run bash "$WATCHDOG"
  [ "$status" -eq 0 ]
  [ "$(reexecs)" -eq 2 ]
  [[ "$output" == *"1 changed"* ]]
}

@test "a manager that still reports no watchdog after the re-exec is a failure, with the way out" {
  have_device
  : >"$FLAGS/reexec-has-no-effect"
  run bash "$WATCHDOG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not report a runtime watchdog"* ]]
  [[ "$output" == *"rm $CONF"* ]]
}

@test "a failed re-exec is a failure, and says the file will still be read at boot" {
  have_device
  : >"$FLAGS/reexec-fails"
  run bash "$WATCHDOG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"daemon-reexec failed"* ]]
  [[ "$output" == *"next boot"* ]]
}
