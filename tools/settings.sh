#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Every setting this board can be given, the value it has, and where it came from.
#
#   ~/two-computers-one-board/tools/settings.sh
#
# Read-only. Nothing is changed and nothing needs root.
#
# WHERE THE LIST COMES FROM
# -------------------------
# docs/reference/configuration.md, the page that documents them: every table
# above "Not for changing", which is where the test seams start. That page is
# already held to the code by tools/check-config-docs.sh, which fails CI when a
# script reads a setting the page does not name. Reading the list from it,
# rather than keeping a second one here, is what stops this command falling
# behind the scripts: there is nothing here to forget to update.
#
# WHERE A VALUE COMES FROM
# ------------------------
# The units that read settings (unoq-usb-gadget, unoq-usb-bind,
# unoq-uplink-fallback, unoq-leds) get them from /etc/default/unoq-usb. Anything
# run by hand gets them from the environment it was started in. So a setting is
#
#   file          set in /etc/default/unoq-usb, which is what the units see
#   environment   not in the file, but set in the shell this was run from
#   default       neither, so the script's own default applies
#
# and a setting the file and this shell disagree about says both.
set -uo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
PAGE="$PROJECT/docs/reference/configuration.md"
# UNOQ_ROOT is the tests' prefix for system paths, as in provision/lib.sh.
CONF="${UNOQ_ROOT:-}/etc/default/unoq-usb"

[ -r "$PAGE" ] || {
  echo "settings: cannot read $PAGE" >&2
  exit 1
}

if [ -t 1 ]; then
  BOLD=$'\033[1m' DIM=$'\033[2m' YELLOW=$'\033[33m' OFF=$'\033[0m'
else
  BOLD="" DIM="" YELLOW="" OFF=""
fi

# rows - "section<TAB>name<TAB>default" for every setting the page lists above
# "Not for changing". A row may name several variables; each gets a line.
rows() {
  awk -F'|' '
    /^## Not for changing/ { exit }
    /^##+ / { section = $0; sub(/^#+ /, "", section); next }
    /^\| *`[A-Z]/ {
      def = $3
      gsub(/`/, "", def)
      gsub(/^ +| +$/, "", def)
      names = $2
      while (match(names, /`[A-Z][A-Z0-9_]*`/)) {
        print section "\t" substr(names, RSTART + 1, RLENGTH - 2) "\t" def
        names = substr(names, RSTART + RLENGTH)
      }
    }
  ' "$PAGE"
}

# from_file <name> - the value the file gives it, if it gives one. The file is
# read, never sourced: it is root's, and this runs as anyone.
in_file() { [ -r "$CONF" ] && grep -qE "^[[:space:]]*$1=" "$CONF"; }
from_file() {
  sed -nE "s/^[[:space:]]*$1=(.*)$/\\1/p" "$CONF" | tail -1 |
    sed -E "s/^\"(.*)\"$/\\1/; s/^'(.*)'$/\\1/"
}

KNOWN=" "
last=""
while IFS=$'\t' read -r section name def; do
  KNOWN="$KNOWN$name "
  if [ "$section" != "$last" ]; then
    printf '\n%s== %s ==%s\n' "$BOLD" "$section" "$OFF"
    last="$section"
  fi
  note=""
  if in_file "$name"; then
    value="$(from_file "$name")"
    source="file"
    if [ -n "${!name+x}" ] && [ "${!name}" != "$value" ]; then
      note="  ${YELLOW}this shell has ${!name}${OFF}"
    fi
  elif [ -n "${!name+x}" ]; then
    value="${!name}"
    source="environment"
  else
    value="$def"
    source="default"
  fi
  [ "$source" = default ] && source="${DIM}default${OFF}"
  printf '  %-34s %-28s %s%s\n' "$name" "${value:-<empty>}" "$source" "$note"
done < <(rows)

# Lines in the file that set nothing: a name the page does not list is a
# setting no script reads, which is a typo or a setting that has been retired.
# Either way it does nothing, and nothing else would say so.
if [ -r "$CONF" ]; then
  stray=""
  while IFS= read -r name; do
    case "$KNOWN" in *" $name "*) ;; *) stray="$stray $name" ;; esac
  done < <(sed -nE 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p' "$CONF" | sort -u)
  if [ -n "$stray" ]; then
    printf '\n%s== not settings ==%s\n' "$BOLD" "$OFF"
    for name in $stray; do
      printf '  %s%-34s set in %s, and nothing reads it%s\n' "$YELLOW" "$name" "$CONF" "$OFF"
    done
  fi
fi

printf '\n%sThe units read %s%s. Anything run by hand reads its environment.%s\n' \
  "$DIM" "$CONF" "$([ -r "$CONF" ] || echo ', which does not exist on this board')" "$OFF"
