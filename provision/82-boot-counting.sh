#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Boot new kernels on trial, and fall back to the last good one by itself.
#
#   sudo bash ~/two-computers-one-board/provision/82-boot-counting.sh
#
# Idempotent: a second run reports "already correct" and changes nothing.
#
# Layer 1 of issue #93, "a recovery path no matter what". The microcontroller
# already works this way - MCUboot boots a new image on probation and reverts
# it unless it is confirmed. This is the same for the Linux kernel, with
# systemd-boot, which this board already boots through (systemd-boot 257 under
# U-Boot's UEFI, one Type 1 entry per kernel on the EFI partition).
#
# HOW IT WORKS
# ------------
#   1. /etc/kernel/tries holds 3. kernel-install, which Debian's kernel hook
#      (/etc/kernel/postinst.d/zz-systemd-boot) runs for every kernel package,
#      then writes the new kernel's entry as <token>-<version>+3.conf.
#   2. systemd-boot prefers that entry, as the newest, and renames it at each
#      attempt: +2-1, +1-2, +0-3. An entry at +0 is "bad", sorted below every
#      good one, and the previous kernel boots instead - with nobody at the
#      board.
#   3. unoq-boot-health.service is what systemd-bless-boot waits for: the
#      boot finished and sshd is up, a minute in. When it passes,
#      systemd-bless-boot drops the counter and the entry is an ordinary one.
#
# NOT boot-complete.target, where systemd's own documentation hangs such a
# check. On this board qbootctl.service also waits for that target, to mark
# the Qualcomm boot slot (boot_a/boot_b) successful, and it is pulled in on
# every boot. The first version of this hung the check there, and found that
# out on the board before any reboot: a boot without SSH would have left the
# FIRMWARE slot unmarked as well as the kernel, and enough of those make the
# Qualcomm boot chain fall back to its other slot. The check gates the kernel
# entry's blessing and nothing else; boot-complete.target and qbootctl are as
# the stock image has them.
#
# The hardware watchdog (80-watchdog.sh, --with-watchdog) is what turns a
# kernel that hangs rather than panics into a counted attempt. Without it a
# hang waits for someone to pull the power.
#
# WHAT THIS DOES NOT DO
# ---------------------
# It does not touch the entry the board is running now. That kernel is known to
# boot - this is running on it - and on a board with one kernel there would be
# nothing to fall back to anyway. Counting starts with the next kernel that is
# installed, and only matters while the previous one is still installed beside
# it, which Debian keeps until `apt autoremove`.
#
# NOT YET RUN THROUGH A REBOOT. Whether it works depends on U-Boot letting
# systemd-boot rename a file on the EFI partition at boot, which nothing short
# of a counted boot can show. Until that has been seen, this is opt-in:
# bootstrap.sh runs it only with --with-boot-counting, and --everything leaves
# it out. docs/reference/troubleshooting.md has the one-reboot test that settles it.
#
# REVERT: rm /etc/kernel/tries &&
#         systemctl disable unoq-boot-health.service &&
#         rm /etc/systemd/system/unoq-boot-health.service && systemctl daemon-reload
#         (an entry already installed with a counter keeps it until it is
#         blessed or the kernel is removed; `bootctl list` shows which)
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
need_root

TRIES="${UNOQ_BOOT_TRIES:-3}"
KERNEL_CONF="${UNOQ_KERNEL_CONF_DIR:-/etc/kernel}"

step "boot loader"
# Only systemd-boot counts boots, and only when it is the loader that is
# installed. bootctl answers both questions without touching anything.
if ! command -v bootctl >/dev/null 2>&1 || ! bootctl is-installed --quiet 2>/dev/null; then
  skip "systemd-boot is not installed here - nothing to count with, nothing written"
  summary
  exit 0
fi
skip "systemd-boot installed: $(bootctl --version 2>/dev/null | head -1)"

# One to nine. 0 would mark every new kernel bad before it had booted once,
# and the kernel's own help for the file takes a whole number.
case "$TRIES" in
  [1-9]) ;;
  *) fail "UNOQ_BOOT_TRIES must be a whole number from 1 to 9, not '$TRIES'" ;;
esac

# REVERT: rm /etc/kernel/tries
step "tries for new kernels"
# A here-string, not `echo |`: a pipe runs write_file in a subshell, and the
# changed/ok it counts would be lost from the summary.
write_file 0644 "$KERNEL_CONF/tries" <<<"$TRIES" || true

# REVERT: systemctl disable unoq-boot-health.service && rm /etc/systemd/system/unoq-boot-health.service
step "health check"
install_unit "$PROJECT/provision/unoq-boot-health.service"
# Enabled, not started. It is wired to systemd-bless-boot.service, which is
# only pulled in on a counted boot, and it does nothing on any other boot (its
# condition is the variable systemd-boot sets on one). Starting it now would
# sleep a minute and prove nothing about any kernel.
if systemctl is-enabled --quiet unoq-boot-health.service 2>/dev/null; then
  skip "unoq-boot-health.service already enabled"
else
  systemctl enable unoq-boot-health.service >/dev/null 2>&1 ||
    fail "could not enable unoq-boot-health.service"
  did "unoq-boot-health.service enabled (runs only on a counted boot)"
fi

step "now"
# What is installed now, so the line below means something. A board whose
# current entry already has a counter is part-way through a trial.
skip "booted from: $(bootctl status 2>/dev/null | sed -n 's/^ *Current Entry: //p' | head -1)"
skip "the next kernel installed is tried $TRIES times before the previous one takes over"

summary
