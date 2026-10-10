#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Drive the two RGB LEDs Linux owns: connectivity, and whether anything failed.
#
#   sudo ~/two-computers-one-board/status/leds.sh once     # sample, set, exit
#   sudo ~/two-computers-one-board/status/leds.sh run      # loop forever - what the service runs
#   sudo ~/two-computers-one-board/status/leds.sh off      # dark, kernel triggers handed back
#   sudo ~/two-computers-one-board/status/leds.sh test     # cycle the colours, to learn them
#   ~/two-computers-one-board/status/leds.sh explain       # what the colours mean, no root needed
#
# WHY
# ---
# Everything else this project does to stay reachable - the bind guard, the
# uplink fallback, the wifi rescue - reports through channels that need the
# board to be reachable. Logs need ssh. status.sh needs a shell. The one moment
# you want to know what state the board is in is the moment you cannot ask it.
#
# An LED needs nothing. It is the only diagnostic here that works across a room,
# on a board nobody has logged into.
#
# FOUR RGB LEDS, OF WHICH LINUX OWNS TWO
# --------------------------------------
# Linux exposes six writable entries under /sys/class/leds/unoq:*, and it is
# very tempting to read that as six indicators. It is not. They are the red,
# green and blue channels of TWO RGB packages, which the -1 and -2 suffixes are
# quietly telling you:
#
#   LED 1   unoq:user-red1    unoq:user-green1   unoq:user-blue1
#   LED 2   unoq:panic-red2   unoq:wlan-green2   unoq:bt-blue2
#
# This was got wrong first time, and the hardware said so immediately: an
# earlier version lit four channels to mean four separate things and the board
# showed two cyan LEDs. sysfs cannot tell you this - every channel has its own
# directory and its own brightness file whether it is one package or six. Only
# looking at the board tells you.
#
# LED 3 and LED 4 are wired to the STM32, not to Linux. Zephyr's board
# definition calls them led3_red/green/blue and led4_*. Nothing here can reach
# them; that is firmware territory.
#
# THE DISK-ACTIVITY TRIGGERS DO NOT WORK ON THIS KERNEL
# -----------------------------------------------------
# The obvious way to show eMMC activity is to hand a channel to the kernel:
# `mmc0`, `disk-activity` and `disk-write` are all offered in the trigger list,
# and the kernel knows about every transfer at a resolution no polling loop
# could match. It was tried first for exactly that reason.
#
# None of them fire. Measured, with 400 MB of O_DIRECT writes running and the
# brightness sampled 400 times: ON in **0** samples, for all three triggers. The
# board agrees - nothing visible happens. The triggers are registered, so they
# appear in the list and accept being selected; whatever should call into them
# does not, on this kernel.
#
# Being listed is not the same as being implemented, and a trigger you can
# select is not a trigger that fires. So disk activity is not shown here at all,
# and it is not shown anywhere else on the board either. Feeding it to LED 4 on
# the MCU from /sys/block/mmcblk0/stat was tried and dropped: sampled twice a
# second and pushed down a 115200 link, it was a lamp that sat on through a copy
# and off otherwise. LED 4 now shows whether Linux is still talking to the MCU -
# see mcu/app/include/status_leds.h.
#
# Relatedly, the MMC subsystem registers an `mmc0::` LED of its own. It is NOT
# one of the four: it lives under the MMC controller rather than the gpio-leds
# node, and nothing is physically wired to it on this board. That is why you
# will never see it blink either.
#
# WHY SAMPLING FOR THE REST
# -------------------------
# Hooking bind-guard.sh and wifi.sh would light the LEDs at the moment things
# change, and be wrong forever afterwards if anything changed underneath. A
# stale LED is worse than a dark one, because it is confidently wrong. Sampling
# is self-correcting: pull the cable and within one interval the colours tell
# the truth again, whatever caused it.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INTERVAL="${UNOQ_LED_INTERVAL:-5}"
# The only expensive check here, so it runs every Nth pass. Link state changes
# in seconds; reachability does not, and pinging every five seconds forever is
# rude to whatever is upstream.
NET_EVERY="${UNOQ_LED_NET_EVERY:-12}"
PROBE_IP="${UNOQ_LED_PROBE_IP:-1.1.1.1}"
BRIDGE="${UNOQ_USB_BRIDGE:-br-usb}"
G="${UNOQ_GADGET_DIR:-/sys/kernel/config/usb_gadget/unoq}"
LEDS="${UNOQ_LED_DIR:-/sys/class/leds}"
# The bind guard is asked whether it has given up, which is half of what LED 2
# reports. Overridable rather than hardcoded as "$HERE/bind-guard.sh": that
# assumed the two scripts live in the same directory, which made this untestable
# and would have broken silently the moment either moved.
GUARD="${UNOQ_BIND_GUARD:-$HERE/../usb/bind-guard.sh}"

# LED 1, driven from here as one colour at a time. Order: red, green, blue.
# Reached by name through a nameref in set_rgb, which shellcheck cannot follow.
# shellcheck disable=SC2034
LED1=(unoq:user-red1 unoq:user-green1 unoq:user-blue1)

# LED 2 - is anything wrong? Same one-colour-at-a-time treatment as LED 1.
# shellcheck disable=SC2034
LED2=(unoq:panic-red2 unoq:wlan-green2 unoq:bt-blue2)

# Two of LED 2's channels arrive bound to kernel triggers, and both are dead
# weight here: bt-blue2 follows bluetooth-power, and 10-optimize-board.sh
# disables Bluetooth; wlan-green2 follows phy0tx, which only flickers while wifi
# is on, and the point of wifi.sh is to turn wifi off. They are taken over
# explicitly, and `off` hands them back - a tool that quietly rebinds hardware
# and never undoes it is how a board drifts from what its documentation says.
declare -A STOCK_TRIGGER=(
  ["unoq:wlan-green2"]="phy0tx"
  ["unoq:bt-blue2"]="bluetooth-power"
)

usage() {
  sed -n '4,10p' "$0"
  exit 2
}

# --- driving one channel ----------------------------------------------------

# A channel bound to a kernel trigger will accept a write and be overwritten a
# moment later, which looks like broken code rather than a conflict. Refusing is
# clearer, and it is why taking a channel over is a separate, deliberate step.
set_chan() {
  local led="$LEDS/$1" on="$2" trig
  [ -w "$led/brightness" ] || return 0
  if [ -r "$led/trigger" ]; then
    trig="$(tr ' ' '\n' <"$led/trigger" 2>/dev/null | grep -m1 '^\[' | tr -d '[]')"
    case "$trig" in
      none | '') ;;
      *) return 0 ;;
    esac
  fi
  echo "$on" >"$led/brightness" 2>/dev/null
}

# set_rgb <array-name> <colour> - one colour at a time, never a mix.
set_rgb() {
  local -n chans="$1"
  local r=0 g=0 b=0
  case "$2" in
    red) r=1 ;;
    green) g=1 ;;
    blue) b=1 ;;
    yellow) r=1 g=1 ;;
    white) r=1 g=1 b=1 ;;
    off) ;;
  esac
  set_chan "${chans[0]}" "$r"
  set_chan "${chans[1]}" "$g"
  set_chan "${chans[2]}" "$b"
}

apply_triggers() {
  local name
  for name in "${!STOCK_TRIGGER[@]}"; do
    [ -w "$LEDS/$name/trigger" ] || continue
    grep -q '\[none\]' "$LEDS/$name/trigger" 2>/dev/null && continue
    echo none >"$LEDS/$name/trigger" 2>/dev/null
  done
}

restore_triggers() {
  local name
  for name in "${!STOCK_TRIGGER[@]}"; do
    [ -w "$LEDS/$name/trigger" ] || continue
    echo 0 >"$LEDS/$name/brightness" 2>/dev/null
    echo "${STOCK_TRIGGER[$name]}" >"$LEDS/$name/trigger" 2>/dev/null
  done
}

all_off() {
  set_rgb LED1 off
  set_rgb LED2 off
}

# --- reading the state ------------------------------------------------------

# Bound with nobody on the other end is what a charge-only cable gives you, and
# it is worth distinguishing from a link that works.
usb_link_up() {
  [ -n "$(cat "$G/UDC" 2>/dev/null)" ] || return 1
  ip link show "$BRIDGE" >/dev/null 2>&1 || return 1
  ip -4 route show default dev "$BRIDGE" 2>/dev/null | grep -q . && return 0
  [ -s /run/unoq-usb-dnsmasq.leases ]
}

guard_tripped() {
  local out
  out="$("$GUARD" status 2>/dev/null)" || return 1
  echo "$out" | awk -F'[ /]' '/^attempts:/ {exit !($2 >= $3)}'
}

# Anything systemd has given up on. A broad net on purpose: this is the general
# "a human should look at this board" signal, and it costs one call.
units_failed() {
  [ "$(systemctl list-units --state=failed --no-legend 2>/dev/null | grep -c .)" -gt 0 ]
}

have_internet() { ping -c1 -W3 "$PROBE_IP" >/dev/null 2>&1; }

# --- one pass ---------------------------------------------------------------

NET_OK=1 # assumed until the first probe says otherwise

sample_and_set() {
  local probe="${1:-1}"
  if [ "$probe" = 1 ]; then
    have_internet && NET_OK=1 || NET_OK=0
  fi

  # LED 1 - can this board reach anything?
  if [ "$NET_OK" = 1 ]; then
    set_rgb LED1 green
  elif usb_link_up; then
    set_rgb LED1 blue # a computer is there, nothing beyond it
  else
    set_rgb LED1 red # no way out at all
  fi

  # LED 2 - systemd's opinion of the board. Green is not decoration: it is the
  # difference between "nothing is wrong" and "this checker is not running",
  # which a dark LED cannot tell you.
  if guard_tripped || units_failed; then
    set_rgb LED2 red
  else
    set_rgb LED2 green
  fi
}

case "${1:-}" in
  once)
    apply_triggers
    sample_and_set 1
    ;;
  run)
    apply_triggers
    # SIGKILL never runs a trap, which is why the unit also has ExecStopPost.
    trap 'restore_triggers; exit 0' TERM INT
    n=0
    while true; do
      probe=0
      [ $((n % NET_EVERY)) -eq 0 ] && probe=1
      sample_and_set "$probe"
      n=$((n + 1))
      sleep "$INTERVAL"
    done
    ;;
  test)
    apply_triggers
    for c in red green blue; do
      echo "  LED 1 $c"
      set_rgb LED1 "$c"
      sleep 2
    done
    set_rgb LED1 off
    for c in red green; do
      echo "  LED 2 $c"
      set_rgb LED2 "$c"
      sleep 2
    done
    all_off
    ;;
  off)
    all_off
    restore_triggers
    ;;
  explain)
    cat <<EOF
Two RGB LEDs, above the matrix, opposite the USB-C port. Linux drives these
two; LED 3 and LED 4 belong to the STM32.

LED 1 - can this board reach anything?  (one colour at a time)

  green    the internet is reachable
  blue     a computer is on the USB cable, but nothing beyond it
           (the host is not sharing its connection, or is not routing)
  red      no uplink at all - go and look

LED 2 - systemd's opinion of this board

  green    every unit is healthy, and the bind guard has not tripped
  red      SOMETHING NEEDS A HUMAN: a systemd unit has failed, or the bind
           guard has refused to bind the gadget. Everything else on this
           board recovers by itself; these do not.

Green is not decoration. A dark LED cannot tell you the difference between
"nothing is wrong" and "the thing that checks is not running", and those need
very different responses.

Sampled every ${INTERVAL}s, so the colours correct themselves rather than
remembering something that has stopped being true. Reachability is probed every
$((INTERVAL * NET_EVERY))s.

eMMC activity is deliberately NOT shown, on any of the four. The kernel's mmc0,
disk-activity and disk-write triggers are all offered by this kernel and none
of them fire - measured at 0 of 400 samples under sustained writes.

LED 3 and LED 4 are the firmware's (mcu/app/include/status_leds.h):

  LED 3    green   running a confirmed firmware image
           yellow  running an unconfirmed image - the next reset reverts it
           red     a subsystem failed to start
  LED 4    green   the MCU heard an 'app' command from Linux in the last 4s
           red     nothing for longer than that

Learn the colours with:  sudo $0 test
EOF
    ;;
  *) usage ;;
esac
exit 0
