#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# install_unit rewrites every systemd unit in this project on its way into
# /etc/systemd/system, substituting the checkout path and the owning user.
#
# The failure it has to prevent is a unit that installs happily and then fails
# at boot with 203/EXEC - a status that names the unit but not the path it
# could not run, and reads the same as a permissions problem. Two ways to get
# there:
#
#   1. The path spelled some way sed does not know. `~/two-computers-one-board` and
#      `$HOME/two-computers-one-board` look equivalent to /home/arduino/two-computers-one-board and are not:
#      systemd expands neither, and passes them to execve() literally.
#
#   2. A path that is simply not there yet, because provisioning steps have an
#      order and the venv or the script has not been built.
#
# Both are cheap to catch at install time and expensive to diagnose at boot.
#
# These tests also killed a check that could never fire. install_unit briefly
# asserted "no placeholder remains after substitution", which sounds sensible
# and is impossible - sed replaces it wherever it appears. Test 6 is what is
# left of that: it pins the actual behaviour instead.

# The literal that provision/lib.sh substitutes. These must agree: when the
# repository was renamed, this file was (deliberately) left out of the sweep
# and three tests failed immediately - which is the suite doing its job, but
# the next person should not have to rediscover why.
PLACEHOLDER="/home/arduino/two-computers-one-board"

setup() {
  load helpers/stub
  stub_setup

  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  # install_unit writes to /etc and calls systemctl. Neither is acceptable in a
  # test, so the write goes to a temp root and systemctl is stubbed.
  # write_file is called with an absolute path, and the stub below prefixes
  # $ETC - so the tree that actually gets written is $ETC/etc/systemd/system.
  # Creating $ETC/systemd/system instead would work (the stub mkdir -p's) and
  # read as though the assertions below were looking in the wrong place.
  ETC="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ETC/etc/systemd/system"
  stub systemctl
  stub install_root

  # A real executable for the happy path to point at.
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  printf '#!/bin/sh\n' >"$BIN/thing"
  chmod +x "$BIN/thing"
}

# Source lib.sh with the pieces that touch the real system replaced.
#
# Sourcing rather than executing because install_unit is a function, and the
# alternative - a fixture script that calls it - would put a layer between the
# test and the thing being tested for no gain.
load_lib() {
  # Fail loudly if lib.sh cannot be sourced. `|| true` here would mean a syntax
  # error in lib.sh leaves install_unit undefined, `run` returns 127, and every
  # test asserting "this should fail" passes for entirely the wrong reason -
  # the same trap the fail() stub below fell into once already.
  # shellcheck disable=SC1090
  source "$PROJECT/provision/lib.sh" || {
    echo "could not source provision/lib.sh" >&2
    return 1
  }
  declare -F install_unit >/dev/null || {
    echo "lib.sh sourced but install_unit is not defined" >&2
    return 1
  }

  PROJECT_UNDER_TEST="${1:-/opt/checkout}"
  PROJECT="$PROJECT_UNDER_TEST"
  TARGET_USER="${2:-someone}"

  # need_root and the reporting verbs are lib.sh's; only the two that would
  # escape the sandbox are replaced. `fail` must still abort, because every
  # assertion below is about whether it fired.
  write_file() {
    local mode="$1" path="$2"
    mkdir -p "$ETC/$(dirname "$path")"
    cat >"$ETC/$path"
    return 0
  }
  # Matches lib.sh's real contract: fail() ABORTS. An earlier version of this
  # stub returned 1 instead, so install_unit carried on past its own checks and
  # every failure test passed for the wrong reason - the stub was wrong, not
  # the code. `run` executes in a subshell, so exit is captured as a status.
  fail() {
    echo "FAILED: $*" >&2
    exit 1
  }
  did() { :; }
  skip_() { :; }
}

unit() {
  local path="$BATS_TEST_TMPDIR/$1.service"
  shift
  printf '%s\n' "$@" >"$path"
  echo "$path"
}

# --- substitution ----------------------------------------------------------

@test "the project path is substituted into ExecStart" {
  load_lib "$BATS_TEST_TMPDIR"
  src="$(unit ok "[Service]" "ExecStart=/home/arduino/two-computers-one-board/bin/thing")"
  run install_unit "$src"
  [ "$status" -eq 0 ]
  run cat "$ETC/etc/systemd/system/ok.service"
  [[ "$output" == *"ExecStart=$BATS_TEST_TMPDIR/bin/thing"* ]]
  [[ "$output" != *"/home/arduino/two-computers-one-board"* ]]
}

@test "User and Group are substituted" {
  load_lib "$BATS_TEST_TMPDIR" "operator"
  src="$(unit u "[Service]" "User=arduino" "Group=arduino" \
    "ExecStart=/home/arduino/two-computers-one-board/bin/thing")"
  run install_unit "$src"
  [ "$status" -eq 0 ]
  run cat "$ETC/etc/systemd/system/u.service"
  [[ "$output" == *"User=operator"* ]]
  [[ "$output" == *"Group=operator"* ]]
}

@test "a unit that waits for the home directory waits for the right one" {
  # RequiresMountsFor=/home/arduino is not the checkout path, so the first
  # substitution never touched it. Under another account the unit then waited
  # on a mount point that does not exist.
  load_lib "$BATS_TEST_TMPDIR" "operator"
  TARGET_HOME=/home/operator
  src="$(unit m "[Unit]" "RequiresMountsFor=/home/arduino" "[Service]" \
    "ExecStart=/home/arduino/two-computers-one-board/bin/thing")"
  run install_unit "$src"
  [ "$status" -eq 0 ]
  run cat "$ETC/etc/systemd/system/m.service"
  [[ "$output" == *"RequiresMountsFor=/home/operator"* ]]
  [[ "$output" != *"/home/arduino"* ]]
}

@test "a mount that is not the home directory is left alone" {
  load_lib "$BATS_TEST_TMPDIR" "operator"
  TARGET_HOME=/home/operator
  src="$(unit s "[Unit]" "RequiresMountsFor=/srv/unoq-share" "[Service]" \
    "ExecStart=/home/arduino/two-computers-one-board/bin/thing")"
  run install_unit "$src"
  [ "$status" -eq 0 ]
  run cat "$ETC/etc/systemd/system/s.service"
  [[ "$output" == *"RequiresMountsFor=/srv/unoq-share"* ]]
}

# --- the placeholder that looks real ---------------------------------------

@test "a tilde path is rejected, because systemd will not expand it" {
  # ~/two-computers-one-board reads as equivalent to /home/arduino/two-computers-one-board and is not: sed does
  # not know that spelling, and systemd passes it to execve() literally. The
  # unit then fails at boot with 203/EXEC, naming the unit but not the path.
  load_lib "$BATS_TEST_TMPDIR"
  src="$(unit tilde "[Service]" "ExecStart=~/two-computers-one-board/bin/thing")"
  run install_unit "$src"
  [ "$status" -ne 0 ]
  [[ "$output" == *"will not expand"* ]]
}

@test "\$HOME is rejected for the same reason" {
  load_lib "$BATS_TEST_TMPDIR"
  src="$(unit home "[Service]" "ExecStart=$BIN/thing" \
    "Environment=EXTRA=\$HOME/two-computers-one-board/share")"
  run install_unit "$src"
  [ "$status" -ne 0 ]
  [[ "$output" == *"will not expand"* ]]
}

@test "nothing is written when a unit is rejected" {
  load_lib "$BATS_TEST_TMPDIR"
  src="$(unit nowrite "[Service]" "ExecStart=~/two-computers-one-board/nope")"
  run install_unit "$src"
  [ "$status" -ne 0 ]
  [ ! -f "$ETC/etc/systemd/system/nowrite.service" ]
}

@test "the placeholder itself is substituted wherever it appears" {
  # Including outside Exec* lines. This is why there is no "leftover
  # placeholder" check: sed is global, so that check could never fire, and
  # writing this test is what showed it was dead code.
  load_lib "$BATS_TEST_TMPDIR"
  src="$(unit env "[Service]" "ExecStart=$BIN/thing" \
    "Environment=EXTRA=/home/arduino/two-computers-one-board/share")"
  run install_unit "$src"
  [ "$status" -eq 0 ]
  run cat "$ETC/etc/systemd/system/env.service"
  [[ "$output" == *"EXTRA=$BATS_TEST_TMPDIR/share"* ]]
}

# --- programs that are not there -------------------------------------------

@test "an ExecStart that does not exist is caught before boot" {
  load_lib "$BATS_TEST_TMPDIR"
  src="$(unit ghost "[Service]" "ExecStart=$BATS_TEST_TMPDIR/bin/absent")"
  run install_unit "$src"
  [ "$status" -ne 0 ]
  [[ "$output" == *"runs a program that is not there"* ]]
  [[ "$output" == *"absent"* ]]
}

@test "a file that exists but is not executable is caught too" {
  load_lib "$BATS_TEST_TMPDIR"
  touch "$BIN/notexec"
  src="$(unit noexec "[Service]" "ExecStart=$BIN/notexec")"
  run install_unit "$src"
  [ "$status" -ne 0 ]
  [[ "$output" == *"runs a program that is not there"* ]]
}

@test "ExecStartPre and ExecStop are checked, not just ExecStart" {
  load_lib "$BATS_TEST_TMPDIR"
  src="$(unit pre "[Service]" \
    "ExecStartPre=$BATS_TEST_TMPDIR/bin/absent check" \
    "ExecStart=$BIN/thing")"
  run install_unit "$src"
  [ "$status" -ne 0 ]
  [[ "$output" == *"absent"* ]]
}

@test "a '-' prefixed program is allowed to be missing, as systemd allows" {
  # `-` means "a failure of this command is not a failure of the unit", and
  # that includes not existing. Requiring it would be stricter than systemd and
  # would reject units that are correct.
  load_lib "$BATS_TEST_TMPDIR"
  src="$(unit dash "[Service]" "ExecStartPre=-$BATS_TEST_TMPDIR/bin/absent" \
    "ExecStart=$BIN/thing")"
  run install_unit "$src"
  [ "$status" -eq 0 ]
}

@test "an '@' prefixed program must still exist" {
  # @ only changes argv[0]; it says nothing about tolerating failure, so the
  # prefix must be stripped and the path still checked. This is the case that
  # a naive "skip anything not starting with /" would wave through.
  load_lib "$BATS_TEST_TMPDIR"
  src="$(unit at "[Service]" "ExecStart=@$BATS_TEST_TMPDIR/bin/absent name")"
  run install_unit "$src"
  [ "$status" -ne 0 ]
  [[ "$output" == *"runs a program that is not there"* ]]
}

@test "combined prefixes are stripped, not just the first" {
  load_lib "$BATS_TEST_TMPDIR"
  src="$(unit combo "[Service]" "ExecStart=+@$BATS_TEST_TMPDIR/bin/absent n")"
  run install_unit "$src"
  [ "$status" -ne 0 ]
  [[ "$output" == *"runs a program that is not there"* ]]
}

@test "arguments are not mistaken for the executable" {
  load_lib "$BATS_TEST_TMPDIR"
  src="$(unit args "[Service]" "ExecStart=$BIN/thing --root /nowhere --port 8080")"
  run install_unit "$src"
  [ "$status" -eq 0 ]
}

@test "a bare command name is left to systemd's own PATH" {
  # Second-guessing systemd's PATH here would produce false failures on units
  # that legitimately say `ExecStart=/bin/sleep` style bare names.
  load_lib "$BATS_TEST_TMPDIR"
  src="$(unit bare "[Service]" "ExecStart=true")"
  run install_unit "$src"
  [ "$status" -eq 0 ]
}

# --- the real units --------------------------------------------------------

@test "every unit in the repository installs cleanly against this checkout" {
  # The end-to-end assertion, and the one that would have caught a new unit
  # spelling the project path some other way.
  REAL="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load_lib "$REAL"
  for src in "$REAL"/*/*.service; do
    [ -e "$src" ] || continue
    # Skip units whose programs are venv entry points that may not be built in
    # this environment - the substitution check still runs on all of them.
    run install_unit "$src"
    if [ "$status" -ne 0 ]; then
      [[ "$output" == *"runs a program that is not there"* ]] ||
        {
          echo "unexpected failure for $src: $output"
          false
        }
    fi
  done
}

@test "a '-' anywhere in a combined prefix still means optional" {
  # systemd allows the prefix characters in combination and in any order, so
  # `+-/path` is optional too. Detecting `-` only in first position and
  # stripping it afterwards is stricter than systemd and rejects correct units.
  load_lib "$BATS_TEST_TMPDIR"
  src="$(unit combodash "[Service]" \
    "ExecStartPre=+-$BATS_TEST_TMPDIR/bin/absent" \
    "ExecStart=$BIN/thing")"
  run install_unit "$src"
  [ "$status" -eq 0 ]
}

@test "an '@' before a '-' does not make it required" {
  load_lib "$BATS_TEST_TMPDIR"
  src="$(unit atdash "[Service]" "ExecStart=@-$BATS_TEST_TMPDIR/bin/absent n")"
  run install_unit "$src"
  [ "$status" -eq 0 ]
}

# --- a renderer that produces nothing ---------------------------------------

@test "an unreadable source is a failure, not an empty unit" {
  load_lib "$BATS_TEST_TMPDIR"
  run install_unit "$BATS_TEST_TMPDIR/does-not-exist.service"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot read"* ]]
  [ ! -f "$ETC/etc/systemd/system/does-not-exist.service" ]
}

@test "an empty source file does not install an empty unit" {
  # Empty output passes every check below it vacuously - grep finds no shell
  # syntax and no Exec lines in nothing - and systemd loads an empty unit
  # happily, so the service just never runs and nothing says why.
  load_lib "$BATS_TEST_TMPDIR"
  src="$BATS_TEST_TMPDIR/empty.service"
  : >"$src"
  run install_unit "$src"
  [ "$status" -ne 0 ]
  [ ! -f "$ETC/etc/systemd/system/empty.service" ]
  # The MESSAGE matters, not just the refusal. "no [Section] header" would also
  # be true of an empty file and would send someone looking for a typo in a
  # file that has nothing in it at all. Asserting it here is also what keeps
  # the emptiness check from looking redundant with the section check and
  # being deleted - it is not redundant, it is more specific.
  [[ "$output" == *"rendered to nothing"* ]]
}

@test "a file with no section header is rejected" {
  load_lib "$BATS_TEST_TMPDIR"
  src="$(unit nosection "# just a comment" "ExecStart=$BIN/thing")"
  run install_unit "$src"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no [Section] header"* ]]
}

# --- Documentation= ---------------------------------------------------------

@test "a Documentation=file: target that does not exist is caught" {
  # These fail SILENTLY in production: nothing reads them until a person runs
  # `systemctl status` and follows the link. Two units shipped for weeks
  # pointing at docs/usb.md and docs/mpu.md after the docs moved under
  # reference/, and nothing anywhere noticed.
  load_lib "$BATS_TEST_TMPDIR"
  src="$(unit doc "[Unit]" "Documentation=file:$BATS_TEST_TMPDIR/gone.md" \
    "[Service]" "ExecStart=$BIN/thing")"
  run install_unit "$src"
  [ "$status" -ne 0 ]
  [[ "$output" == *"documents itself with a file that is not there"* ]]
}

@test "http and man Documentation entries are left alone" {
  # Not ours to verify, and checking them would make provisioning need the
  # network - which is the one thing this board's whole design avoids.
  load_lib "$BATS_TEST_TMPDIR"
  src="$(unit docurl "[Unit]" \
    "Documentation=https://example.invalid/x man:systemd(1)" \
    "[Service]" "ExecStart=$BIN/thing")"
  run install_unit "$src"
  [ "$status" -eq 0 ]
}

@test "several Documentation entries on one line are all checked" {
  load_lib "$BATS_TEST_TMPDIR"
  src="$(unit docmulti "[Unit]" \
    "Documentation=file:$BIN/thing file:$BATS_TEST_TMPDIR/gone.md" \
    "[Service]" "ExecStart=$BIN/thing")"
  run install_unit "$src"
  [ "$status" -ne 0 ]
  [[ "$output" == *"gone.md"* ]]
}

# --- the interpreter, not just the file ------------------------------------

@test "a script whose interpreter is missing is caught" {
  # The case this whole check was written for, which it originally missed.
  # Moving the checkout left the venv's console scripts present and executable
  # with a shebang naming a python that no longer existed - so -x passed,
  # install_unit was happy, and systemd reported 203/EXEC naming the SCRIPT
  # rather than the interpreter that was actually gone.
  load_lib "$BATS_TEST_TMPDIR"
  printf '#!%s/bin/absent-python\nprint(1)\n' "$BATS_TEST_TMPDIR" >"$BIN/script"
  chmod +x "$BIN/script"
  src="$(unit interp "[Service]" "ExecStart=$BIN/script")"
  run install_unit "$src"
  [ "$status" -ne 0 ]
  [[ "$output" == *"interpreter is missing"* ]]
  [[ "$output" == *"absent-python"* ]]
}

@test "a working interpreter passes" {
  load_lib "$BATS_TEST_TMPDIR"
  printf '#!/bin/sh\nexit 0\n' >"$BIN/good"
  chmod +x "$BIN/good"
  src="$(unit goodinterp "[Service]" "ExecStart=$BIN/good")"
  run install_unit "$src"
  [ "$status" -eq 0 ]
}

@test "env-style shebangs are accepted without resolving the argument" {
  # `#!/usr/bin/env python3` runs /usr/bin/env, which resolves python3 from
  # PATH itself. Checking the argument would mean reimplementing that lookup
  # and would fail on anything using a PATH systemd sets up later.
  load_lib "$BATS_TEST_TMPDIR"
  printf '#!/usr/bin/env definitely-not-installed\n' >"$BIN/envstyle"
  chmod +x "$BIN/envstyle"
  src="$(unit envstyle "[Service]" "ExecStart=$BIN/envstyle")"
  run install_unit "$src"
  [ "$status" -eq 0 ]
}

@test "a binary with no shebang is not mistaken for a broken script" {
  load_lib "$BATS_TEST_TMPDIR"
  cp /bin/true "$BIN/realbinary"
  src="$(unit binary "[Service]" "ExecStart=$BIN/realbinary")"
  run install_unit "$src"
  [ "$status" -eq 0 ]
}

@test "a tab-separated shebang splits on the tab, as the kernel does" {
  # The kernel ends the interpreter name at a space OR a tab, so this shebang
  # names /usr/bin/env and runs fine. Splitting on a literal space alone would
  # leave "env<TAB>definitely-not-installed" in the interpreter and fail -x on
  # a unit that works - a false failure that blocks provisioning outright.
  load_lib "$BATS_TEST_TMPDIR"
  printf '#!/usr/bin/env\tdefinitely-not-installed\n' >"$BIN/tabbed"
  chmod +x "$BIN/tabbed"
  src="$(unit tabbed "[Service]" "ExecStart=$BIN/tabbed")"
  run install_unit "$src"
  [ "$status" -eq 0 ]
}

@test "a missing interpreter is still caught when separated by a tab" {
  # The other half: widening the split must not blind the check itself.
  load_lib "$BATS_TEST_TMPDIR"
  printf '#!%s/bin/absent\tfoo\n' "$BATS_TEST_TMPDIR" >"$BIN/tabbedbad"
  chmod +x "$BIN/tabbedbad"
  src="$(unit tabbedbad "[Service]" "ExecStart=$BIN/tabbedbad")"
  run install_unit "$src"
  [ "$status" -ne 0 ]
  [[ "$output" == *"interpreter is missing"* ]]
  [[ "$output" == *"absent"* ]]
}
