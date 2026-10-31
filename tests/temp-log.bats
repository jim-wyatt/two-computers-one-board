#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# provision/66-temp-log.sh installs unoq-temp-log.service, the daemon that
# keeps the MCU's temperature log on Linux. What is at stake: it refuses to
# install a unit whose program is not there yet; it makes the log's directory
# for the account that writes it; and it takes the serial port over from the
# CPU-bars demo properly - disabled, not only stopped, because two enabled
# units that conflict leave which one runs at boot to chance. It also says
# whether the web server will show the graph, and how to go back.
#
# What this cannot show: that the MCU answers, that rows arrive, or that the
# graph draws. That is the board's job.

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
  STEP="$PROJECT/provision/66-temp-log.sh"

  export UNOQ_UNIT_DIR="$BATS_TEST_TMPDIR/etc/systemd/system"
  export UNOQ_RUNTIME_DIR="$BATS_TEST_TMPDIR/usr/local/lib/unoq"
  export UNOQ_STATE_DIR="$BATS_TEST_TMPDIR/var/lib/unoq"
  export UNOQ_IN_BOOTSTRAP=1
  UNOQ_USER="$(id -un)"
  export UNOQ_USER
  export FAKE_HOME="$BATS_TEST_TMPDIR/home"
  UNIT="$UNOQ_UNIT_DIR/unoq-temp-log.service"
  U=unoq-temp-log.service
  BARS=unoq-cpu-bars.service
  DIR="$UNOQ_STATE_DIR/templog"

  FLAGS="$BATS_TEST_TMPDIR/flags"
  mkdir -p "$FLAGS"
  export FLAGS

  stub sleep
  # Recorded, so a test can see who the directory was made for: the tests
  # run as that account, so the owner alone would not show it.
  stub_body install <<'SH'
exec /usr/bin/install "$@"
SH
  stub_body id <<'SH'
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
SH
  stub_body getent <<'SH'
[ "$1" = passwd ] && { echo "$2:x:1000:1000::$FAKE_HOME:/bin/bash"; exit 0; }
exec /usr/bin/getent "$@"
SH
  # The same manager with a memory as tests/cpu-bars.bats.
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

with_venv() {
  mkdir -p "$PROJECT/.venv/bin"
  printf '#!/bin/bash\nexit 0\n' >"$PROJECT/.venv/bin/unoq-temp-log"
  chmod +x "$PROJECT/.venv/bin/unoq-temp-log"
}

# demo_installed - the CPU-bars demo, enabled and running, as 65 leaves it.
demo_installed() {
  : >"$FLAGS/enabled-$BARS"
  : >"$FLAGS/active-$BARS"
}

# learn_unit <ExecStart arguments> - an installed unoq-learn.service.
learn_unit() {
  mkdir -p "$UNOQ_UNIT_DIR"
  echo "ExecStart=/x/unoq-learn $1" >"$UNOQ_UNIT_DIR/unoq-learn.service"
}

# revert - the REVERT comment in the step's header, as one line.
revert() {
  awk '
    /^# REVERT:/ { buf = substr($0, 11); inrev = 1; next }
    inrev && /^#  / { sub(/^# +/, ""); buf = buf " " $0; next }
    inrev { print buf; exit }
  ' "$STEP"
}

# --- before the venv --------------------------------------------------------

@test "no venv yet: the step stops, says which step builds it, and changes nothing" {
  demo_installed
  run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unoq-temp-log missing"* ]]
  [[ "$output" == *"provision/user/35-python-venv.sh"* ]]
  [ ! -e "$UNIT" ]
  [ ! -e "$DIR" ]
  # The demo is still there: stopping it for a logger that cannot start
  # would leave the board with neither.
  [ -e "$FLAGS/active-$BARS" ]
  never_ran systemctl
}

# --- the first run ----------------------------------------------------------

@test "a fresh board gets the directory and the unit, enabled and started" {
  with_venv
  run "$STEP"
  [ "$status" -eq 0 ]
  [ -d "$DIR" ]
  [ "$(stat -c %U "$DIR")" = "$UNOQ_USER" ]
  ran "install -d -m 0755 -o $UNOQ_USER -g $(id -gn) $DIR"
  [ -f "$UNIT" ]
  ran "systemctl daemon-reload"
  ran "systemctl enable --now $U"
  [[ "$output" == *"running as PID 4242"* ]]
}

@test "the unit runs the checkout's venv as the owner and conflicts with the demo" {
  with_venv
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qx "User=$UNOQ_USER" "$UNIT"
  grep -qx "Group=$UNOQ_USER" "$UNIT"
  grep -qx "ExecStart=$PROJECT/.venv/bin/unoq-temp-log --dir /var/lib/unoq/templog --interval 10" "$UNIT"
  grep -qx "Conflicts=unoq-cpu-bars.service" "$UNIT"
  grep -qx "Requires=unoq-link.service" "$UNIT"
  grep -qx "KillSignal=SIGINT" "$UNIT"
  refute grep -q "$UNOQ_RUNTIME_DIR" "$UNIT"
}

@test "a directory owned by someone else is given to the owner" {
  # Made by hand with sudo mkdir: root's, and the daemon could not write it.
  with_venv
  mkdir -p "$DIR"
  stub_body stat <<'SH'
[ "$1" = -c ] && { echo root; exit 0; }
exec /usr/bin/stat "$@"
SH
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$DIR, owned by $UNOQ_USER"* ]]
  ran_like "^install -d -m 0755 -o $UNOQ_USER "
}

# --- the demo ---------------------------------------------------------------

@test "the CPU-bars demo is disabled, not only stopped, and it says so" {
  with_venv
  demo_installed
  run "$STEP"
  [ "$status" -eq 0 ]
  ran "systemctl disable --now $BARS"
  [ ! -e "$FLAGS/enabled-$BARS" ]
  [ ! -e "$FLAGS/active-$BARS" ]
  [[ "$output" == *"stopped and disabled the CPU-bars demo"* ]]
  # ...before the logger is started, so it is not the one that loses the port.
  off="$(grep -n "^systemctl disable --now $BARS\$" "$STUB_LOG" | cut -d: -f1)"
  on="$(grep -n "^systemctl enable --now $U\$" "$STUB_LOG" | cut -d: -f1)"
  [ "$off" -lt "$on" ]
}

@test "a board without the demo has nothing of it touched" {
  with_venv
  run "$STEP"
  [ "$status" -eq 0 ]
  refute ran_like "^systemctl disable"
  [[ "$output" == *"the CPU-bars demo is not enabled"* ]]
}

@test "a demo that will not stop stops the step, before the logger is installed" {
  with_venv
  demo_installed
  stub_body systemctl <<'SH'
case "$1" in
  is-enabled) exit 0 ;;
  disable) exit 1 ;;
  *) exit 0 ;;
esac
SH
  run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not stop unoq-cpu-bars"* ]]
  [ ! -e "$UNIT" ]
}

@test "the way back is printed" {
  with_venv
  run "$STEP"
  [[ "$output" == *"sudo systemctl disable --now unoq-temp-log && sudo bash $PROJECT/provision/65-cpu-bars.sh"* ]]
}

# --- the second run ---------------------------------------------------------

@test "a second run changes nothing" {
  with_venv
  demo_installed
  run "$STEP"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 changed,"* ]]
  refute ran "systemctl daemon-reload"
  refute ran_like '^systemctl (enable|start|restart|disable)'
}

# --- a logger that gave up --------------------------------------------------

@test "a logger that gave up is cleared and started again, and says so" {
  with_venv
  run "$STEP"
  rm -f "$FLAGS/active-$U"
  : >"$FLAGS/failed-$U"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cleared the failed state unoq-temp-log was left in"* ]]
  reset="$(grep -n "^systemctl reset-failed $U\$" "$STUB_LOG" | cut -d: -f1)"
  start="$(grep -n "^systemctl enable --now $U\$" "$STUB_LOG" | cut -d: -f1)"
  [ -n "$reset" ] && [ -n "$start" ]
  [ "$reset" -lt "$start" ]
}

@test "a start that does not take is a warning that says where to look" {
  with_venv
  : >"$FLAGS/wont-start"
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qE 'warn +service is not running - check: journalctl -u unoq-temp-log' <<<"$output"
  [[ "$output" != *"running as PID"* ]]
}

# --- the web page -----------------------------------------------------------

@test "with no web server it says the log has no page, and is not a warning" {
  with_venv
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unoq-learn is not installed"* ]]
  refute grep -qE '^ *warn .*unoq-learn' <<<"$output"
}

@test "a web server from before /data/ is a warning that names the step to re-run" {
  with_venv
  learn_unit "--root /srv/unoq-share --port 8080"
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qE 'warn +unoq-learn does not serve /data/ yet' <<<"$output"
  [[ "$output" == *"provision/75-learning-web.sh"* ]]
}

@test "a web server that serves /data/ is reported as doing so" {
  with_venv
  learn_unit "--root /srv/unoq-share --port 8080 --data /var/lib/unoq/templog"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unoq-learn serves the log at /data/"* ]]
  [[ "$output" != *"does not serve"* ]]
}

# --- the way back -----------------------------------------------------------

@test "the REVERT line stops the logger, removes its unit, and keeps the record" {
  with_venv
  run "$STEP"
  : >"$DIR/temps.csv"
  cmd="$(revert)"
  [ -n "$cmd" ]
  cmd="${cmd//\/etc\/systemd\/system/$UNOQ_UNIT_DIR}"
  : >"$STUB_LOG"
  bash -c "$cmd"
  [ ! -e "$UNIT" ]
  [ ! -e "$FLAGS/enabled-$U" ]
  [ ! -e "$FLAGS/active-$U" ]
  ran "systemctl daemon-reload"
  [ -e "$DIR/temps.csv" ]
}
