#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# The first run of this project on a factory-fresh board, reached the way a
# factory-fresh board is reached - `adb shell` over the USB cable - ended with
# the board powered, on wifi, and impossible to log into. Three things, each
# small:
#
#   - "arduino-router stopped and disabled" was printed, and it was running. A
#     .path unit had started it again; disable_unit reported what it had asked
#     for, not what was true. The router kept the MCU's serial port.
#   - provision/60-usb-gadget.sh stopped adbd half way down. `adb shell` is
#     adbd's child, so that killed the script, before it had installed the
#     gadget that was supposed to replace adb.
#   - Nothing had switched SSH on. The stock image ships it off.
#
# What is tested here is the order things are closed and opened in, and that
# what gets printed is what happened. What CANNOT be tested here is the half
# that matters most: that the gadget binds on a real controller once adbd has
# let go of it, and that a computer on the other end of the cable sees a
# network adapter and a drive. That has not been seen on any board yet.

setup() {
  load helpers/stub
  stub_setup

  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  HANDOVER="$PROJECT/usb/handover.sh"
  GADGET_STEP="$PROJECT/provision/60-usb-gadget.sh"

  FLAGS="$BATS_TEST_TMPDIR/flags"
  mkdir -p "$FLAGS/active" "$FLAGS/enabled" "$FLAGS/sticky" "$FLAGS/missing" \
    "$FLAGS/broken" "$FLAGS/dies" "$FLAGS/clings"

  # Root's copy of the hand-over, as 60-usb-gadget.sh would have installed it.
  # A fake: what is being tested from this side is whether it gets called.
  export UNOQ_RUNTIME_DIR="$BATS_TEST_TMPDIR/runtime"
  mkdir -p "$UNOQ_RUNTIME_DIR/usb"
  cat >"$UNOQ_RUNTIME_DIR/usb/handover.sh" <<SH
#!/bin/bash
echo "installed-handover" >>"$STUB_LOG"
SH
  chmod +x "$UNOQ_RUNTIME_DIR/usb/handover.sh"
  export FLAGS

  export UNOQ_GADGET_DIR="$BATS_TEST_TMPDIR/configfs/unoq"
  export UNOQ_UDC_DIR="$BATS_TEST_TMPDIR/udc"
  export UNOQ_SSH_DIR="$BATS_TEST_TMPDIR/ssh"
  export UNOQ_CGROUP_FILE="$BATS_TEST_TMPDIR/cgroup"
  mkdir -p "$UNOQ_GADGET_DIR" "$UNOQ_UDC_DIR" "$UNOQ_SSH_DIR"
  echo "0::/system.slice/ssh.service" >"$UNOQ_CGROUP_FILE"
  UNOQ_USER="$(id -un)"
  export UNOQ_USER

  stub_body id <<'SH'
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
SH
  stub logger
  stub ssh-keygen
  stub systemd-run

  # A systemd with a memory. A unit is running if $FLAGS/active/<unit> exists
  # and enabled if $FLAGS/enabled/<unit> does, so a test sets the scene by
  # touching files. Two more directories describe the awkward cases:
  #   missing/<unit>  the unit does not exist on this board
  #   sticky/<unit>   stopping it does not work - something starts it again
  #   clings/<unit>   disabling it does not work - it stays enabled
  #   broken/<unit>   starting it fails, and systemctl says so
  #   dies/<unit>     starting it "works", and it is not running afterwards
  stub_body systemctl <<'SH'
verb="$1"; shift
args=()
for a in "$@"; do case "$a" in -*) ;; *) args+=("$a") ;; esac; done
case "$verb" in
  is-active)
    [ -e "$FLAGS/active/${args[0]}" ]
    exit ;;
  is-enabled)
    [ -e "$FLAGS/enabled/${args[0]}" ] && { echo enabled; exit 0; }
    echo disabled
    exit 1 ;;
  cat | list-unit-files)
    [ -e "$FLAGS/missing/${args[0]}" ] && exit 1
    echo "${args[0]} static" ;;
  disable)
    for u in "${args[@]}"; do
      [ -e "$FLAGS/clings/$u" ] || rm -f "$FLAGS/enabled/$u"
      [ -e "$FLAGS/sticky/$u" ] || rm -f "$FLAGS/active/$u"
    done ;;
  enable | start | restart)
    [ -e "$FLAGS/broken/${args[0]}" ] && exit 1
    for u in "${args[@]}"; do
      [ "$verb" = enable ] && touch "$FLAGS/enabled/$u"
      [ -e "$FLAGS/dies/$u" ] || touch "$FLAGS/active/$u"
    done ;;
  stop) for u in "${args[@]}"; do rm -f "$FLAGS/active/$u"; done ;;
esac
exit 0
SH
}

running() { touch "$FLAGS/active/$1" "$FLAGS/enabled/$1"; }

load_lib() {
  # shellcheck disable=SC1090
  source "$PROJECT/provision/lib.sh" || {
    echo "could not source provision/lib.sh" >&2
    return 1
  }
  declare -F ensure_ssh >/dev/null || {
    echo "lib.sh sourced but ensure_ssh is not defined" >&2
    return 1
  }
}

# --- disable_unit says what is true -------------------------------------------

@test "a unit that stops is reported as stopped" {
  running arduino-app-cli.service
  load_lib
  run disable_unit arduino-app-cli.service
  [ "$status" -eq 0 ]
  [[ "$output" == *"arduino-app-cli.service stopped and disabled"* ]]
}

@test "a unit that something starts again is not reported as stopped" {
  # The stock board: arduino-router, held up by arduino-router-serial.path.
  running arduino-router.service
  touch "$FLAGS/sticky/arduino-router.service"
  load_lib
  run disable_unit arduino-router.service
  [ "$status" -ne 0 ]
  [[ "$output" != *"stopped and disabled"* ]]
  [[ "$output" == *"still running"* ]]
}

@test "one unit that will not stop does not hide the ones that did" {
  running arduino-router.service
  running arduino-app-cli.service
  touch "$FLAGS/sticky/arduino-router.service"
  load_lib
  run disable_unit arduino-router.service arduino-app-cli.service
  [ "$status" -ne 0 ]
  [[ "$output" == *"arduino-app-cli.service stopped and disabled"* ]]
}

@test "a unit that stops but stays enabled is not reported as dealt with" {
  # It is quiet now and back at the next boot, which is the worse half to miss.
  running arduino-app-cli.service
  touch "$FLAGS/clings/arduino-app-cli.service"
  load_lib
  run disable_unit arduino-app-cli.service
  [ "$status" -ne 0 ]
  [[ "$output" != *"stopped and disabled"* ]]
  [[ "$output" == *"still enabled"* ]]
}

@test "the router's trigger is disabled before the router is" {
  # Stop the router first and arduino-router-serial.path has it back before
  # the next line. This is an assertion about the order in a file, because the
  # only thing that can show the order WORKS is a stock board.
  line="$(grep -A2 '^disable_unit arduino-router' "$PROJECT/provision/20-dev-tools.sh" | tr -d '\\\n')"
  path_at="${line%%arduino-router-serial.path*}"
  router_at="${line%%arduino-router.service*}"
  [ "${#path_at}" -lt "${#line}" ]
  [ "${#path_at}" -lt "${#router_at}" ]
}

# --- ensure_ssh ---------------------------------------------------------------

@test "sshd is switched on when it was off, as it is on a stock board" {
  touch "$UNOQ_SSH_DIR/ssh_host_ed25519_key"
  load_lib
  run ensure_ssh
  [ "$status" -eq 0 ]
  ran "systemctl enable --now ssh.service"
  never_ran ssh-keygen
}

@test "host keys are generated when there are none" {
  load_lib
  run ensure_ssh
  [ "$status" -eq 0 ]
  ran "ssh-keygen -A"
}

@test "an sshd that will not start is a failure, not a line of output" {
  touch "$UNOQ_SSH_DIR/ssh_host_ed25519_key"
  touch "$FLAGS/broken/ssh.service"
  load_lib
  run ensure_ssh
  [ "$status" -ne 0 ]
}

@test "an sshd that starts and then is not running is a failure too" {
  # No host key it can use, a bad sshd_config: systemctl start returns 0 and
  # the unit is dead a moment later. Asking is not the same as having.
  touch "$UNOQ_SSH_DIR/ssh_host_ed25519_key"
  touch "$FLAGS/dies/ssh.service"
  load_lib
  run ensure_ssh
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not stay running"* ]]
}

@test "a board with no ssh unit at all is a failure" {
  touch "$FLAGS/missing/ssh.service"
  load_lib
  run ensure_ssh
  [ "$status" -ne 0 ]
  never_ran "systemctl enable --now ssh.service"
}

# --- in_unit_cgroup ------------------------------------------------------------

@test "a shell started by adbd knows it" {
  echo "0::/system.slice/adbd.service" >"$UNOQ_CGROUP_FILE"
  load_lib
  run in_unit_cgroup adbd.service
  [ "$status" -eq 0 ]
}

@test "an SSH session is not mistaken for one" {
  echo "0::/user.slice/user-1000.slice/session-3.scope" >"$UNOQ_CGROUP_FILE"
  load_lib
  run in_unit_cgroup adbd.service
  [ "$status" -ne 0 ]
}

@test "a unit whose name merely ends the same way does not match" {
  echo "0::/system.slice/not-adbd.service" >"$UNOQ_CGROUP_FILE"
  load_lib
  run in_unit_cgroup adbd.service
  [ "$status" -ne 0 ]
}

# --- usb/handover.sh -----------------------------------------------------------

@test "adb is not touched while sshd is not running" {
  running adbd.service
  run "$HANDOVER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED"* ]]
  never_ran "systemctl disable --now adbd.service"
  [ -e "$FLAGS/active/adbd.service" ]
}

@test "with sshd up, adbd goes and the gadget is built" {
  running ssh.service
  running adbd.service
  run "$HANDOVER"
  [ "$status" -eq 0 ]
  ran "systemctl disable --now adbd.service"
  ran "systemctl restart unoq-usb-gadget.service"
  [ ! -e "$FLAGS/active/adbd.service" ]
}

@test "the gadget is not built over an adbd that would not stop" {
  running ssh.service
  running adbd.service
  touch "$FLAGS/sticky/adbd.service"
  run "$HANDOVER"
  [ "$status" -ne 0 ]
  never_ran "systemctl restart unoq-usb-gadget.service"
}

@test "the gadget is not built over an adbd that is still enabled" {
  # Stopped is not enough: at the next boot it is back, racing for the port.
  running ssh.service
  running adbd.service
  touch "$FLAGS/clings/adbd.service"
  run "$HANDOVER"
  [ "$status" -ne 0 ]
  never_ran "systemctl restart unoq-usb-gadget.service"
}

@test "a journal that takes no messages does not turn success into failure" {
  stub logger 1
  running ssh.service
  running adbd.service
  touch "$UNOQ_UDC_DIR/4e00000.usb"
  run "$HANDOVER"
  [ "$status" -eq 0 ]
}

@test "with a cable already in, the bind is started by hand" {
  # The udev rule fires when a controller appears. This one appeared at boot.
  running ssh.service
  running adbd.service
  touch "$UNOQ_UDC_DIR/4e00000.usb"
  run "$HANDOVER"
  [ "$status" -eq 0 ]
  ran "systemctl start unoq-usb-bind.service"
}

@test "with no cable in, nothing is bound and that is not an error" {
  running ssh.service
  run "$HANDOVER"
  [ "$status" -eq 0 ]
  never_ran "systemctl start unoq-usb-bind.service"
}

@test "a board whose adbd is already gone still gets its gadget rebuilt" {
  running ssh.service
  run "$HANDOVER"
  [ "$status" -eq 0 ]
  never_ran "systemctl disable --now adbd.service"
  ran "systemctl restart unoq-usb-gadget.service"
}

@test "a gadget that fails to build is reported, with the way back to adb" {
  running ssh.service
  running adbd.service
  touch "$FLAGS/broken/unoq-usb-gadget.service"
  run "$HANDOVER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"enable --now adbd"* ]]
}

@test "the hand-over refuses to run as anyone but root" {
  stub_body id <<'SH'
[ "${1:-}" = "-u" ] && { echo 1000; exit 0; }
exec /usr/bin/id "$@"
SH
  running ssh.service
  run "$HANDOVER"
  [ "$status" -ne 0 ]
  never_ran "systemctl restart unoq-usb-gadget.service"
}

# --- usb_handover: called, or scheduled ------------------------------------------

@test "from an SSH session the hand-over is simply run" {
  load_lib
  usb_handover
  [ "$HANDOVER_DEFERRED" = 0 ]
  ran "installed-handover"
  never_ran systemd-run
}

@test "from adb shell it is scheduled, with the delay, and not run" {
  echo "0::/system.slice/adbd.service" >"$UNOQ_CGROUP_FILE"
  export UNOQ_HANDOVER_DELAY=7
  load_lib
  usb_handover
  [ "$HANDOVER_DEFERRED" = 1 ]
  never_ran "installed-handover"
  ran_like "^systemd-run .*--unit=unoq-usb-handover .*--on-active=7 .*$UNOQ_RUNTIME_DIR/usb/handover.sh\$"
  # A timer's default accuracy is a minute. Measured: 30 seconds late.
  ran_like "^systemd-run .*AccuracySec=1s"
}

@test "from adb shell, a hand-over that cannot be scheduled is a failure and adb is left alone" {
  echo "0::/system.slice/adbd.service" >"$UNOQ_CGROUP_FILE"
  running adbd.service
  stub systemd-run 1
  load_lib
  run usb_handover
  [ "$status" -ne 0 ]
  [[ "$output" == *"adb is untouched"* ]]
  never_ran "installed-handover"
  [ -e "$FLAGS/active/adbd.service" ]
}

@test "a hand-over that fails when run directly is a failure, and says where to look" {
  # It used to warn and return 0, and the step went on to print "bound".
  printf '#!/bin/bash\nexit 1\n' >"$UNOQ_RUNTIME_DIR/usb/handover.sh"
  load_lib
  run usb_handover
  [ "$status" -ne 0 ]
  [[ "$output" == *"hand-over failed"* ]]
  [[ "$output" != *"hand-over ran"* ]]
}

@test "the step does not let a failed hand-over pass" {
  # In the file, because running the whole step needs a board: the status of
  # usb_handover has to be kept, and has to reach a fail.
  grep -q '^usb_handover || HANDOVER_FAILED=1$' "$GADGET_STEP"
  grep -q '^\[ "\$HANDOVER_FAILED" = 0 \] ||$' "$GADGET_STEP"
  # And "bound" is the gadget's own UDC file, not a controller being present.
  grep -q 'bound="\$(cat "\$G/UDC"' "$GADGET_STEP"
}

# --- the step that calls it ------------------------------------------------------

@test "the step opens SSH before it does anything that closes adb" {
  # Order in a file again. `ensure_ssh` has to come before the hand-over, and
  # nothing in the step may stop adbd by itself - that is handover.sh's job,
  # because only handover.sh can be run from outside adbd.
  ssh_line="$(grep -n '^ensure_ssh' "$GADGET_STEP" | cut -d: -f1)"
  handover_line="$(grep -n '^usb_handover ' "$GADGET_STEP" | cut -d: -f1)"
  [ -n "$ssh_line" ] && [ -n "$handover_line" ]
  [ "$ssh_line" -lt "$handover_line" ]
  ! grep -nE '^[^#]*(disable_unit|systemctl (stop|disable)[^#]*) adbd' "$GADGET_STEP"
}

@test "the hand-over is the last thing the step does to the board" {
  handover_line="$(grep -n '^usb_handover ' "$GADGET_STEP" | cut -d: -f1)"
  last_install="$(grep -nE '^[^#]*(install_unit|install_root_scripts|apt_install|write_file|enable_unit|systemctl enable)' "$GADGET_STEP" | tail -1 | cut -d: -f1)"
  [ "$last_install" -lt "$handover_line" ]
}
