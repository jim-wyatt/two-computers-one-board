#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# provision/75-learning-web.sh serves the share image over HTTP. It adds one
# line to /etc/fstab, the file the board boots from, so that line has to be
# right the first time and never twice: nofail, so a board whose image is
# missing still boots, and offset=, or the mount finds a partition table where
# it expects a filesystem. An older line without the offset is replaced, not
# kept beside the new one.
#
# Its check at the end has to fail when nothing is listening. curl prints
# "000" for a refused connection, and a check that took any output as an
# answer once reported `ok HTTP 000` with no server running.
#
# What this cannot show: that the loop mount works, or that the server serves.
# That is the board's job.

setup() {
  load helpers/stub
  stub_setup

  # A copy of the checkout, so a test decides whether the venv has been built.
  # python/ holds the unit and the file it names as its documentation.
  REAL="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PROJECT="$BATS_TEST_TMPDIR/checkout"
  mkdir -p "$PROJECT"
  cp -r "$REAL/provision" "$REAL/python" "$PROJECT/"
  STEP="$PROJECT/provision/75-learning-web.sh"

  export UNOQ_UNIT_DIR="$BATS_TEST_TMPDIR/etc/systemd/system"
  export UNOQ_RUNTIME_DIR="$BATS_TEST_TMPDIR/usr/local/lib/unoq"
  export UNOQ_SHARE_MOUNT="$BATS_TEST_TMPDIR/srv/unoq-share"
  export UNOQ_FSTAB="$BATS_TEST_TMPDIR/etc/fstab"
  export UNOQ_IN_BOOTSTRAP=1
  UNOQ_USER="$(id -un)"
  export UNOQ_USER
  export FAKE_HOME="$BATS_TEST_TMPDIR/home"
  MOUNT="$UNOQ_SHARE_MOUNT"
  FSTAB="$UNOQ_FSTAB"
  IMG="$FAKE_HOME/unoq-share.img"
  LINE="$IMG $MOUNT vfat loop,ro,nofail,offset=1048576,umask=0022,utf8 0 0"
  UNIT="$UNOQ_UNIT_DIR/unoq-learn.service"
  U=unoq-learn.service

  # A board's fstab, which the step adds to and must otherwise leave alone.
  mkdir -p "$(dirname "$FSTAB")"
  printf '%s\n' \
    "UUID=1234 / ext4 errors=remount-ro 0 1" \
    "/dev/disk/by-partlabel/efi /boot/efi vfat umask=0077 0 1" >"$FSTAB"
  cp "$FSTAB" "$BATS_TEST_TMPDIR/fstab.stock"

  FLAGS="$BATS_TEST_TMPDIR/flags"
  mkdir -p "$FLAGS"
  export FLAGS
  : >"$FLAGS/mounted"

  stub sleep
  stub_body id <<'SH'
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
SH
  stub_body getent <<'SH'
[ "$1" = passwd ] && { echo "$2:x:1000:1000::$FAKE_HOME:/bin/bash"; exit 0; }
exec /usr/bin/getent "$@"
SH
  stub_body mountpoint <<'SH'
[ -e "$FLAGS/mounted" ]
SH
  # A server that answers, unless a test says nothing is listening: then curl
  # does what it really does, and prints 000 as well as failing.
  stub_body curl <<'SH'
if [ -e "$FLAGS/no-server" ]; then
  printf '000'
  exit 7
fi
printf '200'
SH
  stub_body ip <<'SH'
printf '%s\n' \
  "br-usb           UP             192.168.137.210/24 169.254.7.7/16" \
  "docker0          DOWN           172.17.0.1/16" \
  "wlan0            UP             10.0.0.5/24"
SH
  stub_body systemctl <<'SH'
u="${*: -1}"
case "$1" in
  is-enabled) [ -e "$FLAGS/enabled-$u" ] ;;
  is-active) [ -e "$FLAGS/active-$u" ] ;;
  enable) : >"$FLAGS/enabled-$u"; [ "$2" = --now ] && : >"$FLAGS/active-$u"; exit 0 ;;
  disable) rm -f "$FLAGS/enabled-$u"; [ "$2" = --now ] && rm -f "$FLAGS/active-$u"; exit 0 ;;
  *) exit 0 ;;
esac
SH
}

# with_venv - the venv's entry point, as 35-python-venv.sh leaves it.
with_venv() {
  mkdir -p "$PROJECT/.venv/bin"
  printf '#!/bin/bash\nexit 0\n' >"$PROJECT/.venv/bin/unoq-learn"
  chmod +x "$PROJECT/.venv/bin/unoq-learn"
}

# revert - the REVERT comment in the step's header, as one line: "# REVERT:"
# and the "#" of each continuation dropped.
revert() {
  awk '
    /^# REVERT:/ { buf = substr($0, 11); inrev = 1; next }
    inrev && /^#  / { sub(/^# +/, ""); buf = buf " " $0; next }
    inrev { print buf; exit }
  ' "$STEP"
}

# --- what it refuses --------------------------------------------------------

@test "no venv yet: the step stops, says which step builds it, and touches nothing" {
  run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unoq-learn missing"* ]]
  [[ "$output" == *"provision/user/35-python-venv.sh"* ]]
  cmp -s "$FSTAB" "$BATS_TEST_TMPDIR/fstab.stock"
  [ ! -e "$UNIT" ]
}

@test "nothing to serve: the step stops, says how to build it, and touches nothing" {
  with_venv
  rm "$FLAGS/mounted"
  run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$MOUNT has no content"* ]]
  [[ "$output" == *"share/build-image.sh"* ]]
  cmp -s "$FSTAB" "$BATS_TEST_TMPDIR/fstab.stock"
  [ ! -e "$UNIT" ]
}

@test "a plain directory with content is served, with a warning that it is not the image" {
  with_venv
  rm "$FLAGS/mounted"
  mkdir -p "$MOUNT"
  : >"$MOUNT/index.html"
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qE "warn +$MOUNT is a plain directory, not the image mount" <<<"$output"
  [ -f "$UNIT" ]
}

# --- the line in fstab ------------------------------------------------------

@test "a fresh board gets one fstab line, read-only, nofail, at the partition's offset" {
  with_venv
  run "$STEP"
  [ "$status" -eq 0 ]
  [ "$(grep -cF "$MOUNT" "$FSTAB")" -eq 1 ]
  grep -qxF "$LINE" "$FSTAB"
  ran "systemctl daemon-reload"
  [[ "$output" == *"added $MOUNT to $FSTAB (ro, nofail)"* ]]
}

@test "the rest of fstab is left exactly as it was" {
  with_venv
  run "$STEP"
  [ "$status" -eq 0 ]
  # The stock lines, in order, at the top, unchanged.
  head -n 2 "$FSTAB" | cmp -s - "$BATS_TEST_TMPDIR/fstab.stock"
}

@test "an entry from before the image had a partition table is replaced, not kept beside" {
  # Mounted without offset=, it finds the MBR where it expects a boot sector
  # and fails at every boot.
  with_venv
  echo "$IMG $MOUNT vfat loop,ro,nofail 0 0" >>"$FSTAB"
  run "$STEP"
  [ "$status" -eq 0 ]
  [ "$(grep -cF "$MOUNT" "$FSTAB")" -eq 1 ]
  grep -qxF "$LINE" "$FSTAB"
  head -n 2 "$FSTAB" | cmp -s - "$BATS_TEST_TMPDIR/fstab.stock"
  [[ "$output" == *"updated the $MOUNT fstab entry with the partition offset"* ]]
}

# --- the unit ---------------------------------------------------------------

@test "the unit serves the mount it was given, as the owner, and waits for it" {
  with_venv
  run "$STEP"
  [ "$status" -eq 0 ]
  # /data/ is the temperature log (66-temp-log.sh), named whether or not
  # that is installed, at the path its own unit writes to.
  grep -qx "ExecStart=$PROJECT/.venv/bin/unoq-learn --root $MOUNT --port 8080 --data /var/lib/unoq/templog" "$UNIT"
  grep -q -- "--dir /var/lib/unoq/templog " "$PROJECT/python/unoq-temp-log.service"
  grep -qx "RequiresMountsFor=$MOUNT" "$UNIT"
  grep -qx "User=$UNOQ_USER" "$UNIT"
  ran "systemctl enable --now $U"
}

# --- the second run ---------------------------------------------------------

@test "a second run changes nothing, fstab included" {
  with_venv
  run "$STEP"
  cp "$FSTAB" "$BATS_TEST_TMPDIR/fstab.after-first"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 changed,"* ]]
  [[ "$output" == *"$MOUNT already in $FSTAB"* ]]
  cmp -s "$FSTAB" "$BATS_TEST_TMPDIR/fstab.after-first"
  refute ran "systemctl daemon-reload"
  refute ran_like '^systemctl (enable|start|restart)'
}

# --- the check at the end ---------------------------------------------------

@test "an answering server is reported with its status code" {
  with_venv
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"HTTP 200 from http://127.0.0.1:8080/"* ]]
}

@test "nothing listening is a warning, not 'ok HTTP 000'" {
  with_venv
  : >"$FLAGS/no-server"
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qE 'warn +no response on port 8080 \(last code: 000\) - check: journalctl -u unoq-learn' <<<"$output"
  [[ "$output" != *"HTTP 000 from"* ]]
  # It gives the server time to bind before deciding: ten tries.
  [ "$(grep -c '^curl ' "$STUB_LOG")" -eq 10 ]
}

@test "every address of every interface that is up is offered, and nothing else" {
  with_venv
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"http://192.168.137.210:8080/"* ]]
  [[ "$output" == *"http://169.254.7.7:8080/"* ]]
  [[ "$output" == *"http://10.0.0.5:8080/"* ]]
  [[ "$output" != *"172.17.0.1"* ]]
}

# --- the way back -----------------------------------------------------------

@test "the REVERT line stops the server and removes its unit" {
  with_venv
  run "$STEP"
  text="$(revert)"
  [ -n "$text" ]
  # Its first half undoes the unit; the rest is for a person, at the board.
  cmd="${text%% then:*}"
  cmd="${cmd//\/etc\/systemd\/system/$UNOQ_UNIT_DIR}"
  : >"$STUB_LOG"
  bash -c "$cmd"
  [ ! -e "$UNIT" ]
  [ ! -e "$FLAGS/enabled-$U" ]
  [ ! -e "$FLAGS/active-$U" ]
  ran "systemctl daemon-reload"
  [[ "$text" == *"delete its line from /etc/fstab" ]]
}
