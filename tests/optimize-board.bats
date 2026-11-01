#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# provision/10-optimize-board.sh is the first step a restored board gets, and
# the broadest: it switches off the desktop and what a headless board does not
# use, upgrades the image, grants the hardware groups, and deletes Arduino's
# container images. What is at stake is mostly what it must NOT do. The
# upgrade is `upgrade`, never one that removes packages, it keeps the board's
# config files, and Arduino's audio package is pinned before it runs. The
# image list is written before the images are deleted. A board that asked to
# keep Bluetooth, or its images, keeps them. The CPU governor it sets is one
# every policy offers, and one it was not told to leave to the kernel.
#
# The board's /etc and the cpufreq policies in its /sys are under UNOQ_ROOT,
# and apt's cache under UNOQ_APT_CACHE_DIR; everything else it changes is a
# command, stubbed.
#
# What this cannot show: that the board boots to a login prompt afterwards, or
# that the upgrade leaves it bootable. That is the board's job.

setup() {
  load helpers/stub
  stub_setup

  REAL="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  STEP="$REAL/provision/10-optimize-board.sh"

  FLAGS="$BATS_TEST_TMPDIR/flags"
  mkdir -p "$FLAGS"
  export FLAGS

  export UNOQ_ROOT="$BATS_TEST_TMPDIR/root"
  export UNOQ_APT_CACHE_DIR="$BATS_TEST_TMPDIR/var/cache/apt"
  export UNOQ_RUN_DIR="$BATS_TEST_TMPDIR/run"
  export UNOQ_IN_BOOTSTRAP=1
  unset UNOQ_CPU_GOVERNOR
  mkdir -p "$UNOQ_APT_CACHE_DIR/archives" "$UNOQ_RUN_DIR"
  UNOQ_USER="$(id -un)"
  export UNOQ_USER
  export FAKE_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$FAKE_HOME"
  export UNOQ_BACKUP="$FAKE_HOME/uno-q-backup"
  PIN="$UNOQ_ROOT/etc/apt/preferences.d/arduino-alsa-ucm-conf.pref"
  SPI_RULE="$UNOQ_ROOT/etc/udev/rules.d/91-spidev-local.rules"
  PYDEV="python$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')-dev"
  CPUFREQ="$UNOQ_ROOT/sys/devices/system/cpu/cpufreq"
  GOV_CONF="$UNOQ_ROOT/etc/tmpfiles.d/unoq-cpufreq.conf"
  export PIN

  stub udevadm
  # systemd-tmpfiles: what --create does with a `w` line, under UNOQ_ROOT. The
  # glob is left unquoted on purpose, to expand the way tmpfiles expands it.
  stub_body systemd-tmpfiles <<'SH'
[ "$1" = --create ] || exit 0
while read -r type path _ _ _ _ arg; do
  [ "$type" = w ] || continue
  for f in "$UNOQ_ROOT"$path; do [ -e "$f" ] && printf '%s' "$arg" >"$f"; done
done <"$2"
SH
  stub_body id <<'SH'
case "${1:-}" in
  -u) echo 0 ;;
  -nG) cat "$FLAGS/groups" 2>/dev/null; echo ;;
  *) exec /usr/bin/id "$@" ;;
esac
SH
  stub_body getent <<'SH'
case "$1" in
  passwd) echo "$2:x:1000:1000::$FAKE_HOME:/bin/bash" ;;
  group) [ -e "$FLAGS/group-$2" ] ;;
  *) exec /usr/bin/getent "$@" ;;
esac
SH
  stub_body groupadd <<'SH'
: >"$FLAGS/group-${*: -1}"
SH
  stub_body usermod <<'SH'
printf ' %s' "$2" >>"$FLAGS/groups"
SH
  stub_body runuser <<'SH'
while [ "$1" != "--" ]; do shift; done
shift
exec "$@"
SH
  stub_body dpkg-query <<'SH'
[ -e "$FLAGS/pkg-${*: -1}" ] && echo "install ok installed"
exit 0
SH
  # apt: as many upgrades pending as $FLAGS/pending says. An upgrade notes
  # whether Arduino's pin was in place when it ran.
  stub_body apt-get <<'SH'
case "$1" in
  -s) for _ in $(seq 1 "$(cat "$FLAGS/pending" 2>/dev/null || echo 0)"); do echo "Inst libfoo"; done ;;
  upgrade)
    [ -e "$PIN" ] && : >"$FLAGS/pinned-at-upgrade"
    [ -e "$FLAGS/upgrade-fails" ] && exit 100
    echo 0 >"$FLAGS/pending"
    ;;
  install) for a in "$@"; do case "$a" in -* | install) ;; *) : >"$FLAGS/pkg-$a" ;; esac; done ;;
  clean) rm -rf "$UNOQ_APT_CACHE_DIR/archives/"* ;;
esac
exit 0
SH
  # Docker, with the images in $FLAGS/images, one tag per line.
  stub_body docker <<'SH'
case "$1 ${2:-}" in
  "info "*) [ ! -e "$FLAGS/docker-down" ] ;;
  "images -q") [ -s "$FLAGS/images" ] && echo 0123456789ab; exit 0 ;;
  "images --format") cat "$FLAGS/images" 2>/dev/null; echo "<none>:<none>" ;;
  "system df") echo "2.1GB" ;;
  "image prune") [ -s "$FLAGS/images" ] && : >"$FLAGS/pruned-with-list-$(test -s "$UNOQ_BACKUP/docker-images.txt" && echo yes || echo no)"; : >"$FLAGS/images" ;;
esac
SH
  stub_body systemctl <<'SH'
u="${*: -1}"
case "$1" in
  get-default) cat "$FLAGS/default-target" 2>/dev/null || echo graphical.target ;;
  set-default) echo "$2" >"$FLAGS/default-target" ;;
  list-unit-files) [ -e "$FLAGS/unit-$2" ] && echo "$2 enabled"; exit 0 ;;
  cat) [ -e "$FLAGS/unit-$2" ]; exit ;;
  is-enabled)
    [ -e "$FLAGS/masked-$u" ] && { echo masked; exit 1; }
    [ -e "$FLAGS/enabled-$u" ] && { echo enabled; exit 0; }
    echo disabled
    exit 1
    ;;
  is-active) [ -e "$FLAGS/active-$u" ]; exit ;;
  is-failed) [ -e "$FLAGS/failed-$u" ]; exit ;;
  reset-failed) rm -f "$FLAGS/failed-$u" ;;
  stop) rm -f "$FLAGS/active-$u" ;;
  mask) : >"$FLAGS/masked-$u"; rm -f "$FLAGS/enabled-$u" ;;
  disable)
    rm -f "$FLAGS/enabled-$u"
    [ "$2" = --now ] && rm -f "$FLAGS/active-$u"
    ;;
  enable) : >"$FLAGS/enabled-$u" ;;
esac
exit 0
SH
}

TIER1="lightdm.service ModemManager.service fwupd-refresh.timer apt-daily.timer apt-daily-upgrade.timer"
TIER2="bluetooth.service blueman-mechanism.service udisks2.service"

# stock_board - a restored image: the desktop as the default target, every
# unit the step switches off there and running, upgrades pending, a full apt
# cache, Arduino's container images, and the gpiod group the image defines.
stock_board() {
  local u
  for u in $TIER1 $TIER2 fwupd.service fwupd-refresh.service; do
    : >"$FLAGS/unit-$u"
    : >"$FLAGS/enabled-$u"
    : >"$FLAGS/active-$u"
  done
  echo 70 >"$FLAGS/pending"
  head -c 12M /dev/zero >"$UNOQ_APT_CACHE_DIR/archives/big.deb"
  printf '%s\n' "ghcr.io/arduino/app-bricks/python-base:0.6.4" \
    "ghcr.io/arduino/app-bricks/ei-models-runner:0.6.4" >"$FLAGS/images"
  : >"$FLAGS/group-gpiod"
  cpufreq_policy policy0
}

# cpufreq_policy <name> [governors] - a policy dir as the kernel shows it, on
# the kernel's default governor.
cpufreq_policy() {
  mkdir -p "$CPUFREQ/$1"
  echo "${2:-ondemand userspace performance schedutil} " >"$CPUFREQ/$1/scaling_available_governors"
  echo schedutil >"$CPUFREQ/$1/scaling_governor"
}

# revert <step heading> - the REVERT comment above that part of the step, as
# one line: "# REVERT:" and the "#" of each continuation dropped.
revert() {
  awk -v want="$1" '
    /^# REVERT:/ { buf = substr($0, 11); inrev = 1; next }
    inrev && /^#  / { sub(/^# +/, ""); buf = buf " " $0; next }
    { inrev = 0 }
    /^step "/ && buf != "" { if (index($0, "\"" want "\"")) { print buf; exit } buf = "" }
  ' "$STEP"
}

# --- the first run ----------------------------------------------------------

@test "a stock board boots to a text login, with what it does not use switched off" {
  stock_board
  run "$STEP"
  [ "$status" -eq 0 ]
  [ "$(cat "$FLAGS/default-target")" = multi-user.target ]
  local u
  for u in $TIER1 $TIER2; do
    ran "systemctl disable --now $u"
    [ ! -e "$FLAGS/enabled-$u" ]
  done
  # fwupd restarts whenever fwupdmgr runs, so it is masked, not disabled.
  [ -e "$FLAGS/masked-fwupd.service" ]
}

@test "a stock board is upgraded, keeping its config files, and told it needs a reboot" {
  stock_board
  run "$STEP"
  [ "$status" -eq 0 ]
  ran "apt-get update -qq"
  ran "apt-get upgrade -y -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef"
  [[ "$output" == *"upgraded 70 package(s)"* ]]
  [ -e "$UNOQ_RUN_DIR/unoq-packages-changed" ]
}

@test "the upgrade never removes a package to move forward" {
  # The Qualcomm platform packages are what make this board boot.
  stock_board
  run "$STEP"
  refute ran_like '^apt-get .*(full-upgrade|dist-upgrade|autoremove)'
}

@test "Arduino's audio package is pinned by the time the upgrade runs" {
  # Debian's backports build has no profile for this board; taking it leaves
  # remoteproc_audio_fixup failed at every boot and LED 2 blinking red.
  stock_board
  run "$STEP"
  [ "$status" -eq 0 ]
  [ -e "$FLAGS/pinned-at-upgrade" ]
  [ "$(cat "$PIN")" = "$(printf 'Package: alsa-ucm-conf\nPin: origin apt-repo.arduino.cc\nPin-Priority: 1001')" ]
}

@test "the downloaded packages are cleared after the upgrade" {
  stock_board
  run "$STEP"
  [ "$status" -eq 0 ]
  ran "apt-get clean"
  [[ "$output" == *"apt cache cleared (was 12 MB)"* ]]
}

@test "the hardware groups are made and the owner is put in them" {
  stock_board
  run "$STEP"
  [ "$status" -eq 0 ]
  ran "groupadd -r i2c"
  ran "groupadd -r spi"
  ran "usermod -aG i2c $UNOQ_USER"
  ran "usermod -aG spi $UNOQ_USER"
  ran "usermod -aG gpiod $UNOQ_USER"
  grep -qx 'SUBSYSTEM=="spidev", GROUP="spi", MODE="0660"' "$SPI_RULE"
  ran "udevadm control --reload-rules"
  ran "udevadm trigger --subsystem-match=spidev"
}

@test "the Python headers installed are the ones for the board's own python3" {
  stock_board
  run "$STEP"
  [ "$status" -eq 0 ]
  ran_like "^apt-get install -y --no-install-recommends $PYDEV\$"
}

@test "Arduino's container images are listed, then deleted" {
  # The list is the only way to get them back, so it is written first.
  stock_board
  run "$STEP"
  [ "$status" -eq 0 ]
  [ -e "$FLAGS/pruned-with-list-yes" ]
  [ "$(cat "$UNOQ_BACKUP/docker-images.txt")" = "$(printf '%s\n' \
    ghcr.io/arduino/app-bricks/python-base:0.6.4 \
    ghcr.io/arduino/app-bricks/ei-models-runner:0.6.4)" ]
}

@test "a stock board is set to ondemand now, and at every boot" {
  # Two policies, so the one glob line is seen to reach both.
  stock_board
  cpufreq_policy policy4
  run "$STEP"
  [ "$status" -eq 0 ]
  grep -qx 'w /sys/devices/system/cpu/cpufreq/policy\*/scaling_governor - - - - ondemand' "$GOV_CONF"
  ran "systemd-tmpfiles --create $GOV_CONF"
  [ "$(cat "$CPUFREQ/policy0/scaling_governor")" = ondemand ]
  [ "$(cat "$CPUFREQ/policy4/scaling_governor")" = ondemand ]
  [[ "$output" == *"policy0 now reads ondemand"* ]]
  [[ "$output" == *"policy4 now reads ondemand"* ]]
}

@test "a governor that does not take is said so" {
  stock_board
  stub systemd-tmpfiles
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"policy0 reads 'schedutil', not ondemand"* ]]
}

# --- the second run ---------------------------------------------------------

@test "a second run changes nothing" {
  stock_board
  run "$STEP"
  : >"$STUB_LOG"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 changed,"* ]]
  [[ "$output" == *"all packages already current"* ]]
  refute ran_like '^apt-get (upgrade|install)'
  refute ran_like '^systemctl (disable|mask|set-default)'
  refute ran_like '^(groupadd|usermod|udevadm|systemd-tmpfiles)'
}

# --- what it can be told to leave -------------------------------------------

@test "UNOQ_SKIP_APT_UPGRADE=1 skips the upgrade and still writes the pin" {
  # The pin is for any later `apt upgrade`, not just this one.
  stock_board
  UNOQ_SKIP_APT_UPGRADE=1 run "$STEP"
  [ "$status" -eq 0 ]
  # An update is still owed to the packages the step installs; an upgrade is not.
  refute ran_like '^apt-get (-s )?upgrade'
  [[ "$output" == *"upgrade skipped (UNOQ_SKIP_APT_UPGRADE=1)"* ]]
  [ -e "$PIN" ]
}

@test "UNOQ_TIER2=0 leaves Bluetooth and udisks2 as they were" {
  stock_board
  UNOQ_TIER2=0 run "$STEP"
  [ "$status" -eq 0 ]
  local u
  for u in $TIER2; do
    refute ran "systemctl disable --now $u"
    [ -e "$FLAGS/enabled-$u" ]
  done
}

@test "a board running the Bluetooth sensor keeps Bluetooth, and only Bluetooth" {
  # 68-ble-sensor.sh is the exception to TIER 2. A re-run of bootstrap comes
  # through here before 68, and Bluetooth off would stop the sensor with it.
  stock_board
  : >"$FLAGS/enabled-unoq-ble-sensor.service"
  run "$STEP"
  [ "$status" -eq 0 ]
  refute ran "systemctl disable --now bluetooth.service"
  [ -e "$FLAGS/enabled-bluetooth.service" ]
  [ -e "$FLAGS/active-bluetooth.service" ]
  [[ "$output" == *"bluetooth.service kept: unoq-ble-sensor is enabled"* ]]
  ran "systemctl disable --now blueman-mechanism.service"
  ran "systemctl disable --now udisks2.service"
}

@test "UNOQ_KEEP_DOCKER_IMAGES=1 keeps the images" {
  stock_board
  UNOQ_KEEP_DOCKER_IMAGES=1 run "$STEP"
  [ "$status" -eq 0 ]
  refute ran "docker image prune -af"
  [ -s "$FLAGS/images" ]
}

@test "UNOQ_CPU_GOVERNOR=kernel leaves the governor to the kernel, and removes nothing" {
  stock_board
  UNOQ_CPU_GOVERNOR=kernel run "$STEP"
  [ "$status" -eq 0 ]
  [ ! -e "$GOV_CONF" ]
  refute ran_like '^systemd-tmpfiles'
  [ "$(cat "$CPUFREQ/policy0/scaling_governor")" = schedutil ]
  [[ "$output" == *"left to the kernel (UNOQ_CPU_GOVERNOR=kernel)"* ]]
  # A file an earlier run wrote is the REVERT line's to remove, not this.
  run "$STEP"
  UNOQ_CPU_GOVERNOR='' run "$STEP"
  [ "$status" -eq 0 ]
  [ -e "$GOV_CONF" ]
}

@test "UNOQ_CPU_GOVERNOR=performance writes performance" {
  stock_board
  UNOQ_CPU_GOVERNOR=performance run "$STEP"
  [ "$status" -eq 0 ]
  grep -q ' performance$' "$GOV_CONF"
  [ "$(cat "$CPUFREQ/policy0/scaling_governor")" = performance ]
}

@test "a governor the kernel does not offer fails before anything changes" {
  # powersave is not built into this kernel, so not offered. Caught at the
  # top, not in its step: nothing else in the run has happened yet either.
  stock_board
  UNOQ_CPU_GOVERNOR=powersave run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNOQ_CPU_GOVERNOR=powersave is not offered by policy0"* ]]
  [ ! -e "$GOV_CONF" ]
  [ ! -e "$PIN" ]
  refute ran_like '^(systemd-tmpfiles|apt-get|systemctl (set-default|disable|mask))'
}

@test "two governors at once are not one the kernel offers" {
  # Each word is offered, and in that order, so the list contains the pair as
  # it stands. But the line would write both, which the kernel refuses.
  stock_board
  UNOQ_CPU_GOVERNOR="userspace performance" run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not offered by policy0"* ]]
  [ ! -e "$GOV_CONF" ]
}

@test "a governor missing from one policy of two fails too" {
  stock_board
  cpufreq_policy policy4 "userspace performance schedutil"
  run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"=ondemand is not offered by policy4 (it offers: userspace performance schedutil )"* ]]
  [ ! -e "$GOV_CONF" ]
}

@test "a machine without cpufreq is left alone" {
  stock_board
  rm -r "$CPUFREQ"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no cpufreq policies"* ]]
  [ ! -e "$GOV_CONF" ]
}

# --- what it finds ----------------------------------------------------------

@test "nothing to upgrade says so, and leaves no reboot note" {
  stock_board
  echo 0 >"$FLAGS/pending"
  : >"$FLAGS/pkg-$PYDEV"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all packages already current"* ]]
  refute ran_like '^apt-get upgrade'
  [ ! -e "$UNOQ_RUN_DIR/unoq-packages-changed" ]
}

@test "an upgrade that fails stops the step" {
  stock_board
  : >"$FLAGS/upgrade-fails"
  run "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"apt-get upgrade - fix the cause and re-run this script"* ]]
}

@test "a firmware-update check left failed is cleared, so LED 2 does not blink for it" {
  stock_board
  : >"$FLAGS/failed-fwupd-refresh.service"
  run "$STEP"
  [ "$status" -eq 0 ]
  ran "systemctl stop fwupd-refresh.service"
  ran "systemctl reset-failed fwupd-refresh.service"
  [[ "$output" == *"cleared the failed state fwupd-refresh.service was left in"* ]]
}

@test "Docker already switched off is not reported as a fault" {
  # A second bootstrap, after 15-dev-tools.sh disabled the daemon.
  stock_board
  : >"$FLAGS/docker-down"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker daemon not running - nothing to reclaim from here"* ]]
  refute ran "docker image prune -af"
}

@test "an image without a gpiod group says so, and is not an error" {
  stock_board
  rm "$FLAGS/group-gpiod"
  run "$STEP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no gpiod group on this image"* ]]
  refute ran "usermod -aG gpiod $UNOQ_USER"
}

# --- the way back -----------------------------------------------------------

@test "the REVERT line for the pin removes it" {
  stock_board
  run "$STEP"
  cmd="$(revert "audio package pin")"
  [ "$cmd" = "rm /etc/apt/preferences.d/arduino-alsa-ucm-conf.pref" ]
  bash -c "${cmd//\/etc/$UNOQ_ROOT/etc}"
  [ ! -e "$PIN" ]
}

@test "the REVERT line for SPI access removes the rule and reloads udev" {
  stock_board
  run "$STEP"
  cmd="$(revert "SPI access")"
  [ -n "$cmd" ]
  : >"$STUB_LOG"
  bash -c "${cmd//\/etc/$UNOQ_ROOT/etc}"
  [ ! -e "$SPI_RULE" ]
  ran "udevadm control --reload"
}

@test "the REVERT line for the desktop brings the target and lightdm back" {
  stock_board
  run "$STEP"
  cmd="$(revert "desktop stack")"
  [ -n "$cmd" ]
  bash -c "$cmd"
  [ "$(cat "$FLAGS/default-target")" = graphical.target ]
  [ -e "$FLAGS/enabled-lightdm" ]
}

@test "the REVERT line for the governor removes the file and puts schedutil back" {
  stock_board
  run "$STEP"
  [ "$(cat "$CPUFREQ/policy0/scaling_governor")" = ondemand ]
  cmd="$(revert "CPU governor")"
  [ -n "$cmd" ]
  cmd="${cmd//\/etc/$UNOQ_ROOT/etc}"
  bash -c "${cmd// \/sys\// $UNOQ_ROOT/sys/}"
  [ ! -e "$GOV_CONF" ]
  [ "$(cat "$CPUFREQ/policy0/scaling_governor")" = schedutil ]
}
