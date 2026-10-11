#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Optional: show host CPU load on the LED matrix at every boot.
#
#   sudo bash ~/two-computers-one-board/provision/65-cpu-bars.sh
#
# Idempotent. Unlike 10..40 this one is a convenience, not a prerequisite -
# nothing else in the project needs it, and it is the only unit here that holds
# a resource you will want back.
#
# IT KEEPS /dev/ttyHS1 OPEN. It is opened with an exclusive lock, so while this
# service runs, `mcucon`, `tio`, unoq.MCU and FOTA all fail with "device busy".
# Stop it before working on the MCU:
#
#     sudo systemctl stop unoq-cpu-bars      # start it again when you are done
#
# Flashing over SWD (flash.sh, zflash) is unaffected - that is OpenOCD on the
# GPIO lines, not the UART.
#
# REVERT: systemctl disable --now unoq-cpu-bars.service &&
#         rm /etc/systemd/system/unoq-cpu-bars.service && systemctl daemon-reload
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
need_root

step "prerequisites"
if [ -x "$PROJECT/.venv/bin/unoq-cpu-bars" ]; then
  skip "unoq-cpu-bars entry point present"
else
  fail "$PROJECT/.venv/bin/unoq-cpu-bars missing.
  Build the venv first:  bash $PROJECT/provision/user/35-python-venv.sh"
fi

step "unoq-cpu-bars.service"
install_unit "$PROJECT/python/unoq-cpu-bars.service"
# A demo that gave up on a silent microcontroller is in the failed state, and
# systemd refuses to start a unit that hit its start limit until that is
# cleared. This step usually runs right after the firmware has been flashed,
# which is exactly when the reason it gave up has just been fixed.
if systemctl is-failed --quiet unoq-cpu-bars.service 2>/dev/null; then
  systemctl reset-failed unoq-cpu-bars.service >/dev/null 2>&1 || true
  did "cleared the failed state unoq-cpu-bars was left in (it had stopped retrying)"
fi
enable_unit unoq-cpu-bars.service

step "verify"
sleep 2
if systemctl is-active --quiet unoq-cpu-bars.service; then
  skip "running as PID $(systemctl show unoq-cpu-bars.service -p MainPID --value)"
else
  warn "service is not running - check: journalctl -u unoq-cpu-bars -n 30"
fi

summary
echo "Logs:  journalctl -u unoq-cpu-bars -f"
echo "Stop:  sudo systemctl stop unoq-cpu-bars   (frees /dev/ttyHS1)"
