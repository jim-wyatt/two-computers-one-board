#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Drive the two RGB LEDs Linux owns: connectivity, and whether anything failed.
#
#   sudo ~/two-computers-one-board/status/leds.sh once     # sample, set, exit
#   sudo ~/two-computers-one-board/status/leds.sh run      # loop forever - what the service runs
#   sudo ~/two-computers-one-board/status/leds.sh off      # dark, kernel triggers handed back
#   sudo ~/two-computers-one-board/status/leds.sh test     # cycle the states, to learn them
#   sudo ~/two-computers-one-board/status/leds.sh show 1 blue slow   # one LED, by hand
#   ~/two-computers-one-board/status/leds.sh explain       # what each light means, no root needed
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
#
# COLOUR ALONE WAS NOT ENOUGH
# ---------------------------
# The first scheme said everything in hue, and mostly in red against green -
# the one pair that about one man in twelve cannot tell apart. To them LED 2
# had a single state: "all is well" and "this needs a human" were the same
# light. An indicator that cannot be read is not an indicator.
#
# So every state now has a RHYTHM as well, and the rhythm alone is enough:
#
#   steady       fine
#   slow blink   degraded, or in progress - once every two seconds
#   fast blink   a fault that needs a human - twice a second (never faster
#                than three: that is the ceiling for anything that flashes)
#   dark         nothing is driving the LED: the checker is not running
#
# Colour still means what it meant; it is now the second witness rather than
# the only one. The blinking is done by the kernel's `timer` trigger, not by
# this script's loop: a loop that wakes every five seconds cannot blink at four
# hertz, and the kernel's timer keeps time between passes at no cost.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INTERVAL="${UNOQ_LED_INTERVAL:-5}"
# The only expensive check here, so it runs every Nth pass. Link state changes
# in seconds; reachability does not, and pinging every five seconds forever is
# rude to whatever is upstream.
NET_EVERY="${UNOQ_LED_NET_EVERY:-12}"
PROBE_IP="${UNOQ_LED_PROBE_IP:-1.1.1.1}"
# The two rhythms, as milliseconds lit and then the same again dark. The
# firmware uses the same figures for LED 3 and LED 4 (status_leds.h), so that
# "slow" and "fast" look alike on all four. Anything that is not a positive
# whole number goes back to the default: the kernel would refuse it, and a
# refused write here is silent.
SLOW_MS="${UNOQ_LED_BLINK_SLOW_MS:-1000}"
FAST_MS="${UNOQ_LED_BLINK_FAST_MS:-250}"
case "$SLOW_MS" in '' | 0* | *[!0-9]*) SLOW_MS=1000 ;; esac
case "$FAST_MS" in '' | 0* | *[!0-9]*) FAST_MS=250 ;; esac
BRIDGE="${UNOQ_USB_BRIDGE:-br-usb}"
G="${UNOQ_GADGET_DIR:-/sys/kernel/config/usb_gadget/unoq}"
LEDS="${UNOQ_LED_DIR:-/sys/class/leds}"
# The bind guard is asked whether it has given up, which is half of what LED 2
# reports. Overridable rather than hardcoded as "$HERE/bind-guard.sh": that
# assumed the two scripts live in the same directory, which made this untestable
# and would have broken silently the moment either moved.
GUARD="${UNOQ_BIND_GUARD:-$HERE/../usb/bind-guard.sh}"

# LED 1, driven from here as one colour at a time. Order: red, green, blue.
# Reached by name through a nameref in set_led, which shellcheck cannot follow.
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
  sed -n '4,11p' "$0"
  exit 2
}

# --- driving one channel ----------------------------------------------------

# The trigger a channel is bound to: the bracketed word in its trigger file.
chan_trigger() {
  tr ' ' '\n' <"$LEDS/$1/trigger" 2>/dev/null | grep -m1 '^\[' | tr -d '[]'
}

# A channel bound to a kernel trigger will accept a write and be overwritten a
# moment later, which looks like broken code rather than a conflict. Refusing is
# clearer, and it is why taking a channel over is a separate, deliberate step.
# `timer` is the one trigger that counts as ours: it is how this script blinks.
chan_ours() {
  [ -w "$LEDS/$1/brightness" ] || return 1
  [ -r "$LEDS/$1/trigger" ] || return 0
  case "$(chan_trigger "$1")" in
    none | timer | '') return 0 ;;
  esac
  return 1
}

# Steadily on or off. The trigger goes first: a timer left behind keeps
# blinking whatever is written to brightness afterwards. It is written without
# looking at what is there - this only runs when something is changing, and
# "none" over "none" costs nothing.
chan_steady() {
  local led="$LEDS/$1"
  chan_ours "$1" || return 0
  [ -w "$led/trigger" ] && echo none >"$led/trigger" 2>/dev/null
  echo "$2" >"$led/brightness" 2>/dev/null
}

# chan_is <channel> 0|1|blink [ms] - is it already doing that? Read back from
# the kernel, not remembered. Brightness is not consulted for a blinking
# channel: the kernel moves it up and down itself, so it reads as either.
chan_is() {
  local led="$LEDS/$1" trig
  chan_ours "$1" || return 0 # not ours, so nothing here to correct
  trig="$(chan_trigger "$1")"
  if [ "$2" = blink ]; then
    [ "$trig" = timer ] &&
      [ "$(cat "$led/delay_on" 2>/dev/null)" = "$3" ] &&
      [ "$(cat "$led/delay_off" 2>/dev/null)" = "$3" ]
  else
    [ "$trig" != timer ] && [ "$(cat "$led/brightness" 2>/dev/null)" = "$2" ]
  fi
}

# --- driving one LED --------------------------------------------------------

declare -A NO_TIMER_SAID=()

# Long enough for the kernel's blink timer to have fired - it runs on the next
# jiffy, 10 ms at the very slowest - and far shorter than the half second it
# then waits. See set_led.
SETTLE=0.05

# set_led <array-name> <colour> [steady|slow|fast]
#
# TWO THINGS THIS IS CAREFUL ABOUT
#
# It only writes when something is different. Every write to a timer's files
# restarts that timer, so a pass that rewrote the same state every five seconds
# would restart the blink every five seconds, and a rhythm with a hiccup in it
# is a third rhythm nobody defined. What the LED is doing now is read back from
# sysfs rather than kept in a variable, for the reason everything else here
# samples: a variable is a memory, and it would go on believing in a blink that
# something else had since switched off.
#
# Channels of one LED blink together. Yellow is the red and the green channel,
# and to the kernel those are two unrelated LEDs with a timer each, so nothing
# keeps them in step unless they are started in step. Worse, a restarted timer
# does not start "on": it starts by inverting whatever the channel is showing
# at that instant (drivers/leds/led-core.c, led_timer_function). Two channels
# caught either side of a tick would then blink turn and turn about, and yellow
# would read as red alternating with green. So the start is walked through
# states that are known rather than raced:
#
#   1. every channel dark, no trigger          all off
#   2. trigger=timer on each lit channel       each comes on, for the default
#                                              500 ms; wait for that to happen
#   3. delay_on on each                        each restarts, so goes off, for
#                                              500 ms; wait again
#   4. delay_off on each, back to back         each restarts, so comes ON, a
#                                              few microseconds apart
#
# A single-channel colour has nobody to keep step with and skips the waiting.
# Linux's own states are all single-channel today; the two-channel path is
# there because set_led offers yellow and white, and offering a colour that
# blinks wrongly would be a trap. It is reasoned from the kernel source and has
# not yet been watched on the board - `show 1 yellow slow` is how to watch it.
set_led() {
  local -n chans="$1"
  local rhythm="${3:-steady}" ms=0 same=1 i c
  local on=(0 0 0) want=() lit=()
  case "$2" in
    red) on=(1 0 0) ;;
    green) on=(0 1 0) ;;
    blue) on=(0 0 1) ;;
    yellow) on=(1 1 0) ;;
    white) on=(1 1 1) ;;
    off) ;;
  esac
  case "$rhythm" in
    slow) ms="$SLOW_MS" ;;
    fast) ms="$FAST_MS" ;;
  esac

  for i in 0 1 2; do
    [ "${on[$i]}" = 1 ] && chan_ours "${chans[$i]}" && lit+=("${chans[$i]}")
  done

  # No timer trigger, no rhythm. The colour is still true, so show that, and
  # say once what has been lost rather than once every pass.
  if [ "$ms" != 0 ]; then
    for c in "${lit[@]}"; do
      grep -qw timer "$LEDS/$c/trigger" 2>/dev/null && continue
      if [ -z "${NO_TIMER_SAID[$1]:-}" ]; then
        echo "leds: $1 cannot blink - $c offers no 'timer' trigger." \
          "Showing colour only, steady; fine and faulty now differ by hue alone." >&2
        NO_TIMER_SAID[$1]=1
      fi
      ms=0
      break
    done
  fi

  for i in 0 1 2; do
    want[i]="${on[$i]}"
    [ "$ms" != 0 ] && [ "${on[$i]}" = 1 ] && want[i]=blink
    chan_is "${chans[$i]}" "${want[$i]}" "$ms" || same=0
  done
  [ "$same" = 1 ] && return 0

  if [ "$ms" = 0 ]; then
    for i in 0 1 2; do chan_steady "${chans[$i]}" "${on[$i]}"; done
    return 0
  fi

  for i in 0 1 2; do chan_steady "${chans[$i]}" 0; done
  for c in "${lit[@]}"; do echo timer >"$LEDS/$c/trigger" 2>/dev/null; done
  [ "${#lit[@]}" -gt 1 ] && sleep "$SETTLE"
  for c in "${lit[@]}"; do echo "$ms" >"$LEDS/$c/delay_on" 2>/dev/null; done
  [ "${#lit[@]}" -gt 1 ] && sleep "$SETTLE"
  for c in "${lit[@]}"; do echo "$ms" >"$LEDS/$c/delay_off" 2>/dev/null; done
  return 0
}

apply_triggers() {
  local name
  for name in "${!STOCK_TRIGGER[@]}"; do
    [ -w "$LEDS/$name/trigger" ] || continue
    # Ours already, steady or blinking. Rewriting it would restart a blink.
    grep -qE '\[(none|timer)\]' "$LEDS/$name/trigger" 2>/dev/null && continue
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

# Unconditional, unlike set_led: this is the path that runs when the checker
# stops, and a timer left behind would go on blinking with nothing behind it -
# an LED that looks alive and reports on nothing.
all_off() {
  local c
  for c in "${LED1[@]}" "${LED2[@]}"; do chan_steady "$c" 0; done
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
    set_led LED1 green steady
  elif usb_link_up; then
    set_led LED1 blue slow # a computer is there, nothing beyond it
  else
    set_led LED1 red fast # no way out at all
  fi

  # LED 2 - systemd's opinion of the board. Green is not decoration: it is the
  # difference between "nothing is wrong" and "this checker is not running",
  # which a dark LED cannot tell you. There is no slow blink here because there
  # is no middle state: anything that would recover by itself is not reported.
  if guard_tripped || units_failed; then
    set_led LED2 red fast
  else
    set_led LED2 green steady
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
    # Dark first: the kernel blinks without us, so a blink left running would
    # outlive the thing that decided on it.
    trap 'all_off; restore_triggers; exit 0' TERM INT
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
    # Three seconds each: long enough to count a slow blink three times.
    for look in "green steady" "blue slow" "red fast"; do
      echo "  LED 1  ${look#* }, ${look% *}"
      # shellcheck disable=SC2086 # two words on purpose: colour, rhythm
      set_led LED1 $look
      sleep 3
    done
    set_led LED1 off
    for look in "green steady" "red fast"; do
      echo "  LED 2  ${look#* }, ${look% *}"
      # shellcheck disable=SC2086
      set_led LED2 $look
      sleep 3
    done
    all_off
    ;;
  show)
    # One LED, by hand - for checking a rhythm on the hardware. Stop the
    # service first, or its next pass puts the truth back.
    case "${2:-}" in 1 | 2) ;; *) usage ;; esac
    case "${3:-}" in red | green | blue | yellow | white | off) ;; *) usage ;; esac
    case "${4:-steady}" in steady | slow | fast) ;; *) usage ;; esac
    apply_triggers
    set_led "LED$2" "$3" "${4:-steady}"
    ;;
  off)
    all_off
    restore_triggers
    ;;
  explain)
    cat <<EOF
Two RGB LEDs, above the matrix, opposite the USB-C port. Linux drives these
two; LED 3 and LED 4 belong to the STM32.

Each state has a rhythm as well as a colour, and the rhythm is enough by
itself - you do not need to tell red from green to read these:

  steady       fine
  slow blink   degraded, or in progress      (once every two seconds)
  fast blink   a fault that needs a human    (twice a second)
  dark         nothing is driving the LED - the checker is not running

LED 1 - can this board reach anything?

  steady      green   the internet is reachable
  slow blink  blue    a computer is on the USB cable, but nothing beyond it
                      (the host is not sharing its connection, or not routing)
  fast blink  red     no uplink at all - go and look

LED 2 - systemd's opinion of this board

  steady      green   every unit is healthy, and the bind guard has not tripped
  fast blink  red     SOMETHING NEEDS A HUMAN: a systemd unit has failed, or
                      the bind guard has refused to bind the gadget. Everything
                      else on this board recovers by itself; these do not.

A lit, steady light is not decoration. A dark LED cannot tell you the
difference between "nothing is wrong" and "the thing that checks is not
running", and those need very different responses.

Sampled every ${INTERVAL}s, so the lights correct themselves rather than
remembering something that has stopped being true. Reachability is probed every
$((INTERVAL * NET_EVERY))s.

eMMC activity is deliberately NOT shown, on any of the four. The kernel's mmc0,
disk-activity and disk-write triggers are all offered by this kernel and none
of them fire - measured at 0 of 400 samples under sustained writes.

LED 3 and LED 4 are the firmware's (mcu/app/include/status_leds.h):

  LED 3    steady      green   running a confirmed firmware image
           slow blink  yellow  running an unconfirmed image - the next reset
                               reverts it
           fast blink  red     a subsystem failed to start
  LED 4    steady      green   the MCU heard an 'app' command from Linux in
                               the last 4s
           fast blink  red     nothing for longer than that

Learn them with:  sudo $0 test
EOF
    ;;
  *) usage ;;
esac
exit 0
