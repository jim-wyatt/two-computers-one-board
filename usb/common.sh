# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Helpers the scripts in usb/ share. Sourced, never executed:
#
#   . "$(dirname "$0")/common.sh"
#
# By path from the script's own directory, not from provision/lib.sh, because
# the root services run root-owned copies in /usr/local/lib/unoq, and only
# usb/ and status/ are copied there (install_runtime in provision/lib.sh copies
# usb/*.sh, so this file goes with them).
#
# Each of these used to be written out in every script that needed it, and the
# copies drifted: three of the four IPv4 checks accepted 999.1.1.1 and "....",
# and one udhcpc check was a plain `pid_is busybox udhcpc` that took any BusyBox
# applet for the DHCP client (#115). One copy cannot disagree with itself.
#
# This file is sourced, so it has no shebang - the directive below is what
# tells shellcheck which shell to assume.
# shellcheck shell=bash

PROC="${UNOQ_PROC:-/proc}"

# pid_is <pidfile> <acceptable comm>... - is THAT daemon running, not just
# something with its number?
#
# Not `kill -0 "$(cat pidfile)"`, which asks whether any process has the pid.
# A daemon that dies without tidying up leaves its pid file behind, and pids
# are reused: with a stale file, whatever had been given that pid since was
# taken for the daemon - left alone where the daemon should have been started,
# or killed in its place, as root. And kill -0 against a root-owned process
# fails with EPERM for an ordinary user, so it would report a healthy daemon as
# stopped in exactly the read-only paths that should need no privileges.
pid_is() {
  local pidfile="$1" pid comm want
  shift
  pid="$(cat "$pidfile" 2>/dev/null)"
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  comm="$(cat "$PROC/$pid/comm" 2>/dev/null)" || return 1
  for want in "$@"; do
    [ "$comm" = "$want" ] && return 0
  done
  return 1
}

# is_udhcpc <pidfile> - is the process in that file the DHCP client?
#
# comm alone cannot say. udhcpc is a BusyBox applet: started as
# `busybox udhcpc`, the kernel calls the process "busybox", and so it calls
# every other applet started that way. So the command line is read as well, and
# one of its words has to be udhcpc. (Started through a `udhcpc` symlink, comm
# is udhcpc and that is enough.)
is_udhcpc() {
  local pid arg
  pid_is "$1" udhcpc && return 0
  pid_is "$1" busybox || return 1
  pid="$(cat "$1" 2>/dev/null)"
  while IFS= read -r -d '' arg; do
    case "$arg" in udhcpc | */udhcpc) return 0 ;; esac
  done <"$PROC/$pid/cmdline" 2>/dev/null
  return 1
}

# is_ipv4 <string> - four numbers, each 0 to 255, and nothing else.
#
# What it guards is a command line run as root: addresses from a lease, from a
# file, or from a computer we do not control, on their way to ip(8), udhcpc and
# the state files. Anything that is not plainly an address is refused rather
# than escaped - no legitimate value needs it. "Digits and dots" let through
# 999.999.999.999, 1.2.3.4.5 and "....", none of which is an address.
is_ipv4() {
  local o
  local -a parts
  case "$1" in '' | *[!0-9.]* | .* | *. | *..*) return 1 ;; esac
  IFS=. read -r -a parts <<<"$1"
  [ "${#parts[@]}" -eq 4 ] || return 1
  for o in "${parts[@]}"; do
    # No leading zeros: inet_aton reads 010 as octal, so "010.0.0.1" is a
    # different address to different programs.
    case "$o" in 0 | [1-9] | [1-9][0-9] | [1-9][0-9][0-9]) ;; *) return 1 ;; esac
    [ "$o" -le 255 ] || return 1
  done
}
