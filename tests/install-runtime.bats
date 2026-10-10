#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# install_runtime copies the scripts that root runs out of the checkout and
# into a directory only root can write, and the root units are pointed there
# (tests/install-unit.bats has that half).
#
# It exists because the units used to execute the checkout itself: a directory
# in somebody's home, which an editor, a `git pull` or any process running as
# that user can change - and whatever changed it had then changed what root
# does at the next boot, with no password asked.
#
# So what matters here is not that files get copied. It is:
#
#   - the copy is what the checkout says, and stays that way: a changed script
#     is replaced, and said to be, because that line of output is now the only
#     moment a change reaches a root service;
#   - nothing is left behind. A script removed from the repository and still
#     sitting in root's directory is the original problem again;
#   - nobody but the owner can write any of it;
#   - a second run changes nothing and says so;
#   - it will not empty a directory it did not make.
#
# The suite runs as an ordinary user, so "owned by root" is "owned by whoever
# ran it" here - the code asks for the effective user both times. That root's
# files really end up root's is one of the things only a board can show.

setup() {
  load helpers/stub
  stub_setup

  REAL="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  # A checkout of our own, so a test can edit and delete scripts in it.
  SRC="$BATS_TEST_TMPDIR/checkout"
  mkdir -p "$SRC/usb" "$SRC/status" "$SRC/mcu"
  printf '#!/bin/bash\necho dhcp v1\n' >"$SRC/usb/usb-dhcp.sh"
  printf '#!/bin/bash\necho net-up\n' >"$SRC/usb/usb-net-up.sh"
  printf '#!/bin/bash\necho leds\n' >"$SRC/status/leds.sh"
  printf '#!/bin/bash\necho link\n' >"$SRC/mcu/link-up.sh"
  # Not executable in the checkout, deliberately: the mode root's copy gets is
  # the one install_runtime gives it, not one inherited from a working tree.
  chmod 0644 "$SRC"/usb/*.sh "$SRC/status/leds.sh" "$SRC/mcu/link-up.sh"

  RT="$BATS_TEST_TMPDIR/runtime/unoq"
  export UNOQ_RUNTIME_DIR="$RT"
}

# lib.sh with the checkout swapped for the one above. The reporting verbs are
# replaced by ones that can be asserted on; fail still aborts, as it must.
load_lib() {
  # shellcheck disable=SC1090
  source "$REAL/provision/lib.sh" || {
    echo "could not source provision/lib.sh" >&2
    return 1
  }
  declare -F install_runtime >/dev/null || {
    echo "lib.sh sourced but install_runtime is not defined" >&2
    return 1
  }
  PROJECT="$SRC"
  TARGET_USER="operator"
  TARGET_HOME="/home/operator"
  did() { echo "changed $*"; }
  skip() { echo "ok $*"; }
  warn() { echo "warn $*"; }
  fail() {
    echo "FAILED: $*" >&2
    exit 1
  }
}

# `! cmd` does not fail a bats test unless it is the last line of it.
refute() {
  if "$@"; then return 1; fi
}

ALL=(usb/usb-dhcp.sh usb/usb-net-up.sh status/leds.sh mcu/link-up.sh)

# Every file and directory under root's directory with its modification time
# and inode. Unchanged between two runs means the second wrote nothing.
stamps() { find "$RT" -exec stat -c '%n %i %y' {} + | sort; }

# --- the first run ----------------------------------------------------------

@test "the first run copies every script, in the layout of the repository" {
  load_lib
  run install_runtime "${ALL[@]}"
  # 0 is "something changed", like write_file.
  [ "$status" -eq 0 ]
  for f in "${ALL[@]}"; do
    cmp "$SRC/$f" "$RT/$f"
    [[ "$output" == *"changed installed $RT/$f"* ]]
  done
  # The layout is what keeps "$HERE/usb-dhcp.sh" and "$HERE/../usb/bind-guard.sh"
  # meaning what they meant: nothing is flattened.
  [ -d "$RT/usb" ] && [ -d "$RT/status" ] && [ -d "$RT/mcu" ]
}

@test "the copies are executable and only their owner can write them" {
  load_lib
  # A permissive umask must not leak into what root will run.
  umask 0000
  run install_runtime "${ALL[@]}"
  [ "$status" -eq 0 ]
  for f in "${ALL[@]}"; do
    [ "$(stat -c %a "$RT/$f")" = 755 ]
    [ "$(stat -c %u "$RT/$f")" = "$(id -u)" ]
  done
  for d in "$RT" "$RT/usb" "$RT/status" "$RT/mcu"; do
    [ "$(stat -c %a "$d")" = 755 ]
  done
  [ "$(stat -c %a "$RT/env")" = 644 ]
  # Stated the other way round as well: nothing in the tree, of any kind, that
  # group or other may write.
  run find "$RT" -perm /022
  [ -z "$output" ]
}

@test "the destination is where UNOQ_RUNTIME_DIR says, and nowhere else" {
  # shellcheck disable=SC2030  # local to this test, which is the intention
  export UNOQ_RUNTIME_DIR="$BATS_TEST_TMPDIR/elsewhere/lib"
  load_lib
  run install_runtime "${ALL[@]}"
  [ "$status" -eq 0 ]
  [ -x "$BATS_TEST_TMPDIR/elsewhere/lib/usb/usb-dhcp.sh" ]
  [ ! -e "$RT" ]
}

@test "with nothing set it is /usr/local/lib/unoq" {
  unset UNOQ_RUNTIME_DIR
  load_lib
  [ "$RUNTIME_DIR" = /usr/local/lib/unoq ]
}

# --- the second run ---------------------------------------------------------

@test "a second run with nothing changed writes nothing and says so" {
  load_lib
  run install_runtime "${ALL[@]}"
  [ "$status" -eq 0 ]
  before="$(stamps)"
  run install_runtime "${ALL[@]}"
  # 1 is "nothing changed" - what a step uses to decide not to restart.
  [ "$status" -eq 1 ]
  [[ "$output" != *"changed"* ]]
  [[ "$output" == *"ok 4 of root's scripts in $RT already match the checkout"* ]]
  [ "$(stamps)" = "$before" ]
}

@test "a directory that inherited setgid is not 'fixed' on every run" {
  # Debian's /usr/local has been group-staff and setgid, a new directory under
  # it inherits the bit, and a numeric chmod keeps it. Comparing the whole mode
  # would report a change on every run for ever.
  load_lib
  mkdir -p "$BATS_TEST_TMPDIR/runtime"
  chmod g+s "$BATS_TEST_TMPDIR/runtime"
  run install_runtime "${ALL[@]}"
  [ "$status" -eq 0 ]
  run install_runtime "${ALL[@]}"
  [ "$status" -eq 1 ]
  [[ "$output" != *"changed"* ]]
}

# --- a script edited in the checkout ----------------------------------------

@test "a changed script is replaced, and the output names it" {
  load_lib
  run install_runtime "${ALL[@]}"
  printf '#!/bin/bash\necho dhcp v2\n' >"$SRC/usb/usb-dhcp.sh"
  run install_runtime "${ALL[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"changed updated $RT/usb/usb-dhcp.sh"* ]]
  cmp "$SRC/usb/usb-dhcp.sh" "$RT/usb/usb-dhcp.sh"
  # And only it: the other three are counted, not rewritten.
  [ "$(grep -c '^changed' <<<"$output")" = 1 ]
  [[ "$output" == *"ok 3 of root's scripts"* ]]
}

@test "until that run, root's copy is still the old script" {
  # The point of the whole arrangement, as a test: writing to the checkout does
  # not change what root runs. Provisioning does.
  load_lib
  run install_runtime "${ALL[@]}"
  printf '#!/bin/bash\necho something else entirely\n' >"$SRC/usb/usb-dhcp.sh"
  run "$RT/usb/usb-dhcp.sh"
  [ "$output" = "dhcp v1" ]
}

@test "a copy whose mode has drifted is put right even though its content matches" {
  load_lib
  run install_runtime "${ALL[@]}"
  chmod 0777 "$RT/status/leds.sh"
  run install_runtime "${ALL[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"changed updated $RT/status/leds.sh"* ]]
  [ "$(stat -c %a "$RT/status/leds.sh")" = 755 ]
}

@test "a directory whose mode has drifted is put right" {
  load_lib
  run install_runtime "${ALL[@]}"
  chmod 0777 "$RT/usb"
  run install_runtime "${ALL[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"changed owner and mode of $RT/usb put right"* ]]
  [ "$(stat -c %a "$RT/usb")" = 755 ]
}

@test "a copy that was swapped for a symlink is replaced by a file" {
  # cmp follows links, so a link to the checkout's own script compares equal.
  # Accepting that would hand the checkout straight back to root.
  load_lib
  run install_runtime "${ALL[@]}"
  rm "$RT/mcu/link-up.sh"
  ln -s "$SRC/mcu/link-up.sh" "$RT/mcu/link-up.sh"
  run install_runtime "${ALL[@]}"
  [ "$status" -eq 0 ]
  [ ! -L "$RT/mcu/link-up.sh" ]
  [ -f "$RT/mcu/link-up.sh" ]
}

@test "a replaced script is a new file, never one written in place" {
  # udhcpc runs usb-dhcp.sh on lease events without asking whether
  # provisioning has finished. A rename means the path holds the old script or
  # the new one and never half of either.
  load_lib
  run install_runtime "${ALL[@]}"
  before="$(stat -c %i "$RT/usb/usb-dhcp.sh")"
  printf '#!/bin/bash\necho dhcp v2\n' >"$SRC/usb/usb-dhcp.sh"
  run install_runtime "${ALL[@]}"
  [ "$(stat -c %i "$RT/usb/usb-dhcp.sh")" != "$before" ]
  run find "$RT" -name '.*'
  [ -z "$output" ]
}

# --- a script that is no longer one of them ---------------------------------

@test "a script dropped from the set is removed from root's directory" {
  load_lib
  run install_runtime "${ALL[@]}"
  [ -e "$RT/usb/usb-net-up.sh" ]
  run install_runtime usb/usb-dhcp.sh status/leds.sh mcu/link-up.sh
  [ "$status" -eq 0 ]
  [ ! -e "$RT/usb/usb-net-up.sh" ]
  [[ "$output" == *"changed removed $RT/usb/usb-net-up.sh"* ]]
  # The ones still in the set are untouched.
  [ -x "$RT/usb/usb-dhcp.sh" ]
}

@test "a file nobody installed is removed too, whatever it is" {
  # Not only yesterday's scripts: anything that turns up in a directory root
  # executes from. Including a link, which a test for regular files would miss.
  load_lib
  run install_runtime "${ALL[@]}"
  printf '#!/bin/bash\n' >"$RT/usb/planted.sh"
  ln -s /bin/true "$RT/status/link"
  run install_runtime "${ALL[@]}"
  [ "$status" -eq 0 ]
  [ ! -e "$RT/usb/planted.sh" ]
  [ ! -L "$RT/status/link" ]
}

@test "a directory left empty by that is removed as well" {
  load_lib
  run install_runtime "${ALL[@]}"
  run install_runtime usb/usb-dhcp.sh usb/usb-net-up.sh status/leds.sh
  [ "$status" -eq 0 ]
  [ ! -e "$RT/mcu" ]
  [ -d "$RT/usb" ]
}

@test "the env file is never mistaken for a stale script" {
  load_lib
  run install_runtime "${ALL[@]}"
  run install_runtime "${ALL[@]}"
  [ -f "$RT/env" ]
  [[ "$output" != *"removed"* ]]
}

# --- who the board belongs to, written down ---------------------------------

@test "the env file records the owner's home and the checkout" {
  # gadget-up.sh used to ask who owned it. The copy is root's, so the answer
  # has to be written down by the one thing that knows.
  load_lib
  run install_runtime "${ALL[@]}"
  run grep -x "UNOQ_OWNER_HOME=/home/operator" "$RT/env"
  [ "$status" -eq 0 ]
  run grep -x "UNOQ_CHECKOUT=$SRC" "$RT/env"
  [ "$status" -eq 0 ]
}

@test "the env file follows the board to a new owner" {
  load_lib
  run install_runtime "${ALL[@]}"
  TARGET_HOME=/home/somebody-else
  run install_runtime "${ALL[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"changed updated $RT/env"* ]]
  run grep -c "^UNOQ_OWNER_HOME=" "$RT/env"
  [ "$output" = 1 ]
  grep -qx "UNOQ_OWNER_HOME=/home/somebody-else" "$RT/env"
}

@test "with no home directory known, nothing is installed" {
  load_lib
  TARGET_HOME=""
  run install_runtime "${ALL[@]}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no home directory known"* ]]
  [ ! -e "$RT" ]
}

# --- refusals ---------------------------------------------------------------

@test "an empty set is refused: it would delete everything and install nothing" {
  load_lib
  run install_runtime "${ALL[@]}"
  run install_runtime
  [ "$status" -ne 0 ]
  [[ "$output" == *"no scripts to install"* ]]
  [ -x "$RT/usb/usb-dhcp.sh" ]
}

@test "a script that is not in the checkout stops the run before anything is written" {
  load_lib
  run install_runtime usb/usb-dhcp.sh usb/no-such-script.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"usb/no-such-script.sh is not a regular file"* ]]
  [ ! -e "$RT" ]
}

@test "a symlink in the checkout is not followed" {
  # It would copy whatever it points at, from anywhere, into a file anyone can
  # read and root will execute.
  load_lib
  ln -s /etc/hostname "$SRC/usb/link.sh"
  run install_runtime usb/usb-dhcp.sh usb/link.sh
  [ "$status" -ne 0 ]
  [ ! -e "$RT" ]
}

@test "a path that climbs out of the checkout is refused" {
  load_lib
  for bad in ../outside.sh usb/../../outside.sh /etc/passwd env; do
    run install_runtime usb/usb-dhcp.sh "$bad"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a path inside the checkout"* ]]
  done
  [ ! -e "$RT" ]
}

@test "a directory it did not create is not adopted, and not emptied" {
  # Everything not in the set is deleted, so the set had better be describing
  # a directory that is this project's. UNOQ_RUNTIME_DIR=/usr/local/lib is one
  # typo away.
  load_lib
  mkdir -p "$RT"
  echo "somebody's library" >"$RT/libsomething.so"
  run install_runtime "${ALL[@]}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"was not created by this"* ]]
  [ "$(cat "$RT/libsomething.so")" = "somebody's library" ]
  [ ! -e "$RT/usb" ]
}

@test "an empty directory is taken over: it is what an interrupted first run leaves" {
  load_lib
  mkdir -p "$RT"
  run install_runtime "${ALL[@]}"
  [ "$status" -eq 0 ]
  [ -x "$RT/usb/usb-dhcp.sh" ]
}

@test "a destination that is a symlink is refused" {
  load_lib
  mkdir -p "$BATS_TEST_TMPDIR/runtime" "$BATS_TEST_TMPDIR/somewhere-in-home"
  ln -s "$BATS_TEST_TMPDIR/somewhere-in-home" "$RT"
  run install_runtime "${ALL[@]}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"symbolic link"* ]]
  run ls -A "$BATS_TEST_TMPDIR/somewhere-in-home"
  [ -z "$output" ]
}

@test "a destination that is not a directory of its own is refused" {
  for bad in / /usr relative/path ""; do
    # shellcheck disable=SC2030,SC2031
    export UNOQ_RUNTIME_DIR="$bad"
    load_lib
    # "" is "not set", which is the default and fine; the rest are refused.
    [ -n "$bad" ] || continue
    run install_runtime "${ALL[@]}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to manage"* ]]
  done
}

# --- the set the steps really install ---------------------------------------

@test "the project's own set is every usb script, the LEDs and the link" {
  load_lib
  : >"$SRC/usb/notes.txt"
  run runtime_files
  [ "$output" = "mcu/link-up.sh
status/leds.sh
usb/usb-dhcp.sh
usb/usb-net-up.sh" ]
}

@test "everything a root unit starts is in the set the steps install" {
  # Against the real repository: each script named on an Exec line of a unit
  # that runs as root must be one install_root_scripts copies, or the unit is
  # refused on the board by a check that passed everywhere else.
  load_lib
  PROJECT="$REAL"
  set_now="$(runtime_files)"
  for unit in "$REAL"/*/*.service; do
    unit_runs_as_root "$unit" || continue
    while IFS= read -r rel; do
      grep -qxF "$rel" <<<"$set_now" || {
        echo "$unit starts $rel, which is not copied"
        false
      }
    done < <(grep -E '^Exec[A-Za-z]+=' "$unit" |
      grep -o '/home/arduino/two-computers-one-board/[^ ]*' |
      sed 's|/home/arduino/two-computers-one-board/||')
  done
}

@test "every sibling a copied script reaches for is copied with it" {
  # The scripts find each other as "$HERE/name.sh", and leds.sh reaches across
  # to ../usb/bind-guard.sh. A copy whose sibling stayed behind fails at the
  # next cable plug, as root, with nothing in any gate to say so.
  load_lib
  PROJECT="$REAL"
  run install_root_scripts
  [ "$status" -eq 0 ]
  for f in $(runtime_files); do
    dir="$(dirname "$RT/$f")"
    # shellcheck disable=SC2016  # $HERE is the text being looked for
    while IFS= read -r ref; do
      [ -x "$dir/$ref" ] || {
        echo "$f reaches for $ref, which is not in $dir"
        false
      }
    done < <(grep -v '^[[:space:]]*#' "$REAL/$f" |
      grep -o '\$HERE/[A-Za-z0-9./_-]*\.sh' | sed 's|^\$HERE/||' | sort -u)
  done
  # And each copy is the checkout's script, byte for byte.
  for f in $(runtime_files); do
    cmp "$REAL/$f" "$RT/$f"
  done
}

# --- the path on the way there ----------------------------------------------

@test "a directory someone else could write is reported, all the way up" {
  # A root-owned file is only as safe as the directories above it: whoever can
  # write a parent can rename the child aside.
  load_lib
  run install_runtime "${ALL[@]}"
  chmod 0775 "$BATS_TEST_TMPDIR/runtime"
  run runtime_dir_exposed "$RT" "$(id -u)"
  [[ "$output" == *"$BATS_TEST_TMPDIR/runtime"* ]]
  # The directory itself is ours and 0755, so it is not on the list.
  refute grep -qx "$RT" <<<"$output"
  chmod 0755 "$BATS_TEST_TMPDIR/runtime"
  run runtime_dir_exposed "$RT" "$(id -u)"
  refute grep -qx "$BATS_TEST_TMPDIR/runtime" <<<"$output"
}

@test "a directory owned by somebody else is reported whatever its mode" {
  load_lib
  run install_runtime "${ALL[@]}"
  # Asked as though root were the expected owner: every directory here belongs
  # to whoever is running the suite, so each one is somebody else's.
  # (Nothing to show when the suite itself runs as root: they are all root's.)
  [ "$(id -u)" != 0 ] || return 0
  run runtime_dir_exposed "$RT" 0
  grep -qx "$RT" <<<"$output"
}
