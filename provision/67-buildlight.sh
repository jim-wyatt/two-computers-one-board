#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Optional: a build light. The board watches a GitHub Actions workflow and
# shows its latest run on the LED matrix, instead of the CPU-bars demo.
#
#   sudo bash ~/two-computers-one-board/provision/67-buildlight.sh
#
# Idempotent. Like 65 and 66 it is a convenience, not a prerequisite, and like
# them it holds /dev/ttyHS1 while it runs. The port has one owner, so the
# three are alternatives: THIS STEP TAKES THE PANEL FROM THE DEMO - IT STOPS
# AND DISABLES THE CPU-BARS DEMO, AND THE TEMPERATURE LOGGER OR THE BLUETOOTH
# SENSOR (68) IF THAT IS WHAT THE BOARD RUNS. The units say Conflicts= as well, but two enabled units that
# conflict leave which one runs at boot to chance, so they are disabled rather
# than only stopped. To go back to the demo:
#
#     sudo systemctl disable --now unoq-buildlight
#     sudo bash ~/two-computers-one-board/provision/65-cpu-bars.sh
#
# The settings are in /etc/unoq/buildlight.env. This step writes it once, with
# every setting commented, and never again: after that it is yours, and a
# re-run keeps what you put in it. It is mode 0640, root and your group,
# because it is where a token goes. Nothing in the repository holds a token,
# and the daemon never prints one. Edit it, then:
#
#     sudo systemctl restart unoq-buildlight
#
# The firmware has to be new enough to draw a whole frame (`app matrix frame`,
# #177). An older one makes every start fail, and the journal says so.
#
# REVERT: systemctl disable --now unoq-buildlight.service &&
#         rm /etc/systemd/system/unoq-buildlight.service && systemctl daemon-reload
#
# The settings file is left behind on purpose, since it may hold a token you
# would rather delete yourself: rm /etc/unoq/buildlight.env.
# The demo comes back with 65-cpu-bars.sh.
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
need_root

U=unoq-buildlight.service
ENV_FILE="$SYSROOT/etc/unoq/buildlight.env"
GROUP="$(id -gn "$TARGET_USER")"

step "prerequisites"
if [ -x "$PROJECT/.venv/bin/unoq-buildlight" ]; then
  skip "unoq-buildlight entry point present"
else
  fail "$PROJECT/.venv/bin/unoq-buildlight missing.
  Build the venv first:  bash $PROJECT/provision/user/35-python-venv.sh
  (it is a new entry point, so an existing venv needs the editable
   install re-run, which that step does)"
fi

step "the settings"
# Written ONCE. write_file would put the template back over someone's edits on
# every run, and with them their token, so it is not used here.
if [ -f "$ENV_FILE" ]; then
  skip "$ENV_FILE kept as it is: it is yours to edit"
else
  TMP="$(mktemp)" || fail "mktemp"
  cat >"$TMP" <<'ENV'
# unoq-buildlight's settings, read by unoq-buildlight.service.
# Written once by provision/67-buildlight.sh and never again, so edit freely,
# then:  sudo systemctl restart unoq-buildlight
# docs/reference/configuration.md describes each one.

# The repository to watch, as owner/name. A fork: put your own name here.
UNOQ_BUILDLIGHT_REPO=jim-wyatt/two-computers-one-board

# The workflow's file name in .github/workflows/, or its numeric id.
#UNOQ_BUILDLIGHT_WORKFLOW=ci.yml

# The branch whose latest run is shown.
#UNOQ_BUILDLIGHT_BRANCH=main

# Seconds between polls. Without a token GitHub allows 60 requests an hour
# from one address; an unchanged answer does not count, so 60 is enough.
#UNOQ_BUILDLIGHT_INTERVAL=60

# Optional for a public repository, needed for a private one: a fine-grained
# token with read-only access to Actions on that one repository, and nothing
# else. This file is mode 0640, root and your group. Nothing prints it.
#UNOQ_BUILDLIGHT_TOKEN=
ENV
  install -d -m 0755 "$(dirname "$ENV_FILE")" || fail "cannot create $(dirname "$ENV_FILE")"
  install -m 0640 -o root -g "$GROUP" "$TMP" "$ENV_FILE" || fail "could not write $ENV_FILE"
  rm -f "$TMP"
  did "wrote $ENV_FILE (0640 root:$GROUP), watching jim-wyatt/two-computers-one-board"
fi
# Kept, but not left readable by everyone: it is where a token goes.
PERMS="$(stat -c '%a %U %G' "$ENV_FILE")"
if [ "$PERMS" = "640 root $GROUP" ]; then
  skip "$ENV_FILE is 0640 root:$GROUP"
else
  if ! { chown "root:$GROUP" "$ENV_FILE" && chmod 0640 "$ENV_FILE"; }; then
    fail "could not make $ENV_FILE 0640 root:$GROUP"
  fi
  did "$ENV_FILE was $PERMS; now 0640 root:$GROUP"
fi
# Whether there is a token, never what it is.
if grep -qE '^[[:space:]]*UNOQ_BUILDLIGHT_TOKEN=[^[:space:]]' "$ENV_FILE"; then
  skip "a token is set"
else
  skip "no token: fine for a public repository, at one poll a minute"
fi

step "the panel"
# The port has one owner. Off before this is started, so it is not the
# build light that loses the port.
for other in unoq-cpu-bars.service unoq-temp-log.service unoq-ble-sensor.service; do
  if systemctl is-enabled --quiet "$other" 2>/dev/null; then
    systemctl disable --now "$other" >/dev/null 2>&1 ||
      fail "could not stop ${other%.service}, which holds the serial port"
    case "$other" in
      unoq-cpu-bars.service) did "stopped and disabled the CPU-bars demo: the panel is the build light's now" ;;
      unoq-temp-log.service) did "stopped and disabled the temperature logger (its record is kept): the port to the MCU has one owner" ;;
      *) did "stopped and disabled the Bluetooth sensor: the port to the MCU has one owner" ;;
    esac
  else
    skip "${other%.service} is not enabled"
  fi
done

step "$U"
install_unit "$PROJECT/python/$U"
# As in 65: a light that gave up on a silent MCU - or on a firmware without
# frames, which this step often follows the fix for - is in the failed state,
# and its count of recent starts outlives that state.
WAS_FAILED=0
systemctl is-failed --quiet "$U" 2>/dev/null && WAS_FAILED=1
systemctl reset-failed "$U" >/dev/null 2>&1 || true
[ "$WAS_FAILED" = 1 ] &&
  did "cleared the failed state unoq-buildlight was left in (it had stopped retrying)"
enable_unit "$U"

step "verify"
sleep 2
if systemctl is-active --quiet "$U"; then
  skip "running as PID $(systemctl show "$U" -p MainPID --value)"
else
  warn "service is not running - check: journalctl -u unoq-buildlight -n 30"
fi

summary
echo "Settings: $ENV_FILE   (then: sudo systemctl restart unoq-buildlight)"
echo "Logs:     journalctl -u unoq-buildlight -f"
echo "Back to the CPU-bars demo:"
echo "          sudo systemctl disable --now unoq-buildlight && sudo bash $PROJECT/provision/65-cpu-bars.sh"
