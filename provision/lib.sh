# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Shared helpers for the provision scripts. Sourced, never executed.
#
#   . "$(dirname "$0")/lib.sh"
#
# This file is sourced, so it has no shebang - the directive below is what
# tells shellcheck which shell to assume.
# shellcheck shell=bash
#
# WHY THESE EXIST
# ---------------
# Every script here has to be safe to re-run: bootstrap.sh calls them in
# sequence, and a half-finished board gets the same sequence again rather than
# a different recovery path. "Idempotent" here means the second run makes no
# changes and says so, not that it merely survives.
#
# They also have to work from wherever the repo was cloned. The scripts used to
# name the checkout path and the `arduino` user literally, which is fine on the
# board they were written on and wrong everywhere else.

# --- who and where ---------------------------------------------------------

# The repo root, derived from this file rather than assumed.
PROVISION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$(cd "$PROVISION_DIR/.." && pwd)"
export PROVISION_DIR PROJECT

# The human this board belongs to. These scripts run under sudo, so $USER is
# root and useless; SUDO_USER is the account that invoked us, which is the one
# that owns the checkout, holds the group memberships and gets the venv.
TARGET_USER="${UNOQ_USER:-${SUDO_USER:-$(stat -c %U "$PROJECT")}}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
export TARGET_USER TARGET_HOME

# --- output ----------------------------------------------------------------

if [ -t 1 ]; then
  P_GREEN=$'\033[32m' P_YELLOW=$'\033[33m' P_RED=$'\033[31m' P_BOLD=$'\033[1m' P_DIM=$'\033[2m' P_OFF=$'\033[0m'
else
  P_GREEN="" P_YELLOW="" P_RED="" P_BOLD="" P_DIM="" P_OFF=""
fi

# Counters, so a run can end with "3 changed, 9 already correct" instead of
# leaving you to read the whole log to find out whether it did anything.
CHANGED=0
UNCHANGED=0

step() { printf '\n%s== %s ==%s\n' "$P_BOLD" "$*" "$P_OFF"; }
did() {
  CHANGED=$((CHANGED + 1))
  printf '  %schanged%s  %s\n' "$P_GREEN" "$P_OFF" "$*"
}
skip() {
  UNCHANGED=$((UNCHANGED + 1))
  printf '  %sok     %s %s\n' "$P_DIM" "$P_OFF" "$*"
}
warn() { printf '  %swarn%s    %s\n' "$P_YELLOW" "$P_OFF" "$*" >&2; }
fail() {
  printf '  %sFAILED%s  %s\n' "$P_RED" "$P_OFF" "$*" >&2
  exit 1
}

summary() {
  printf '\n%s%d changed, %d already correct.%s\n' "$P_BOLD" "$CHANGED" "$UNCHANGED" "$P_OFF"
  # A board provisioned before root ran its own copies has units that still
  # execute the checkout, and each stays that way until the step that installed
  # it runs again. No single step can fix it for the others, so a step run by
  # hand says so. Under bootstrap.sh it is said ONCE, by bootstrap, at the end:
  # the first version printed these four lines after every one of fourteen
  # steps, most of which could do nothing about it, on a board that was in the
  # middle of being fixed.
  [ -n "${UNOQ_IN_BOOTSTRAP:-}" ] || warn_stale_root_units
}

need_root() {
  [ "$(id -u)" = 0 ] || fail "run this with sudo: sudo bash $0"
}

# --- idempotent primitives -------------------------------------------------

# apt_install <pkg>... - install only what is genuinely missing, so a re-run
# costs nothing and does not drag in an apt-get update it does not need.
apt_install() {
  local missing=() p
  for p in "$@"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed" || missing+=("$p")
  done
  if [ ${#missing[@]} -eq 0 ]; then
    skip "packages already installed: $*"
    return 0
  fi
  # Only refresh the index when we are actually about to install something.
  # Repeated `apt-get update` is the slowest part of a re-run by far.
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" >/dev/null ||
    fail "apt-get install ${missing[*]}"
  did "installed: ${missing[*]}"
}

# apt_remove <pkg>... - remove only what is actually present.
apt_remove() {
  local present=() p
  for p in "$@"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed" && present+=("$p")
  done
  if [ ${#present[@]} -eq 0 ]; then
    skip "already absent: $*"
    return 0
  fi
  DEBIAN_FRONTEND=noninteractive apt-get remove -y "${present[@]}" >/dev/null ||
    fail "apt-get remove ${present[*]}"
  did "removed: ${present[*]}"
}

# unit_exists <unit> - true if systemd knows about it at all. Guards every
# disable/mask below: a stock board that never had lightdm should report
# "not present", not an error the reader has to decide is harmless.
unit_exists() {
  systemctl list-unit-files "$1" --no-legend 2>/dev/null | grep -q . ||
    systemctl cat "$1" >/dev/null 2>&1
}

# disable_unit <unit>... - stop, disable, and say which of those was needed.
#
# Returns 1 if any unit is still running afterwards, and says so. It used to
# print "stopped and disabled" on the strength of having asked: on a stock
# board arduino-router was asked, kept running because a .path unit started it
# again, and went on holding /dev/ttyHS1 under a line that said it was gone.
# What systemd was asked for and what is now true are different things, and
# only the second is worth printing.
disable_unit() {
  local u rc=0
  for u in "$@"; do
    if ! unit_exists "$u"; then
      skip "$u not present"
      continue
    fi
    if [ "$(systemctl is-enabled "$u" 2>/dev/null)" = "disabled" ] &&
      ! systemctl is-active --quiet "$u"; then
      skip "$u already stopped and disabled"
      continue
    fi
    systemctl disable --now "$u" >/dev/null 2>&1
    if systemctl is-active --quiet "$u"; then
      warn "$u is still running after being stopped - something starts it again."
      warn "  what does:  systemctl show $u -p TriggeredBy -p WantedBy -p RequiredBy"
      rc=1
    elif [ "$(systemctl is-enabled "$u" 2>/dev/null)" = "enabled" ]; then
      # Stopped now, and back at the next boot: the half that is easy to miss,
      # because everything looks right until then.
      warn "$u stopped, but is still enabled - it will start again at boot."
      warn "  why:  systemctl disable $u"
      rc=1
    else
      # A unit stopped on purpose is not a failure, but systemd may record it
      # as one: socat, which is all arduino-router-serial is, exits 143 when
      # told to stop. LED 2 blinks red for any failed unit, so without this a
      # run that went perfectly ended with a red light for the thing it had
      # just been asked to switch off.
      systemctl reset-failed "$u" >/dev/null 2>&1 || true
      did "$u stopped and disabled"
    fi
  done
  return "$rc"
}

# ensure_ssh - make sure there is an SSH server running, or fail.
#
# The stock image ships openssh-server installed and switched off: the factory
# way in is `adb shell` over the USB cable. Anything that takes that cable away
# has to leave another door open first, and this is the door.
#
# Host keys are generated if there are none, because a server with no host key
# starts, fails, and reports it only in the journal. `ssh-keygen -A` creates
# the missing ones and leaves existing ones alone.
# REVERT: systemctl disable --now ssh
ensure_ssh() {
  local unit="ssh.service" k have=0
  unit_exists "$unit" || fail "no $unit on this board - install openssh-server first"
  for k in "${UNOQ_SSH_DIR:-/etc/ssh}"/ssh_host_*_key; do
    [ -e "$k" ] && have=1
  done
  if [ "$have" = 0 ]; then
    ssh-keygen -A >/dev/null 2>&1 || fail "could not generate SSH host keys"
    did "SSH host keys generated"
  fi
  enable_unit "$unit"
  systemctl is-active --quiet "$unit" ||
    fail "$unit did not stay running - check: journalctl -u ssh -n 20"
}

# in_unit_cgroup <unit> - is this process running inside that unit's cgroup?
#
# `adb shell` is a child of adbd, and systemd kills a unit's whole cgroup when
# it stops the unit. So a script started from `adb shell` that stops adbd is
# stopping itself, part way through whatever it was doing.
in_unit_cgroup() {
  grep -qE "/$1(/|\$)" "${UNOQ_CGROUP_FILE:-/proc/self/cgroup}" 2>/dev/null
}

# usb_handover - run usb/handover.sh, or arrange for it to be run.
#
# Sets HANDOVER_DEFERRED=1 when it was scheduled and has not happened yet, so
# the caller knows there is nothing to verify and something to tell the user.
# Returns 1 when it was run here and failed.
#
# From `adb shell` this process is adbd's child, and the hand-over stops adbd.
# So it is given to systemd to run from outside, a little later - long enough
# for the rest of the run to finish printing. Anywhere else it is just called.
usb_handover() {
  local handover="$RUNTIME_DIR/usb/handover.sh"
  local delay="${UNOQ_HANDOVER_DELAY:-20}"
  # Read by the caller, which shellcheck cannot see from here.
  # shellcheck disable=SC2034
  HANDOVER_DEFERRED=0
  if ! in_unit_cgroup adbd.service; then
    if "$handover"; then
      did "hand-over ran"
      return 0
    fi
    # Returned, not swallowed: the caller is a provisioning step, and a step
    # that carries on to print "bound" over a hand-over that failed has said
    # something untrue in the one place a person will look.
    warn "hand-over failed - check: journalctl -t unoq-usb-handover -n 40"
    return 1
  fi
  # A hand-over still pending from an earlier run would make the unit name
  # taken. Whatever it was going to do, this one does.
  systemctl stop unoq-usb-handover.timer unoq-usb-handover.service >/dev/null 2>&1
  # AccuracySec, because a timer's default accuracy is a minute: "20 seconds"
  # was measured firing 30 seconds late, with nothing to say why the board was
  # still sitting there on adb.
  systemd-run --quiet --collect --unit=unoq-usb-handover \
    --on-active="$delay" --timer-property=AccuracySec=1s \
    "$handover" >/dev/null 2>&1 ||
    fail "could not schedule the hand-over - adb is untouched, nothing is bound"
  did "hand-over scheduled in ${delay}s (this is an adb shell, and it will close)"
  # shellcheck disable=SC2034
  HANDOVER_DEFERRED=1
}

# mask_unit <unit> - for services that restart themselves on demand.
mask_unit() {
  local u="$1"
  if ! unit_exists "$u"; then
    skip "$u not present"
    return 0
  fi
  if [ "$(systemctl is-enabled "$u" 2>/dev/null)" = "masked" ]; then
    skip "$u already masked"
    return 0
  fi
  systemctl stop "$u" >/dev/null 2>&1
  systemctl mask "$u" >/dev/null 2>&1
  did "$u masked"
}

# ensure_group <group> - create as a system group if missing.
ensure_group() {
  if getent group "$1" >/dev/null; then
    skip "group $1 exists"
  else
    groupadd -r "$1" || fail "groupadd $1"
    did "group $1 created"
  fi
}

# add_to_group <group> - put TARGET_USER in it, if not already.
add_to_group() {
  if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx "$1"; then
    skip "$TARGET_USER already in $1"
  else
    usermod -aG "$1" "$TARGET_USER" || fail "usermod -aG $1 $TARGET_USER"
    did "$TARGET_USER added to $1 (needs re-login to take effect)"
  fi
}

# write_file <mode> <path> - content on stdin. Writes only on a real change,
# so re-runs neither touch mtimes nor trigger daemon reloads that watch them.
write_file() {
  local mode="$1" path="$2" tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  if [ -f "$path" ] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
    skip "$path up to date"
    return 1
  fi
  install -D -m "$mode" "$tmp" "$path" || fail "could not write $path"
  rm -f "$tmp"
  did "wrote $path"
  return 0
}

# --- what root runs ---------------------------------------------------------
#
# WHY THERE ARE TWO COPIES OF SOME SCRIPTS
# ----------------------------------------
# Six of the units installed here run as root: unoq-link, unoq-leds and the four
# USB ones. They used to execute the scripts in the checkout, which is in a home
# directory and belongs to the person who cloned it. So anything able to write
# there - an editor plugin, a compromised user process, a `git pull`, a branch
# switch - changed what root would run at the next boot or cable plug, with no
# password asked. And not one file each: the scripts call their siblings by
# relative path (usb-net-up.sh hands usb-dhcp.sh to udhcpc, leds.sh reaches
# ../usb/bind-guard.sh), so it was the whole directory that was trusted.
#
# Now root runs root-owned COPIES, in a directory only root can write, and the
# units that run as root are pointed at those. The copies mirror the layout of
# the repository - usb/, status/, mcu/ - so every relative reference between
# them means what it meant before and no script had to learn a new path.
#
# What that changes for a person: editing a script in the checkout no longer
# changes what the board does. Re-running a provisioning step does - with sudo,
# which is the point. Provisioning is the gate, and the `changed  updated ...`
# line it prints is the moment a change reaches a root service.
#
# The units that run as the user out of the Python venv (unoq-cpu-bars,
# unoq-learn) are not part of this. They have User= and no root to lend, and a
# virtualenv cannot be copied anyway.
RUNTIME_DIR="${UNOQ_RUNTIME_DIR:-/usr/local/lib/unoq}"
RUNTIME_DIR="${RUNTIME_DIR%/}"
export RUNTIME_DIR

# runtime_files - the scripts root runs, as paths relative to the checkout.
#
# ONE set, installed whole by every step that installs a root unit, rather than
# each step copying the files it thinks it needs. Three reasons:
#
#   - the steps overlap: leds.sh (step 35) asks usb/bind-guard.sh (step 60's)
#     whether the guard has given up, so "its own files" is not a clean split;
#   - install_runtime removes what is not in the set it was given, and three
#     steps each pruning down to a different subset would delete one another's
#     scripts;
#   - a script that nothing starts costs nothing. The USB scripts sitting in
#     /usr/local/lib/unoq on a board that never enabled the gadget are inert.
#
# usb/ is a glob on purpose. A new helper there is called by a sibling as
# "$HERE/new.sh", and a hand-kept list that missed it would produce a copy of
# the caller with nothing to call - found at the next cable plug, by root, on a
# board that may be reachable only over that cable.
runtime_files() {
  local f
  echo mcu/link-up.sh
  echo status/leds.sh
  for f in "$PROJECT"/usb/*.sh; do
    [ -f "$f" ] && echo "usb/$(basename "$f")"
  done
  # Not the status of that last test: a glob that matched nothing is an empty
  # set, which install_runtime refuses in words, not a failure to report here.
  return 0
}

# unit_runs_as_root <unit file> - true unless it names some other account.
# A unit with no User= runs as root; that default is the whole problem.
unit_runs_as_root() {
  local user
  user="$(sed -n 's/^User=[[:space:]]*//p' "$1" 2>/dev/null | tail -1)"
  case "$user" in
    "" | root | 0) return 0 ;;
    *) return 1 ;;
  esac
}

# warn_failed_units - say which systemd units have failed, if any.
#
# LED 2 blinks red when any unit is in the failed state, and a light cannot
# say which. The end of a run is when somebody is looking at both the board
# and the terminal, so this is where the two are joined up: the names, and what
# to do about them. Silent when nothing has failed, which is the usual case.
warn_failed_units() {
  local failed
  failed="$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print $1}')"
  [ -n "$failed" ] || return 0
  warn "systemd reports failed units, and LED 2 blinks red while it does:"
  local u
  for u in $failed; do
    warn "    $u"
  done
  warn "  why:    systemctl status <unit>"
  warn "  clear:  sudo systemctl reset-failed <unit>    (once you know why)"
}

# warn_stale_root_units - name them, and say what fixes each.
warn_stale_root_units() {
  local stale
  stale="$(stale_root_units)"
  [ -n "$stale" ] || return 0
  warn "these units still run as root from the checkout or the home directory:"
  warn "  $(tr '\n' ' ' <<<"$stale")"
  warn "  re-run the step that installed each one - 30-mcu-link.sh for unoq-link,"
  warn "  35-status-leds.sh for unoq-leds, 60-usb-gadget.sh for the others"
}

# stale_root_units [dir] - installed unoq-* units that run as root and still
# execute something from the checkout or anywhere else in the home directory.
# Prints their names; prints nothing on a board with none.
stale_root_units() {
  local dir="${1:-/etc/systemd/system}" u
  local -a under=(-e "$PROJECT/")
  # Guarded: an empty TARGET_HOME would make the pattern "/", which every
  # absolute path contains.
  [ -n "${TARGET_HOME:-}" ] && under+=(-e "$TARGET_HOME/")
  for u in "$dir"/unoq-*.service; do
    [ -f "$u" ] || continue
    unit_runs_as_root "$u" || continue
    if grep -E '^Exec[A-Za-z]+=' "$u" | grep -qF "${under[@]}"; then
      basename "$u"
    fi
  done
}

# runtime_dir_exposed <dir> [uid] - the directory and every one above it that
# someone other than <uid> (default root) could rename things in. Prints one
# per line; prints nothing when the path is sound.
#
# A root-owned file is only as protected as the directories on the way to it:
# whoever can write a parent can rename the child aside and put their own in
# its place, whatever the child's own mode says.
runtime_dir_exposed() {
  local d="$1" uid="${2:-0}" owner mode
  while :; do
    if [ -e "$d" ]; then
      owner="$(stat -c %u "$d")"
      mode="$(stat -c %A "$d")"
      # drwxrwxr-x: character 6 is group write, character 9 is other write.
      if [ "$owner" != "$uid" ] || [ "${mode:5:1}" = w ] || [ "${mode:8:1}" = w ]; then
        echo "$d"
      fi
    fi
    [ "$d" = / ] && break
    d="$(dirname "$d")"
  done
}

# _runtime_dir <dir> - make it, or put its owner and mode right. 0 = changed.
#
# The owner is "whoever this process is", which under sudo is root and is the
# only owner a step can give a file anyway. Spelled $EUID so that the suites,
# which run as an ordinary user, exercise the same lines against directories
# of their own.
_runtime_dir() {
  local d="$1" have
  # Said again here although install_runtime has already looked: this function
  # is what would chown and chmod whatever a link leads to, and it should not
  # depend on a caller having checked.
  [ -L "$d" ] && fail "$d is a symbolic link - not creating root's scripts through it"
  if [ ! -d "$d" ]; then
    install -d -o "$EUID" -g "$(id -g)" -m 0755 "$d" || fail "could not create $d"
    did "created $d"
    return 0
  fi
  # The last three digits only. A directory made under a setgid parent - and
  # Debian's /usr/local has been one - reads as 2755, keeps that bit through a
  # numeric chmod, and would otherwise be "fixed" on every run for ever. The
  # bit is harmless here: the group it would hand down is the one set below.
  have="$(stat -c '%u:%g %a' "$d")"
  [ "${have% *}:${have: -3}" = "$EUID:$(id -g):755" ] && return 1
  if ! chown "$EUID:$(id -g)" "$d" || ! chmod 0755 "$d"; then
    fail "could not fix the owner and mode of $d"
  fi
  did "owner and mode of $d put right"
  return 0
}

# _runtime_put <mode> <source> <destination> - 0 = written, 1 = already right.
#
# "Already right" is content AND owner AND mode: a copy with the correct bytes
# that has become group-writable is exactly as broken as one with the wrong
# bytes, and must not be reported as ok.
#
# Written beside the destination and renamed over it, so there is no moment at
# which the path holds half a script. udhcpc runs usb-dhcp.sh as root on every
# lease event and does not ask provisioning whether it has finished.
_runtime_put() {
  local mode="$1" src="$2" dst="$3" verb=installed tmp
  if [ -f "$dst" ] && [ ! -L "$dst" ]; then
    if cmp -s "$src" "$dst" &&
      [ "$(stat -c '%u:%g %a' "$dst")" = "$EUID:$(id -g) ${mode#0}" ]; then
      return 1
    fi
    verb=updated
  fi
  tmp="$(dirname "$dst")/.$(basename "$dst").new"
  if ! install -o "$EUID" -g "$(id -g)" -m "$mode" "$src" "$tmp" ||
    ! mv -fT "$tmp" "$dst"; then
    rm -f "$tmp"
    fail "could not install $dst"
  fi
  did "$verb $dst"
  return 0
}

# install_runtime <relative-path>... - make $RUNTIME_DIR hold exactly these
# files from the checkout, owned by root, mode 0755, and nothing else.
# The steps do not call this with a list of their own - they call
# install_root_scripts, below, which passes the one set there is.
#
# Returns 0 if anything changed and 1 if nothing did, like write_file - a step
# that has to restart a long-running service uses that to know whether the
# process it left running is now out of date.
#
# "AND NOTHING ELSE" IS NOT TIDINESS. A script deleted or renamed in the
# repository would otherwise stay behind in root's directory: executable,
# root-owned, no longer reviewed by anyone, and still there for an old unit or
# a sibling's "$HERE/..." to find. A stale file root will run is the problem
# this directory exists to end, so the same call that installs also removes.
#
# That makes the directory one this function OWNS, and it refuses to adopt one
# it did not create - see the checks below. Pointing UNOQ_RUNTIME_DIR at
# /usr/local/lib and having it emptied is not a mistake to leave possible.
install_runtime() {
  local dest="$RUNTIME_DIR" changed=1 same=0 rel f tmp
  local -a set=("$@") parents=()
  local -A keep=()

  # An empty set would prune everything and install nothing, which is the one
  # outcome that leaves every root unit pointing at a file that is not there.
  [ ${#set[@]} -gt 0 ] || fail "install_runtime: no scripts to install from $PROJECT"
  [ -n "${TARGET_HOME:-}" ] || fail "install_runtime: no home directory known for $TARGET_USER"

  # Everything is checked BEFORE anything is written: a set with one bad name
  # in it must not leave the directory half replaced.
  for rel in "${set[@]}"; do
    case "$rel" in
      "" | env | /* | .. | ../* | */.. | */../*)
        fail "install_runtime: not a path inside the checkout: '$rel'"
        ;;
    esac
    # Regular files only. A symlink would copy whatever it points at, from
    # anywhere on the board, into a world-readable file.
    if [ ! -f "$PROJECT/$rel" ] || [ -L "$PROJECT/$rel" ]; then
      fail "install_runtime: $PROJECT/$rel is not a regular file"
    fi
    keep["$rel"]=1
  done

  case "$dest" in
    /*/*) ;;
    *) fail "install_runtime: refusing to manage '$dest' - UNOQ_RUNTIME_DIR must be an absolute path below the root directory" ;;
  esac
  [ -L "$dest" ] && fail "install_runtime: $dest is a symbolic link - root's scripts must live where it says, not where a link leads"
  # The env file is written first and never pruned, so it doubles as the mark
  # of a directory this function made. An empty directory is fair game too: it
  # is what an interrupted first run leaves.
  if [ -e "$dest" ] && [ ! -f "$dest/env" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
    fail "install_runtime: $dest exists and was not created by this - not touching it.
  Everything in it that is not one of this project's scripts would be deleted.
  Move it aside, or set UNOQ_RUNTIME_DIR to a directory of its own."
  fi

  # THE DIRECTORIES INSIDE IT, TOO.
  #
  # The line above refuses a destination that is a link, and that was the only
  # link looked for. Further down, each child directory was tested with -d,
  # which follows links and so says "yes, a directory" about
  #
  #   /usr/local/lib/unoq/usb -> /home/someone/anything
  #
  # and the scripts were then written through it: root's copies landing outside
  # the directory that exists to contain them, in a place its owner can swap
  # them, after the link's target had been chowned to root and chmodded on the
  # way past. A stale link from an older layout does it as well as a planted
  # one. Checked here, with the rest, so nothing has been written when it stops.
  # A path that exists and is not a directory is refused at the same time; it
  # would only have failed half-way through otherwise.
  for rel in "${set[@]}"; do
    f="$(dirname "$rel")"
    while [ "$f" != . ]; do
      if [ -L "$dest/$f" ]; then
        fail "install_runtime: $dest/$f is a symbolic link - root's scripts would be
  written to wherever it leads, not into $dest. Nothing was changed.
  Look at it (ls -l $dest), remove it, and run this again."
      fi
      if [ -e "$dest/$f" ] && [ ! -d "$dest/$f" ]; then
        fail "install_runtime: $dest/$f is in the way and is not a directory.
  Nothing was changed. Remove it and run this again."
      fi
      f="$(dirname "$f")"
    done
  done

  _runtime_dir "$dest" && changed=0

  # WHO THE BOARD BELONGS TO, WRITTEN DOWN.
  #
  # The scripts used to work this out from where they were: gadget-up.sh took
  # the fileshare image from the home directory of whoever owned the script.
  # The copy is owned by root, so that answer is now /root and wrong. Deriving
  # things from file ownership is what stopped being true here, so the two
  # facts are stated instead - as data, read with sed, not as shell to source.
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
# Written by provision/lib.sh (install_runtime). Do not edit: it is rewritten
# by the next provisioning step, and nothing here is a setting.
#
# The scripts beside this file are root-owned copies of the ones in
# UNOQ_CHECKOUT, and are what the unoq-* services that run as root execute.
# Editing the checkout does not change them. Re-running a step does:
#   sudo bash $PROJECT/provision/35-status-leds.sh
UNOQ_OWNER_HOME=$TARGET_HOME
UNOQ_CHECKOUT=$PROJECT
EOF
  if _runtime_put 0644 "$tmp" "$dest/env"; then changed=0; fi
  rm -f "$tmp"

  for rel in "${set[@]}"; do
    # Every directory on the way down, outermost first, not only the last one:
    # `install -D` would create them with whatever the umask allows and never
    # look at them again.
    parents=()
    f="$(dirname "$rel")"
    while [ "$f" != . ]; do
      parents=("$f" ${parents[@]+"${parents[@]}"})
      f="$(dirname "$f")"
    done
    for f in ${parents[@]+"${parents[@]}"}; do
      _runtime_dir "$dest/$f" && changed=0
    done
    if _runtime_put 0755 "$PROJECT/$rel" "$dest/$rel"; then
      changed=0
    else
      same=$((same + 1))
    fi
  done
  [ "$same" -gt 0 ] && skip "$same of root's scripts in $dest already match the checkout"

  # Everything that is not a directory, so a stray symlink or socket goes too.
  while IFS= read -r -d '' f; do
    rel="${f#"$dest"/}"
    [ "$rel" = env ] && continue
    [ -n "${keep[$rel]:-}" ] && continue
    rm -f "$f" || fail "could not remove $f"
    did "removed $f (not one of the scripts root runs any more)"
    changed=0
  done < <(find "$dest" -mindepth 1 ! -type d -print0)
  while IFS= read -r -d '' f; do
    rmdir "$f" 2>/dev/null || continue
    did "removed empty $f"
    changed=0
  done < <(find "$dest" -mindepth 1 -depth -type d -empty -print0)

  # Only meaningful as root: as anyone else every directory is "not root's".
  if [ "$EUID" = 0 ]; then
    f="$(runtime_dir_exposed "$dest")"
    if [ -n "$f" ]; then
      warn "root's scripts are in a path that is not root's alone to change:"
      warn "  $(tr '\n' ' ' <<<"$f")"
      warn "  whoever can write one of those can replace what root runs"
    fi
  fi

  return "$changed"
}

# install_root_scripts - install_runtime, with the set from runtime_files.
# What every step that installs a root unit calls, before it installs the unit.
# Returns what install_runtime returns: 0 if anything changed, 1 if not.
install_root_scripts() {
  local -a set=()
  mapfile -t set < <(runtime_files)
  install_runtime ${set[@]+"${set[@]}"}
}

# render_unit <source.service> - the unit as it will be installed, on stdout.
#
# The units are checked in with this board's literal paths so they stay valid,
# readable files, and /home/arduino/two-computers-one-board in them is a
# placeholder. What it becomes depends on who would be running the thing named:
#
#   on an Exec*= line of a unit that runs as root   -> $RUNTIME_DIR
#   everywhere else                                 -> $PROJECT, the checkout
#
# "Everywhere else" is every line of a unit that has User= (unoq-cpu-bars and
# unoq-learn run from the venv, which lives in the checkout and cannot be
# copied), and the lines of a root unit that are not executed - Documentation=
# still opens the file a person would edit.
#
# The rule is by LINE, not by a list of directories that happen to be copied,
# so that it cannot be got half right: there is no spelling of a root unit's
# ExecStart that leaves root executing the checkout. A script that is not in
# the set install_runtime copies does not fall back to the checkout copy - it
# is simply not there, and install_unit refuses it below.
#
# A function of its own, not private to install_unit, because
# tools/check-units.sh has to verify the units exactly as they will be
# installed, and a second copy of these expressions over there would be right
# until the day this one changed.
render_unit() {
  local src="$1" exec_root="$PROJECT"
  unit_runs_as_root "$src" && exec_root="$RUNTIME_DIR"
  # The home directory by itself, for the units that wait for it to mount.
  # It has to be rewritten separately: the first expressions only match the
  # checkout path, so under any account but arduino those units went on
  # waiting for a /home/arduino that was never going to appear.
  sed -e "/^Exec[A-Za-z]*=/s#/home/arduino/two-computers-one-board#$exec_root#g" \
    -e "s#/home/arduino/two-computers-one-board#$PROJECT#g" \
    -e "s#^RequiresMountsFor=/home/arduino\$#RequiresMountsFor=$TARGET_HOME#" \
    -e "s#^User=arduino\$#User=$TARGET_USER#" \
    -e "s#^Group=arduino\$#Group=$TARGET_USER#" \
    "$src"
}

# install_unit <source.service> - copy a unit into /etc/systemd/system with the
# paths and the owning user substituted in (see render_unit), then reload only
# if it changed.
#
# A unit that runs as root needs install_runtime to have run FIRST: its Exec
# lines name root's copies, and the check below is of the path as rewritten.
# In the other order the step stops here, with the old unit still in place and
# still working, rather than installing one that points at nothing.
#
# This is also what moves a board provisioned before root had its own copies:
# the unit already installed there names the checkout, so it no longer matches
# what is rendered, and it is rewritten and reloaded like any other change.
install_unit() {
  local src="$1" name rendered
  name="$(basename "$src")"
  [ -r "$src" ] || fail "install_unit: cannot read $src"

  # Captured for the checks below only. Command substitution strips trailing
  # newlines, so the WRITE re-runs the renderer and pipes it straight through -
  # a unit file that did not end in exactly one newline would otherwise be
  # rewritten on every run, turning the second run's `skip` into a `did` and
  # quietly destroying the idempotence signal a re-provision depends on.
  #
  # EVERY FAILURE MODE OF THE RENDERER HAS TO BE CAUGHT HERE, because empty
  # output passes all of the checks below vacuously - grep finds no shell
  # syntax and no Exec lines in nothing - and the write pipeline would then
  # install an empty unit file. systemd loads that happily and the service
  # simply never runs.
  rendered="$(render_unit "$src")" || fail "install_unit: could not render $src"
  [ -n "$rendered" ] || fail "install_unit: $src rendered to nothing"
  grep -q '^\[' <<<"$rendered" ||
    fail "install_unit: $src has no [Section] header - not a unit file"

  # SHELL SYNTAX SYSTEMD DOES NOT EXPAND.
  #
  # Not a check that the substitution happened - that one cannot fail, because
  # sed replaces the placeholder wherever it appears, and writing the test for
  # it is what showed the check was vacuous.
  #
  # The failure that IS real is a unit written with the path spelled some other
  # way. `~/...` and `$HOME/...` read as obviously equivalent to a human, are
  # not substituted, and systemd expands neither: it passes them to execve()
  # literally, so the unit fails at boot with 203/EXEC naming the unit but not
  # the path, which reads like a permissions problem.
  local shellism
  # Single quotes are the point: these are patterns to find literally in the
  # unit, not variables to expand here.
  # shellcheck disable=SC2016
  shellism="$(grep -nE '(^|=|:| )(~/|\$HOME|\$\{HOME)' <<<"$rendered" || true)"
  if [ -n "$shellism" ]; then
    fail "$name uses shell syntax systemd will not expand:
  $shellism
  systemd passes these to execve() literally. Write the path as
  /home/arduino/two-computers-one-board/... and install_unit will substitute the real checkout."
  fi

  # Every program the unit runs must exist NOW. systemd reports a missing
  # ExecStart as status=203/EXEC at boot, which names the unit but not the
  # path, and looks identical to a permissions problem.
  local line prog optional
  while IFS= read -r line; do
    prog="${line#*=}"
    prog="${prog#"${prog%%[![:space:]]*}"}"
    # Strip systemd's prefix characters (-, @, :, +, !) and note whether `-` was
    # among them, in ONE pass. Testing for `-` first and stripping afterwards
    # looks equivalent and is not: systemd allows the prefixes in combination
    # and in any order, so `+-/path` would be seen as non-optional, have its `-`
    # stripped, and then be required to exist - stricter than systemd, failing
    # an install that is correct.
    #
    # `-` means "a failure of this command is not a failure of the unit", which
    # includes the program not being there at all.
    optional=0
    while :; do
      case "$prog" in
        -*)
          optional=1
          prog="${prog#?}"
          ;;
        [@:+!]*) prog="${prog#?}" ;;
        *) break ;;
      esac
    done
    prog="${prog%% *}"
    # Only absolute paths: systemd resolves bare names against its own PATH,
    # and second-guessing that here would produce false failures.
    case "$prog" in /*) ;; *) continue ;; esac
    [ "$optional" = 1 ] && continue
    if [ ! -x "$prog" ]; then
      fail "$name runs a program that is not there:
  $prog
  from: $line
  Provisioning steps have an order - if this is a venv entry point, the venv
  step has not run yet; if it is a script, check the path in $src.
  A unit that runs as root runs the copies in $RUNTIME_DIR, so
  its script has to be one install_runtime copies (runtime_files, in
  provision/lib.sh) and install_runtime has to have run before this."
    fi

    # AND ITS INTERPRETER, which -x does not tell you about.
    #
    # This check was written to prevent 203/EXEC at boot and then failed to,
    # for exactly this reason. Moving the checkout during the rename left the
    # venv's console scripts in place - present, executable, and starting
    # `#!/home/arduino/OLD-PATH/.venv/bin/python`, which no longer existed. The
    # file passed -x, install_unit was happy, and systemd reported
    #
    #   Failed at step EXEC ...: No such file or directory
    #   status=203/EXEC
    #
    # naming the script rather than the interpreter that was actually missing.
    # A venv is not relocatable; its shebangs are absolute paths.
    local shebang interp
    read -r shebang <"$prog" 2>/dev/null || shebang=""
    case "$shebang" in
      '#!'*)
        interp="${shebang#\#!}"
        interp="${interp#"${interp%%[![:space:]]*}"}"
        # First word only. `#!/usr/bin/env python3` runs /usr/bin/env, which
        # resolves python3 from PATH itself - not ours to second-guess.
        #
        # Split on ANY whitespace, not a literal space: the kernel ends the
        # interpreter name at a space OR a tab (fs/binfmt_script.c), so
        # `#!/usr/bin/env<TAB>python3` names /usr/bin/env just as the spaced
        # form does. Splitting on " " alone would leave the tab and the
        # argument in $interp and fail -x on a shebang that works perfectly.
        # This also drops a trailing CR from a CRLF file: the kernel would
        # keep it and fail, but erring toward accepting costs us a missed
        # diagnosis, while erring toward rejecting blocks a working install.
        interp="${interp%%[[:space:]]*}"
        [ -x "$interp" ] || fail "$name runs a script whose interpreter is missing:
  script:      $prog
  interpreter: $interp
  from: $line
  This is what produces 203/EXEC while the script itself looks fine. If the
  interpreter is under .venv, the checkout has probably moved - a virtualenv
  is not relocatable, and its shebangs are absolute. Rebuild it:
    bash \"$PROJECT/provision/user/40-python-venv.sh\""
        ;;
    esac
  done < <(grep -E '^Exec[A-Za-z]+=' <<<"$rendered" || true)

  # Documentation=file: targets, for the same reason as the Exec paths above -
  # except these fail SILENTLY. Nothing reads them until a person runs
  # `systemctl status` and follows the link, so a stale one survives
  # indefinitely. Two did: the docs restructure moved usb.md and mpu.md under
  # reference/ and left two units pointing at paths that no longer existed.
  #
  # Only file: is checked. https: and man: are not ours to verify, and trying
  # would make this need the network.
  local doc
  while IFS= read -r line; do
    for doc in ${line#*=}; do
      case "$doc" in file:*) ;; *) continue ;; esac
      doc="${doc#file:}"
      [ -e "$doc" ] && continue
      fail "$name documents itself with a file that is not there:
  $doc
  from: $line
  A moved or renamed document is the usual cause."
    done
  done < <(grep -E '^Documentation=' <<<"$rendered" || true)

  if render_unit "$src" | write_file 0644 "/etc/systemd/system/$name"; then
    systemctl daemon-reload
  fi
}

# enable_unit <unit> - enable and start, if it is not already both.
enable_unit() {
  local u="$1"
  if systemctl is-enabled --quiet "$u" 2>/dev/null && systemctl is-active --quiet "$u"; then
    skip "$u already enabled and running"
    return 0
  fi
  systemctl enable --now "$u" >/dev/null 2>&1 || fail "could not enable $u"
  did "$u enabled and started"
}

# backup_stock_firmware - copy the stock MCU image aside, if it is still there.
#
# Returns 0 if a copy now exists, 1 if there was nothing to copy. The CALLER
# decides what that means: bootstrap.sh warns and carries on, 40-purge-arduino.sh
# refuses, because only one of them is about to delete the original.
#
# WHY IT LIVES HERE
# -----------------
# Two callers need the same answer to "where is it, and is it saved?", and the
# answer is not obvious: the path moved between core versions (0.55.2 has it in
# firmwares/, older cores in variants/), which is exactly the kind of detail
# that rots differently in two places.
#
# WHY BOOTSTRAP CALLS IT AT ALL
# -----------------------------
# The image ships in the arduino-* debs, so every factory-fresh board has one -
# and a board that has been provisioned, purged or reflashed may not. The only
# moment it is certain to be there is the beginning, which is not the moment
# anyone thinks to look for it. It is 634 KB. Taking the copy on the way past
# costs nothing and removes the single most annoying way to need a factory
# restore.
backup_stock_firmware() {
  local backup_dir found
  backup_dir="${UNOQ_BACKUP:-$TARGET_HOME/uno-q-backup}"

  if compgen -G "$backup_dir/*.hex" >/dev/null; then
    skip "stock MCU firmware already saved in $backup_dir"
    return 0
  fi

  found="$(find "$TARGET_HOME/.arduino15/packages/arduino/hardware/zephyr" \
    -name '*stm32u585xx*.hex' -type f 2>/dev/null | sort | head -1)"
  [ -n "$found" ] || return 1

  # Runs as root from the provision scripts and as the user from bootstrap, and
  # the copy must end up owned by the user either way - a root-owned backup in
  # $HOME is the thing that bites six months later, when you cannot write to it.
  if [ "$(id -u)" = 0 ]; then
    as_user mkdir -p "$backup_dir" && as_user cp "$found" "$backup_dir/"
  else
    mkdir -p "$backup_dir" && cp "$found" "$backup_dir/"
  fi || return 1

  did "stock MCU firmware saved -> $backup_dir/$(basename "$found")"
  return 0
}

# as_user <cmd>... - run something as the owning user, with a login-ish env.
# The user-level steps install into $TARGET_HOME and must not leave root-owned
# files behind; that is the single most common way a bootstrap half-works.
as_user() {
  runuser -u "$TARGET_USER" -- "$@"
}
