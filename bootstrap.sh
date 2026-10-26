#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Take a stock, freshly flashed Arduino UNO Q to a working hybrid dev board.
#
#   git clone https://github.com/jim-wyatt/two-computers-one-board.git ~/two-computers-one-board
#   cd ~/two-computers-one-board && ./bootstrap.sh
#
# Run it as YOURSELF, not as root: it calls sudo for the parts that need it and
# keeps everything else owned by you. A bootstrap that runs wholly as root
# leaves a $HOME full of root-owned files, which is the most common way this
# kind of script half-works.
#
# IDEMPOTENT. Re-running is the recovery path: every step reports "changed" or
# "already correct", so a run that died halfway is fixed by running it again,
# not by unpicking what it did.
#
# WHAT IT SETS UP, WITH NO OPTIONS
# --------------------------------
# The board the course is taught on, whole: the toolchain, this project's
# firmware, and the three things that make it a board you can use from the
# computer next to it.
#
#   - the CPU-bars demo on the LED matrix, from boot      (--no-cpu-bars)
#   - the course, served by the board on port 8080        (--no-learning)
#   - network and a drive over the USB cable               (--no-usb-gadget)
#
# They were options once. Someone following the setup page then had to know to
# ask for the demo the exercises are built on, and found out about the web page
# by wondering where it was. Each costs something - the demo holds the MCU's
# serial port, the web server has no password, the USB link takes the port from
# adb and switches SSH on - and the notice printed before anything happens says
# so, with the option that leaves it out. --minimal leaves out all three.
#
# WHAT IT STILL DOES NOT DO, UNLESS ASKED
# ---------------------------------------
#   - purge the Arduino packages (--with-purge; it is the one step you cannot
#     casually undo, and the stock MCU firmware is not ours to redistribute)
#   - arm the hardware watchdog (--with-watchdog) or tighten the EFI
#     partition's permissions (--with-esp-lockdown). Each has been run on one
#     board, through reboots, and that is all: one can reset the board and the
#     other edits the fstab entry it boots from
#
# TIME AND SPACE: 18 minutes 59 seconds on a factory-restored board over home
# broadband, with no options, timed on 2026-10-11. The Zephyr workspace (~2 GB) and SDK (~0.8 GB) are most of the
# download, and 3.3 GB ends up in the home directory. Make sure you have ~6 GB
# free: the builds and the drive image need room as well.
set -uo pipefail

PROJECT="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT" || exit 1
# shellcheck source=provision/lib.sh
. "$PROJECT/provision/lib.sh"

WITH_PURGE=0
WITH_CPU_BARS=1
WITH_USB_GADGET=1
WITH_LEARNING=1
WITH_WATCHDOG=0
WITH_ESP_LOCKDOWN=0
WITH_BOOT_COUNTING=0
SKIP_MCU=0

usage() {
  sed -n '2,/^set -uo pipefail$/p' "$0" | sed '$d'
  cat <<'EOF'

Leave out something that is on by default:
  --no-cpu-bars       no LED-matrix demo at boot (65). It holds /dev/ttyHS1.
  --no-learning       no web server for the course on port 8080 (75)
  --no-usb-gadget     no network and drive over USB (95). Keeps adb on the
                      USB port, and leaves SSH as it was.
  --minimal           none of those three

Add something that is not:
  --with-purge        also remove the Arduino Debian packages (55)
  --with-watchdog     also arm the hardware watchdog (80): the board resets if
                      systemd stops for 30s. It came through one firmware build
                      under heavy swap without firing; it has never been made
                      to fire on purpose.
  --with-esp-lockdown also make the EFI partition root-only (85). Edits the
                      /etc/fstab entry the board boots from, backed up first.
  --with-boot-counting
                      also boot new kernels on trial (82): one that does not
                      come up with SSH three times running is set aside for
                      the previous kernel.

  --skip-mcu          do not build or flash the MCU firmware
  -h, --help          this

--with-cpu-bars, --with-learning, --with-usb-gadget and --everything are still
accepted: the first three ask for what now happens anyway, and --everything
adds --with-purge and --with-boot-counting.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --with-purge) WITH_PURGE=1 ;;
    --no-cpu-bars) WITH_CPU_BARS=0 ;;
    --no-usb-gadget) WITH_USB_GADGET=0 ;;
    --no-learning) WITH_LEARNING=0 ;;
    --minimal)
      WITH_CPU_BARS=0
      WITH_USB_GADGET=0
      WITH_LEARNING=0
      ;;
    # Once the way to ask for these. They are the default now, and a command
    # copied from an older page must go on meaning what it meant.
    --with-cpu-bars) WITH_CPU_BARS=1 ;;
    --with-usb-gadget) WITH_USB_GADGET=1 ;;
    --with-learning) WITH_LEARNING=1 ;;
    --with-watchdog) WITH_WATCHDOG=1 ;;
    --with-esp-lockdown) WITH_ESP_LOCKDOWN=1 ;;
    --with-boot-counting) WITH_BOOT_COUNTING=1 ;;
    # The watchdog and the EFI lockdown are in neither the default nor
    # --everything, on purpose. For those two the evidence is one board: each
    # ran there and came back from reboots, the watchdog through a firmware
    # build with swap nearly full. That is a board it works on, not a reason to
    # switch it on for everybody - one can reset the board mid-build, the other
    # edits the fstab entry it boots from. Each has to be asked for by name
    # until it has been seen on more than one.
    # Boot counting is in --everything: on its own board it went through a
    # counted boot and was marked good, and what it risks is a kernel that has
    # yet to be installed, with the previous one there to fall back to.
    --everything)
      WITH_PURGE=1
      WITH_BOOT_COUNTING=1
      WITH_CPU_BARS=1
      WITH_USB_GADGET=1
      WITH_LEARNING=1
      ;;
    --skip-mcu) SKIP_MCU=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $arg (try --help)" >&2
      exit 2
      ;;
  esac
done

[ "$(id -u)" = 0 ] && fail "run this as yourself, not with sudo - it calls sudo where needed"

# The user-level steps install cmake, ninja, west and uv into ~/.local/bin. On a
# board that has been logged into since, the login shell put that on PATH. On a
# first run it did not exist at login, so nothing did - and everything after
# the step that created it could not find what it had just installed.
export PATH="$HOME/.local/bin:$PATH"
# Tells each step it is one of many, so that warnings about the board as a
# whole are left for the end of this script. -E carries it through sudo.
export UNOQ_IN_BOOTSTRAP=1

# --- what this is about to do ----------------------------------------------

# Said before anything happens, not discovered afterwards. The two-line install
# in the README is all most people read, and it used to be possible to lose a
# sketch, the desktop and App Lab on the strength of it.
#
# A pause, not a prompt: a prompt would stop this being runnable unattended,
# and re-running it unattended is the recovery path. Only on a terminal, so a
# script driving this is not held up for a notice nobody is reading.
echo
echo "This will change this board. With the options given, it will:"
echo
echo "  - switch off the desktop, Arduino's services, Docker and automatic updates"
echo "  - upgrade the installed packages"
echo "  - install the Zephyr SDK and workspace into $HOME (~3 GB)"
[ "$SKIP_MCU" = 0 ] &&
  echo "  - REPLACE THE FIRMWARE ON THE MICROCONTROLLER (the stock image is saved first)"
[ "$WITH_PURGE" = 1 ] &&
  echo "  - REMOVE THE ARDUINO PACKAGES (--with-purge; hard to undo)"
[ "$WITH_CPU_BARS" = 1 ] &&
  echo "  - run the CPU-bars demo from boot, which holds the serial port to the microcontroller (--no-cpu-bars to leave it out)"
[ "$WITH_LEARNING" = 1 ] &&
  echo "  - serve the course on port 8080, with no password, to anything that can reach the board (--no-learning)"
[ "$WITH_USB_GADGET" = 1 ] &&
  echo "  - make the USB port a network link and a drive: adb stops working, SSH is switched on, and the port can no longer host devices (--no-usb-gadget)"
[ "$WITH_WATCHDOG" = 1 ] &&
  echo "  - arm the hardware watchdog: the board RESETS ITSELF if systemd stalls (--with-watchdog; held through one loaded build, on one board)"
[ "$WITH_ESP_LOCKDOWN" = 1 ] &&
  echo "  - edit the /boot/efi line of /etc/fstab, the partition this board boots from (--with-esp-lockdown; backed up first)"
[ "$WITH_BOOT_COUNTING" = 1 ] &&
  echo "  - boot every new kernel on trial, falling back to the previous one by itself (--with-boot-counting)"
echo
echo "Every change is listed, with how to undo it, in docs/setup.md."
if [ -t 0 ]; then
  echo "Ctrl-C now if that is not what you want. Starting in 10 seconds..."
  sleep 10
fi

# --- preflight -------------------------------------------------------------

step "preflight"

# `compatible` is a list of NUL-separated strings, most-specific first. It has
# to be split ON the NULs, not stripped OF them: `tr -d` concatenated the three
# tokens into "arduino,imolaqcom,qrb2210qcom,qcm2290", which matches neither
# board, so this check warned "unrecognized board" on every UNO Q and every
# VENTUNO Q it ever ran on - an identity check that had never once identified
# anything.
BOARD="$(tr '\0' '\n' </sys/firmware/devicetree/base/compatible 2>/dev/null | head -1)"
case "$BOARD" in
  arduino,imola) skip "board: Arduino UNO Q ($BOARD)" ;;
  arduino,monza) skip "board: Arduino VENTUNO Q ($BOARD)" ;;
  "") warn "cannot read the devicetree - this may not be an UNO Q. Continuing." ;;
  *) warn "unrecognized board '$BOARD' - written for arduino,imola. Continuing." ;;
esac

# SUDO, ONCE, AND THEN KEPT
# -------------------------
# sudo remembers a password for fifteen minutes. The Zephyr workspace alone
# takes longer than that to download, and the steps after it need root. So
# "once, cached for the run" was true only on a board with passwordless sudo,
# which is what this was developed on; a stock board asks again, an hour in, at
# a prompt nobody is sitting at. The first stock board to be looked at after a
# factory restore showed it: its sudo wants a password.
#
# So the timestamp is refreshed once a minute for as long as this script is
# alive - ALWAYS, not only when a password seems to be needed. Deciding that
# was tried twice and is not worth depending on:
#
#   sudo -n true        true for an account that needs a password and used
#                       sudo a minute ago, so the refresher never started
#   sudo -n -k -v       the careful version. False on a machine whose sudo
#                       needs no password at all, under one sudo
#                       implementation, and true under another
#
# A refresher on a passwordless machine is one command a minute that does
# nothing. One that is missing where it was needed is the original failure. So
# the probe below only chooses the wording, and nothing rests on it.
if sudo -n -k true 2>/dev/null; then
  skip "sudo available without a password"
else
  echo "  sudo will prompt for your password, once."
fi
# `sudo -n true` first: if a command already runs without a prompt, that is
# the whole of what is needed, and `sudo -v` must not be asked. -v wants a
# password unless EVERY rule for the account is NOPASSWD, so on a board with one
# rule that needs a password and one that does not, it prompts on a terminal
# and fails outright without one (over ssh, from a script) - for a run in which
# nothing would have asked. Found by the second run on a real board.
sudo -n true 2>/dev/null || sudo -v || fail "sudo is required"
# -n, so that if the timestamp has lapsed anyway the refresher stops quietly
# rather than putting a second prompt in the middle of somebody else's output;
# the step that needs root will then ask, which is no worse than before. It
# ends with this script, by the trap and by the check on $$. Its output is
# closed so that the sleep it leaves behind for up to a minute does not hold a
# pipe open (adb shell, | tee) after the script has finished.
(
  while kill -0 "$$" 2>/dev/null; do
    sleep 60
    sudo -n -v 2>/dev/null || exit 0
  done
) >/dev/null 2>&1 </dev/null &
SUDO_KEEPALIVE=$!
# shellcheck disable=SC2064  # the PID is known now, and must not change
trap "kill $SUDO_KEEPALIVE 2>/dev/null" EXIT

FREE_MB=$(df -Pm "$HOME" | awk 'NR==2 {print $4}')
# Asked only of a board that still has the downloading ahead of it. On a second
# run the SDK and the workspace are already there, about 3 GB of them, and this
# warned that there was not room for what was sitting on the disk.
#
# "Already there" is the test each step uses for itself, not a directory
# existing: an SDK is its compiler, and a workspace is its modules, which are
# the last and largest thing fetched. A run interrupted half way has the
# directories and still has the downloading to do.
INSTALLED_WS="${ZEPHYR_WORKSPACE:-$HOME/zephyrproject}"
# The SDK that will be asked for, not any SDK: an older one lying about does
# not save the download. Same default as provision/user/25-zephyr-sdk.sh.
INSTALLED_SDK="$HOME/zephyr-sdk-${ZEPHYR_SDK_VERSION:-1.0.1}"
if [ -d "$INSTALLED_WS/modules/hal/stm32" ] &&
  { [ -x "$INSTALLED_SDK/gnu/arm-zephyr-eabi/bin/arm-zephyr-eabi-gcc" ] ||
    [ -x "$INSTALLED_SDK/arm-zephyr-eabi/bin/arm-zephyr-eabi-gcc" ]; }; then
  skip "${FREE_MB} MB free in $HOME (the SDK and workspace are already installed)"
elif [ "$FREE_MB" -lt 6000 ]; then
  warn "only ${FREE_MB} MB free in $HOME - the SDK and workspace need ~3 GB, and the builds more"
else
  skip "${FREE_MB} MB free in $HOME"
fi

curl -fsS --max-time 20 -o /dev/null https://github.com 2>/dev/null ||
  fail "no network access - the SDK, Zephyr and PyPI all need to be reachable"
skip "network reachable"

# Take the stock MCU image now, while it is certainly still there.
#
# It ships in the arduino-* debs, so a factory-fresh board has one and a board
# that has been purged or reflashed does not. 55-purge-arduino.sh also saves it,
# but that step is optional and most people never run it - so on most boards the
# only copy sits in ~/.arduino15 until the day it is wanted, which is usually
# the day after something removed it. It is 634 KB and it is not ours to redistribute,
# so a lost copy means a factory restore to get it back.
HAVE_STOCK_FW=1
backup_stock_firmware || {
  HAVE_STOCK_FW=0
  warn "no stock MCU firmware found to back up, and no earlier copy in
        ${UNOQ_BACKUP:-$HOME/uno-q-backup}"
}

# --- run the steps ---------------------------------------------------------

# run_step <label> <sudo|user> <script> [args...]
run_step() {
  local label="$1" mode="$2" script="$3"
  shift 3
  printf '\n%s########## %s ##########%s\n' "$P_BOLD" "$label" "$P_OFF"
  if [ "$mode" = sudo ]; then
    sudo -E bash "$script" "$@" || fail "$label failed - fix it and re-run bootstrap.sh"
  else
    bash "$script" "$@" || fail "$label failed - fix it and re-run bootstrap.sh"
  fi
}

run_step "10  board optimization (root)" sudo "$PROJECT/provision/10-optimize-board.sh"
run_step "15  dev tools (root)" sudo "$PROJECT/provision/15-dev-tools.sh"

run_step "20  host tools: uv, cmake, ninja, west (you)" user "$PROJECT/provision/user/20-host-tools.sh"
run_step "25  Zephyr SDK (you)" user "$PROJECT/provision/user/25-zephyr-sdk.sh"
run_step "30  Zephyr workspace, the long download (you)" user "$PROJECT/provision/user/30-zephyr-workspace.sh"
run_step "35  python venv + unoq package (you)" user "$PROJECT/provision/user/35-python-venv.sh"
run_step "40  shell env + git hook (you)" user "$PROJECT/provision/user/40-shell-env.sh"

# 45 needs the venv from 35 to verify the GPIO lines, so it runs after it.
run_step "45  MCU link GPIOs (root)" sudo "$PROJECT/provision/45-mcu-link.sh"
# Unconditional, deliberately: these are the board's only output when the
# network is down and nobody can log in, so they must not depend on an extra.
run_step "50  status LEDs (root)" sudo "$PROJECT/provision/50-status-leds.sh"

[ "$WITH_PURGE" = 1 ] &&
  run_step "55  purge Arduino packages (root)" sudo "$PROJECT/provision/55-purge-arduino.sh"

# --- MCU firmware ----------------------------------------------------------

# A build or a flash that fails does not stop the run - the optional extras
# below do not depend on it, and half a board is easier to fix than none. But
# it used to end there: a line of yellow in the middle of a long log, then
# "done" and exit status 0. On the board this project is developed on that hid
# a build that had been failing for two months. So it is remembered, the
# reason is shown where it happened, and the run ends by saying so and
# exiting non-zero.
#
# WHAT IS ON THE CHIP is remembered separately, because the two failures leave
# it in different states and the closing message used to give one answer for
# both: "the microcontroller is running whatever it ran before". True of a
# build that failed - nothing was written. Not something anyone can promise of
# a flash that failed: flash-all.sh writes the bootloader and then the
# application, as two operations, and stopping in or between them can leave a
# new bootloader in front of an old application, or half of either.
FIRMWARE_PROBLEM=""
FIRMWARE_STATE=""
# /tmp unless TMPDIR says otherwise, which is what lets tests/bootstrap.bats
# run this without writing over a real run's logs.
BUILD_LOG="${TMPDIR:-/tmp}/zbuild-bootstrap.log"
FLASH_LOG="${TMPDIR:-/tmp}/zflash-bootstrap.log"

if [ "$SKIP_MCU" = 0 ]; then
  printf '\n%s########## 60  MCU firmware ##########%s\n' "$P_BOLD" "$P_OFF"
  step "build"
  if bash "$PROJECT/mcu/zbuild.sh" "$PROJECT/mcu/app" >"$BUILD_LOG" 2>&1; then
    did "firmware built (log: $BUILD_LOG)"
  else
    warn "build failed - skipping the flash. The end of $BUILD_LOG:"
    tail -n 6 "$BUILD_LOG" | sed 's/^/          /' >&2
    FIRMWARE_PROBLEM="the firmware did not build"
    FIRMWARE_STATE="Nothing was written to the microcontroller: it is running whatever it
        ran before. Fix the cause shown under 'MCU firmware' above and run
        this again."
    SKIP_MCU=1
  fi
fi

# No copy of what is on the chip, so do not write over it.
#
# This used to be a warning that the flash then walked straight past, while
# 55-purge-arduino.sh - which only deletes the file the copy is made from -
# refuses outright in the same situation. The step that overwrites the firmware
# itself was the one that did not check. A factory restore brings the stock
# image back, so nothing here was unrecoverable; it was just not what anyone
# agreed to. The firmware is still built, so the override is one command away.
if [ "$SKIP_MCU" = 0 ] && [ "$HAVE_STOCK_FW" = 0 ] && [ "${UNOQ_ALLOW_NO_STOCK_FW:-0}" != 1 ]; then
  step "flash"
  warn "NOT flashing: there is no copy of the firmware currently on the microcontroller."
  warn "  If that is fine (the board already runs this firmware, or you do not"
  warn "  want the stock image back), flash it yourself:"
  warn "    $PROJECT/mcu/flash-all.sh"
  warn "  or re-run with UNOQ_ALLOW_NO_STOCK_FW=1 in front of ./bootstrap.sh"
  SKIP_MCU=1
fi

if [ "$SKIP_MCU" = 0 ]; then
  step "flash"
  # An MCUboot build must be flashed as the full chain the first time: the
  # signed app alone lands in slot0 with no bootloader in front of it.
  # The demo is paused while the chip is written. It talks to the MCU twice a
  # second and retries when it gets no answer, and it only has so many retries
  # before systemd calls it failed (see python/unoq-cpu-bars.service): a flash
  # was measured using seven of the twelve. Stopped, it uses none. It is
  # started again below - by step 65 in the usual case, and here when this run
  # was asked to leave the demo out but an earlier one installed it.
  # "activating" as well as "active": between attempts the unit sits in
  # activating (auto-restart) for RestartSec, and a run that began in that
  # gap would have left it retrying through the whole flash.
  DEMO_PAUSED=0
  case "$(systemctl show unoq-cpu-bars.service -p ActiveState --value 2>/dev/null)" in
    active | activating)
      sudo systemctl stop unoq-cpu-bars.service && DEMO_PAUSED=1
      ;;
  esac
  # flash-all.sh derives the workspace itself.
  if bash "$PROJECT/mcu/flash-all.sh" >"$FLASH_LOG" 2>&1; then
    did "MCUboot + application flashed"
  else
    warn "flash failed. The end of $FLASH_LOG:"
    tail -n 6 "$FLASH_LOG" | sed 's/^/          /' >&2
    FIRMWARE_PROBLEM="the firmware was built but could not be flashed"
    FIRMWARE_STATE="DO NOT ASSUME THE MICROCONTROLLER IS AS IT WAS. The bootloader and the
        application are written one after the other, and a flash that stops
        part-way can leave it with one and not the other, or not booting.
        $FLASH_LOG shows how far it got. Once the cause is
        fixed, write both again:
          $PROJECT/mcu/flash-all.sh"
    warn "the microcontroller may be partly written. Recover with: $PROJECT/mcu/flash-all.sh"
  fi
  if [ "$DEMO_PAUSED" = 1 ] && [ "$WITH_CPU_BARS" = 0 ]; then
    # The count of recent starts first, for the same reason step 65 clears it:
    # a demo stopped on its last permitted attempt would be refused this start.
    sudo systemctl reset-failed unoq-cpu-bars.service 2>/dev/null || true
    sudo systemctl start unoq-cpu-bars.service ||
      warn "could not start unoq-cpu-bars again - check: journalctl -u unoq-cpu-bars -n 20"
  fi
fi

# --- optional extras -------------------------------------------------------

[ "$WITH_CPU_BARS" = 1 ] &&
  run_step "65  CPU bars at boot (root)" sudo "$PROJECT/provision/65-cpu-bars.sh"
# Both of the next two hand out the same image: the web server serves from it
# and the gadget exports it as the drive. Nothing used to build it here, so
# --with-learning stopped at "has no content. Build the share first" on every
# board that had not already had it built by hand - which is every fresh one,
# and it took --everything down with it. build-image.sh renders the
# documentation itself, so this is the whole of what they need. The VS Code
# installers are a separate, deliberate download: share/fetch-vscode.sh.
if [ "$WITH_LEARNING" = 1 ] || [ "$WITH_USB_GADGET" = 1 ]; then
  run_step "70  the drive image, with this documentation on it (root)" sudo "$PROJECT/share/build-image.sh"
fi
[ "$WITH_LEARNING" = 1 ] &&
  run_step "75  learning content web server (root)" sudo "$PROJECT/provision/75-learning-web.sh"
# The two that are asked for by name only (see the argument parsing). Down
# here, after the firmware build and the image build, so the watchdog is never
# armed for the first time with the longest jobs of the run still ahead of it,
# and 85 edits /etc/fstab after 70 has added its line, not before.
[ "$WITH_WATCHDOG" = 1 ] &&
  run_step "80  hardware watchdog (root)" sudo "$PROJECT/provision/80-watchdog.sh"
[ "$WITH_BOOT_COUNTING" = 1 ] &&
  run_step "82  kernels boot on trial (root)" sudo "$PROJECT/provision/82-boot-counting.sh"
[ "$WITH_ESP_LOCKDOWN" = 1 ] &&
  run_step "85  EFI partition permissions (root)" sudo "$PROJECT/provision/85-esp-permissions.sh"
# Always, and after everything that downloads or installs: what the run
# fetched in order to build things is not needed once they are built.
run_step "90  disk space back (root)" sudo "$PROJECT/provision/90-cleanup.sh"
# Last, always: it takes the USB host port down with it.
[ "$WITH_USB_GADGET" = 1 ] &&
  run_step "95  USB gadget (root)" sudo "$PROJECT/provision/95-usb-gadget.sh"

# --- done ------------------------------------------------------------------

printf '\n%s########## done ##########%s\n' "$P_BOLD" "$P_OFF"
cat <<EOF

  source $PROJECT/env.sh          # or open a new shell
  $PROJECT/tools/check.sh         # all quality gates
  mcucon                          # watch the MCU console

  hpy -c "from unoq import MCU; print(MCU().status())"   # ask the MCU how it is

EOF
[ "$WITH_CPU_BARS" = 0 ] &&
  echo "  LED matrix demo at boot:  sudo bash provision/65-cpu-bars.sh"
[ "$WITH_PURGE" = 0 ] &&
  echo "  Reclaim the Arduino disk: sudo bash provision/55-purge-arduino.sh"
[ "$WITH_USB_GADGET" = 0 ] &&
  echo "  IP over USB + fileshare:  sudo bash provision/95-usb-gadget.sh"
echo

# Once, after everything that was going to run has run. What is left here is
# what this invocation did not reach - typically the USB units, on a board that
# has the gadget and was not asked for it again.
warn_stale_root_units
# And what the red light, if there is one, is about.
warn_failed_units
# And whether anything running is still the version from before the run.
advise_reboot

if [ -n "$FIRMWARE_PROBLEM" ]; then
  fail "everything above is in place, but $FIRMWARE_PROBLEM.
        $FIRMWARE_STATE"
fi
