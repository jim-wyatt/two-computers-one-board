#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# status/leds.sh decides what the two Linux-driven LEDs say about the board. It is
# the only thing that still reports when the network, the gadget and the shell
# have all gone - so a wrong color here is worse than a dark board: it is a
# board confidently lying about its own health.
#
# The whole script is drivable from the environment already - the sysfs root,
# the gadget directory and the bridge name are all overridable - so these tests
# build a fake /sys/class/leds in a temporary directory and read it back
# afterwards. Nothing touches the real LEDs.
#
# WHAT THE FAKE HAS TO PRETEND
# ----------------------------
# A state is a color AND a rhythm, and the rhythm is the kernel's `timer`
# trigger. Real sysfs reacts to a write: put `timer` in `trigger` and the file
# reads back `none [timer] heartbeat`, and `delay_on` and `delay_off` appear;
# put `none` there and they go. A directory of plain files does none of that,
# so kernel_reacts() below does it by hand after every run. It is modeled on
# the board (kernel 7.0.0, which offers exactly `none timer heartbeat`).
#
# The limit: it reacts after the script has finished, not between its writes,
# and it cannot blink. That channels blink in step, and that an unchanged pass
# does not make the light stutter, are things only the board can show; what is
# checked here is the writes that would cause them.

CHANNELS=(unoq:user-red1 unoq:user-green1 unoq:user-blue1
  unoq:panic-red2 unoq:wlan-green2 unoq:bt-blue2)

setup() {
  load helpers/stub
  stub_setup

  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LEDSH="$PROJECT/status/leds.sh"

  export UNOQ_LED_DIR="$BATS_TEST_TMPDIR/leds"
  export UNOQ_GADGET_DIR="$BATS_TEST_TMPDIR/gadget"
  export UNOQ_USB_BRIDGE=br-test
  KERNEL="$BATS_TEST_TMPDIR/kernel" # what the fake kernel knows, per channel

  # A fake sysfs. Every channel starts with no trigger claimed and the light
  # off, which is what the board looks like after `leds.sh off`.
  mkdir -p "$KERNEL"
  for ch in "${CHANNELS[@]}"; do
    mkdir -p "$UNOQ_LED_DIR/$ch"
    echo 0 >"$UNOQ_LED_DIR/$ch/brightness"
    offers "$ch" none timer heartbeat
  done

  mkdir -p "$UNOQ_GADGET_DIR"
  echo "4e00000.usb" >"$UNOQ_GADGET_DIR/UDC" # bound, by default

  # A computer on the cable, by default: the controller says a host has
  # configured the board, and the bridge has carrier from the host's driver.
  export UNOQ_UDC_DIR="$BATS_TEST_TMPDIR/udc"
  export UNOQ_NET_SYSFS="$BATS_TEST_TMPDIR/net"
  mkdir -p "$UNOQ_UDC_DIR/4e00000.usb" "$UNOQ_NET_SYSFS/br-test"
  echo configured >"$UNOQ_UDC_DIR/4e00000.usb/state"
  echo 1 >"$UNOQ_NET_SYSFS/br-test/carrier"

  # Healthy board by default; each test breaks one thing.
  stub ping 0         # the internet is reachable
  stub systemctl 0 "" # no failed units
  # No route on the bridge, and no answer from ip at all: usb_link_up() asks
  # the kernel's sysfs, and a test that still passed only because routes were
  # faked is what hid #109.
  stub ip 1
  stub logger
}

# offers <channel> <trigger>... - the triggers this channel's kernel has, the
# first of them selected.
offers() {
  local ch="$1"
  shift
  echo "$*" >"$KERNEL/$ch.offers"
  echo "$1" >"$KERNEL/$ch.selected"
  show_trigger "$ch"
}

# bound_to <channel> <trigger> - as if something else had selected it.
bound_to() {
  echo "$2" >"$KERNEL/$1.selected"
  show_trigger "$1"
}

show_trigger() {
  local w line=""
  for w in $(cat "$KERNEL/$1.offers"); do
    [ "$w" = "$(cat "$KERNEL/$1.selected")" ] && w="[$w]"
    line="${line:+$line }$w"
  done
  echo "$line" >"$UNOQ_LED_DIR/$1/trigger"
}

# What the kernel would have done about whatever was written to `trigger`. A
# bare word in the file means the script wrote there since we last looked.
kernel_reacts() {
  local ch d word
  for ch in "${CHANNELS[@]}"; do
    d="$UNOQ_LED_DIR/$ch"
    word="$(cat "$d/trigger")"
    case "$word" in *\[*) continue ;; esac
    # A trigger the kernel does not have is refused, and nothing changes.
    if grep -qw -- "$word" "$KERNEL/$ch.offers"; then
      echo "$word" >"$KERNEL/$ch.selected"
    fi
    show_trigger "$ch"
    if [ "$(cat "$KERNEL/$ch.selected")" = timer ]; then
      # The files exist from the moment the trigger is selected, at the
      # kernel's default of half a second each way.
      [ -e "$d/delay_on" ] || echo 500 >"$d/delay_on"
      [ -e "$d/delay_off" ] || echo 500 >"$d/delay_off"
    else
      rm -f "$d/delay_on" "$d/delay_off"
    fi
  done
}

# leds <verb>... - run the script, then let the fake kernel catch up.
leds() {
  run "$LEDSH" "$@"
  kernel_reacts
}

# look_of LED1|LED2 -> "green steady", "blue slow", "red fast", "off", or a
# description of whatever else it found. A channel counts as lit if it is on or
# if a timer is blinking it; brightness says nothing about a blinking channel.
look_of() {
  local -n chans="$1"
  local i d bits="" rhythm="" this
  for i in 0 1 2; do
    d="$UNOQ_LED_DIR/${chans[$i]}"
    if grep -q '\[timer\]' "$d/trigger"; then
      bits+=1
      case "$(cat "$d/delay_on")/$(cat "$d/delay_off")" in
        1000/1000) this=slow ;;
        250/250) this=fast ;;
        *) this="odd($(cat "$d/delay_on")/$(cat "$d/delay_off"))" ;;
      esac
    else
      [ -e "$d/delay_on" ] && this=stray-delay-file || this=steady
      [ "$(cat "$d/brightness")" = 1 ] && bits+=1 || {
        bits+=0
        [ "$this" = steady ] && continue
      }
    fi
    [ -z "$rhythm" ] || [ "$rhythm" = "$this" ] || this="out-of-step"
    rhythm="$this"
  done
  case "$bits" in
    100) echo "red $rhythm" ;;
    010) echo "green $rhythm" ;;
    001) echo "blue $rhythm" ;;
    110) echo "yellow $rhythm" ;;
    000) echo "off${rhythm:+ $rhythm}" ;;
    *) echo "mixed:$bits $rhythm" ;;
  esac
}
LED1=(unoq:user-red1 unoq:user-green1 unoq:user-blue1)
LED2=(unoq:panic-red2 unoq:wlan-green2 unoq:bt-blue2)

# Every file's modification time. Unchanged between two runs means the second
# wrote nothing - and on the board, any write to a timer's files restarts it.
stamps() { find "$UNOQ_LED_DIR" -type f -exec stat -c '%n %y' {} + | sort; }

# A bind guard that answers `status` however the test wants. leds.sh used to
# look for it beside itself, which made this untestable; UNOQ_BIND_GUARD was
# added for that, and is also what lets the two scripts stop being neighbors.
guard_says() {
  cat >"$BATS_TEST_TMPDIR/guard" <<EOF
#!/bin/bash
echo "$1"
EOF
  chmod +x "$BATS_TEST_TMPDIR/guard"
  export UNOQ_BIND_GUARD="$BATS_TEST_TMPDIR/guard"
}

# --- LED 1: can this board reach anything? ---------------------------------

@test "internet reachable is green and steady" {
  leds once
  [ "$status" -eq 0 ]
  [ "$(look_of LED1)" = "green steady" ]
}

@test "no internet but a computer on the cable is a slow blue blink, not red" {
  # The distinction that earns the third color: "plugged in, host not sharing"
  # and "nothing there at all" are different problems with different fixes.
  stub ping 1
  leds once
  [ "$(look_of LED1)" = "blue slow" ]
}

@test "no internet and no gadget bound is a fast red blink" {
  stub ping 1
  : >"$UNOQ_GADGET_DIR/UDC" # built but not bound
  leds once
  [ "$(look_of LED1)" = "red fast" ]
}

@test "no internet and no bridge is a fast red blink even with the gadget bound" {
  stub ping 1
  rm -r "$UNOQ_NET_SYSFS/br-test"
  leds once
  [ "$(look_of LED1)" = "red fast" ]
}

@test "a computer sharing no connection is slow blue, with no route anywhere" {
  # #109: the only way to read as linked was a default route over the bridge,
  # which a host that is not sharing its connection never gives. A working
  # cable showed fast red.
  stub ping 1
  stub ip 1
  leds once
  [ "$(look_of LED1)" = "blue slow" ]
}

@test "no cable is fast red, though the gadget is bound from boot" {
  # The controller has no host. This is the board's own state with nothing
  # plugged in: bound, "not attached", and avahi's link-local default route
  # still sitting on a bridge that is down - which used to read as linked.
  stub ping 1
  echo "not attached" >"$UNOQ_UDC_DIR/4e00000.usb/state"
  echo 0 >"$UNOQ_NET_SYSFS/br-test/carrier"
  stub_body ip <<'SH'
case "$*" in *"route show default"*) echo "default scope link metric 1002 linkdown" ;; esac
exit 0
SH
  leds once
  [ "$(look_of LED1)" = "red fast" ]
}

@test "a charge-only cable is fast red" {
  # Power and no data: the host never enumerates the board.
  stub ping 1
  echo powered >"$UNOQ_UDC_DIR/4e00000.usb/state"
  echo 0 >"$UNOQ_NET_SYSFS/br-test/carrier"
  leds once
  [ "$(look_of LED1)" = "red fast" ]
}

@test "a host that enumerated the board but has not brought its network up is fast red" {
  # Configured, but no NCM driver on the other end: nothing to talk to.
  stub ping 1
  echo 0 >"$UNOQ_NET_SYSFS/br-test/carrier"
  leds once
  [ "$(look_of LED1)" = "red fast" ]
}

# --- LED 2: does anything need a human? ------------------------------------

@test "a healthy board is green and steady, not dark" {
  # Lit is load-bearing. A dark LED cannot distinguish "nothing is wrong" from
  # "the thing that checks whether anything is wrong is not running".
  leds once
  [ "$(look_of LED2)" = "green steady" ]
}

@test "a failed systemd unit is a fast red blink" {
  stub systemctl 0 "does-not-exist.service loaded failed failed Nonsense"
  leds once
  [ "$(look_of LED2)" = "red fast" ]
}

@test "a tripped bind guard is a fast red blink" {
  guard_says "attempts: 3/3  (/var/lib/unoq/usb-bind-attempts)"
  leds once
  [ "$(look_of LED2)" = "red fast" ]
}

# --- finding the guard without being told where it is -----------------------
#
# Every test above hands leds.sh a guard through UNOQ_BIND_GUARD. The service
# sets no such thing: it relies on "$HERE/../usb/bind-guard.sh", a path out of
# its own directory and into a sibling. That holds in the checkout because the
# repository is laid out that way, and holds for the root-owned copy the
# service really runs only because install_root_scripts (provision/lib.sh)
# copies usb/ and status/ side by side. Both are run here with the real guard
# and a counter at its limit.

guard_at_its_limit() {
  unset UNOQ_BIND_GUARD
  export UNOQ_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export UNOQ_USB_BIND_MAX_ATTEMPTS=3
  mkdir -p "$UNOQ_STATE_DIR"
  echo "some-earlier-boot 3" >"$UNOQ_STATE_DIR/usb-bind-attempts"
}

@test "from the checkout, the real guard is found beside usb/" {
  guard_at_its_limit
  leds once
  [ "$status" -eq 0 ]
  [ "$(look_of LED2)" = "red fast" ]
}

@test "as root's copy, the real guard is found beside it in root's directory" {
  guard_at_its_limit
  RT="$BATS_TEST_TMPDIR/unoq"
  (
    export UNOQ_RUNTIME_DIR="$RT"
    # shellcheck disable=SC1091
    source "$PROJECT/provision/lib.sh"
    install_root_scripts
  ) >/dev/null
  run "$RT/status/leds.sh" once
  kernel_reacts
  [ "$status" -eq 0 ]
  [ "$(look_of LED2)" = "red fast" ]
  # And it is root's guard that answered, not the checkout's reached some
  # other way: take root's copy away and the LED has nothing to go on.
  rm "$RT/usb/bind-guard.sh"
  run "$RT/status/leds.sh" once
  kernel_reacts
  [ "$(look_of LED2)" = "green steady" ]
}

@test "a guard below its limit leaves it green and steady" {
  guard_says "attempts: 2/3  (/var/lib/unoq/usb-bind-attempts)"
  leds once
  [ "$(look_of LED2)" = "green steady" ]
}

# --- rhythm: the channel that does not need color vision -------------------

@test "no two states of one LED share a rhythm" {
  # The point of the whole exercise. If two states of an LED blinked alike,
  # telling them apart would be back to telling red from green.
  leds once
  healthy1="$(look_of LED1)" healthy2="$(look_of LED2)"
  stub ping 1
  leds once
  cable="$(look_of LED1)"
  : >"$UNOQ_GADGET_DIR/UDC"
  stub systemctl 0 "x.service loaded failed failed X"
  leds once
  nothing="$(look_of LED1)" failed="$(look_of LED2)"

  [ "${healthy1#* }" != "${cable#* }" ]
  [ "${healthy1#* }" != "${nothing#* }" ]
  [ "${cable#* }" != "${nothing#* }" ]
  [ "${healthy2#* }" != "${failed#* }" ]
}

@test "an unchanged state is not written again, so a blink keeps its phase" {
  # Any write to a timer's files restarts it. Rewriting the same state every
  # pass would make the light hiccup every five seconds.
  stub ping 1
  stub systemctl 0 "x.service loaded failed failed X"
  leds once
  [ "$(look_of LED1)" = "blue slow" ]
  [ "$(look_of LED2)" = "red fast" ]
  before="$(stamps)"
  leds once
  [ "$(stamps)" = "$before" ]
  [ "$(look_of LED1)" = "blue slow" ]
}

@test "an unchanged steady state is not written again either" {
  leds once
  before="$(stamps)"
  leds once
  [ "$(stamps)" = "$before" ]
}

@test "a change of state moves the blink to the new channel at the new rate" {
  stub ping 1
  leds once
  [ "$(look_of LED1)" = "blue slow" ]
  : >"$UNOQ_GADGET_DIR/UDC"
  leds once
  [ "$(look_of LED1)" = "red fast" ]
  grep -q '\[none\]' "$UNOQ_LED_DIR/unoq:user-blue1/trigger"
  grep -q '\[timer\]' "$UNOQ_LED_DIR/unoq:user-red1/trigger"
  [ "$(cat "$UNOQ_LED_DIR/unoq:user-red1/delay_on")" = 250 ]
  [ "$(cat "$UNOQ_LED_DIR/unoq:user-red1/delay_off")" = 250 ]
}

@test "a steady state clears the blink that was there before" {
  # brightness alone does not do it: the timer goes on blinking over the top.
  stub ping 1
  : >"$UNOQ_GADGET_DIR/UDC"
  stub systemctl 0 "x.service loaded failed failed X"
  leds once
  [ "$(look_of LED1)" = "red fast" ]
  [ "$(look_of LED2)" = "red fast" ]
  stub ping 0
  stub systemctl 0 ""
  leds once
  [ "$(look_of LED1)" = "green steady" ]
  [ "$(look_of LED2)" = "green steady" ]
  for ch in "${CHANNELS[@]}"; do
    grep -q '\[none\]' "$UNOQ_LED_DIR/$ch/trigger"
  done
}

@test "the blink periods can be set, and nonsense falls back to the defaults" {
  stub ping 1
  UNOQ_LED_BLINK_SLOW_MS=700 leds once
  [ "$(cat "$UNOQ_LED_DIR/unoq:user-blue1/delay_on")" = 700 ]
  [ "$(cat "$UNOQ_LED_DIR/unoq:user-blue1/delay_off")" = 700 ]
  UNOQ_LED_BLINK_SLOW_MS=quickly leds once
  [ "$(look_of LED1)" = "blue slow" ]
}

@test "a two-channel color blinks both channels, started in one last burst" {
  # Yellow is red and green, and to the kernel those are two LEDs with a timer
  # each. They are in step only if they are started in step: every delay_off -
  # the write that starts the blink that stays - comes after every delay_on.
  leds show 1 yellow slow
  [ "$status" -eq 0 ]
  [ "$(look_of LED1)" = "yellow slow" ]
  r="$UNOQ_LED_DIR/unoq:user-red1" g="$UNOQ_LED_DIR/unoq:user-green1"
  [ "$r/delay_off" -nt "$g/delay_on" ]
  [ "$g/delay_off" -nt "$r/delay_on" ]
}

@test "show refuses a color or a rhythm it does not know" {
  run "$LEDSH" show 1 mauve slow
  [ "$status" -eq 2 ]
  run "$LEDSH" show 1 red frantic
  [ "$status" -eq 2 ]
  run "$LEDSH" show 3 red fast
  [ "$status" -eq 2 ]
}

# --- a kernel that cannot blink ---------------------------------------------

@test "without the timer trigger the color is shown steady, and it says so" {
  # Half the information is better than none, and far better than a channel
  # left dark because a write to `trigger` was refused.
  for ch in "${CHANNELS[@]}"; do offers "$ch" none heartbeat; done
  stub ping 1
  stub systemctl 0 "x.service loaded failed failed X"
  leds once
  [ "$status" -eq 0 ]
  [ "$(look_of LED1)" = "blue steady" ]
  [ "$(look_of LED2)" = "red steady" ]
  [[ "$output" == *"timer"* ]]
}

@test "the missing timer is reported once, not on every pass" {
  for ch in "${CHANNELS[@]}"; do offers "$ch" none heartbeat; done
  stub ping 1
  UNOQ_LED_INTERVAL=0.1 run timeout 1 "$LEDSH" run
  [ "$(grep -c "LED1 cannot blink" <<<"$output")" -eq 1 ]
}

# --- refusing to fight the kernel ------------------------------------------

@test "a channel already owned by a kernel trigger is left alone" {
  # Writing to a triggered channel succeeds and is overwritten a moment later,
  # which reads as broken code rather than as a conflict. Refusing is clearer.
  bound_to unoq:user-green1 heartbeat
  leds once
  [ "$(cat "$UNOQ_LED_DIR/unoq:user-green1/brightness")" = 0 ]
  grep -q '\[heartbeat\]' "$UNOQ_LED_DIR/unoq:user-green1/trigger"
}

# --- going dark -------------------------------------------------------------

@test "off turns every channel off" {
  leds once
  [ "$(look_of LED1)" = "green steady" ]
  leds off
  [ "$status" -eq 0 ]
  [ "$(look_of LED1)" = off ]
  [ "$(look_of LED2)" = off ]
}

@test "off stops a blink, not just a steady light" {
  # The kernel blinks with no process behind it. A timer left running after
  # the checker has gone is an LED that looks alive and reports on nothing.
  stub ping 1
  : >"$UNOQ_GADGET_DIR/UDC"
  stub systemctl 0 "x.service loaded failed failed X"
  leds once
  [ "$(look_of LED1)" = "red fast" ]
  [ "$(look_of LED2)" = "red fast" ]
  leds off
  [ "$(look_of LED1)" = off ]
  [ "$(look_of LED2)" = off ]
  for ch in "${CHANNELS[@]}"; do
    refute grep -q '\[timer\]' "$UNOQ_LED_DIR/$ch/trigger"
    [ ! -e "$UNOQ_LED_DIR/$ch/delay_on" ]
  done
}

@test "stopping the loop leaves the board dark" {
  stub ping 1
  UNOQ_LED_INTERVAL=0.1 run timeout 1 "$LEDSH" run
  kernel_reacts
  [ "$(look_of LED1)" = off ]
  [ "$(look_of LED2)" = off ]
}

# --- the interface ----------------------------------------------------------

@test "explain works without root and without touching the LEDs" {
  run "$LEDSH" explain
  [ "$status" -eq 0 ]
  [[ "$output" == *"LED 1"* ]]
  [[ "$output" == *"LED 2"* ]]
  [ "$(look_of LED1)" = off ]
}

@test "explain gives every state a rhythm, not only a color" {
  run "$LEDSH" explain
  [[ "$output" == *"steady"* ]]
  [[ "$output" == *"slow blink"* ]]
  [[ "$output" == *"fast blink"* ]]
  # No state line may name a color without a rhythm in front of it.
  refute grep -E '^ +(LED [34] +)?(red|green|blue|yellow) ' <<<"$output"
}

@test "an unknown verb is a usage error" {
  run "$LEDSH" frobnicate
  [ "$status" -eq 2 ]
}
