#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# provision/56-slim-root.sh removes four groups of packages this project never
# uses - the browser, the desktop, Docker and the GPU compute tools - with
# `apt-get purge --autoremove`. Two things make that safe to ask for: the
# exact list of what goes is written down before anything goes, so one
# command puts it back; and the step refuses, before removing anything, when
# apt's own simulation shows something the board needs going with them.
#
# What this cannot show: what apt really decides on a board. That was
# measured there (issue #219: 346 packages, 1.6 GB, none of the protected
# ones); here apt is a stub that says what each test tells it to.

setup() {
  load helpers/stub
  stub_setup

  REAL="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  STEP="$REAL/provision/56-slim-root.sh"

  UNOQ_USER="$(id -un)"
  export UNOQ_USER
  export FAKE_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$FAKE_HOME"
  export UNOQ_IN_BOOTSTRAP=1
  export UNOQ_RUN_DIR="$BATS_TEST_TMPDIR/run"
  mkdir -p "$UNOQ_RUN_DIR"
  BACKUP="$FAKE_HOME/uno-q-backup"
  LIST="$BACKUP/slim-removed-packages.txt"
  export LIST

  FLAGS="$BATS_TEST_TMPDIR/flags"
  mkdir -p "$FLAGS"
  export FLAGS

  stub_body id <<'SH'
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
SH
  stub_body getent <<'SH'
[ "$1" = passwd ] && { echo "$2:x:1000:1000::$FAKE_HOME:/bin/bash"; exit 0; }
exec /usr/bin/getent "$@"
SH
  stub_body runuser <<'SH'
while [ "$1" != "--" ]; do shift; done
shift
exec "$@"
SH
  # A package database with a memory: a package is installed while its flag
  # file exists.
  stub_body dpkg-query <<'SH'
[ -e "$FLAGS/pkg-${*: -1}" ] && echo "install ok installed"
exit 0
SH
  # apt, as far as this step uses it. The simulation names every package
  # asked for that is installed, then what $FLAGS/orphans says autoremove
  # would take with them, then anything in $FLAGS/sim-extra as it stands.
  # The real purge records what the list said at that moment, so a test can
  # tell whether it was written first.
  stub_body apt-get <<'SH'
if [ "$1" = -s ]; then
  [ -e "$FLAGS/sim-fails" ] && { echo "E: Unable to locate package" >&2; exit 100; }
  echo "NOTE: This is only a simulation!"
  for a in "$@"; do
    case "$a" in -*|purge) continue ;; esac
    [ -e "$FLAGS/pkg-$a" ] && echo "Purg $a [1.0]"
  done
  [ -e "$FLAGS/orphans" ] && sed 's/.*/Purg & [1.0]/' "$FLAGS/orphans"
  [ -e "$FLAGS/sim-extra" ] && cat "$FLAGS/sim-extra"
  exit 0
fi
if [ "$1" = purge ]; then
  cp "$LIST" "$FLAGS/list-at-purge" 2>/dev/null
  [ -e "$FLAGS/purge-fails" ] && exit 100
  for a in "$@"; do rm -f "$FLAGS/pkg-$a"; done
  rm -f "$FLAGS/orphans"
fi
exit 0
SH
}

# installed <pkg>... - mark packages installed.
installed() {
  local p
  for p in "$@"; do : >"$FLAGS/pkg-$p"; done
}

# orphans <pkg>... - what autoremove would take along with them.
orphans() { printf '%s\n' "$@" >"$FLAGS/orphans"; }

# --- what it removes --------------------------------------------------------

@test "only the packages that are installed are purged, one group of each" {
  installed chromium xfce4 docker.io clinfo
  run "$STEP"
  [ "$status" -eq 0 ]
  ran "apt-get purge -y --autoremove chromium xfce4 docker.io clinfo"
  [[ "$output" == *"removed 4 packages"* ]]
}

@test "a board with only some of them is fine, and the rest are not asked for" {
  installed docker-cli
  run "$STEP"
  [ "$status" -eq 0 ]
  ran "apt-get purge -y --autoremove docker-cli"
}

@test "the list is written before anything is removed, with what autoremove takes" {
  installed chromium lightdm
  orphans libfoo1 python3-dbus
  run "$STEP"
  [ "$status" -eq 0 ]
  [ -s "$FLAGS/list-at-purge" ]
  [ "$(cat "$FLAGS/list-at-purge")" = "$(printf '%s\n' chromium libfoo1 lightdm python3-dbus)" ]
  cmp -s "$LIST" "$FLAGS/list-at-purge"
  [[ "$output" == *"$LIST"* ]]
}

@test "a list from an earlier run is kept and added to, not written over" {
  # A purge that failed half way, run again: what went the first time has to
  # stay on the list, or nobody gets it back.
  mkdir -p "$BACKUP"
  echo "chromium" >"$LIST"
  installed docker.io
  orphans containerd
  run "$STEP"
  [ "$status" -eq 0 ]
  [ "$(cat "$LIST")" = "$(printf '%s\n' chromium containerd docker.io)" ]
}

@test "a purge that fails is a failure, and the list is still there" {
  installed chromium
  : >"$FLAGS/purge-fails"
  run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"apt-get purge"* ]]
  [ "$(cat "$LIST")" = chromium ]
}

# --- what it refuses --------------------------------------------------------

# Every package the issue checked is kept, and what this project installs or
# runs on. Written out here rather than read from the step: this is the list
# the step has to protect, so it cannot also be the step's own word for it.
PROTECTED=(bluez network-manager wpasupplicant pipewire wireplumber
  openssh-server ssh dropbear-bin git systemd systemd-sysv udev
  firmware-qcom-soc firmware-atheros clangd-19 clangd-21 python3 python3.13
  python3.13-dev python3-dev alsa-ucm-conf sudo tio avahi-daemon
  avahi-autoipd dosfstools fdisk rsync initramfs-tools busybox gcc make
  wget curl ca-certificates libgpiod3)

@test "every protected package in the simulated removal is a refusal, before anything is written or removed" {
  local p
  for p in "${PROTECTED[@]}"; do
    rm -rf "$BACKUP" "$FLAGS"/*
    : >"$STUB_LOG"
    installed chromium
    orphans libfoo1 "$p"
    run "$STEP"
    [ "$status" -ne 0 ] || {
      echo "not refused: $p"
      return 1
    }
    [[ "$output" == *"$p"* ]]
    [[ "$output" == *"Nothing was removed"* ]]
    refute ran_like '^apt-get purge'
    [ ! -e "$LIST" ]
  done
}

@test "names that only start like a protected one are not refused" {
  # The issue's own run took these, and they are not what the names above
  # protect: the Bluetooth file-transfer daemon, the tray applet for the
  # network manager, the Python bindings for D-Bus and Cairo.
  installed chromium blueman
  orphans bluez-obexd network-manager-applet python3-dbus python3-gi-cairo
  run "$STEP"
  [ "$status" -eq 0 ]
  ran_like '^apt-get purge -y --autoremove'
}

@test "a simulation that would install something is a refusal" {
  installed docker.io
  echo "Inst something-else (2.0 Debian:13/stable [arm64])" >"$FLAGS/sim-extra"
  run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"something-else"* ]]
  refute ran_like '^apt-get purge'
}

@test "a simulation that fails is a refusal" {
  installed docker.io
  : >"$FLAGS/sim-fails"
  run "$STEP"
  [ "$status" -ne 0 ]
  refute ran_like '^apt-get purge'
  [ ! -e "$LIST" ]
}

# --- the second run ---------------------------------------------------------

@test "a second run finds nothing to remove and changes nothing" {
  installed chromium xfce4 docker.io mesa-opencl-icd
  orphans libfoo1
  run "$STEP"
  [ "$status" -eq 0 ]
  before="$(cat "$LIST")"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 changed,"* ]]
  [[ "$output" == *"none of them installed"* ]]
  refute ran_like '^apt-get'
  [ "$(cat "$LIST")" = "$before" ]
}

# --- the way back -----------------------------------------------------------

@test "the REVERT line reinstalls from the file the step writes" {
  revert="$(grep -m1 '^# REVERT:' "$STEP")"
  [[ "$revert" == *"xargs apt-get install -y <"*"slim-removed-packages.txt"* ]]
  installed chromium
  run "$STEP"
  [ "$status" -eq 0 ]
  [ -s "$LIST" ]
}
