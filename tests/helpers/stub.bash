# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# Replace an external command with a recording no-op, by putting a directory of
# fakes at the front of PATH.
#
# WHY THIS AND NOT A REFACTOR
# ---------------------------
# The obvious way to make shell testable is to split every script into a
# "decide" half and a "do" half, and test the first. That is a large change to
# scripts that currently work, made before there are any tests to catch it
# going wrong - which is the wrong order.
#
# These scripts already have a seam, because everything they actually do is
# another program: ip, nmcli, systemctl, logger, dnsmasq. Shadowing those on
# PATH lets the REAL script run, unmodified, while nothing reaches the board.
# What you assert on is the argv it would have used.
#
# The limit is worth stating: this proves what a script decides to run, not
# that running it has the intended effect on a kernel. `ip route replace` being
# called with the right arguments is not the same as the route existing. That
# second half is what the board is for.

# stub_setup - private bin at the front of PATH, and an empty call log.
# Call this in setup(), before running anything under test.
stub_setup() {
  STUB_DIR="$BATS_TEST_TMPDIR/stub-bin"
  STUB_LOG="$BATS_TEST_TMPDIR/stub-calls.log"
  mkdir -p "$STUB_DIR"
  : >"$STUB_LOG"
  PATH="$STUB_DIR:$PATH"
  export PATH STUB_LOG
}

# stub <name> [exit_code] [stdout]
#
# One line per call, written with ONE write. It used to be three printfs, which
# is three writes: fine while only one stub ran at a time, and not once a
# script under test had something running in the background. Two stubs
# appending at once then interleaved halves of each other's lines, and a test
# that looked for a whole line did not find it.
#
# Records one line per invocation: the command name followed by its arguments,
# space separated. Arguments containing spaces are not distinguishable in the
# log, which is fine for everything here and worth knowing before you rely on
# it for something else.
stub() {
  local name="$1" code="${2:-0}" out="${3:-}"
  cat >"$STUB_DIR/$name" <<EOF
#!/bin/bash
printf '%s\n' "$name\${*:+ \$*}" >>"$STUB_LOG"
[ -n '$out' ] && printf '%s\n' '$out'
exit $code
EOF
  chmod +x "$STUB_DIR/$name"
}

# stub_body <name>  (body on stdin)
#
# A stub that still records every call, but then runs logic of your own. For
# commands a script uses in two different ways and expects different answers
# from - `ip link show` as a probe, then `ip route replace` as an action.
#
#   stub_body ip <<'SH'
#   case "$1 $2" in "link show") exit 0 ;; esac
#   exit 0
#   SH
stub_body() {
  local name="$1"
  {
    echo '#!/bin/bash'
    echo "printf '%s\n' \"$name\${*:+ \$*}\" >>\"\$STUB_LOG\""
    cat
  } >"$STUB_DIR/$name"
  chmod +x "$STUB_DIR/$name"
}

# calls - everything the stubs recorded, in order.
calls() { cat "$STUB_LOG"; }

# ran <command line> - exact match on a whole recorded line.
ran() { grep -qxF "$1" "$STUB_LOG"; }

# ran_like <extended regex> - for when one argument is unpredictable.
ran_like() { grep -qE "$1" "$STUB_LOG"; }

# never_ran <name> - the command was not invoked at all.
never_ran() { ! grep -q "^$1 " "$STUB_LOG" && ! grep -qx "$1" "$STUB_LOG"; }
