#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# bootstrap.sh, and only the last thing it says.
#
# A firmware build or flash that fails does not stop the run: the rest of the
# board is still worth setting up. So the run carries on, and ends by saying
# what did not happen - and that sentence is all most people will read of a
# forty-minute log.
#
# It used to be one sentence for both failures: "the microcontroller is running
# whatever it ran before". For a build that failed, true: nothing was written.
# For a flash that failed, a guess. flash-all.sh writes the bootloader and then
# the application, in two operations, and one that stops part-way can leave a
# chip that is neither what it was nor what was meant. Being told it is
# untouched is what sends someone looking everywhere but at the chip.
#
# Every step is a fake here - `sudo` and `bash` themselves are stubs, so no
# provisioning script runs at all. What is tested is which of the two endings
# is chosen, not anything a step does.
#
# What this cannot show: what state a real interrupted flash leaves the STM32
# in. That is the reason the message no longer claims to know.

setup() {
  load helpers/stub
  stub_setup

  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  # Its two logs go to TMPDIR, not over the top of a real run's in /tmp.
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  UNOQ_USER="$(id -un)"
  export UNOQ_USER
  # A saved copy of the stock firmware, so the flash is not skipped for want
  # of one - that refusal is a different ending, with its own words.
  export UNOQ_BACKUP="$BATS_TEST_TMPDIR/backup"
  mkdir -p "$UNOQ_BACKUP"
  : >"$UNOQ_BACKUP/stock.hex"
  unset UNOQ_ALLOW_NO_STOCK_FW

  FLAGS="$BATS_TEST_TMPDIR/flags"
  mkdir -p "$FLAGS"
  export FLAGS

  stub sudo
  stub curl
  stub sleep

  # `bash <script>` is how bootstrap.sh runs every step that is not sudo's, the
  # build and the flash among them. The fake goes in a directory of its own
  # that only bootstrap.sh is given, so that nothing bats itself runs finds it.
  STEPS_BIN="$BATS_TEST_TMPDIR/steps-bin"
  mkdir -p "$STEPS_BIN"
  cat >"$STEPS_BIN/bash" <<'SH'
#!/bin/bash
{ printf 'bash'; printf ' %s' "$@"; printf '\n'; } >>"$STUB_LOG"
case "$1" in
  */mcu/zbuild.sh)
    if [ -e "$FLAGS/build-fails" ]; then
      echo "ninja: build stopped: subcommand failed."
      exit 1
    fi
    ;;
  */mcu/flash-all.sh)
    echo "== 1/2 MCUboot -> boot_partition =="
    if [ -e "$FLAGS/flash-fails" ]; then
      echo "== 2/2 signed application -> slot0 =="
      echo "Error: ** Programming Failed **"
      exit 1
    fi
    ;;
esac
exit 0
SH
  chmod +x "$STEPS_BIN/bash"
}

bootstrap() {
  run env PATH="$STEPS_BIN:$PATH" /bin/bash "$PROJECT/bootstrap.sh" "$@" </dev/null
}

@test "with nothing failing it builds, flashes, and ends cleanly" {
  bootstrap
  [ "$status" -eq 0 ]
  ran_like "^bash $PROJECT/mcu/zbuild\.sh "
  ran "bash $PROJECT/mcu/flash-all.sh"
  [[ "$output" != *"FAILED"* ]]
}

@test "a build that fails: nothing was written, and it says so" {
  : >"$FLAGS/build-fails"
  bootstrap
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED"*"the firmware did not build"* ]]
  [[ "$output" == *"Nothing was written to the microcontroller"* ]]
  [[ "$output" == *"ninja: build stopped"* ]]
  # And nothing was: the flash was never started.
  ! ran_like 'mcu/flash-all\.sh'
  [[ "$output" != *"DO NOT ASSUME"* ]]
}

@test "a flash that fails: it does not claim the microcontroller is as it was" {
  : >"$FLAGS/flash-fails"
  bootstrap
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED"*"could not be flashed"* ]]
  [[ "$output" == *"DO NOT ASSUME THE MICROCONTROLLER IS AS IT WAS"* ]]
  # The sentence that used to be printed here, for a chip that may be half written.
  [[ "$output" != *"running whatever it"* ]]
  [[ "$output" != *"Nothing was written"* ]]
  # What to do about it, and where it got to.
  [[ "$output" == *"$PROJECT/mcu/flash-all.sh"* ]]
  [[ "$output" == *"Programming Failed"* ]]
  [[ "$output" == *"$TMPDIR/zflash-bootstrap.log"* ]]
}

@test "either failure still lets the rest of the run happen first" {
  : >"$FLAGS/flash-fails"
  bootstrap --with-learning
  [ "$status" -eq 1 ]
  ran_like "^sudo -E bash $PROJECT/provision/70-learning-web\.sh\$"
  [[ "$output" == *"########## done ##########"* ]]
}

@test "--skip-mcu touches the microcontroller not at all and has nothing to report" {
  : >"$FLAGS/flash-fails"
  bootstrap --skip-mcu
  [ "$status" -eq 0 ]
  ! ran_like 'mcu/(zbuild|flash-all)\.sh'
}

@test "--help is the header and the options, and not the first lines of the script" {
  bootstrap --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--with-watchdog"* ]]
  [[ "$output" == *"TIME AND SPACE"* ]]
  [[ "$output" != *"set -uo pipefail"* ]]
  [[ "$output" != *"PROJECT="* ]]
}

# --- a board whose sudo wants a password ------------------------------------
#
# Every board this was developed on had passwordless sudo. A stock one does
# not, and sudo forgets a password after fifteen minutes - less than the
# workspace download takes.

needs_a_password() {
  stub_body sudo <<'SH'
[ "$*" = "-n -k -v" ] && exit 1
exit 0
SH
}

@test "when sudo needs a password it is asked for once, then kept alive" {
  needs_a_password
  bootstrap
  [ "$status" -eq 0 ]
  ran "sudo -v"
  ran "sudo -n -v"
  [ "$(grep -cx 'sudo -v' "$STUB_LOG")" -eq 1 ]
}

@test "the refresher does not outlive the run" {
  needs_a_password
  bootstrap
  [ "$status" -eq 0 ]
  before="$(grep -cx 'sudo -n -v' "$STUB_LOG")"
  /bin/sleep 0.3
  [ "$(grep -cx 'sudo -n -v' "$STUB_LOG")" -eq "$before" ]
}

@test "passwordless sudo is neither prompted nor refreshed" {
  bootstrap
  [ "$status" -eq 0 ]
  ! ran "sudo -v"
  ! ran "sudo -n -v"
}

@test "a refused password stops the run before anything is done" {
  stub_body sudo <<'SH'
[ "$*" = "-n -k -v" ] && exit 1
[ "$*" = "-v" ] && exit 1
exit 0
SH
  bootstrap
  [ "$status" -eq 1 ]
  [[ "$output" == *"sudo is required"* ]]
  ! ran_like '^bash .*/provision/'
}

@test "a password still cached from a minute ago does not pass for passwordless" {
  # A plain `sudo -n` probe succeeds on the strength of the cache; only the one
  # that ignores it knows this account needs a password, and so needs keeping
  # alive.
  stub_body sudo <<'SH'
[ "$*" = "-n -k -v" ] && exit 1
exit 0
SH
  bootstrap
  [ "$status" -eq 0 ]
  ran "sudo -n -k -v"
  ran "sudo -n -v"
  [[ "$output" != *"without a password"* ]]
}
