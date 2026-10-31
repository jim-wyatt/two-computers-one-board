#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# provision/45-mcu-link.sh installs unoq-link.service, which drives BOOT0 and
# the UART enable line at every boot. Without it the board looks dead after a
# reboot: BOOT0 floats, the STM32 sits in its ROM bootloader, and /dev/ttyHS1
# says nothing. What is at stake is that unit naming something root can run at
# boot, and root running its own copy of link-up.sh rather than the checkout.
#
# The step also owes some restraint. A second run changes nothing. A changed
# link-up.sh reaches root's copy but is not applied mid-session, because the
# lines are already driven. The check at the end reads the lines' direction
# and never requests them, since requesting a line drops its drive.
#
# What this cannot show: that link-up.sh drives the lines the kernel calls 37
# and 70, or that the unit runs before anything needs the link. That is the
# board's job, and a reboot is the test.

setup() {
  load helpers/stub
  stub_setup

  # A copy of the checkout, so a test decides whether it has a venv. The step
  # finds its checkout from where lib.sh is, and the real one has a venv on the
  # board and in CI. These five directories are all the step and root's copies
  # reach.
  REAL="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PROJECT="$BATS_TEST_TMPDIR/checkout"
  mkdir -p "$PROJECT"
  cp -r "$REAL/provision" "$REAL/mcu" "$REAL/usb" "$REAL/net" "$REAL/status" "$PROJECT/"
  STEP="$PROJECT/provision/45-mcu-link.sh"

  export UNOQ_UNIT_DIR="$BATS_TEST_TMPDIR/etc/systemd/system"
  export UNOQ_RUNTIME_DIR="$BATS_TEST_TMPDIR/usr/local/lib/unoq"
  export UNOQ_RUN_DIR="$BATS_TEST_TMPDIR/run"
  mkdir -p "$UNOQ_RUN_DIR"
  # The end-of-run warnings read the board's own /etc/systemd/system. Under
  # bootstrap they are said once, at the end, and not by this step.
  export UNOQ_IN_BOOTSTRAP=1
  UNOQ_USER="$(id -un)"
  export UNOQ_USER
  export FAKE_HOME="$BATS_TEST_TMPDIR/home"
  UNIT="$UNOQ_UNIT_DIR/unoq-link.service"

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
  # runuser -u <user> -- <cmd>: recorded, then run as ourselves.
  stub_body runuser <<'SH'
while [ "$1" != "--" ]; do shift; done
shift
exec "$@"
SH
  # A package database with a memory: tio is there once it has been installed.
  stub_body dpkg-query <<'SH'
[ -e "$FLAGS/pkg-${*: -1}" ] && echo "install ok installed"
exit 0
SH
  stub_body apt-get <<'SH'
[ "$1" = remove ] && { rm -f "$FLAGS/pkg-${*: -1}"; exit 0; }
for a in "$@"; do [ "$a" = tio ] && : >"$FLAGS/pkg-tio"; done
exit 0
SH
  # A manager with a memory: enabled and running once asked, not before.
  stub_body systemctl <<'SH'
u="${*: -1}"
case "$1" in
  is-enabled) [ -e "$FLAGS/enabled-$u" ] ;;
  is-active) [ -e "$FLAGS/active-$u" ] ;;
  enable) : >"$FLAGS/enabled-$u"; [ "$2" = --now ] && : >"$FLAGS/active-$u"; exit 0 ;;
  disable) rm -f "$FLAGS/enabled-$u"; [ "$2" = --now ] && rm -f "$FLAGS/active-$u"; exit 0 ;;
  *) exit 0 ;;
esac
SH
}

# with_venv - a venv whose python prints whatever $FLAGS/link-state holds,
# which is what `print(link_state())` would. No file: it prints nothing.
with_venv() {
  mkdir -p "$PROJECT/.venv/bin"
  cat >"$PROJECT/.venv/bin/python" <<'SH'
#!/bin/bash
[ -e "$FLAGS/link-state" ] && cat "$FLAGS/link-state"
exit 0
SH
  chmod +x "$PROJECT/.venv/bin/python"
}

lines_are() { echo "$1" >"$FLAGS/link-state"; }
DRIVEN="{'boot0': 'OUTPUT', 'link_enable': 'OUTPUT'}"

# revert <step heading> - the REVERT comment above that part of the step, as
# one line: "# REVERT:" and the "#" of each continuation dropped.
revert() {
  awk -v want="$1" '
    /^# REVERT:/ { buf = substr($0, 11); inrev = 1; next }
    inrev && /^#  / { sub(/^# +/, ""); buf = buf " " $0; next }
    { inrev = 0 }
    /^step "/ && buf != "" { if (index($0, "\"" want "\"")) { print buf; exit } buf = "" }
  ' "$STEP"
}

# --- the first run ----------------------------------------------------------

@test "a fresh board gets tio, root's scripts and the unit, enabled and started" {
  run "$STEP"
  [ "$status" -eq 0 ]
  ran_like '^apt-get install .*tio'
  [ -x "$UNOQ_RUNTIME_DIR/mcu/link-up.sh" ]
  cmp -s "$PROJECT/mcu/link-up.sh" "$UNOQ_RUNTIME_DIR/mcu/link-up.sh"
  [ -f "$UNIT" ]
  ran "systemctl daemon-reload"
  ran "systemctl enable --now unoq-link.service"
  [[ "$output" == *"Serial console:  tio /dev/ttyHS1 -b 115200"* ]]
}

@test "the unit runs root's copy of link-up.sh, never the checkout" {
  # The checkout is the owner's to write. A unit that ran it would run, as
  # root at the next boot, whatever was last saved there.
  run "$STEP"
  [ "$status" -eq 0 ]
  [ "$(grep '^ExecStart=' "$UNIT")" = "ExecStart=$UNOQ_RUNTIME_DIR/mcu/link-up.sh" ]
  refute grep -qE "^Exec[A-Za-z]*=.*$PROJECT" "$UNIT"
  # The home directory it waits for is the owner's, not /home/arduino.
  grep -qx "RequiresMountsFor=$FAKE_HOME" "$UNIT"
}

# --- the second run ---------------------------------------------------------

@test "a second run changes nothing" {
  run "$STEP"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 changed,"* ]]
  never_ran apt-get
  refute ran "systemctl daemon-reload"
  refute ran_like '^systemctl (enable|start|restart)'
}

@test "a changed link-up.sh reaches root's copy, and is not applied mid-session" {
  # The lines are already driven. Driving them again under a running board is
  # not something a provisioning run should do unasked; the next boot does it.
  run "$STEP"
  echo "# changed" >>"$PROJECT/mcu/link-up.sh"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  cmp -s "$PROJECT/mcu/link-up.sh" "$UNOQ_RUNTIME_DIR/mcu/link-up.sh"
  [[ "$output" == *"updated $UNOQ_RUNTIME_DIR/mcu/link-up.sh"* ]]
  refute ran_like '^systemctl (start|restart|reload-or-restart|try-restart|enable --now) unoq-link'
  refute ran_like '^(/.*/)?link-up\.sh'
}

# --- the check at the end ---------------------------------------------------

@test "driven lines are reported as the check passing" {
  with_venv
  lines_are "$DRIVEN"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"link lines driven: $DRIVEN"* ]]
  ran_like "^runuser -u $UNOQ_USER -- $PROJECT/.venv/bin/python -c"
}

@test "a floating line is a warning, not a pass" {
  with_venv
  lines_are "{'boot0': 'INPUT', 'link_enable': 'OUTPUT'}"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"link lines look wrong: {'boot0': 'INPUT'"* ]]
  [[ "$output" != *"link lines driven"* ]]
}

@test "a state nobody could read says so" {
  with_venv
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not read link state"* ]]
}

@test "no venv yet: the check is put off, and says which step builds it" {
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"venv not built yet - run provision/user/35-python-venv.sh"* ]]
  never_ran runuser
}

@test "the check never requests the lines" {
  # gpioget requests a line as an input, which drops the drive: the read
  # would break the link it is checking.
  with_venv
  lines_are "$DRIVEN"
  run "$STEP"
  never_ran gpioget
  never_ran gpioset
  never_ran gpiomon
}

# --- the way back -----------------------------------------------------------

@test "the REVERT line for tio removes it" {
  run "$STEP"
  cmd="$(revert "serial terminal")"
  [ "$cmd" = "apt-get remove -y tio" ]
  bash -c "$cmd"
  [ ! -e "$FLAGS/pkg-tio" ]
}

@test "the REVERT line for the unit stops it and removes what the step installed" {
  run "$STEP"
  text="$(revert "the scripts root runs")"
  [ -n "$text" ]
  # Its first half undoes the unit. Run against this test's directories, it
  # has to find the unit where the step put it, under the name it was given.
  cmd="${text%% then,*}"
  cmd="${cmd//\/etc\/systemd\/system/$UNOQ_UNIT_DIR}"
  bash -c "$cmd"
  [ ! -e "$UNIT" ]
  [ ! -e "$FLAGS/enabled-unoq-link.service" ]
  [ ! -e "$FLAGS/active-unoq-link.service" ]
  ran "systemctl daemon-reload"
  # Its last command removes root's scripts, from where they really are.
  [[ "$text" == *"rm -r /usr/local/lib/unoq" ]]
}

@test "the REVERT line names every other unit that runs root's scripts" {
  # It says to remove /usr/local/lib/unoq only once none of them is left. A
  # unit missing from that list is one left pointing at nothing.
  text="$(revert "the scripts root runs")"
  # The list is the part in brackets. The prose around it says "unoq-*",
  # which as a glob would match every unit and make this pass whatever.
  others="${text#*(}"
  others="${others%%)*}"
  [ -n "$others" ] && [ "$others" != "$text" ]
  for src in "$REAL"/*/unoq-*.service; do
    name="$(basename "$src" .service)"
    [ "$name" = unoq-link ] && continue
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
