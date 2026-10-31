#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# provision/65-cpu-bars.sh installs unoq-cpu-bars.service, the demo that shows
# host CPU load on the LED matrix. What is at stake is small but specific: it
# refuses to install a unit whose program is not there yet, it runs as the
# owner from the checkout's venv, and a demo that gave up on a silent MCU is
# given its retries back, because this step usually runs right after flashing
# fixed whatever it gave up on.
#
# What this cannot show: that the matrix lights, or that the service holds
# /dev/ttyHS1. That is the board's job.

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
  STEP="$PROJECT/provision/65-cpu-bars.sh"

  export UNOQ_UNIT_DIR="$BATS_TEST_TMPDIR/etc/systemd/system"
  export UNOQ_RUNTIME_DIR="$BATS_TEST_TMPDIR/usr/local/lib/unoq"
  # The end-of-run warnings read the board's own /etc/systemd/system. Under
  # bootstrap they are said once, at the end, and not by this step.
  export UNOQ_IN_BOOTSTRAP=1
  UNOQ_USER="$(id -un)"
  export UNOQ_USER
  export FAKE_HOME="$BATS_TEST_TMPDIR/home"
  UNIT="$UNOQ_UNIT_DIR/unoq-cpu-bars.service"
  U=unoq-cpu-bars.service

  FLAGS="$BATS_TEST_TMPDIR/flags"
  mkdir -p "$FLAGS"
  export FLAGS

  stub sleep
  stub_body id <<'SH'
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
SH
  stub_body getent <<'SH'
[ "$1" = passwd ] && { echo "$2:x:1000:1000::$FAKE_HOME:/bin/bash"; exit 0; }
exec /usr/bin/getent "$@"
SH
  # A manager with a memory: enabled and running once asked, failed when a
  # test says so, and a start that does not take when a test says that.
  stub_body systemctl <<'SH'
u="${*: -1}"
case "$1" in
  is-enabled) [ -e "$FLAGS/enabled-$u" ] ;;
  is-active) [ -e "$FLAGS/active-$u" ] ;;
  is-failed) [ -e "$FLAGS/failed-$u" ] ;;
  reset-failed) rm -f "$FLAGS/failed-$u"; exit 0 ;;
  show) echo 4242 ;;
  enable)
    : >"$FLAGS/enabled-$u"
    [ "$2" = --now ] && [ ! -e "$FLAGS/wont-start" ] && : >"$FLAGS/active-$u"
    exit 0
    ;;
  disable) rm -f "$FLAGS/enabled-$u"; [ "$2" = --now ] && rm -f "$FLAGS/active-$u"; exit 0 ;;
  *) exit 0 ;;
esac
SH
}

# with_venv - the venv's entry point, as 35-python-venv.sh leaves it.
with_venv() {
  mkdir -p "$PROJECT/.venv/bin"
  printf '#!/bin/bash\nexit 0\n' >"$PROJECT/.venv/bin/unoq-cpu-bars"
  chmod +x "$PROJECT/.venv/bin/unoq-cpu-bars"
}

# revert - the REVERT comment in the step's header, as one line: "# REVERT:"
# and the "#" of each continuation dropped.
revert() {
  awk '
    /^# REVERT:/ { buf = substr($0, 11); inrev = 1; next }
    inrev && /^#  / { sub(/^# +/, ""); buf = buf " " $0; next }
    inrev { print buf; exit }
  ' "$STEP"
}

# --- before the venv --------------------------------------------------------

@test "no venv yet: the step stops, says which step builds it, and installs nothing" {
  # A unit installed now would fail at every boot with 203/EXEC.
  run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unoq-cpu-bars missing"* ]]
  [[ "$output" == *"provision/user/35-python-venv.sh"* ]]
  [ ! -e "$UNIT" ]
  never_ran systemctl
}

# --- the first run ----------------------------------------------------------

@test "a fresh board gets the unit, enabled and started" {
  with_venv
  run "$STEP"
  [ "$status" -eq 0 ]
  [ -f "$UNIT" ]
  ran "systemctl daemon-reload"
  ran "systemctl enable --now $U"
  [[ "$output" == *"running as PID 4242"* ]]
}

@test "the unit runs the checkout's venv as the owner, not as root" {
  # It is a demo in the owner's checkout. Nothing about it needs root, and a
  # unit that ran the checkout as root would run whatever was last saved there.
  with_venv
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qx "User=$UNOQ_USER" "$UNIT"
  grep -qx "Group=$UNOQ_USER" "$UNIT"
  grep -qx "ExecStart=$PROJECT/.venv/bin/unoq-cpu-bars --interval 0.5" "$UNIT"
  refute grep -q "$UNOQ_RUNTIME_DIR" "$UNIT"
}

# --- the second run ---------------------------------------------------------

@test "a second run changes nothing" {
  with_venv
  run "$STEP"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 changed,"* ]]
  refute ran "systemctl daemon-reload"
  refute ran_like '^systemctl (enable|start|restart)'
}

# --- a demo that gave up ----------------------------------------------------

@test "a demo that gave up is cleared and started again, and says so" {
  with_venv
  run "$STEP"
  rm -f "$FLAGS/active-$U"
  : >"$FLAGS/failed-$U"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cleared the failed state unoq-cpu-bars was left in"* ]]
  ran "systemctl reset-failed $U"
  ran "systemctl enable --now $U"
}

@test "the start count is cleared before the start, even on a unit that is not failed" {
  # A demo stopped on its last permitted start is "inactive", not failed, and
  # its next start is still refused. reset-failed is what clears the count.
  with_venv
  run "$STEP"
  rm -f "$FLAGS/active-$U"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  reset="$(grep -n "^systemctl reset-failed $U\$" "$STUB_LOG" | cut -d: -f1)"
  start="$(grep -n "^systemctl enable --now $U\$" "$STUB_LOG" | cut -d: -f1)"
  [ -n "$reset" ] && [ -n "$start" ]
  [ "$reset" -lt "$start" ]
  # Clearing nothing is not a change worth reporting.
  [[ "$output" != *"cleared the failed state"* ]]
}

@test "a start that does not take is a warning that says where to look" {
  # A demo, not a prerequisite: nothing later in bootstrap needs it, so it
  # does not stop the run.
  with_venv
  : >"$FLAGS/wont-start"
  run "$STEP"
  [ "$status" -eq 0 ]
  # Labeled a warning, not an "ok" line that happens to say something bad.
  grep -qE 'warn +service is not running - check: journalctl -u unoq-cpu-bars' <<<"$output"
  [[ "$output" != *"running as PID"* ]]
}

# --- the way back -----------------------------------------------------------

@test "the REVERT line stops the demo and removes its unit" {
  with_venv
  run "$STEP"
  cmd="$(revert)"
  [ -n "$cmd" ]
  # Run against this test's directories, it has to find the unit where the
  # step put it, under the name it was given.
  cmd="${cmd//\/etc\/systemd\/system/$UNOQ_UNIT_DIR}"
  : >"$STUB_LOG"
  bash -c "$cmd"
  [ ! -e "$UNIT" ]
  [ ! -e "$FLAGS/enabled-$U" ]
  [ ! -e "$FLAGS/active-$U" ]
  ran "systemctl daemon-reload"
}
