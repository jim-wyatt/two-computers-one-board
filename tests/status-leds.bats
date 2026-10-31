#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# provision/50-status-leds.sh installs unoq-leds.service, which drives the two
# LEDs Linux owns. They are the board's only output when the network is down
# and nobody can log in, so the step installs them whatever it finds, and a
# board with fewer LEDs than expected is a warning rather than a stop.
#
# The step also owes a restart when what is running is no longer what is
# installed. A changed unit, or a changed leds.sh, otherwise leaves the old
# process running "already enabled", which is how the LEDs went on running a
# script from a path that no longer existed. A run with nothing new changes
# nothing.
#
# What this cannot show: what the LEDs say. leds.bats is for that.

setup() {
  load helpers/stub
  stub_setup

  # A copy of the checkout, so a test can edit what the step installs. These
  # five directories are all the step and root's copies reach.
  REAL="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PROJECT="$BATS_TEST_TMPDIR/checkout"
  mkdir -p "$PROJECT"
  cp -r "$REAL/provision" "$REAL/mcu" "$REAL/usb" "$REAL/net" "$REAL/status" "$PROJECT/"
  STEP="$PROJECT/provision/50-status-leds.sh"

  export UNOQ_UNIT_DIR="$BATS_TEST_TMPDIR/etc/systemd/system"
  export UNOQ_RUNTIME_DIR="$BATS_TEST_TMPDIR/usr/local/lib/unoq"
  export UNOQ_LED_DIR="$BATS_TEST_TMPDIR/leds"
  # The end-of-run warnings read the board's own /etc/systemd/system. Under
  # bootstrap they are said once, at the end, and not by this step.
  export UNOQ_IN_BOOTSTRAP=1
  UNOQ_USER="$(id -un)"
  export UNOQ_USER
  export FAKE_HOME="$BATS_TEST_TMPDIR/home"
  UNIT="$UNOQ_UNIT_DIR/unoq-leds.service"
  U=unoq-leds.service

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
  # A manager with a memory: enabled and running once asked, not before, and
  # a start that fails when a test says so.
  stub_body systemctl <<'SH'
u="${*: -1}"
case "$1" in
  is-enabled) [ -e "$FLAGS/enabled-$u" ] ;;
  is-active) [ -e "$FLAGS/active-$u" ] ;;
  enable)
    [ -e "$FLAGS/wont-start" ] && exit 1
    : >"$FLAGS/enabled-$u"
    [ "$2" = --now ] && : >"$FLAGS/active-$u"
    exit 0
    ;;
  disable) rm -f "$FLAGS/enabled-$u"; [ "$2" = --now ] && rm -f "$FLAGS/active-$u"; exit 0 ;;
  *) exit 0 ;;
esac
SH
}

# leds <n> - the first n of the six channels, writable.
leds() {
  local ch n=0
  for ch in unoq:user-red1 unoq:user-green1 unoq:user-blue1 \
    unoq:panic-red2 unoq:wlan-green2 unoq:bt-blue2; do
    [ "$n" -lt "$1" ] || break
    mkdir -p "$UNOQ_LED_DIR/$ch"
    : >"$UNOQ_LED_DIR/$ch/brightness"
    n=$((n + 1))
  done
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

# --- the first run ----------------------------------------------------------

@test "a fresh board gets root's scripts and the unit, enabled and started" {
  leds 6
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all six channels present and writable"* ]]
  cmp -s "$PROJECT/status/leds.sh" "$UNOQ_RUNTIME_DIR/status/leds.sh"
  [ -f "$UNIT" ]
  ran "systemctl daemon-reload"
  ran "systemctl enable --now $U"
}

@test "the unit runs root's copy of leds.sh, never the checkout" {
  # The checkout is the owner's to write. A unit that ran it would run, as
  # root, whatever was last saved there.
  leds 6
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qx "ExecStart=$UNOQ_RUNTIME_DIR/status/leds.sh run" "$UNIT"
  grep -qx "ExecStopPost=$UNOQ_RUNTIME_DIR/status/leds.sh off" "$UNIT"
  refute grep -qE "^Exec[A-Za-z]*=.*$PROJECT" "$UNIT"
}

# --- fewer LEDs than expected -----------------------------------------------

@test "some of the LEDs missing is a warning, and the unit is installed anyway" {
  leds 3
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qE 'warn +only 3 of 6 LED channels found' <<<"$output"
  [ -f "$UNIT" ]
  ran "systemctl enable --now $U"
}

@test "no LEDs at all is a warning, and the unit is installed anyway" {
  # The LEDs are the fallback. Making them depend on what the step can see is
  # making the fallback depend on the board being as expected.
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qE "warn +no unoq:\* LEDs under $UNOQ_LED_DIR" <<<"$output"
  [ -f "$UNIT" ]
  ran "systemctl enable --now $U"
}

# --- the second run ---------------------------------------------------------

@test "a second run changes nothing" {
  leds 6
  run "$STEP"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 changed,"* ]]
  [[ "$output" == *"already enabled and running"* ]]
  refute ran "systemctl daemon-reload"
  refute ran_like '^systemctl (enable|start|restart)'
}

@test "a changed unit restarts the service that is running the old one" {
  leds 6
  run "$STEP"
  sed -i 's/^RestartSec=.*/RestartSec=11/' "$PROJECT/status/unoq-leds.service"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qx "RestartSec=11" "$UNIT"
  ran "systemctl daemon-reload"
  ran "systemctl restart $U"
  [[ "$output" == *"unit changed, service restarted"* ]]
}

@test "a changed leds.sh reaches root's copy and restarts the service" {
  # The unit is byte for byte what it was, and the process is the old leds.sh,
  # read by bash from a file that has since been replaced underneath it.
  leds 6
  run "$STEP"
  echo "# changed" >>"$PROJECT/status/leds.sh"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  cmp -s "$PROJECT/status/leds.sh" "$UNOQ_RUNTIME_DIR/status/leds.sh"
  ran "systemctl restart $U"
  [[ "$output" == *"scripts changed, service restarted"* ]]
}

@test "a change is not a restart of a service that was not running" {
  # Someone stopped it. The step starts it, once, rather than restarting it.
  leds 6
  run "$STEP"
  rm -f "$FLAGS/active-$U"
  echo "# changed" >>"$PROJECT/status/leds.sh"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  refute ran "systemctl restart $U"
  ran "systemctl enable --now $U"
}

@test "a service that will not start is a warning that says where to look" {
  leds 6
  : >"$FLAGS/wont-start"
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qE 'warn +could not start unoq-leds.service - check: journalctl -u unoq-leds' <<<"$output"
}

# --- the way back -----------------------------------------------------------

@test "the REVERT line stops the service and removes its unit" {
  leds 6
  run "$STEP"
  text="$(revert)"
  [ -n "$text" ]
  # Its first half undoes the unit. Run against this test's directories, it
  # has to find the unit where the step put it, under the name it was given.
  cmd="${text%% then,*}"
  cmd="${cmd//\/etc\/systemd\/system/$UNOQ_UNIT_DIR}"
  : >"$STUB_LOG"
  bash -c "$cmd"
  [ ! -e "$UNIT" ]
  [ ! -e "$FLAGS/enabled-$U" ]
  [ ! -e "$FLAGS/active-$U" ]
  ran "systemctl daemon-reload"
  # Its last command removes root's scripts, from where they really are.
  [[ "$text" == *"rm -r /usr/local/lib/unoq" ]]
}

@test "the REVERT line names every other unit that runs root's scripts" {
  # It says to remove /usr/local/lib/unoq only once none of them is left. A
  # unit missing from that list is one left pointing at nothing.
  text="$(revert)"
  # The list is the part in brackets.
  others="${text#*(}"
  others="${others%%)*}"
  [ -n "$others" ] && [ "$others" != "$text" ]
  for src in "$REAL"/*/unoq-*.service; do
    name="$(basename "$src" .service)"
    [ "$name" = unoq-leds ] && continue
    grep -qE '^User=' "$src" && continue
    grep -qE '^Exec[A-Za-z]*=[-@:+!]*/home/arduino/two-computers-one-board/' "$src" || continue
    found=0
    for word in $(tr -c 'a-z0-9*-' ' ' <<<"$others"); do
      # shellcheck disable=SC2053 # the list's words are globs, unoq-usb-*
      [[ "$name" == $word ]] && found=1
    done
    if [ "$found" = 0 ]; then
      echo "$name runs root's scripts and is not in the REVERT list: $others"
      false
    fi
  done
}
