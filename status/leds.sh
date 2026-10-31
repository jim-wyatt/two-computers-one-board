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
# is self-correcting: pull the cable and within one interval the colors tell
# the truth again, whatever caused it.
#
# COLOR ALONE WAS NOT ENOUGH
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
# Color still means what it meant; it is now the second witness rather than
# the only one. The blinking is done by the kernel's `timer` trigger, not by
# this script's loop: a loop that wakes every five seconds cannot blink at four
# hertz, and the kernel's timer keeps time between passes at no cost.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INTERVAL="${UNOQ_LED_INTERVAL:-5}"
# The slow checks run every Nth pass: the ping, and the list of boot entries.
# Link state changes in seconds; reachability does not, and pinging every five
# seconds forever is rude to whatever is upstream. A kernel is set aside only
# at boot, or when one is installed or removed, so a minute late is on time.
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
UDC_DIR="${UNOQ_UDC_DIR:-/sys/class/udc}"
NET_SYSFS="${UNOQ_NET_SYSFS:-/sys/class/net}"
LEDS="${UNOQ_LED_DIR:-/sys/class/leds}"
# The bind guard is asked whether it has given up, which is half of what LED 2
# reports. Overridable rather than hardcoded as "$HERE/bind-guard.sh": that
# assumed the two scripts live in the same directory, which made this untestable
# and would have broken silently the moment either moved.
GUARD="${UNOQ_BIND_GUARD:-$HERE/../usb/bind-guard.sh}"
# systemd-bless-boot is not on PATH: it lives with systemd's other helpers.
# PATH is asked first, which is also how the tests put a fake in its place.
BLESS_BOOT="$(command -v systemd-bless-boot 2>/dev/null)"
for b in /usr/lib/systemd/systemd-bless-boot /lib/systemd/systemd-bless-boot; do
  [ -n "$BLESS_BOOT" ] && break
  [ -x "$b" ] && BLESS_BOOT="$b"
done

# LED 1, driven from here as one color at a time. Order: red, green, blue.
# Reached by name through a nameref in set_led, which shellcheck cannot follow.
# shellcheck disable=SC2034
LED1=(unoq:user-red1 unoq:user-green1 unoq:user-blue1)

# LED 2 - is anything wrong? Same one-color-at-a-time treatment as LED 1.
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

# set_led <array-name> <color> [steady|slow|fast]
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
# A single-channel color has nobody to keep step with and skips the waiting.
# One of Linux's own states needs the two-channel path: LED 2's yellow, for a
# kernel on trial. It is reasoned from the kernel source and has not yet been
# watched on the board - `show 2 yellow slow` is how to watch it.
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

  # No timer trigger, no rhythm. The color is still true, so show that, and
  # say once what has been lost rather than once every pass.
  if [ "$ms" != 0 ]; then
    for c in "${lit[@]}"; do
      grep -qw timer "$LEDS/$c/trigger" 2>/dev/null && continue
      if [ -z "${NO_TIMER_SAID[$1]:-}" ]; then
        echo "leds: $1 cannot blink - $c offers no 'timer' trigger." \
          "Showing color only, steady; fine and faulty now differ by hue alone." >&2
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

# Whether a computer is on the cable, with a network interface up for the
# board - the kernel's answer, not the routing table's.
#
# It used to be "bound, and br-usb has a default route, or dnsmasq has a
# lease". dnsmasq is gone with the DHCP-server mode, so nothing writes that
# file, and the route was wrong both ways (#109): a computer that shares no
# connection gives no route, so a working cable showed fast red; and avahi's
# link-local default route sits on br-usb with the link DOWN, so with no cable
# at all it showed slow blue. Bound is no evidence either way - the gadget is
# bound to the controller from boot, cable or not.
#
#   UDC state "configured"  a host enumerated the board and chose a
#                           configuration. Not true of a charge-only cable,
#                           which has no data lines to enumerate over.
#   bridge carrier 1        the host's NCM driver brought the link up, so
#                           there is a network interface on the other end.
usb_link_up() {
  local udc
  udc="$(cat "$G/UDC" 2>/dev/null)"
  [ -n "$udc" ] || return 1
  [ "$(cat "$UDC_DIR/$udc/state" 2>/dev/null)" = configured ] || return 1
  [ "$(cat "$NET_SYSFS/$BRIDGE/carrier" 2>/dev/null)" = 1 ]
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

# BOOT COUNTING: A KERNEL ON TRIAL, AND ONE SET ASIDE
#
# With provision/82-boot-counting.sh, a new kernel's entry carries a try
# counter in its file name (foo+3.conf). systemd-boot takes a try at each boot
# of it, and systemd-bless-boot drops the counter once unoq-boot-health has
# passed. An entry that runs out of tries sorts below the good ones, and the
# board boots the previous kernel by itself. All of which works, and none of
# which shows: a board on trial and a board that has quietly fallen back both
# look exactly like a healthy one.
#
# On trial: systemd-bless-boot reads one EFI variable and stats one file, and
# says `indeterminate` for a counted boot that has not been marked good yet.
# Uncounted boots say `clean`, blessed ones `good`, and a missing tool says
# nothing, so a board without boot counting never gets here. It is cheap, and
# it changes within a minute or two of boot, so it is asked every pass.
on_trial() {
  [ -n "$BLESS_BOOT" ] || return 1
  [ "$("$BLESS_BOOT" status 2>/dev/null)" = indeterminate ]
}

# Set aside: an entry with no tries left. bootctl reads the boot partition and
# never writes it with `list`; its JSON says "triesLeft":0, and JSON numbers
# have no leading zeros, so that is never the start of a 10. The entry being
# booted is left out: on its last try it reads 0 too, and it is on trial, not
# set aside yet. The JSON is one line, so it is cut at each entry first. It
# stays lit until the kernel is reinstalled or removed: the board coped, but a
# kernel did not boot, and someone should find out why.
kernel_set_aside() {
  bootctl list --json=short --no-pager 2>/dev/null |
    sed 's/},{/}\n{/g' | grep '"triesLeft":0' | grep -qv '"isSelected":true'
}

# --- one pass ---------------------------------------------------------------

NET_OK=1    # assumed until the first probe says otherwise
SET_ASIDE=0 # likewise

sample_and_set() {
  local probe="${1:-1}"
  if [ "$probe" = 1 ]; then
    have_internet && NET_OK=1 || NET_OK=0
    kernel_set_aside && SET_ASIDE=1 || SET_ASIDE=0
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
  # which a dark LED cannot tell you. The two slow blinks are the middle
  # states, both from boot counting: degraded, and in progress.
  #
  # Yellow for on trial is LED 3's yellow, for the same idea one chip over: an
  # image that has not been confirmed yet. Blue for set aside, because the two
  # share a rhythm, and blue against yellow is the pair that red-green color
  # blindness leaves apart. Red stays for fast, and outranks both: a failed
  # health check is a failed unit, and that needs a human now.
  if guard_tripped || units_failed; then
    set_led LED2 red fast
  elif [ "$SET_ASIDE" = 1 ]; then
    set_led LED2 blue slow # a kernel used its tries; the board fell back
  elif on_trial; then
    set_led LED2 yellow slow # a counted boot, not marked good yet
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
      # shellcheck disable=SC2086 # two words on purpose: color, rhythm
      set_led LED1 $look
      sleep 3
    done
    set_led LED1 off
    for look in "green steady" "yellow slow" "blue slow" "red fast"; do
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
Four RGB LEDs in a row, at the end of the board opposite the USB-C port. From
the board's edge inwards: LED 4, LED 3, LED 2, LED 1. Linux drives LED 1 and
LED 2, the two furthest from the edge; LED 3 and LED 4 belong to the STM32.

Each state has a rhythm as well as a color, and the rhythm is enough by
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
  slow blink  yellow  on trial: this boot is a new kernel's counted try, and
                      it has not been marked good yet. It turns green once
                      unoq-boot-health passes, a minute or two after boot.
                      If it never does, the next boot is another try, and
                      after the last one the board falls back by itself.
  slow blink  blue    a kernel was set aside: its entry used up its tries
                      and the board booted the one before. The board is fine;
                      the new kernel is not. Which one:  sudo bootctl list
                      Clears when that kernel is reinstalled or removed.
  fast blink  red     SOMETHING NEEDS A HUMAN: a systemd unit has failed, or
                      the bind guard has refused to bind the gadget. Everything
                      else on this board recovers by itself; these do not.
                      One unit worth knowing: unoq-cpu-bars fails after about
                      two and a half minutes of a microcontroller that does not
                      answer. Which unit it is:  systemctl --failed

A lit, steady light is not decoration. A dark LED cannot tell you the
difference between "nothing is wrong" and "the thing that checks is not
running", and those need very different responses.

Sampled every ${INTERVAL}s, so the lights correct themselves rather than
remembering something that has stopped being true. Reachability, and whether a
kernel was set aside, are probed every $((INTERVAL * NET_EVERY))s.

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
