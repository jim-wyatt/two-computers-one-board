#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Serve the learning content and the VS Code installers over HTTP.
#
#   sudo bash ~/two-computers-one-board/provision/75-learning-web.sh
#
# Idempotent. Safe to run at any time. It claims a TCP port and adds one line
# to /etc/fstab, a read-only loop mount of the share image (nofail, so a board
# whose image is missing still boots). The server listens on every interface
# and has no authentication: anyone who can reach the board can read what it
# serves. In particular it does NOT touch the USB port, so it works over the network
# dongle, over WiFi, or over the USB gadget link once that exists.
#
# The content comes from the FAT32 image built by share/build-image.sh, mounted
# read-only at /srv/unoq-share. The same image is what the USB drive exports,
# so the web page and the drive can never disagree.
#
# REVERT: systemctl disable --now unoq-learn.service &&
#         rm /etc/systemd/system/unoq-learn.service && systemctl daemon-reload
#         then: umount /srv/unoq-share, and delete its line from /etc/fstab
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
need_root

MOUNT="${UNOQ_SHARE_MOUNT:-/srv/unoq-share}"
PORT="${UNOQ_LEARN_PORT:-8080}"

step "prerequisites"
if [ -x "$PROJECT/.venv/bin/unoq-learn" ]; then
  skip "unoq-learn entry point present"
else
  fail "$PROJECT/.venv/bin/unoq-learn missing.
  Build the venv first:  bash $PROJECT/provision/user/35-python-venv.sh
  (it is a new entry point, so an existing venv needs the editable
   install re-run:  uv pip install --python $PROJECT/.venv/bin/python -e $PROJECT/python)"
fi

if mountpoint -q "$MOUNT"; then
  skip "$MOUNT is mounted"
elif [ -d "$MOUNT" ] && compgen -G "$MOUNT/*" >/dev/null; then
  warn "$MOUNT is a plain directory, not the image mount - serving it anyway"
else
  fail "$MOUNT has no content.
  Build the share first:  sudo bash $PROJECT/share/fetch-vscode.sh
                          sudo bash $PROJECT/share/build-image.sh"
fi

step "persistent mount"
# The unit has RequiresMountsFor=/srv/unoq-share, which only orders against a
# mount systemd knows about - so the loop mount has to be in fstab, not just
# mounted by hand once.
IMG="${UNOQ_SHARE_IMG:-$TARGET_HOME/unoq-share.img}"
# offset= is not optional: the image carries an MBR (Windows will not reliably
# give a drive letter to removable media without one), so the filesystem starts
# 1 MiB in and a plain `loop` mount finds a partition table where it expects a
# boot sector.
FSTAB_LINE="$IMG $MOUNT vfat loop,ro,nofail,offset=1048576,umask=0022,utf8 0 0"
if grep -q "^$IMG .*offset=1048576" /etc/fstab 2>/dev/null; then
  skip "$MOUNT already in /etc/fstab"
elif grep -qF "$MOUNT" /etc/fstab 2>/dev/null; then
  # An entry from before the image was partitioned would fail to mount at boot.
  # Braces so the [[:space:]] that follows is not read as an array subscript.
  sed -i "\#[[:space:]]${MOUNT}[[:space:]]#c\\$FSTAB_LINE" /etc/fstab
  systemctl daemon-reload
  did "updated the $MOUNT fstab entry with the partition offset"
else
  # nofail: a board whose image is missing must still boot to a login prompt.
  printf '\n# Arduino UNO Q learning content + installers (share/build-image.sh)\n%s\n' \
    "$FSTAB_LINE" >>/etc/fstab
  systemctl daemon-reload
  did "added $MOUNT to /etc/fstab (ro, nofail)"
fi

step "unoq-learn.service"
install_unit "$PROJECT/python/unoq-learn.service"
enable_unit unoq-learn.service

step "verify"
# Retry rather than sleep-and-hope: the server binds about two seconds after
# systemd reports the unit started, and a single immediate probe fails on a
# service that is in fact perfectly healthy.
code=""
reachable=0
for _ in $(seq 1 10); do
  # The EXIT STATUS is the only honest signal here. On a refused connection
  # curl still prints "000" to stdout and exits non-zero, so `[ -n "$code" ]`
  # is true and the probe "passes" - which is exactly what happened during the
  # checkout relocation that found this: `ok HTTP 000` while nothing at all was
  # listening. A verify step that passes when the thing it verifies is down is
  # worse than none, because it is where you look to find out whether it worked.
  if code=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 5 \
    "http://127.0.0.1:$PORT/" 2>/dev/null); then
    reachable=1
    break
  fi
  sleep 1
done
if [ "$reachable" = 1 ]; then
  skip "HTTP $code from http://127.0.0.1:$PORT/"
else
  warn "no response on port $PORT (last code: ${code:-none}) - check: journalctl -u unoq-learn -n 30"
fi

summary
echo
echo "Reachable at:"
# Every global address on every interface that is actually UP.
#
# This printed only $3 - the FIRST address of each interface - and skipped the
# state column entirely. Both halves were wrong in the same direction, which is
# to say it advertised addresses that do not work and hid the one that does:
#
#   br-usb  UP    10.55.0.1/24 192.168.137.210/24    <- second address dropped
#   docker0 DOWN  172.17.0.1/16                      <- printed anyway
#
# (That was when the bridge still carried a fixed 10.55.0.1 as well; it no
# longer does.) The leased address was the ONLY one a plugged-in computer could
# reach; 10.55.0.1 needed a static route on the host, and docker0 is a bridge
# whose daemon 15-dev-tools.sh disables. So the two addresses it offered were
# the unreachable one and the meaningless one.
#
# $2 is the operational state in `ip -br` output, and it is DOWN for docker0
# while `show ... up` is not - that filter matches IFF_UP, which a bridge with
# no carrier still has.
ip -4 -br addr show scope global 2>/dev/null |
  awk -v p="$PORT" '$2 == "UP" {
    for (i = 3; i <= NF; i++) {
      a = $i
      gsub(/\/.*/, "", a)
      if (a) print "  http://" a ":" p "/"
    }
  }'
echo "Logs:  journalctl -u unoq-learn -f"
