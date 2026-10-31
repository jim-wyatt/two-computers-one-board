#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# tools/settings.sh answers "what is this board set to, and where did each value
# come from?" without reading the code. Two things are at stake. Its list has to
# be complete: a setting a script reads and this command does not show is the
# gap #116 found by hand. And its sources have to be right: the units read
# /etc/default/unoq-usb and nothing else, so a value set only in a shell must
# not be reported as what they see.
#
# The list comes from docs/reference/configuration.md, which
# tools/check-config-docs.sh already holds to the code. The last test here
# closes the loop from the other end: every setting the code reads is printed.

setup() {
  load helpers/stub
  stub_setup
  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PAGE="$PROJECT/docs/reference/configuration.md"
  CMD="$PROJECT/tools/settings.sh"
  export UNOQ_ROOT="$BATS_TEST_TMPDIR/root"
  CONF="$UNOQ_ROOT/etc/default/unoq-usb"
  mkdir -p "$(dirname "$CONF")"
}

# line_for <name> - the one output line for that setting, spaces squeezed.
line_for() { grep -E "^  $1 " <<<"$output" | tr -s ' ' | sed 's/^ //'; }

# on_page_above <heading> - every variable the page lists above that heading.
on_page_above() {
  # shellcheck disable=SC2016 # the backticks are markdown, matched literally
  awk -v stop="$1" 'index($0, stop) == 1 { exit } { print }' "$PAGE" |
    grep -E '^\| *`[A-Z]' | cut -d'|' -f2 | grep -oE '`[A-Z][A-Z0-9_]*`' | tr -d '`' | sort -u
}

@test "every setting the page lists for changing is shown, and no test seam is" {
  run env -u UNOQ_LED_INTERVAL "$CMD"
  [ "$status" -eq 0 ]
  local n
  for n in $(on_page_above "## Not for changing"); do
    [ -n "$(line_for "$n")" ] || {
      echo "$n is on the page and not shown"
      false
    }
  done
  # Below that heading are the variables the tests point scripts with.
  [ -z "$(line_for UNOQ_UNIT_DIR)" ]
  [ -z "$(line_for UNOQ_ROOT)" ]
}

@test "with nothing set, a setting shows the page's default, and says so" {
  : >"$CONF"
  run env -u UNOQ_LED_INTERVAL "$CMD"
  [ "$status" -eq 0 ]
  [ "$(line_for UNOQ_LED_INTERVAL)" = "UNOQ_LED_INTERVAL 5 default" ]
}

@test "a value in /etc/default/unoq-usb is shown as the file's, quotes and comments aside" {
  printf '%s\n' '#UNOQ_LED_INTERVAL=9' 'UNOQ_LED_INTERVAL=2' \
    'UNOQ_USB_PROBE_IPS="9.9.9.9 1.0.0.1"' >"$CONF"
  run env -u UNOQ_LED_INTERVAL -u UNOQ_USB_PROBE_IPS "$CMD"
  [ "$status" -eq 0 ]
  [ "$(line_for UNOQ_LED_INTERVAL)" = "UNOQ_LED_INTERVAL 2 file" ]
  [ "$(line_for UNOQ_USB_PROBE_IPS)" = "UNOQ_USB_PROBE_IPS 9.9.9.9 1.0.0.1 file" ]
}

@test "the last line wins, as it does for the unit reading the file" {
  printf '%s\n' 'UNOQ_LED_INTERVAL=2' 'UNOQ_LED_INTERVAL=3' >"$CONF"
  run env -u UNOQ_LED_INTERVAL "$CMD"
  [ "$(line_for UNOQ_LED_INTERVAL)" = "UNOQ_LED_INTERVAL 3 file" ]
}

@test "a value set only in this shell is shown as the environment's" {
  : >"$CONF"
  UNOQ_TIER2=0 run "$CMD"
  [ "$status" -eq 0 ]
  [ "$(line_for UNOQ_TIER2)" = "UNOQ_TIER2 0 environment" ]
}

@test "the file and this shell disagreeing shows what the units see, and the shell's too" {
  # The units never see the shell. Showing the shell's value as the answer
  # would report a setting the running services do not have.
  echo 'UNOQ_LED_INTERVAL=2' >"$CONF"
  UNOQ_LED_INTERVAL=7 run "$CMD"
  [ "$status" -eq 0 ]
  [ "$(line_for UNOQ_LED_INTERVAL)" = "UNOQ_LED_INTERVAL 2 file this shell has 7" ]
}

@test "a line in the file that no script reads is called out" {
  # A typo, or a setting since retired: either way it does nothing, silently.
  printf '%s\n' 'UNOQ_USB_MODE=server' 'UNOQ_LED_INTERVALL=2' >"$CONF"
  run "$CMD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"== not settings =="* ]]
  grep -qE "UNOQ_USB_MODE +set in $CONF, and nothing reads it" <<<"$output"
  grep -qE "UNOQ_LED_INTERVALL +set in $CONF, and nothing reads it" <<<"$output"
}

@test "a board with no settings file says so, rather than reading nothing" {
  run "$CMD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$CONF, which does not exist on this board"* ]]
}

@test "every setting a script reads is shown, apart from test seams and what is set for you" {
  # The code side, as tools/check-config-docs.sh works it out.
  in_code="$(git -C "$PROJECT" ls-files -- '*.sh' '*.service' '*.rules' '*.py' 'env.sh' |
    grep -vE '^(tests|python/tests)/' | sed "s#^#$PROJECT/#" |
    xargs grep -ohE 'UNOQ_[A-Z0-9_]+' | sort -u)"
  # What the page puts below "Not for changing", and the gate's own exceptions.
  not_settings="$(on_page_above "## What is not a variable" | sort -u)"
  not_settings="$not_settings $(grep -oE 'UNOQ_[A-Z0-9_]+' "$PAGE" | sort -u | while read -r v; do
    on_page_above "## Not for changing" | grep -qx "$v" || echo "$v"
  done)"
  run "$CMD"
  # The gate's own exceptions: two prefixes in prose, and a retired setting.
  local v exempt=" UNOQ_ UNOQ_X UNOQ_USB_MODE "
  for v in $in_code; do
    case "$exempt" in *" $v "*) continue ;; esac
    if [ -z "$(line_for "$v")" ] && ! grep -qx "$v" <<<"$(tr ' ' '\n' <<<"$not_settings")"; then
      echo "$v is read by a script and not shown"
      false
    fi
  done
}
