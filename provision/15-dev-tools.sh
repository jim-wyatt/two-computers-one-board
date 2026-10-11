#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Root-level steps for the west-based dev environment.
#
#   sudo bash ~/two-computers-one-board/provision/15-dev-tools.sh
#
# Idempotent. Every change has its revert in the comment above it.
#
# This frees /dev/ttyHS1 (arduino-router holds it) and installs clangd. It does
# NOT purge the Arduino packages - that is 55-purge-arduino.sh, deliberately
# separate and later, because it is the step you cannot casually undo.
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
need_root

echo "== Before =="
free -h | sed -n 2p

# --- 1. clangd: C/C++ IntelliSense. .vscode/settings.json expects it plus a
# --- compile_commands.json, which zbuild.sh symlinks in from the west build.
# ---
# --- The version is discovered rather than pinned; the clangd step further
# --- down says why.
#
# --- Host C compiler. The stock image has NO cc at all - gcc is `un`, not
# --- merely absent - and two things quietly need one.
#
# native_sim. The ztest suites build for the host, not the MCU, so they do not
# use the Zephyr SDK's arm-zephyr-eabi toolchain that everything else here
# relies on. Without gcc, twister reports
#
#   CMake Error ... Could not find CMAKE_C_COMPILER using the following names: gcc
#
# for every suite, which means `tools/check.sh mcu` and mcu/ztest.sh - the gate
# the README tells you to run on the board - could never have passed on a board
# provisioned by this repo. The firmware builds fine throughout, because that is
# a cross build and carries its own compiler, so nothing else hints at it.
#
# spidev. It is a C extension with no aarch64 wheel, so pip builds it from
# source. 10-optimize-board.sh already installs python3-dev for the headers,
# which is only half of what compiling needs - and provisioning the headers
# without the compiler is a strong tell that this was the missing half.
#
# REVERT: apt-get remove -y gcc make
step "host C compiler"
apt_install gcc make

# The Zephyr SDK's setup.sh fetches the toolchain with wget and exits if it is
# missing. Everything in this repo downloads with curl, so nothing here would
# have noticed its absence until user/25-zephyr-sdk.sh, forty lines into a log.
#
# REVERT: apt-get remove -y wget
step "wget (the Zephyr SDK installer needs it)"
apt_install wget

# --- clangd. Debian ships clangd-19 here, but a later image ships a different
# --- one and a pinned name 404s, so the newest available is looked up.
# REVERT: apt-get remove -y clangd-<v> && rm /usr/bin/clangd
step "clangd"
if command -v clangd >/dev/null 2>&1; then
  skip "clangd present: $(clangd --version 2>/dev/null | head -1)"
else
  CLANGD_PKG=""
  for v in 19 18 17 16 15 14; do
    if apt-cache show "clangd-$v" >/dev/null 2>&1; then
      CLANGD_PKG="clangd-$v"
      break
    fi
  done
  [ -n "$CLANGD_PKG" ] || CLANGD_PKG=clangd
  apt_install "$CLANGD_PKG"
  # The unversioned name is what .vscode/settings.json and clangd extensions
  # look for; Debian's versioned package does not provide it.
  if [ ! -e /usr/bin/clangd ] && [ -x "/usr/bin/${CLANGD_PKG}" ]; then
    ln -sf "/usr/bin/${CLANGD_PKG}" /usr/bin/clangd
    did "/usr/bin/clangd -> $CLANGD_PKG"
  fi
fi

# --- 2. Arduino services. The MCU no longer runs Arduino firmware, so the
# --- Router Bridge has nothing to talk to. arduino-router also holds
# --- /dev/ttyHS1 open, which blocks you from reading the Zephyr console.
# --- Frees ~105 MB and releases the UART.
#
# The order is the fix for a board that said "stopped and disabled" and was
# neither. arduino-router-serial.path watches for /dev/ttyGS0 - the serial port
# of the factory USB device, so it is there on every stock board - and starts
# arduino-router-serial.service whenever that exists. That service Requires=
# the router. Stop the router first and the path unit has the pair running
# again before the next line. So: the trigger, then what it starts, then what
# that needs.
# REVERT: systemctl enable --now arduino-router-serial.path arduino-router \
#           arduino-router-serial arduino-app-cli
step "Arduino services"
disable_unit arduino-router-serial.path arduino-router-serial.service \
  arduino-router.service arduino-app-cli.service arduino-avahi-serial.service ||
  warn "the MCU's serial port (/dev/ttyHS1) may still be held - see above"

# --- 2b. The service that would erase this project's firmware at the next boot.
#
# arduino-burn-bootloader.service writes Arduino's own Zephyr bootloader to the
# microcontroller "on first boot", and knows it has done so by a flag file. The
# factory image carries the flag at /var/lib/arduino-app-cli/. The package
# upgrade in step 10 brings a newer unit that looks for it at
# /var/lib/arduino-unoq-config/ instead - so at the first boot after this
# project is installed, the unit finds no flag, decides the board is new, and
# burns the stock bootloader over whatever is on the chip.
#
# Seen on a board set up from the factory image: everything working, a reboot,
# and a dark LED matrix with LED 3 and LED 4 off, while Linux's own LEDs stayed
# green and unoq-cpu-bars restarted forty-five times against a chip that no
# longer had this firmware on it. Nine seconds into the boot, in the journal:
# `arduino-cli burn-bootloader -b arduino:zephyr:unoq`.
#
# It is a oneshot that stays "active" once it has run, so stopping it does
# nothing to the chip; disabling it is what keeps it from running again.
# REVERT: systemctl enable arduino-burn-bootloader.service
#         (and expect it to reflash the MCU at the next boot if its flag,
#         /var/lib/arduino-unoq-config/bootloader_burned.flag, is missing)
step "Arduino's bootloader burner"
disable_unit arduino-burn-bootloader.service ||
  warn "it may run at the next boot and replace the firmware on the MCU"

# --- 3. Docker: exists only to run Arduino Brick container images. ~105 MB.
# REVERT: systemctl enable --now docker docker.socket containerd
step "Docker"
disable_unit docker.service docker.socket containerd.service

# --- 4. Verify the UART is actually free now. This is the whole point of the
# --- step, and it is cheap to check rather than assert.
step "verify /dev/ttyHS1 is free"
if [ ! -e /dev/ttyHS1 ]; then
  warn "/dev/ttyHS1 does not exist - is this an UNO Q?"
elif holder=$(fuser /dev/ttyHS1 2>/dev/null | tr -s ' ' ' ' | sed 's/^ *//;s/ *$//') && [ -n "$holder" ]; then
  # fuser pads its output, and unquoted padding turns into empty ps arguments.
  warn "/dev/ttyHS1 held by PID(s) $holder: $(ps -o comm= -p "${holder// /,}" 2>/dev/null | tr '\n' ' ')"
  warn "  unoq-cpu-bars holding it is expected - see provision/65-cpu-bars.sh"
else
  skip "/dev/ttyHS1 is free"
fi

echo
echo "== After =="
free -h | sed -n 2p
summary
