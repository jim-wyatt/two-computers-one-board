#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# provision/67-buildlight.sh installs unoq-buildlight.service, the daemon that
# shows a GitHub Actions workflow on the LED matrix. What is at stake: it
# refuses to install a unit whose program is not there yet; it writes the
# settings file once and never over someone's edits, which is where their
# token is; that file is never readable by everyone; and it takes the serial
# port from the CPU-bars demo and the temperature logger properly - disabled,
# not only stopped, because two enabled units that conflict leave which one
# runs at boot to chance. It also says how to go back.
#
# What this cannot show: that GitHub answers, or that the panel draws. That is
# the board's job.

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
  STEP="$PROJECT/provision/67-buildlight.sh"

  export UNOQ_ROOT="$BATS_TEST_TMPDIR/root"
  export UNOQ_UNIT_DIR="$BATS_TEST_TMPDIR/etc/systemd/system"
  export UNOQ_RUNTIME_DIR="$BATS_TEST_TMPDIR/usr/local/lib/unoq"
  export UNOQ_IN_BOOTSTRAP=1
  UNOQ_USER="$(id -un)"
  export UNOQ_USER
  GROUP="$(id -gn)"
  export FAKE_HOME="$BATS_TEST_TMPDIR/home"
  UNIT="$UNOQ_UNIT_DIR/unoq-buildlight.service"
  U=unoq-buildlight.service
  BARS=unoq-cpu-bars.service
  LOG=unoq-temp-log.service
  ENV_FILE="$UNOQ_ROOT/etc/unoq/buildlight.env"

  FLAGS="$BATS_TEST_TMPDIR/flags"
  mkdir -p "$FLAGS"
  export FLAGS

  stub sleep
  # The tests are not root, so they cannot give a file to root. install is
  # recorded with its owner, and run without it; stat then says root, as it
  # would on the board, unless a test has said otherwise (FLAGS/owner).
  stub_body install <<'SH'
args=()
while [ $# -gt 0 ]; do
  case "$1" in -o | -g) shift 2 ;; *) args+=("$1") && shift ;; esac
done
exec /usr/bin/install "${args[@]}"
SH
  stub_body stat <<'SH'
if [ "$1" = -c ] && [ "$2" = '%a %U %G' ]; then
  owner=root
  [ -e "$FLAGS/owner" ] && owner="$(cat "$FLAGS/owner")"
  [ -e "$FLAGS/chowned" ] && owner=root
  echo "$(/usr/bin/stat -c %a "$3") $owner $(/usr/bin/stat -c %G "$3")"
  exit 0
fi
exec /usr/bin/stat "$@"
SH
  stub_body chown <<'SH'
: >"$FLAGS/chowned"
SH
  stub_body id <<'SH'
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
SH
  stub_body getent <<'SH'
[ "$1" = passwd ] && { echo "$2:x:1000:1000::$FAKE_HOME:/bin/bash"; exit 0; }
exec /usr/bin/getent "$@"
SH
  # The same manager with a memory as tests/temp-log.bats.
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
  printf '#!/bin/bash\nexit 0\n' >"$PROJECT/.venv/bin/unoq-buildlight"
  chmod +x "$PROJECT/.venv/bin/unoq-buildlight"
}

# running <unit> - enabled and running, as its own step leaves it.
running() {
  : >"$FLAGS/enabled-$1"
  : >"$FLAGS/active-$1"
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
  running "$BARS"
  run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unoq-buildlight missing"* ]]
  [[ "$output" == *"provision/user/35-python-venv.sh"* ]]
  [ ! -e "$UNIT" ]
  [ ! -e "$ENV_FILE" ]
  # The demo is still there: stopping it for a light that cannot start would
  # leave the panel with nothing.
  [ -e "$FLAGS/active-$BARS" ]
  never_ran systemctl
}

# --- the first run ----------------------------------------------------------

@test "a fresh board gets the settings and the unit, enabled and started" {
  with_venv
  run "$STEP"
  [ "$status" -eq 0 ]
  [ -f "$ENV_FILE" ]
  [ -f "$UNIT" ]
  ran "systemctl daemon-reload"
  ran "systemctl enable --now $U"
  [[ "$output" == *"running as PID 4242"* ]]
}

@test "the settings file is 0640, root and the owner's group" {
  with_venv
  run "$STEP"
  [ "$status" -eq 0 ]
  ran_like "^install -m 0640 -o root -g $GROUP .* $ENV_FILE\$"
  [ "$(/usr/bin/stat -c %a "$ENV_FILE")" = 640 ]
  [[ "$output" == *"wrote $ENV_FILE (0640 root:$GROUP)"* ]]
}

@test "the settings file watches this project, and every other setting is commented" {
  with_venv
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qx "UNOQ_BUILDLIGHT_REPO=jim-wyatt/two-computers-one-board" "$ENV_FILE"
  for v in WORKFLOW BRANCH INTERVAL TOKEN; do
    grep -q "^#UNOQ_BUILDLIGHT_$v=" "$ENV_FILE"
    refute grep -q "^UNOQ_BUILDLIGHT_$v=" "$ENV_FILE"
  done
  # Only the one uncommented line: no token is ever written by the repository.
  [ "$(grep -c '^[^#]' "$ENV_FILE")" = 1 ]
  [[ "$output" == *"no token"* ]]
}

@test "the unit runs the checkout's venv as the owner, with the settings, and conflicts with both" {
  with_venv
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qx "User=$UNOQ_USER" "$UNIT"
  grep -qx "Group=$UNOQ_USER" "$UNIT"
  grep -qx "ExecStart=$PROJECT/.venv/bin/unoq-buildlight" "$UNIT"
  # Not rewritten: it is not the checkout's path, and the `-` is kept.
  grep -qx "EnvironmentFile=-/etc/unoq/buildlight.env" "$UNIT"
  grep -qx "Conflicts=unoq-cpu-bars.service unoq-temp-log.service" "$UNIT"
  grep -qx "Requires=unoq-link.service" "$UNIT"
  grep -qx "After=unoq-link.service" "$UNIT"
  grep -qx "KillSignal=SIGINT" "$UNIT"
  refute grep -q "$UNOQ_RUNTIME_DIR" "$UNIT"
}

# --- an edited settings file ------------------------------------------------

@test "an edited settings file is never written over, and its token never printed" {
  with_venv
  mkdir -p "$(dirname "$ENV_FILE")"
  printf 'UNOQ_BUILDLIGHT_REPO=me/mine\nUNOQ_BUILDLIGHT_TOKEN=ghp_SECRET123\n' >"$ENV_FILE"
  chmod 0640 "$ENV_FILE"
  before="$(cat "$ENV_FILE")"
  run "$STEP"
  [ "$status" -eq 0 ]
  [ "$(cat "$ENV_FILE")" = "$before" ]
  [[ "$output" == *"kept as it is"* ]]
  [[ "$output" == *"a token is set"* ]]
  [[ "$output" != *"ghp_SECRET123"* ]]
  refute ran_like "^install .*$ENV_FILE"
}

@test "a token line with nothing after it is no token" {
  with_venv
  mkdir -p "$(dirname "$ENV_FILE")"
  printf 'UNOQ_BUILDLIGHT_TOKEN=\n' >"$ENV_FILE"
  chmod 0640 "$ENV_FILE"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no token"* ]]
}

@test "a settings file left readable by everyone is closed up, and keeps its contents" {
  with_venv
  mkdir -p "$(dirname "$ENV_FILE")"
  printf 'UNOQ_BUILDLIGHT_TOKEN=ghp_SECRET123\n' >"$ENV_FILE"
  chmod 0644 "$ENV_FILE"
  echo "$UNOQ_USER" >"$FLAGS/owner"
  run "$STEP"
  [ "$status" -eq 0 ]
  ran "chown root:$GROUP $ENV_FILE"
  [ "$(/usr/bin/stat -c %a "$ENV_FILE")" = 640 ]
  [[ "$output" == *"was 644 $UNOQ_USER $GROUP; now 0640 root:$GROUP"* ]]
  grep -qx "UNOQ_BUILDLIGHT_TOKEN=ghp_SECRET123" "$ENV_FILE"
}

@test "a settings file that cannot be closed up stops the step" {
  with_venv
  mkdir -p "$(dirname "$ENV_FILE")"
  : >"$ENV_FILE"
  chmod 0644 "$ENV_FILE"
  stub chown 1
  run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not make $ENV_FILE 0640"* ]]
  [ ! -e "$UNIT" ]
}

# --- the panel --------------------------------------------------------------

@test "the CPU-bars demo is disabled, not only stopped, and it says the panel is taken" {
  with_venv
  running "$BARS"
  run "$STEP"
  [ "$status" -eq 0 ]
  ran "systemctl disable --now $BARS"
  [ ! -e "$FLAGS/enabled-$BARS" ]
  [ ! -e "$FLAGS/active-$BARS" ]
  [[ "$output" == *"stopped and disabled the CPU-bars demo: the panel is the build light's now"* ]]
  # ...before the light is started, so it is not the one that loses the port.
  off="$(grep -n "^systemctl disable --now $BARS\$" "$STUB_LOG" | cut -d: -f1)"
  on="$(grep -n "^systemctl enable --now $U\$" "$STUB_LOG" | cut -d: -f1)"
  [ -n "$off" ] && [ "$off" -lt "$on" ]
}

@test "the temperature logger is disabled too, and its record is said to be kept" {
  with_venv
  running "$LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  ran "systemctl disable --now $LOG"
  [ ! -e "$FLAGS/enabled-$LOG" ]
  [[ "$output" == *"stopped and disabled the temperature logger (its record is kept)"* ]]
  off="$(grep -n "^systemctl disable --now $LOG\$" "$STUB_LOG" | cut -d: -f1)"
  on="$(grep -n "^systemctl enable --now $U\$" "$STUB_LOG" | cut -d: -f1)"
  [ -n "$off" ] && [ "$off" -lt "$on" ]
}

@test "a board with neither has nothing of them touched" {
  with_venv
  run "$STEP"
  [ "$status" -eq 0 ]
  refute ran_like "^systemctl disable"
  [[ "$output" == *"unoq-cpu-bars is not enabled"* ]]
  [[ "$output" == *"unoq-temp-log is not enabled"* ]]
}

@test "a demo that will not stop stops the step, before the light is installed" {
  with_venv
  running "$BARS"
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
  [[ "$output" == *"sudo systemctl disable --now unoq-buildlight && sudo bash $PROJECT/provision/65-cpu-bars.sh"* ]]
  [[ "$output" == *"sudo systemctl restart unoq-buildlight"* ]]
}

# --- the second run ---------------------------------------------------------

@test "a second run changes nothing" {
  with_venv
  running "$BARS"
  run "$STEP"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 changed,"* ]]
  refute ran "systemctl daemon-reload"
  refute ran_like '^systemctl (enable|start|restart|disable)'
  refute ran_like '^(install|chown)'
}

# --- a light that gave up ---------------------------------------------------

@test "a light that gave up is cleared and started again, and says so" {
  with_venv
  run "$STEP"
  rm -f "$FLAGS/active-$U"
  : >"$FLAGS/failed-$U"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cleared the failed state unoq-buildlight was left in"* ]]
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
  grep -qE 'warn +service is not running - check: journalctl -u unoq-buildlight' <<<"$output"
  [[ "$output" != *"running as PID"* ]]
}

# --- the way back -----------------------------------------------------------

@test "the REVERT line stops the light, removes its unit, and leaves the settings" {
  with_venv
  run "$STEP"
  cmd="$(revert)"
  [ -n "$cmd" ]
  cmd="${cmd//\/etc\/systemd\/system/$UNOQ_UNIT_DIR}"
  : >"$STUB_LOG"
  bash -c "$cmd"
  [ ! -e "$UNIT" ]
  [ ! -e "$FLAGS/enabled-$U" ]
  [ ! -e "$FLAGS/active-$U" ]
  ran "systemctl daemon-reload"
  [ -e "$ENV_FILE" ]
}
