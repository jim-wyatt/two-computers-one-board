#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Optional: keep the MCU's temperature log on Linux, instead of the CPU-bars demo.
#
#   sudo bash ~/two-computers-one-board/provision/66-temp-log.sh
#
# Idempotent. Like 65 it is a convenience, not a prerequisite, and like 65 it
# holds /dev/ttyHS1 while it runs. The port has one owner, so the two are
# alternatives: THIS STEP STOPS AND DISABLES THE CPU-BARS DEMO (and the build
# light, 67, if the board runs that instead). The units say
# Conflicts= on each other as well, but two enabled units that conflict leave
# which one runs at boot to chance, so the demo is disabled rather than only
# stopped. To go back to the demo:
#
#     sudo systemctl disable --now unoq-temp-log
#     sudo bash ~/two-computers-one-board/provision/65-cpu-bars.sh
#
# What it keeps: temps.csv in /var/lib/unoq/templog, about 4 MB a day (one row
# a second, about 45 bytes), never trimmed - delete it, or the old part of it,
# whenever you like; the daemon carries on from whatever the file ends with.
# The graph next to it is served by unoq-learn at /data/ (75-learning-web.sh).
# On the MCU the log is always running and costs about 10.5 KB of RAM whether
# this is installed or not.
#
# The firmware has to be new enough to keep the log (`app temp log`). An older
# one makes every start fail with a message that says to update it.
#
# REVERT: systemctl disable --now unoq-temp-log.service &&
#         rm /etc/systemd/system/unoq-temp-log.service && systemctl daemon-reload
#
# The record itself is left behind on purpose: rm -r /var/lib/unoq/templog.
# The demo comes back with 65-cpu-bars.sh.
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
need_root

U=unoq-temp-log.service
# UNOQ_STATE_DIR is for the tests. The unit names /var/lib/unoq/templog.
DIR="${UNOQ_STATE_DIR:-/var/lib/unoq}/templog"

step "prerequisites"
if [ -x "$PROJECT/.venv/bin/unoq-temp-log" ]; then
  skip "unoq-temp-log entry point present"
else
  fail "$PROJECT/.venv/bin/unoq-temp-log missing.
  Build the venv first:  bash $PROJECT/provision/user/35-python-venv.sh
  (it is a new entry point, so an existing venv needs the editable
   install re-run, which that step does)"
fi

step "the log's directory"
# Owned by the account the unit runs as: the daemon writes there, and nothing
# else does. /var/lib/unoq itself stays root's - the bind guard keeps its
# counter in it.
if [ -d "$DIR" ] && [ "$(stat -c %U "$DIR")" = "$TARGET_USER" ]; then
  skip "$DIR exists, owned by $TARGET_USER"
else
  install -d -m 0755 "$(dirname "$DIR")" || fail "cannot create $(dirname "$DIR")"
  install -d -m 0755 -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" "$DIR" ||
    fail "cannot create $DIR for $TARGET_USER"
  did "$DIR, owned by $TARGET_USER"
fi

step "the CPU-bars demo"
if systemctl is-enabled --quiet unoq-cpu-bars.service 2>/dev/null; then
  systemctl disable --now unoq-cpu-bars.service >/dev/null 2>&1 ||
    fail "could not stop unoq-cpu-bars, which holds the serial port"
  did "stopped and disabled the CPU-bars demo: the port to the MCU has one owner"
else
  skip "the CPU-bars demo is not enabled"
fi
# The build light (67) holds the same port, and its unit conflicts with this
# one. Disabled for the same reason as the demo.
if systemctl is-enabled --quiet unoq-buildlight.service 2>/dev/null; then
  systemctl disable --now unoq-buildlight.service >/dev/null 2>&1 ||
    fail "could not stop unoq-buildlight, which holds the serial port"
  did "stopped and disabled the build light: the port to the MCU has one owner"
fi

step "$U"
install_unit "$PROJECT/python/$U"
# As in 65: a logger that gave up on a silent MCU - or on a firmware without
# the log, which this step often follows the fix for - is in the failed state,
# and its count of recent starts outlives that state.
WAS_FAILED=0
systemctl is-failed --quiet "$U" 2>/dev/null && WAS_FAILED=1
systemctl reset-failed "$U" >/dev/null 2>&1 || true
[ "$WAS_FAILED" = 1 ] &&
  did "cleared the failed state unoq-temp-log was left in (it had stopped retrying)"
enable_unit "$U"

step "verify"
sleep 2
if systemctl is-active --quiet "$U"; then
  skip "running as PID $(systemctl show "$U" -p MainPID --value)"
else
  warn "service is not running - check: journalctl -u unoq-temp-log -n 30"
fi
# The graph is unoq-learn's to serve. One installed before it learned --data
# serves the course and not this, and nothing else would say so.
LEARN="${UNOQ_UNIT_DIR:-/etc/systemd/system}/unoq-learn.service"
if [ ! -e "$LEARN" ]; then
  skip "unoq-learn is not installed - the log is kept, with no web page (75-learning-web.sh adds it)"
elif grep -q -- "--data " "$LEARN"; then
  skip "unoq-learn serves the log at /data/"
else
  warn "unoq-learn does not serve /data/ yet - re-run: sudo bash $PROJECT/provision/75-learning-web.sh"
fi

summary
echo "Data:  $DIR/temps.csv     Graph: http://<board>:8080/data/"
echo "Logs:  journalctl -u unoq-temp-log -f"
echo "Back to the CPU-bars demo:"
echo "       sudo systemctl disable --now unoq-temp-log && sudo bash $PROJECT/provision/65-cpu-bars.sh"
