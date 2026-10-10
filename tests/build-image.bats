#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# share/build-image.sh has to unmount /srv/unoq-share to make it writable, and
# on a provisioned board something is always holding it: unoq-learn.service
# serves from that directory. The script used to stop at
#
#   umount: /srv/unoq-share: target is busy.
#     FAILED  could not remount /srv/unoq-share rw
#
# which reads as a broken build and is a lock. It now stops the web server
# itself and starts it again, and the thing that must never happen is the
# second half being skipped: a build that fails half-way and leaves the web
# server down, on a board whose landing page is how people find their way in.
#
# The other half is a holder the script cannot move - a shell that has cd'd
# into the mount. That one has to be NAMED, and must never be papered over with
# `umount -l`, which succeeds in exactly the case where something is writing.
#
# What this cannot show: that a stopped unoq-learn really lets go of the mount,
# or that fuser's table looks like the one faked here. That is the board's job.

setup() {
  load helpers/stub
  stub_setup

  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BUILD="$PROJECT/share/build-image.sh"

  # The script's own overrides, pointed away from /srv and /var/lib.
  export UNOQ_SHARE_IMG="$BATS_TEST_TMPDIR/unoq-share.img"
  export UNOQ_SHARE_MOUNT="$BATS_TEST_TMPDIR/mnt"
  export UNOQ_SHARE="$BATS_TEST_TMPDIR/staging"
  UNOQ_USER="$(id -un)"
  export UNOQ_USER
  : >"$UNOQ_SHARE_IMG"
  mkdir -p "$UNOQ_SHARE_MOUNT"

  # Each fake below answers from a flag file, so a test changes the board's
  # state by touching a file rather than by rewriting a stub.
  FLAGS="$BATS_TEST_TMPDIR/flags"
  mkdir -p "$FLAGS"
  export FLAGS

  # need_root asks `id -u`. Everything else id is asked goes to the real one.
  stub_body id <<'SH'
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
SH

  # Packages present, image already partitioned and formatted: the run goes
  # straight to the mount step, which is the one under test.
  stub dpkg-query 0 "install ok installed"
  stub_body blkid <<'SH'
case "$*" in
  *PTTYPE*) echo dos ;;
  *TYPE*) echo vfat ;;
esac
exit 0
SH
  stub mountpoint

  # A read-only loop mount cannot be flipped to rw in place - that refusal is
  # what sends the script down the unmount path at all.
  stub_body mount <<'SH'
case "$*" in
  "-o remount,rw "*) [ -e "$FLAGS/remount-rw-works" ] && exit 0 || exit 32 ;;
  "-o remount,ro "*) [ -e "$FLAGS/remount-ro-fails" ] && exit 32 || exit 0 ;;
esac
exit 0
SH
  stub_body umount <<'SH'
if [ -e "$FLAGS/mount-busy" ]; then
  echo "umount: ${*: -1}: target is busy." >&2
  exit 32
fi
exit 0
SH
  stub_body systemctl <<'SH'
case "$1" in
  is-active) [ -e "$FLAGS/learn-active" ] && exit 0 || exit 3 ;;
  start) [ -e "$FLAGS/learn-start-fails" ] && exit 1 || exit 0 ;;
esac
exit 0
SH
  # fuser -v writes its table to stderr and the bare pids to stdout.
  stub_body fuser <<'SH'
{
  echo "                     USER        PID ACCESS COMMAND"
  echo "${*: -1}:  arduino    4242 ..c.. byobu-shell"
} >&2
echo " 4242"
exit 0
SH

  stub runuser
  stub rsync
  stub sync
  stub chown
  stub du 0 "1.0M	x"
  stub df
}

# line_of <extended regex> - where in the call log the first match is, so two
# calls can be put in order.
line_of() { grep -nE "$1" "$STUB_LOG" | head -1 | cut -d: -f1; }

learn_active() { : >"$FLAGS/learn-active"; }

# --- the service is ours to move -------------------------------------------

@test "a running unoq-learn is stopped before the unmount and started after the update" {
  learn_active
  run bash "$BUILD"
  [ "$status" -eq 0 ]

  stop="$(line_of '^systemctl stop unoq-learn\.service$')"
  unmount="$(line_of "^umount $UNOQ_SHARE_MOUNT\$")"
  rw="$(line_of '^mount -o loop,rw,')"
  ro="$(line_of '^mount -o remount,ro ')"
  start="$(line_of '^systemctl start unoq-learn\.service$')"
  [ -n "$stop" ] && [ -n "$unmount" ] && [ -n "$rw" ] && [ -n "$ro" ] && [ -n "$start" ]
  [ "$stop" -lt "$unmount" ]
  [ "$unmount" -lt "$rw" ]
  [ "$rw" -lt "$ro" ]
  [ "$ro" -lt "$start" ]
}

@test "both halves are reported in the script's own vocabulary" {
  learn_active
  run bash "$BUILD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"changed  unoq-learn.service stopped while $UNOQ_SHARE_MOUNT is remounted"* ]]
  [[ "$output" == *"changed  unoq-learn.service started again"* ]]
}

@test "it is started exactly once, not again by the exit trap" {
  learn_active
  run bash "$BUILD"
  [ "$status" -eq 0 ]
  [ "$(grep -cx 'systemctl start unoq-learn.service' "$STUB_LOG")" -eq 1 ]
}

@test "a unoq-learn that was not running is neither stopped nor started" {
  # An unprovisioned board, or one where it was stopped on purpose. Starting a
  # service somebody stopped is not this script's decision to make.
  run bash "$BUILD"
  [ "$status" -eq 0 ]
  ran "systemctl is-active --quiet unoq-learn.service"
  ! ran_like '^systemctl (stop|start|restart) '
  [[ "$output" != *"unoq-learn"* ]]
}

@test "a mount that goes rw in place leaves the web server running" {
  # No unmount needed, so nothing is holding anything: the old behaviour,
  # unchanged, including not asking systemd anything at all.
  learn_active
  : >"$FLAGS/remount-rw-works"
  run bash "$BUILD"
  [ "$status" -eq 0 ]
  never_ran umount
  never_ran systemctl
}

# --- and has to come back, whatever happens --------------------------------

@test "a later step failing still starts unoq-learn again" {
  learn_active
  : >"$FLAGS/remount-ro-fails"
  run bash "$BUILD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED  could not remount $UNOQ_SHARE_MOUNT read-only"* ]]

  stop="$(line_of '^systemctl stop unoq-learn\.service$')"
  start="$(line_of '^systemctl start unoq-learn\.service$')"
  [ -n "$stop" ] && [ -n "$start" ]
  [ "$stop" -lt "$start" ]
  [[ "$output" == *"unoq-learn.service started again"* ]]
}

@test "a later step failing does not start a unoq-learn that was never running" {
  : >"$FLAGS/remount-ro-fails"
  run bash "$BUILD"
  [ "$status" -ne 0 ]
  ! ran_like '^systemctl (stop|start) '
}

@test "a unoq-learn that will not start again fails the run and says how to start it" {
  learn_active
  : >"$FLAGS/learn-start-fails"
  run bash "$BUILD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sudo systemctl start unoq-learn.service"* ]]
  [[ "$output" == *"FAILED  unoq-learn.service is not running"* ]]
  # One attempt: the trap must not retry what the main path just reported.
  [ "$(grep -cx 'systemctl start unoq-learn.service' "$STUB_LOG")" -eq 1 ]
}

# --- a holder that is not ours to move -------------------------------------

@test "a mount still busy after that fails and names the holder from fuser" {
  learn_active
  : >"$FLAGS/mount-busy"
  run bash "$BUILD"
  [ "$status" -ne 0 ]
  ran "fuser -vm $UNOQ_SHARE_MOUNT"
  [[ "$output" == *"FAILED  could not unmount $UNOQ_SHARE_MOUNT"* ]]
  [[ "$output" == *"4242"* ]]
  [[ "$output" == *"byobu-shell"* ]]
  [[ "$output" == *"then run this again"* ]]
}

@test "a busy mount is never unmounted lazily or by force" {
  learn_active
  : >"$FLAGS/mount-busy"
  run bash "$BUILD"
  [ "$status" -ne 0 ]
  # Exactly the one plain attempt, and no flag on it of any kind.
  [ "$(grep -c '^umount' "$STUB_LOG")" -eq 1 ]
  ran "umount $UNOQ_SHARE_MOUNT"
  ! ran_like '^umount .*(-l|-f|--lazy|--force)'
  # And nothing written to an image that could not be remounted.
  ! ran_like '^mount -o loop,rw'
  never_ran rsync
}

@test "a busy mount still gets unoq-learn started again" {
  # The failure is the shell in the directory, not the web server - so the web
  # server goes back up, serving the read-only mount that never went away.
  learn_active
  : >"$FLAGS/mount-busy"
  run bash "$BUILD"
  [ "$status" -ne 0 ]
  [ "$(grep -cx 'systemctl start unoq-learn.service' "$STUB_LOG")" -eq 1 ]
}

@test "a busy mount with nothing to restart says so without touching systemd further" {
  : >"$FLAGS/mount-busy"
  run bash "$BUILD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"byobu-shell"* ]]
  ! ran_like '^systemctl (stop|start) '
}
