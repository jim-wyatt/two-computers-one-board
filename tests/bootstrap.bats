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

  # Where "packages changed in this boot" is noted. Not the real /run: this
  # machine's own state must not decide what a test of the script says.
  export UNOQ_RUN_DIR="$BATS_TEST_TMPDIR/run"
  mkdir -p "$UNOQ_RUN_DIR"

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
  # The sudo refresher sleeps a minute between refreshes, in the background,
  # for the whole run. A sleep that returned at once would make it spin; this
  # one makes its minute a twentieth of a second.
  stub_body sleep <<'SH'
[ "$1" = 60 ] && exec /bin/sleep 0.05
exit 0
SH

  # `bash <script>` is how bootstrap.sh runs every step that is not sudo's, the
  # build and the flash among them. The fake goes in a directory of its own
  # that only bootstrap.sh is given, so that nothing bats itself runs finds it.
  STEPS_BIN="$BATS_TEST_TMPDIR/steps-bin"
  mkdir -p "$STEPS_BIN"
  cat >"$STEPS_BIN/bash" <<'SH'
#!/bin/bash
printf '%s\n' "bash${*:+ $*}" >>"$STUB_LOG"
case "$1" in
  */mcu/zbuild.sh)
    # The one step here that takes any time at all, so that the sudo refresher
    # (a "minute" of a twentieth of a second, in these tests) gets to run.
    /bin/sleep 0.25
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
  refute ran_like 'mcu/flash-all\.sh'
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
  ran_like "^sudo -E bash $PROJECT/provision/75-learning-web\.sh\$"
  [[ "$output" == *"########## done ##########"* ]]
}

@test "--skip-mcu touches the microcontroller not at all and has nothing to report" {
  : >"$FLAGS/flash-fails"
  bootstrap --skip-mcu
  [ "$status" -eq 0 ]
  refute ran_like 'mcu/(zbuild|flash-all)\.sh'
}

@test "--help is the header and the options, and not the first lines of the script" {
  bootstrap --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--with-watchdog"* ]]
  [[ "$output" == *"TIME AND SPACE"* ]]
  [[ "$output" != *"set -uo pipefail"* ]]
  [[ "$output" != *"PROJECT="* ]]
}

# --- sudo, on a board where it wants a password and one where it does not ----
#
# Every board this was developed on had passwordless sudo. A stock one does
# not, and sudo forgets a password after fifteen minutes - less than the
# workspace download takes.

# What `sudo -n -k true` says decides only the wording.
needs_a_password() {
  stub_body sudo <<'SH'
[ "$*" = "-n -k true" ] && exit 1
[ "$*" = "-n true" ] && exit 1
exit 0
SH
}

@test "sudo is validated once and then kept alive" {
  needs_a_password
  bootstrap
  [ "$status" -eq 0 ]
  [ "$(grep -cx 'sudo -v' "$STUB_LOG")" -eq 1 ]
  ran "sudo -n -v"
  [[ "$output" == *"will prompt for your password, once"* ]]
}

@test "it is kept alive on a passwordless machine too, where that costs nothing" {
  # Deciding which kind of machine this is was got wrong twice. Nothing rests
  # on the answer now: only the line that says whether a prompt is coming.
  bootstrap
  [ "$status" -eq 0 ]
  ran "sudo -n -v"
  [[ "$output" == *"without a password"* ]]
  [[ "$output" != *"will prompt"* ]]
}

@test "an account with one rule that wants a password and one that does not is not asked" {
  # `sudo -v` insists on a password unless every rule is NOPASSWD. With no
  # terminal that is not a prompt, it is a failure - on a board where every
  # command the run needs would have gone through untouched.
  stub_body sudo <<'SH'
[ "$*" = "-v" ] && exit 1
[ "$*" = "-n -v" ] && exit 1
exit 0
SH
  bootstrap
  [ "$status" -eq 0 ]
  refute ran "sudo -v"
  [[ "$output" != *"sudo is required"* ]]
}

@test "with no way to run a command as root at all, it stops and says so" {
  stub_body sudo <<'SH'
case "$*" in "-n true" | "-n -k true" | "-v" | "-n -v") exit 1 ;; esac
exit 0
SH
  bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *"sudo is required"* ]]
}

@test "a password still cached from a minute ago is kept alive like any other" {
  # The case the first version missed: `sudo -n true` is true on the strength
  # of the cache, the run was called passwordless, and nothing refreshed it.
  stub_body sudo <<'SH'
[ "$*" = "-n -k true" ] && exit 1
[ "$*" = "-n true" ] && exit 0
exit 0
SH
  bootstrap
  [ "$status" -eq 0 ]
  ran "sudo -n -v"
}

@test "the refresher does not outlive the run" {
  needs_a_password
  bootstrap
  [ "$status" -eq 0 ]
  before="$(grep -cx 'sudo -n -v' "$STUB_LOG")"
  /bin/sleep 0.3
  [ "$(grep -cx 'sudo -n -v' "$STUB_LOG")" -eq "$before" ]
}

@test "the refresher holds nothing open that the caller is waiting on" {
  # adb shell, and `| tee`, wait for every copy of the pipe to close. The
  # refresher's sleep outlives the script by up to a minute.
  needs_a_password
  out="$BATS_TEST_TMPDIR/piped"
  env PATH="$STEPS_BIN:$PATH" timeout 20 /bin/bash "$PROJECT/bootstrap.sh" </dev/null 2>&1 | cat >"$out"
  grep -q 'done ####' "$out"
}

@test "a refused password stops the run before anything is done" {
  stub_body sudo <<'SH'
[ "$*" = "-n -k true" ] && exit 1
[ "$*" = "-n true" ] && exit 1
[ "$*" = "-v" ] && exit 1
exit 0
SH
  bootstrap
  [ "$status" -eq 1 ]
  [[ "$output" == *"sudo is required"* ]]
  refute ran_like '^bash .*/provision/'
}

# --- free space ---------------------------------------------------------------

tight_disk() {
  stub df 0 "Filesystem 1048576-blocks Used Available Capacity Mounted on
/dev/x 8206 3910 3943 50% /home/arduino"
}

@test "a board with little room and everything still to download is warned" {
  tight_disk
  bootstrap
  [[ "$output" == *"only 3943 MB free"* ]]
}

# installed <what>... - what a finished install leaves, by the steps' own tests.
installed() {
  for what in "$@"; do
    case "$what" in
      sdk)
        mkdir -p "$HOME/zephyr-sdk-1.0.1/gnu/arm-zephyr-eabi/bin"
        : >"$HOME/zephyr-sdk-1.0.1/gnu/arm-zephyr-eabi/bin/arm-zephyr-eabi-gcc"
        chmod +x "$HOME/zephyr-sdk-1.0.1/gnu/arm-zephyr-eabi/bin/arm-zephyr-eabi-gcc"
        ;;
      old-sdk)
        mkdir -p "$HOME/zephyr-sdk-0.17.0/gnu/arm-zephyr-eabi/bin"
        : >"$HOME/zephyr-sdk-0.17.0/gnu/arm-zephyr-eabi/bin/arm-zephyr-eabi-gcc"
        chmod +x "$HOME/zephyr-sdk-0.17.0/gnu/arm-zephyr-eabi/bin/arm-zephyr-eabi-gcc"
        ;;
      workspace) mkdir -p "$HOME/zephyrproject/modules/hal/stm32" ;;
    esac
  done
}

@test "a second run is not warned about room for what is already installed" {
  # 3.9 GB free on a board that has just been set up is the workspace and the
  # SDK being there, not a shortage. It warned, on every later run.
  tight_disk
  installed sdk workspace
  bootstrap
  [[ "$output" != *"only 3943 MB free"* ]]
  [[ "$output" == *"already installed"* ]]
}

@test "a workspace with no SDK is not taken for a finished install" {
  tight_disk
  installed workspace
  bootstrap
  [[ "$output" == *"only 3943 MB free"* ]]
}

@test "an install interrupted part way is still warned" {
  # The directories exist as soon as each step starts. The compiler and the
  # modules, which are most of the download, come last.
  tight_disk
  mkdir -p "$HOME/zephyrproject/zephyr" "$HOME/zephyr-sdk-1.0.1"
  bootstrap
  [[ "$output" == *"only 3943 MB free"* ]]
}

@test "an older SDK lying about does not count as the one that will be downloaded" {
  tight_disk
  installed old-sdk workspace
  bootstrap
  [[ "$output" == *"only 3943 MB free"* ]]
}

# --- a reboot, after packages change ---------------------------------------------

@test "a run that installed packages ends by saying a reboot finishes the job" {
  # needrestart is suspended while these steps run, so nothing restarts the
  # services that were running on libraries apt has just replaced.
  : >"$UNOQ_RUN_DIR/unoq-packages-changed"
  bootstrap
  [[ "$output" == *"sudo reboot"* ]]
}

@test "a run that changed no packages says nothing about rebooting" {
  bootstrap
  [[ "$output" != *"sudo reboot"* ]]
}

# --- what a run with no options sets up ------------------------------------------
#
# The demo, the web server and the USB link were options. They are what the
# course and the setup page assume, so a plain run now includes them, and
# leaving one out is what takes a flag.

ran_step() { ran_like "^sudo -E bash $PROJECT/$1\$"; }
line_of() { grep -nE "$1" "$STUB_LOG" | head -1 | cut -d: -f1; }

@test "with no options, the demo, the drive, the web server and the USB link are all set up" {
  bootstrap
  [ "$status" -eq 0 ]
  ran_step provision/65-cpu-bars.sh
  ran_step share/build-image.sh
  ran_step provision/75-learning-web.sh
  ran_step provision/95-usb-gadget.sh
}

@test "with no options, nothing that has to be asked for by name is run" {
  bootstrap
  [ "$status" -eq 0 ]
  refute ran_step provision/55-purge-arduino.sh
  refute ran_step provision/80-watchdog.sh
  refute ran_step provision/85-esp-permissions.sh
  refute ran_step provision/82-boot-counting.sh
}

@test "boot counting runs with --everything or by name, and not by default" {
  bootstrap --everything
  [ "$status" -eq 0 ]
  ran_step provision/82-boot-counting.sh
  refute ran_step provision/80-watchdog.sh
  refute ran_step provision/85-esp-permissions.sh
  : >"$STUB_LOG"
  bootstrap --with-boot-counting
  [ "$status" -eq 0 ]
  ran_step provision/82-boot-counting.sh
}

@test "--minimal leaves out all three, and the drive image with them" {
  bootstrap --minimal
  [ "$status" -eq 0 ]
  refute ran_step provision/65-cpu-bars.sh
  refute ran_step provision/75-learning-web.sh
  refute ran_step provision/95-usb-gadget.sh
  refute ran_step share/build-image.sh
  # and is still a whole board: firmware built, space given back
  ran_like 'mcu/zbuild\.sh'
  ran_step provision/90-cleanup.sh
}

@test "each --no- leaves out its own and only its own" {
  bootstrap --no-usb-gadget
  refute ran_step provision/95-usb-gadget.sh
  ran_step provision/65-cpu-bars.sh
  ran_step provision/75-learning-web.sh
  : >"$STUB_LOG"
  bootstrap --no-learning
  refute ran_step provision/75-learning-web.sh
  ran_step provision/95-usb-gadget.sh
  ran_step share/build-image.sh
  : >"$STUB_LOG"
  bootstrap --no-cpu-bars
  refute ran_step provision/65-cpu-bars.sh
  ran_step provision/95-usb-gadget.sh
}

@test "the old --with- options are still accepted, and mean what they meant" {
  bootstrap --with-cpu-bars --with-usb-gadget --with-learning
  [ "$status" -eq 0 ]
  ran_step provision/95-usb-gadget.sh
  bootstrap --everything
  [ "$status" -eq 0 ]
  ran_step provision/55-purge-arduino.sh
}

@test "an option given after --minimal puts that one thing back" {
  bootstrap --minimal --with-learning
  ran_step provision/75-learning-web.sh
  refute ran_step provision/95-usb-gadget.sh
}

@test "the notice names each default with the option that leaves it out" {
  bootstrap
  [[ "$output" == *"--no-cpu-bars"* ]]
  [[ "$output" == *"--no-learning"* ]]
  [[ "$output" == *"--no-usb-gadget"* ]]
  [[ "$output" == *"no password"* ]]
  [[ "$output" == *"adb stops working"* ]]
}

@test "the notice does not mention what a --minimal run will not do" {
  bootstrap --minimal
  [[ "$output" != *"port 8080"* ]]
  [[ "$output" != *"adb stops working"* ]]
}

@test "the USB link is still the last step, after the clean-up" {
  bootstrap
  usb="$(line_of "^sudo -E bash $PROJECT/provision/95-usb-gadget\.sh\$")"
  clean="$(line_of "^sudo -E bash $PROJECT/provision/90-cleanup\.sh\$")"
  web="$(line_of "^sudo -E bash $PROJECT/provision/75-learning-web\.sh\$")"
  [ "$web" -lt "$clean" ]
  [ "$clean" -lt "$usb" ]
}

# --- the demo, while the chip is written --------------------------------------------

# demo_in <state> - what systemd says the demo's ActiveState is.
demo_in() {
  echo "$1" >"$BATS_TEST_TMPDIR/demo-state"
  stub_body systemctl <<SH
[ "\$1" = show ] && { cat "$BATS_TEST_TMPDIR/demo-state"; exit 0; }
exit 0
SH
}
demo_running() { demo_in active; }

@test "a running demo is stopped before the flash, so it spends none of its retries on it" {
  demo_running
  bootstrap
  [ "$status" -eq 0 ]
  stop="$(line_of '^sudo systemctl stop unoq-cpu-bars.service$')"
  flash="$(line_of 'mcu/flash-all\.sh')"
  [ -n "$stop" ] && [ -n "$flash" ]
  [ "$stop" -lt "$flash" ]
}

@test "a demo caught between two retries is stopped as well" {
  # activating (auto-restart): where the unit sits for RestartSec between
  # attempts. Not "active", and still about to try again, all through the flash.
  demo_in activating
  bootstrap
  ran "sudo systemctl stop unoq-cpu-bars.service"
}

@test "a demo that was not running is not stopped" {
  demo_in inactive
  bootstrap
  refute ran_like '^sudo systemctl stop unoq-cpu-bars'
}

@test "left out of this run but installed by an earlier one, the demo is started again" {
  # --no-cpu-bars skips the step that would have started it. Leaving a
  # service this run did not install stopped would be a change nobody asked for.
  demo_running
  bootstrap --no-cpu-bars
  [ "$status" -eq 0 ]
  ran "sudo systemctl start unoq-cpu-bars.service"
  # ...with its count of recent starts cleared first. Stopped on its last
  # permitted attempt, it would otherwise be refused the start.
  reset="$(line_of '^sudo systemctl reset-failed unoq-cpu-bars.service$')"
  start="$(line_of '^sudo systemctl start unoq-cpu-bars.service$')"
  [ -n "$reset" ] && [ "$reset" -lt "$start" ]
}

@test "in the usual run it is not started twice: the demo step does that" {
  demo_running
  bootstrap
  refute ran "sudo systemctl start unoq-cpu-bars.service"
  ran_step provision/65-cpu-bars.sh
}

@test "a demo that has already given up is not 'stopped': it is failed, and stays for step 65" {
  demo_in failed
  bootstrap
  refute ran_like '^sudo systemctl stop unoq-cpu-bars'
}

@test "with --skip-mcu nothing is flashed and the demo is left alone" {
  demo_running
  bootstrap --skip-mcu
  refute ran_like '^sudo systemctl stop unoq-cpu-bars'
}
