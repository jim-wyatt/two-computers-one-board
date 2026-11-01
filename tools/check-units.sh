#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Ask systemd whether it would accept this project's unit files and udev rules.
# Run by tools/check.sh shell.
#
#   tools/check-units.sh
#
# Eight units and a rules file are what actually start everything on the board,
# and until this existed nothing read them but a person. A unit with a
# misspelled directive, or one that names a script that has since moved,
# installs without complaint and fails at boot with 203/EXEC - on a board that
# may by then be reachable only through the thing that failed.
#
# systemd-analyze verify loads each unit the way the manager would, and checks
# that what it starts exists and is executable. The units name the checkout as
# /home/arduino/two-computers-one-board, which provision/lib.sh rewrites at
# install time - to the checkout for the units that run as the user, and to
# root's own copies of the scripts for the units that run as root.
#
# So this does what a provisioning step does, into a temporary directory: it
# calls the same install_root_scripts to make the copies, and the same
# render_unit to rewrite each unit, and verifies the result. The scripts being
# checked are still the ones in THIS checkout - the copies are made from it a
# moment earlier - but a root unit is verified against the set that would
# really be installed. A unit naming a script that exists in the repository and
# is not in that set passes a check against the checkout and fails on the
# board; here it fails here.
#
# No root, no board, and nothing is installed or started.
set -uo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT" || exit 1

for tool in systemd-analyze udevadm; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "missing tool: $tool (part of systemd)" >&2
    exit 1
  }
done

WORK="$(mktemp -d)"
# shellcheck disable=SC2064  # $WORK must expand now, not at trap time
trap "rm -rf '$WORK'" EXIT

mapfile -t UNITS < <(git ls-files '*.service')
mapfile -t RULES < <(git ls-files '*.rules')
[ ${#UNITS[@]} -gt 0 ] || {
  echo "no unit files found - is this a git checkout?" >&2
  exit 1
}

# The account the units run as exists on the board and not on a laptop or a CI
# runner. Whoever is running this stands in for it.
#
# In a subshell: lib.sh is written to be sourced by a provisioning step, and
# its fail() exits. Nothing it does here needs root - the copies go under
# $WORK, owned by whoever is running this.
ME="$(id -un)"
if ! (
  export UNOQ_RUNTIME_DIR="$WORK/runtime" UNOQ_USER="$ME"
  # shellcheck source=provision/lib.sh
  . "$PROJECT/provision/lib.sh"
  install_root_scripts >/dev/null || true # 1 only means "nothing changed"
  for u in "${UNITS[@]}"; do
    render_unit "$u" |
      sed -e "s|^User=.*|User=$ME|" -e "s|^Group=.*|Group=$(id -gn)|" \
        >"$WORK/$(basename "$u")"
  done
); then
  echo "could not render the units the way provisioning would" >&2
  exit 1
fi

# A unit of someone else's that ours Requires= has to exist for verify to
# load ours, and on a CI runner some do not: unoq-ble-sensor needs BlueZ's
# bluetooth.service, which a runner has no reason to install. Where the host
# has no such unit, a stand-in with nothing in it is put beside ours. It is
# only something to resolve the name against; ours are still checked whole.
for req in $(sed -n 's/^Requires=//p' "$WORK"/*.service | tr ' ' '\n' | sort -u); do
  case "$req" in *.service) ;; *) continue ;; esac
  [ -e "$WORK/$req" ] && continue
  systemctl cat "$req" >/dev/null 2>&1 && continue
  printf '[Unit]\nDescription=stand-in for %s, which this host does not have\n[Service]\nExecStart=/bin/true\n' \
    "$req" >"$WORK/$req"
done

rc=0

# All of them in one call, from one directory, so that a unit's After= and
# Requires= on a sibling resolve instead of reading as "unit not found".
#
# --man=no: do not go looking for the Documentation= pages.
# The filter drops complaints about OTHER people's units, which verify also
# loads when ours depend on them and which differ on every distribution.
out="$(cd "$WORK" && systemd-analyze verify --man=no ./*.service 2>&1)"
ours="$(grep -E "^(\./)?unoq-|$WORK" <<<"$out" || true)"
if [ -n "$ours" ]; then
  echo "systemd-analyze verify:"
  # shellcheck disable=SC2001  # a path with slashes in it, not a simple prefix
  sed "s|$WORK/||g; s|^|  |" <<<"$ours"
  rc=1
else
  echo "${#UNITS[@]} units: systemd accepts every one, and everything they start exists"
fi

if [ ${#RULES[@]} -gt 0 ]; then
  if out="$(udevadm verify "${RULES[@]}" 2>&1)"; then
    echo "${#RULES[@]} udev rules file(s): udev accepts every one"
  else
    echo "udevadm verify:"
    # shellcheck disable=SC2001
    sed 's|^|  |' <<<"$out"
    rc=1
  fi
fi

exit "$rc"
