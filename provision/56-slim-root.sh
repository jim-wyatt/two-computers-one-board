#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Remove the browser, the desktop, Docker and the GPU compute tools: about
# 1.6 GB of the root filesystem that this project never uses (issue #219).
#
#   sudo bash ~/two-computers-one-board/provision/56-slim-root.sh
#
# Arduino's image ships a full desktop. This board boots to multi-user.target
# and 10-optimize-board.sh disables lightdm; Docker only ever ran App Lab's
# containers, and 15-dev-tools.sh disables it. Switched off, they still take
# up the root, which is the partition that runs out first and the one #169
# will split in two. Measured on the board on 2026-11-02 with
# `apt-get purge --autoremove --assume-no`:
#
#   browser   chromium, the webkit2gtk libraries    165 packages   876 MB
#   desktop   xfce4, lightdm, Xorg and their apps   132 packages   252 MB
#   Docker    docker.io and its CLI plugins          19 packages   331 MB
#   GPU       OpenCL, clinfo, vulkan-tools            7 packages   141 MB
#
# WHAT IT COSTS. No graphical session if a monitor is plugged in; no browser
# on the board, so the diagram gate (tools/check.sh diagrams) needs one put
# back or pointed at; and App Lab would need Docker back. Nothing this project
# runs uses any of it.
#
# HOW IT STAYS SAFE. apt is asked first, with -s, exactly what the purge would
# take, autoremoved dependencies included. If that includes anything on the
# PROTECTED list below, the step refuses and nothing is removed. Otherwise the
# list is written to $LIST BEFORE anything goes, and added to on a later run
# rather than written over, so a purge that stops half way loses nothing.
#
# Only packages that are installed are asked for, so a second run, or a board
# that never had some of them, finds nothing to do and says so.
#
# REVERT: xargs apt-get install -y < ~/uno-q-backup/slim-removed-packages.txt
#   then re-run 10-optimize-board.sh, which switches the desktop and Docker off
#   again the way they were before.
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
need_root

LIST="${UNOQ_BACKUP:-$TARGET_HOME/uno-q-backup}/slim-removed-packages.txt"

# The top-level packages, by group. Exact names, not globs, so what this asks
# for can be read here. A name the board does not have is simply not asked for.
BROWSER=(chromium chromium-common
  libwebkit2gtk-4.1-0 libjavascriptcoregtk-4.1-0
  gir1.2-webkit2-4.1 gir1.2-javascriptcoregtk-4.1
  libwebkit2gtk-4.0-37 libjavascriptcoregtk-4.0-18
  gir1.2-webkit2-4.0 gir1.2-javascriptcoregtk-4.0
  libjavascriptcoregtk-4.0-bin libjavascriptcoregtk-bin
  libwebkit2gtk-4.0-doc webkit2gtk-driver)
DESKTOP=(xfce4 xfce4-appfinder xfce4-helpers xfce4-panel
  xfce4-pulseaudio-plugin xfce4-session xfce4-settings xfce4-terminal
  lightdm lightdm-gtk-greeter light-locker
  xserver-xorg xserver-xorg-core xserver-xorg-input-libinput
  xserver-xorg-video-fbdev
  onboard ristretto thunar thunar-archive-plugin thunar-data thunar-volman
  mate-polkit network-manager-applet nm-connection-editor
  numix-gtk-theme tango-icon-theme blueman pavucontrol synaptic desktop-base)
DOCKER=(docker.io docker-cli docker-buildx docker-compose)
GPU=(mesa-opencl-icd clinfo vulkan-tools mesa-utils-bin)

# What must survive, whatever apt decides to take along. Shell patterns,
# matched against whole package names: `bluez` protects bluez and not
# bluez-obexd, which the measured run removes and nothing here uses.
#
# The board's own: radio, network, audio, the ways in, the boot, the kernel.
# Then this project's: what its steps install (10, 15, 45, 84, 95 and the
# drive image) and what its units and scripts run.
PROTECTED=(
  bluez network-manager wpasupplicant dnsmasq-base iproute2
  pipewire wireplumber alsa-ucm-conf
  openssh-server openssh-client ssh dropbear-bin sudo
  systemd systemd-sysv udev dbus 'systemd-boot*' 'linux-image-*' 'firmware-*'
  e2fsprogs fdisk initramfs-tools busybox
  git curl wget ca-certificates
  python3 'python3.[0-9]*' python3-dev python3-venv
  gcc make clangd 'clangd-*' tio 'libgpiod*'
  avahi-daemon avahi-autoipd dosfstools rsync
)

# protected <pkg> - true if the package is one of the above. The name may
# carry an architecture (libfoo:arm64); the pattern is matched without it.
protected() {
  local p="${1%%:*}" pat
  for pat in "${PROTECTED[@]}"; do
    # shellcheck disable=SC2254 # the patterns are meant to match
    case "$p" in $pat) return 0 ;; esac
  done
  return 1
}

step "what is installed"
present=()
for p in "${BROWSER[@]}" "${DESKTOP[@]}" "${DOCKER[@]}" "${GPU[@]}"; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed" && present+=("$p")
done
if [ ${#present[@]} -eq 0 ]; then
  skip "none of them installed: browser, desktop, Docker and GPU tools already gone"
  summary
  exit 0
fi
skip "${#present[@]} of them installed: ${present[*]}"

# What apt would really do, autoremove included. LC_ALL=C because the lines
# are parsed: Purg (or Remv) is one going, Inst one that would come in.
step "what apt would remove"
sim="$(LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get -s purge --autoremove "${present[@]}" 2>&1)" ||
  fail "apt-get -s purge --autoremove failed, so what it would take is not known. Nothing was removed.
$(tail -n 5 <<<"$sim")"
mapfile -t going < <(awk '/^(Purg|Remv) / { print $2 }' <<<"$sim")
mapfile -t coming < <(awk '/^Inst / { print $2 }' <<<"$sim")
if [ ${#coming[@]} -gt 0 ]; then
  fail "removing these would install ${coming[*]}, which is not what this step is for. Nothing was removed."
fi
hits=()
for p in "${going[@]}"; do protected "$p" && hits+=("$p"); done
if [ ${#hits[@]} -gt 0 ]; then
  fail "apt would also remove ${hits[*]}, which this board needs. Nothing was removed.
        See why:  apt-get -s purge --autoremove ${present[*]}"
fi
skip "${#going[@]} packages would go, none of them protected"

# Written down before anything goes, and merged with an earlier list rather
# than replacing it: a purge that failed half way has already taken some.
step "the list, for the way back"
as_user mkdir -p "$(dirname "$LIST")"
{
  [ -f "$LIST" ] && cat "$LIST"
  printf '%s\n' "${going[@]}"
} | sort -u >"$LIST.tmp" || fail "could not write $LIST.tmp"
if [ -f "$LIST" ] && cmp -s "$LIST" "$LIST.tmp"; then
  rm -f "$LIST.tmp"
  skip "already recorded in $LIST"
else
  mv "$LIST.tmp" "$LIST" || fail "could not write $LIST. Nothing was removed."
  chown "$TARGET_USER:$TARGET_USER" "$LIST" 2>/dev/null
  did "recorded ${#going[@]} packages -> $LIST"
fi

step "remove them"
DEBIAN_FRONTEND=noninteractive apt-get purge -y --autoremove "${present[@]}" >/dev/null ||
  fail "apt-get purge --autoremove ${present[*]} failed. What it took is listed in $LIST,
        and running this again finishes the job."
packages_changed
did "removed ${#present[@]} packages and ${#going[@]} in all (to put them back: xargs apt-get install -y < $LIST)"

summary
