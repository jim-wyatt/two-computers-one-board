#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# provision/82-boot-counting.sh sets the board up to boot every new kernel on
# trial (issue #93, layer 1). What it must never do is the thing that would
# make a recovery mechanism the cause of an outage: mark kernels bad before
# they have been tried, touch the entry the board is running, or start a check
# that sleeps and proves nothing.
#
# What this cannot show: that U-Boot lets systemd-boot rename the entry at
# boot, or that systemd-bless-boot then marks it good. That takes a reboot;
# docs/reference/troubleshooting.md has the test.

setup() {
  load helpers/stub
  stub_setup
  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  STEP="$PROJECT/provision/82-boot-counting.sh"
  export UNOQ_KERNEL_CONF_DIR="$BATS_TEST_TMPDIR/etc/kernel"
  export UNOQ_UNIT_DIR="$BATS_TEST_TMPDIR/etc/systemd/system"
  UNOQ_USER="$(id -un)"
  export UNOQ_USER
  unset UNOQ_BOOT_TRIES
  FLAGS="$BATS_TEST_TMPDIR/flags"
  mkdir -p "$FLAGS"
  export FLAGS

  stub_body id <<'SH'
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
SH
  stub_body bootctl <<'SH'
case "$*" in
  "is-installed --quiet") [ -e "$FLAGS/no-systemd-boot" ] && exit 1; exit 0 ;;
  --version) echo "systemd 257 (257.13-1~deb13u1)" ;;
  status) echo "Current Entry: f182-7.0.0.conf" ;;
esac
exit 0
SH
  stub_body systemctl <<'SH'
case "$1" in
  is-enabled) [ -e "$FLAGS/enabled" ] && exit 0; exit 1 ;;
  enable) : >"$FLAGS/enabled" ;;
esac
exit 0
SH
}

UNIT() { echo "$UNOQ_UNIT_DIR/unoq-boot-health.service"; }

@test "new kernels get three tries" {
  run "$STEP"
  [ "$status" -eq 0 ]
  [ "$(cat "$UNOQ_KERNEL_CONF_DIR/tries")" = 3 ]
}

@test "the health check is installed and enabled, and not started" {
  # It is wired to boot-complete.target, which only a counted boot pulls in.
  # Started now it would sleep a minute and prove nothing about any kernel.
  run "$STEP"
  [ "$status" -eq 0 ]
  [ -f "$(UNIT)" ]
  ran "systemctl enable unoq-boot-health.service"
  refute ran_like '^systemctl (start|restart|enable --now) .*unoq-boot-health'
}

@test "the health check asks for a finished boot and sshd, and nothing else" {
  run "$STEP"
  grep -qx "Before=boot-complete.target" "$(UNIT)"
  grep -qx "RequiredBy=boot-complete.target" "$(UNIT)"
  grep -qx "After=multi-user.target ssh.service" "$(UNIT)"
  grep -qx "ExecStart=/usr/bin/systemctl is-active --quiet ssh.service" "$(UNIT)"
  # Not the network, not the microcontroller: a board with no cable, or a
  # firmware being flashed, is no reason to go back to an older kernel.
  refute grep -qE "network-online|unoq-link|cpu-bars|ttyHS1" "$(UNIT)"
}

@test "the entry the board is running is not touched" {
  run "$STEP"
  refute ran_like '^bootctl (set-default|set-oneshot|unlink|install|update)'
  refute ran_like '^(mv|cp|rm) .*/loader/entries'
}

@test "a second run changes nothing" {
  run "$STEP"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 changed,"* ]]
}

@test "a board without systemd-boot is left alone" {
  : >"$FLAGS/no-systemd-boot"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"systemd-boot is not installed here"* ]]
  [ ! -e "$UNOQ_KERNEL_CONF_DIR/tries" ]
  [ ! -e "$(UNIT)" ]
}

@test "a number of tries that would mark kernels bad, or is not a number, is refused" {
  for bad in 0 10 -1 three 3x; do
    UNOQ_BOOT_TRIES="$bad" run "$STEP"
    [ "$status" -ne 0 ]
    [ ! -e "$UNOQ_KERNEL_CONF_DIR/tries" ]
  done
}
