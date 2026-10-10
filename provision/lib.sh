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
disable_unit() {
  local u
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
    did "$u stopped and disabled"
  done
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

# install_unit <source.service> - copy a unit into /etc/systemd/system with the
# repo path and owning user substituted in, then reload only if it changed.
#
# The units are checked in with this board's literal paths so they stay valid,
# readable files. Rewriting them here is what lets the repo be cloned anywhere
# and still produce units that point at the clone.
install_unit() {
  local src="$1" name rendered
  name="$(basename "$src")"
  render_unit() {
    # The home directory by itself, for the units that wait for it to mount.
    # It has to be rewritten separately: the first expression only matches the
    # checkout path, so under any account but arduino those units went on
    # waiting for a /home/arduino that was never going to appear.
    sed -e "s#/home/arduino/two-computers-one-board#$PROJECT#g" \
      -e "s#^RequiresMountsFor=/home/arduino\$#RequiresMountsFor=$TARGET_HOME#" \
      -e "s#^User=arduino\$#User=$TARGET_USER#" \
      -e "s#^Group=arduino\$#Group=$TARGET_USER#" \
      "$src"
  }
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
  rendered="$(render_unit)" || fail "install_unit: could not render $src"
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
  step has not run yet; if it is a script, check the path in $src."
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
  done < <(grep -E '^(ExecStart|ExecStartPre|ExecStartPost|ExecStop|ExecReload)=' <<<"$rendered" || true)

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

  if render_unit | write_file 0644 "/etc/systemd/system/$name"; then
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
