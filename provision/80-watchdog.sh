#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Arm the hardware watchdog, so a board whose kernel has wedged resets itself.
#
#   sudo bash ~/two-computers-one-board/provision/80-watchdog.sh
#
# Idempotent: a second run reports "already correct" and changes nothing.
#
# NOT YET VALIDATED ON HARDWARE. Everything below was written from what the
# board reports and what systemd documents, and checked against faked commands
# only (tests/watchdog.bats).
#
# WHY
# ---
# Everything this project does to avoid losing the board - the bind guard, the
# uplink fallback, the wifi rescue - is userspace. None of it runs if the
# kernel hangs, and the board is powered by the cable it is administered over,
# so "power cycle it" means unplugging the thing you reach it through. The SoC
# has a watchdog for exactly this, and the stock image leaves it switched off:
#
#   /sys/class/watchdog/watchdog0: identity qcom_wdt, timeout 30, state inactive
#   systemctl show -p RuntimeWatchdogUSec   ->  0
#
# THE WARNING, WHICH IS WHY THIS IS OPT-IN
# ----------------------------------------
# A watchdog that fires during a long Zephyr build because the board swapped
# hard is WORSE than no watchdog: it turns a slow build into a reset, half-way
# through writing a workspace. PID 1 is what pets the device, and PID 1 on a
# 3.6 GB board deep in swap can be late. Nobody has yet run this under that
# load. Until someone has, treat it as an experiment: bootstrap.sh runs it only
# with --with-watchdog, and --everything deliberately does not include it.
#
# HOW
# ---
# systemd already knows how to pet a watchdog: RuntimeWatchdogSec= in
# systemd-system.conf(5). That is one setting in a drop-in rather than a
# service of our own to write, supervise and get wrong, and it means "PID 1 is
# alive and scheduling" is the thing being checked. systemd pings at half the
# interval, so 30s means a ping every 15s and a reset 30s after the last one.
#
# RebootWatchdogSec is left at systemd's default (10min): a shutdown that hangs
# in its last phase is reset after ten minutes instead of never.
#
# DAEMON-REEXEC, NOT DAEMON-RELOAD
# --------------------------------
# The manager has to be told to read the drop-in. systemctl(1) describes
# daemon-reload as re-running generators and reloading UNIT files; it promises
# nothing about system.conf. Recent systemd does in fact re-read its own
# configuration on a reload, but that is behaviour read out of the source, not
# something the manual commits to. daemon-reexec restarts PID 1 from its
# configuration the same way boot does, so it cannot miss the file. It is the
# heavier of the two - state is serialised and the process replaced - and it is
# also what every upgrade of the systemd package does, so it is well trodden.
# It runs only when the file changed or the manager is visibly not armed, and
# the result is then read back rather than assumed.
#
# REVERT: rm /etc/systemd/system.conf.d/50-unoq-watchdog.conf &&
#         systemctl daemon-reexec
#         (then `systemctl show -p RuntimeWatchdogUSec` should read 0 again)
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
need_root

TIMEOUT="${UNOQ_WATCHDOG_SEC:-30}"
CONF_DIR="${UNOQ_WATCHDOG_CONF_DIR:-/etc/systemd/system.conf.d}"
SYSFS="${UNOQ_WATCHDOG_SYSFS:-/sys/class/watchdog}"
CONF="$CONF_DIR/50-unoq-watchdog.conf"
# Below this, an ordinary pause - a burst of swap, a slow flash write - is
# enough to reset the board, and the setting survives the reset. A drop-in
# that reboots the board every few seconds is one you cannot log in to remove.
MIN_TIMEOUT=10

step "watchdog device"
DEV="$(compgen -G "$SYSFS/watchdog[0-9]*" | sort | head -1)"
if [ -z "$DEV" ]; then
  # Not a failure: a VM, a container or a different board has none, and the
  # rest of a provisioning run should not stop for it.
  skip "no hardware watchdog under $SYSFS - nothing to arm, nothing written"
  summary
  exit 0
fi
IDENTITY="$(cat "$DEV/identity" 2>/dev/null || echo unknown)"
HW_TIMEOUT="$(cat "$DEV/timeout" 2>/dev/null || echo '?')"
skip "$(basename "$DEV"): $IDENTITY, hardware timeout ${HW_TIMEOUT}s"

# Whole seconds only. systemd accepts more (ms, min, "default", "off"), and
# each of those is a way to write something other than what was meant: "off"
# and 0 disarm it, which is what the REVERT line is for.
case "$TIMEOUT" in
  '' | *[!0-9]*) fail "UNOQ_WATCHDOG_SEC must be a whole number of seconds, not '$TIMEOUT'" ;;
esac
[ "$TIMEOUT" -ge "$MIN_TIMEOUT" ] ||
  fail "UNOQ_WATCHDOG_SEC=$TIMEOUT is under ${MIN_TIMEOUT}s. A timeout that short resets a
  board that is merely busy, and it would do so again after every reboot."

warn "a watchdog that fires mid-build because the board swapped hard is worse than none."
warn "  This has not been tested under that load. Until it has: opt-in only, and"
warn "  remove it (REVERT, at the top of this script) before trusting a long build to it."

# manager_timeout - what PID 1 says it is doing, which is the only evidence
# that counts. Prints nothing if it cannot be asked.
manager_timeout() {
  systemctl show -p RuntimeWatchdogUSec --value 2>/dev/null
}
armed() {
  case "$(manager_timeout)" in
    '' | 0) return 1 ;;
  esac
  return 0
}

# REVERT: rm /etc/systemd/system.conf.d/50-unoq-watchdog.conf && systemctl daemon-reexec
step "RuntimeWatchdogSec"
REEXEC=0
if write_file 0644 "$CONF" <<EOF; then
# Written by provision/80-watchdog.sh (two-computers-one-board).
# PID 1 pets /dev/watchdog0; if it stops for this long, the hardware resets
# the board. Remove this file and run \`systemctl daemon-reexec\` to disarm.
[Manager]
RuntimeWatchdogSec=${TIMEOUT}s
EOF
  REEXEC=1
elif ! armed; then
  # The file is right and the manager is not using it: an earlier run was
  # interrupted between the two. Re-running is the recovery path, so finish it.
  REEXEC=1
fi

if [ "$REEXEC" = 1 ]; then
  systemctl daemon-reexec ||
    fail "systemctl daemon-reexec failed. $CONF is in place and will be read
  at the next boot. To back out instead: rm $CONF"
  did "systemd re-executed to read $CONF"
fi

step "verify"
if armed; then
  skip "systemd is petting the watchdog: RuntimeWatchdogUSec=$(manager_timeout)"
  STATE="$(cat "$DEV/state" 2>/dev/null || true)"
  [ -z "$STATE" ] || echo "           $(basename "$DEV") state: $STATE"
else
  fail "systemd does not report a runtime watchdog (RuntimeWatchdogUSec=$(manager_timeout)).
  $CONF is in place, so the watchdog will be armed at the next boot whether
  or not that is what you want. Look at:  journalctl -b -g -i watchdog
  To back out:  rm $CONF && systemctl daemon-reexec"
fi

summary
echo "The board now resets if PID 1 stops for ${TIMEOUT}s. To disarm:"
echo "  sudo rm $CONF && sudo systemctl daemon-reexec"
