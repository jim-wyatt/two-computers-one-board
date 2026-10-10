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
# WHAT IT DOES NOT DO
# -------------------
#   - purge the Arduino stack (--with-purge; it is the one step you cannot
#     casually undo, and the stock MCU firmware is not ours to redistribute)
#   - claim /dev/ttyHS1 for the LED matrix demo (--with-cpu-bars)
#   - switch the USB port to peripheral mode (--with-usb-gadget; it drops the
#     USB host port and every device on it, including a network dongle)
#
# TIME AND SPACE: ~40-60 minutes on a cold board, almost all of it the Zephyr
# workspace (~3.3 GB) and SDK (~1 GB). Make sure you have ~6 GB free.
set -uo pipefail

PROJECT="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT" || exit 1
# shellcheck source=provision/lib.sh
. "$PROJECT/provision/lib.sh"

WITH_PURGE=0
WITH_CPU_BARS=0
WITH_USB_GADGET=0
WITH_LEARNING=0
SKIP_MCU=0

usage() {
  sed -n '2,30p' "$0"
  cat <<'EOF'

Options:
  --with-purge        also remove the Arduino Debian packages (40)
  --with-cpu-bars     also run the LED-matrix demo at boot (50) - holds ttyHS1
  --with-usb-gadget   also enable IP-over-USB + the fileshare (60)
                      WARNING: drops the USB host port and anything on it
  --with-learning     also serve the learning content over HTTP (70)
  --everything        all of the above
  --skip-mcu          do not build or flash the MCU firmware at the end
  -h, --help          this
EOF
}

for arg in "$@"; do
  case "$arg" in
    --with-purge) WITH_PURGE=1 ;;
    --with-cpu-bars) WITH_CPU_BARS=1 ;;
    --with-usb-gadget) WITH_USB_GADGET=1 ;;
    --with-learning) WITH_LEARNING=1 ;;
    --everything)
      WITH_PURGE=1
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
echo "  - install the Zephyr SDK and workspace into $HOME (~4.5 GB)"
[ "$SKIP_MCU" = 0 ] &&
  echo "  - REPLACE THE FIRMWARE ON THE MICROCONTROLLER (the stock image is saved first)"
[ "$WITH_PURGE" = 1 ] &&
  echo "  - REMOVE THE ARDUINO PACKAGES (--with-purge; hard to undo)"
[ "$WITH_USB_GADGET" = 1 ] &&
  echo "  - give up the USB host port and everything plugged into it (--with-usb-gadget)"
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
# board, so this check warned "unrecognised board" on every UNO Q and every
# VENTUNO Q it ever ran on - an identity check that had never once identified
# anything.
BOARD="$(tr '\0' '\n' </sys/firmware/devicetree/base/compatible 2>/dev/null | head -1)"
case "$BOARD" in
  arduino,imola) skip "board: Arduino UNO Q ($BOARD)" ;;
  arduino,monza) skip "board: Arduino VENTUNO Q ($BOARD)" ;;
  "") warn "cannot read the devicetree - this may not be an UNO Q. Continuing." ;;
  *) warn "unrecognised board '$BOARD' - written for arduino,imola. Continuing." ;;
esac

if sudo -n true 2>/dev/null; then
  skip "sudo available without a password"
else
  echo "  sudo will prompt for your password (once, cached for the run)."
  sudo -v || fail "sudo is required"
fi

FREE_MB=$(df -Pm "$HOME" | awk 'NR==2 {print $4}')
if [ "$FREE_MB" -lt 6000 ]; then
  warn "only ${FREE_MB} MB free in $HOME - the SDK and workspace need ~4.5 GB"
else
  skip "${FREE_MB} MB free in $HOME"
fi

curl -fsS --max-time 20 -o /dev/null https://github.com 2>/dev/null ||
  fail "no network access - the SDK, Zephyr and PyPI all need to be reachable"
skip "network reachable"

# Take the stock MCU image now, while it is certainly still there.
#
# It ships in the arduino-* debs, so a factory-fresh board has one and a board
# that has been purged or reflashed does not. 40-purge-arduino.sh also saves it,
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

run_step "10  board optimisation (root)" sudo "$PROJECT/provision/10-optimize-board.sh"
run_step "20  dev tools (root)" sudo "$PROJECT/provision/20-dev-tools.sh"

run_step "u10 host tools: uv, cmake, ninja, west" user "$PROJECT/provision/user/10-host-tools.sh"
run_step "u20 Zephyr SDK" user "$PROJECT/provision/user/20-zephyr-sdk.sh"
run_step "u30 Zephyr workspace (~3.3 GB, slow)" user "$PROJECT/provision/user/30-zephyr-workspace.sh"
run_step "u40 python venv + unoq package" user "$PROJECT/provision/user/40-python-venv.sh"
run_step "u50 shell env + git hook" user "$PROJECT/provision/user/50-shell-env.sh"

# 30 needs the venv from u40 to verify the GPIO lines, so it runs after it.
run_step "30  MCU link GPIOs (root)" sudo "$PROJECT/provision/30-mcu-link.sh"
# Unconditional, deliberately: these are the board's only output when the
# network is down and nobody can log in, so they must not depend on an extra.
run_step "35  status LEDs (root)" sudo "$PROJECT/provision/35-status-leds.sh"

[ "$WITH_PURGE" = 1 ] &&
  run_step "40  purge Arduino packages (root)" sudo "$PROJECT/provision/40-purge-arduino.sh"

# --- MCU firmware ----------------------------------------------------------

# A build or a flash that fails does not stop the run - the optional extras
# below do not depend on it, and half a board is easier to fix than none. But
# it used to end there: a line of yellow in the middle of a long log, then
# "done" and exit status 0. On the board this project is developed on that hid
# a build that had been failing for two months. So it is remembered, the
# reason is shown where it happened, and the run ends by saying so and
# exiting non-zero.
FIRMWARE_PROBLEM=""

if [ "$SKIP_MCU" = 0 ]; then
  printf '\n%s########## MCU firmware ##########%s\n' "$P_BOLD" "$P_OFF"
  step "build"
  if bash "$PROJECT/mcu/zbuild.sh" "$PROJECT/mcu/app" >/tmp/zbuild-bootstrap.log 2>&1; then
    did "firmware built (log: /tmp/zbuild-bootstrap.log)"
  else
    warn "build failed - skipping the flash. The end of /tmp/zbuild-bootstrap.log:"
    tail -n 6 /tmp/zbuild-bootstrap.log | sed 's/^/          /' >&2
    FIRMWARE_PROBLEM="the firmware did not build"
    SKIP_MCU=1
  fi
fi

# No copy of what is on the chip, so do not write over it.
#
# This used to be a warning that the flash then walked straight past, while
# 40-purge-arduino.sh - which only deletes the file the copy is made from -
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
  # flash-all.sh derives the workspace itself.
  if bash "$PROJECT/mcu/flash-all.sh" >/tmp/zflash-bootstrap.log 2>&1; then
    did "MCUboot + application flashed"
  else
    warn "flash failed. The end of /tmp/zflash-bootstrap.log:"
    tail -n 6 /tmp/zflash-bootstrap.log | sed 's/^/          /' >&2
    FIRMWARE_PROBLEM="the firmware was built but could not be flashed"
    warn "recover with: $PROJECT/mcu/flash-all.sh"
  fi
fi

# --- optional extras -------------------------------------------------------

[ "$WITH_CPU_BARS" = 1 ] &&
  run_step "50  CPU bars at boot (root)" sudo "$PROJECT/provision/50-cpu-bars.sh"
# Both of the next two hand out the same image: the web server serves from it
# and the gadget exports it as the drive. Nothing used to build it here, so
# --with-learning stopped at "has no content. Build the share first" on every
# board that had not already had it built by hand - which is every fresh one,
# and it took --everything down with it. build-image.sh renders the
# documentation itself, so this is the whole of what they need. The VS Code
# installers are a separate, deliberate download: share/fetch-vscode.sh.
if [ "$WITH_LEARNING" = 1 ] || [ "$WITH_USB_GADGET" = 1 ]; then
  run_step "65  the drive image, with this documentation on it (root)" sudo "$PROJECT/share/build-image.sh"
fi
[ "$WITH_LEARNING" = 1 ] &&
  run_step "70  learning content web server (root)" sudo "$PROJECT/provision/70-learning-web.sh"
# Last, always: it takes the USB host port down with it.
[ "$WITH_USB_GADGET" = 1 ] &&
  run_step "60  USB gadget (root)" sudo "$PROJECT/provision/60-usb-gadget.sh"

# --- done ------------------------------------------------------------------

printf '\n%s########## done ##########%s\n' "$P_BOLD" "$P_OFF"
cat <<EOF

  source $PROJECT/env.sh          # or open a new shell
  $PROJECT/tools/check.sh         # all quality gates
  mcucon                          # watch the MCU console

  hpy -c "from unoq import MCU; print(MCU().status())"   # ask the MCU how it is

EOF
[ "$WITH_CPU_BARS" = 0 ] &&
  echo "  LED matrix demo at boot:  sudo bash provision/50-cpu-bars.sh"
[ "$WITH_PURGE" = 0 ] &&
  echo "  Reclaim the Arduino disk: sudo bash provision/40-purge-arduino.sh"
[ "$WITH_USB_GADGET" = 0 ] &&
  echo "  IP over USB + fileshare:  sudo bash provision/60-usb-gadget.sh"
echo

if [ -n "$FIRMWARE_PROBLEM" ]; then
  fail "everything above is in place, but $FIRMWARE_PROBLEM.
        The microcontroller is running whatever it ran before. Fix the cause
        shown under 'MCU firmware' above and run this again."
fi
