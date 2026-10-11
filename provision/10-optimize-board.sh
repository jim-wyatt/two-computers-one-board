#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Memory and disk reclaim for a headless Arduino UNO Q used as a Linux+MCU dev
# board, and the one apt upgrade a restored board needs. All three matter:
# 3.6 GB of RAM, a 9.8 GB / with ~3 GB free on a stock board which is the first
# thing to run out, and a factory image that is however old the image is.
#
#   sudo bash ~/two-computers-one-board/provision/10-optimize-board.sh
#
# Idempotent: a second run reports "already correct" and changes nothing.
# Every change has its revert command in the comment above it.
#
# TIER 1 is safe on any headless board. TIER 2 depends on what you actually use
# - Bluetooth and udisks2 - and is on by default; UNOQ_TIER2=0 leaves those
# alone, without editing this file, so the bootstrap can pass it through.
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
need_root

echo "== Before =="
free -h | sed -n 2p
df -h / | sed -n 2p

# ===================== TIER 1 - safe when headless ==========================

# --- X11 desktop stack. /sys/class/drm/card0-DP-1/status = disconnected. ----
# Xorg ~90 MB + lightdm-gtk-greeter ~87 MB + lightdm ~8 MB, plus the greeter's
# orphaned pipewire+wireplumber pair ~33 MB. Total ~218 MB for zero users.
# REVERT: systemctl set-default graphical.target && systemctl enable --now lightdm
step "desktop stack"
if [ "$(systemctl get-default)" = "multi-user.target" ]; then
  skip "default target already multi-user"
else
  systemctl set-default multi-user.target >/dev/null 2>&1
  did "default target -> multi-user"
fi
disable_unit lightdm.service

# --- ModemManager: no cellular modem on this board. ~11 MB -----------------
# REVERT: systemctl enable --now ModemManager
step "ModemManager"
disable_unit ModemManager.service

# --- fwupd: on-demand firmware updater, resident at ~44 MB. ----------------
# Restarts by itself whenever you actually run fwupdmgr, hence mask not disable.
# REVERT: systemctl unmask fwupd && systemctl start fwupd
step "fwupd"
mask_unit fwupd.service
# ...and the timer that feeds it, which is a separate unit and was left running.
#
# fwupd-refresh.timer fires daily, fwupd-refresh.service tries to download
# metadata, cannot reach the masked daemon, and exits 1. The board then carries
# a permanently failed unit - visible in `systemctl --failed` forever, on a
# board where nothing is wrong.
#
# That matters more than the tidiness: this project now lights an LED when any
# unit has failed, as the general "a human should look" signal. A failure that
# is always present makes that indicator useless, which is the same disease as a
# warning nobody reads. An alarm that is always on is not an alarm.
#
# Found, fittingly, by the LED itself - it came on within seconds of being
# enabled for the first time, and this was why.
# REVERT: systemctl unmask fwupd && systemctl enable --now fwupd-refresh.timer
disable_unit fwupd-refresh.timer
# Stopped as well, and before it is asked whether it failed. On a board that
# has just got its clock from the network the timer has usually fired already,
# so the service is RUNNING at this point: it was seen to start ten seconds
# before this line, pass the check below as "not failed", and fail fifteen
# seconds later because the daemon it talks to had just been masked. Asking a
# unit that is still running whether it failed gets the answer "not yet".
systemctl stop fwupd-refresh.service >/dev/null 2>&1 || true
if systemctl is-failed --quiet fwupd-refresh.service 2>/dev/null; then
  systemctl reset-failed fwupd-refresh.service >/dev/null 2>&1
  did "cleared the failed state fwupd-refresh.service was left in"
else
  skip "fwupd-refresh.service not in a failed state"
fi

# --- Unattended apt: causes multi-hundred-MB spikes at random times, which
# --- is what pushes a 3.6 GB board into swap mid-build.
# REVERT: systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
step "unattended apt"
disable_unit apt-daily.timer apt-daily-upgrade.timer

# --- Bring the factory image up to date. ------------------------------------
# A freshly restored board is a snapshot of whenever the image was built, and
# it is further behind than it looks: this one came up 70 packages short of
# Debian 13.6, openssl and the security pocket among them. Provisioning is the
# right moment to close that gap - it is the one point where a long download is
# expected anyway, and it happens before the Zephyr workspace fills the disk.
#
# It runs AFTER the timers above are disabled, deliberately. apt-daily firing
# mid-run would sit on /var/lib/dpkg/lock and this would fail on a board that
# is doing nothing wrong.
#
# `upgrade`, NOT `full-upgrade`: upgrade will never remove a package to satisfy
# a dependency. On a board whose Qualcomm platform packages are what make it
# bootable, "apt removed something to move forward" is not a trade worth taking
# for a newer library, and anything held back stays held back and visible.
#
# --force-confold keeps every config file the board already has. The Qualcomm
# overlay ships modified configs, and confdef alone would let a maintainer's
# version win wherever the package has no explicit rule.
#
# This is the slowest step here and the only one that needs the internet.
# Services get restarted as their packages upgrade, so expect a brief blip on
# whatever link you are connected over.
# REVERT: none - apt does not roll back. Pin a version if you need an old one.
step "system packages"
if [ "${UNOQ_SKIP_APT_UPGRADE:-0}" = "1" ]; then
  skip "upgrade skipped (UNOQ_SKIP_APT_UPGRADE=1)"
else
  apt-get update -qq || warn "apt-get update failed - working from a stale index"
  # -s is a dry run, so this costs a second and tells us whether to say
  # "already current" or how much we are about to do.
  PENDING="$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst')"
  if [ "${PENDING:-0}" -eq 0 ]; then
    skip "all packages already current"
  else
    echo "  upgrading $PENDING package(s) - several minutes, and it downloads"
    if DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
      -o Dpkg::Options::=--force-confold \
      -o Dpkg::Options::=--force-confdef >/dev/null; then
      did "upgraded $PENDING package(s)"
    else
      fail "apt-get upgrade - fix the cause and re-run this script"
    fi
  fi
  # The .debs are now dead weight on the partition this script exists to keep
  # free: a 70-package upgrade leaves a few hundred MB in the archive cache.
  CACHE_KB="$(du -sk /var/cache/apt/archives 2>/dev/null | awk '{print $1}')"
  if [ "${CACHE_KB:-0}" -gt 10240 ]; then
    apt-get clean
    did "apt cache cleared (was $((CACHE_KB / 1024)) MB)"
  else
    skip "apt cache already small"
  fi
  # Debian only creates this if something that needs a reboot was replaced.
  # Saying so is the whole job; rebooting a board mid-provision is not ours.
  # ...and needrestart, which would otherwise restart whatever was running on
  # a library that has just been replaced, is suspended for these steps (see
  # lib.sh). So after any upgrade a reboot is what puts every running process
  # on the new code, whether or not Debian left its flag.
  if [ -f /var/run/reboot-required ] || [ "${PENDING:-0}" -gt 0 ]; then
    warn "packages were upgraded: reboot when provisioning has finished, so that"
    warn "  everything running is running the new versions:  sudo reboot"
  fi
fi

# --- I2C access. Stock: PermissionError on /dev/i2c-{0,1,2} ----------------
# REVERT: gpasswd -d $TARGET_USER i2c
step "I2C access"
ensure_group i2c
add_to_group i2c

# --- SPI access. /dev/spidev0.0 is root:root 0600 by default. --------------
# REVERT: rm /etc/udev/rules.d/91-spidev-local.rules && udevadm control --reload
step "SPI access"
ensure_group spi
add_to_group spi
if write_file 0644 /etc/udev/rules.d/91-spidev-local.rules <<'RULE'; then
SUBSYSTEM=="spidev", GROUP="spi", MODE="0660"
RULE
  udevadm control --reload-rules
  udevadm trigger --subsystem-match=spidev
fi

# --- gpiod access. flash.sh bit-bangs SWD through libgpiod, so the owning
# --- user needs the group the stock image already defines for /dev/gpiochip*.
step "GPIO access"
if getent group gpiod >/dev/null; then
  add_to_group gpiod
else
  skip "no gpiod group on this image (stock udev may already permit access)"
fi

# --- Build headers for the `spidev` Python module (the only lib that failed
# --- to install; it needs Python.h). Version is derived, not pinned: a later
# --- image ships a different python3 and `python3.13-dev` would 404.
step "python headers"
PYVER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
apt_install "python${PYVER}-dev"

# --- Docker images: the Arduino App framework's container runtime. ~2 GB. ---
# These are pulled by the stock image and nothing here uses them: the Arduino
# app stack is what runs containers, and 20-dev-tools.sh disables it. On a
# stock board they are three images totalling ~2 GB with no containers, so all
# of it is reclaimable - and it comes off /, which starts with about 3 GB free
# and is the partition that runs out first.
#
# THIS HAS TO HAPPEN HERE, not in 40-purge-arduino.sh where it would sit more
# naturally next to the rest of the Arduino teardown. `docker image rm` needs
# the daemon, and the very next script - 20-dev-tools.sh - does
# `systemctl disable --now docker.service`. By the time 40 runs there is no
# daemon to talk to and the images would be stranded on disk, still costing
# 2 GB, with no obvious sign of why.
#
# The list is written out before anything is removed, because the revert needs
# the internet and you will not remember the tags.
# REVERT: docker pull <each line of $BACKUP_DIR/docker-images.txt>
step "docker images"
DOCKER_LIST="${UNOQ_BACKUP:-$TARGET_HOME/uno-q-backup}/docker-images.txt"
if [ "${UNOQ_KEEP_DOCKER_IMAGES:-0}" = "1" ]; then
  skip "kept (UNOQ_KEEP_DOCKER_IMAGES=1)"
elif ! command -v docker >/dev/null 2>&1; then
  skip "docker not installed"
elif ! docker info >/dev/null 2>&1; then
  # Already disabled by a previous run of 20-dev-tools.sh. Say so rather than
  # printing docker's connection error, which reads like a fault.
  skip "docker daemon not running - nothing to reclaim from here"
elif [ -z "$(docker images -q 2>/dev/null)" ]; then
  skip "no images"
else
  before="$(docker system df --format '{{.Size}}' 2>/dev/null | head -1)"
  as_user mkdir -p "$(dirname "$DOCKER_LIST")"
  docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null |
    grep -v '^<none>' >"$DOCKER_LIST.tmp" 2>/dev/null
  if [ -s "$DOCKER_LIST.tmp" ]; then
    mv "$DOCKER_LIST.tmp" "$DOCKER_LIST"
    chown "$TARGET_USER:$TARGET_USER" "$DOCKER_LIST" 2>/dev/null
    did "recorded $(wc -l <"$DOCKER_LIST") image(s) -> $DOCKER_LIST"
  else
    rm -f "$DOCKER_LIST.tmp"
  fi
  # -a: every image not used by a container, which on this board is all of
  # them. Running containers are never touched, so this stays safe if you have
  # started using docker for something of your own.
  if docker image prune -af >/dev/null 2>&1; then
    did "images pruned (was ${before:-~2 GB})"
  else
    warn "docker image prune failed - check: docker system df"
  fi
fi

# ===================== TIER 2 - opt in with UNOQ_TIER2=1 ====================

# TIER 2 is now ON by default, and the reason is worth stating because it is a
# change of policy rather than of fact.
#
# Nothing in this stack uses Bluetooth or udisks2. The Arduino app framework is
# disabled, there is no desktop, and removable media is mounted by hand on the
# rare occasions it appears. They were opt-in because "might be wanted" felt
# like the safe default; on a board with 3.6 GB where every service is competing
# with a Zephyr build, the safe default is the other way round.
#
# They are DISABLED, not removed. Bluetooth hardware is still there and is a
# perfectly good thing to explore - one command brings it back, and the revert
# line below is that command. UNOQ_TIER2=0 skips this section entirely.
if [ "${UNOQ_TIER2:-1}" = "1" ]; then
  step "TIER 2 (UNOQ_TIER2=0 to keep these)"
  # Bluetooth ~5 MB + blueman-mechanism.
  # REVERT: systemctl enable --now bluetooth blueman-mechanism
  disable_unit bluetooth.service blueman-mechanism.service
  # udisks2: automounts removable media. ~16 MB.
  # REVERT: systemctl enable --now udisks2
  disable_unit udisks2.service
  # NOTE: adbd is deliberately NOT disabled here. It only binds a USB gadget
  # when one exists, and provision/60-usb-gadget.sh coordinates with it.
else
  step "TIER 2"
  skip "skipped (set UNOQ_TIER2=1 to drop Bluetooth and udisks2 as well)"
fi

# --- DO NOT TOUCH: rmtfs, tqftpserv, qbootctl are Qualcomm platform services
# --- (remote filesystem for the DSP, firmware loading, boot slot control).
# --- Disabling them can leave the board unbootable. zramswap is also giving
# --- you the 1.8 GB of compressed swap - keep it.

echo
echo "== After =="
free -h | sed -n 2p
df -h / | sed -n 2p
summary
echo "Group changes need a re-login (or 'newgrp') to take effect."
