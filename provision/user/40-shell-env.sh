#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Wire env.sh into your shell, and install the git pre-commit hook.
# Runs as YOU, not root.
#
#   bash ~/two-computers-one-board/provision/user/40-shell-env.sh
#
# Idempotent: the ~/.bashrc line is added once and matched on the marker, not
# on the literal path, so a re-run after moving the checkout updates it rather
# than appending a second source line.
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"

[ "$(id -u)" = 0 ] && fail "run this WITHOUT sudo - it edits your ~/.bashrc"

MARKER="# unoq hybrid dev environment"
BASHRC="$HOME/.bashrc"

step "$BASHRC"
LINE="$MARKER
source $PROJECT/env.sh"
if grep -qF "$MARKER" "$BASHRC" 2>/dev/null; then
  # Present - check it still points at this checkout.
  if grep -qF "source $PROJECT/env.sh" "$BASHRC"; then
    skip "already sources $PROJECT/env.sh"
  else
    # Rewrite the marked line rather than appending a competing one - and
    # only the marked line. This was a sed over every `source .../env.sh` in
    # the file, so another project's env.sh was repointed at this one too.
    # The line this step writes is the one straight after its marker.
    tmp="$(mktemp)"
    awk -v m="$MARKER" -v new="source $PROJECT/env.sh" '
      prev == m && /^source .*\/env\.sh$/ { $0 = new }
      { print; prev = $0 }' "$BASHRC" >"$tmp" &&
      cat "$tmp" >"$BASHRC" # through the same inode, keeping its mode and owner
    rm -f "$tmp"
    if grep -qxF "source $PROJECT/env.sh" "$BASHRC"; then
      did "repointed the env.sh line at $PROJECT"
    else
      warn "found \"$MARKER\" in $BASHRC but no source line after it to repoint;"
      warn "  add this under it by hand:  source $PROJECT/env.sh"
    fi
  fi
else
  printf '\n%s\n' "$LINE" >>"$BASHRC"
  did "added env.sh to $BASHRC"
fi

step "git pre-commit hook"
# Overridable so the tests do not install a hook in the checkout running them.
GIT_DIR_HERE="${UNOQ_GIT_DIR:-$PROJECT/.git}"
if [ -L "$GIT_DIR_HERE/hooks/pre-commit" ]; then
  skip "hook already installed"
elif [ -d "$GIT_DIR_HERE" ]; then
  # A failure is a warning and only a warning. It used to be followed by
  # `did` regardless, so a hook that was not installed was also reported as
  # installed.
  if "$PROJECT/tools/install-hooks.sh" >/dev/null 2>&1; then
    did "pre-commit hook -> tools/check.sh --fast"
  else
    warn "install-hooks.sh failed (a non-symlink hook may already exist)"
  fi
else
  skip "not a git checkout - no hook to install"
fi

step "verify"
# `shopt -s expand_aliases` is what makes this check able to pass at all.
#
# Bash only expands aliases in interactive shells. In a script - which is every
# way this ever runs - the alias builtin still records zbuild, but `command -v`
# will not report it, so the test failed on a perfectly good env.sh and told the
# reader to go and check it by hand. It had never once succeeded.
#
# It is worth being precise about why it looked fine when tested interactively:
# by then ~/.bashrc has already sourced env.sh, so zbuild is defined in the
# testing shell before the subshell below ever runs, and the check passes for a
# reason that has nothing to do with what it is checking.
#
# The three things asserted are one of each kind env.sh defines - an alias, a
# function, an export - because they fail independently: a syntax error early in
# the file leaves the later ones undefined, and the aliases in particular now
# depend on resolving the checkout path correctly.
# shellcheck source=/dev/null
if (
  set +u
  shopt -s expand_aliases
  . "$PROJECT/env.sh" &&
    command -v zbuild >/dev/null 2>&1 &&
    command -v mcucon >/dev/null 2>&1 &&
    [ -n "$ZEPHYR_BASE" ]
); then
  skip "env.sh defines zbuild, mcucon and ZEPHYR_BASE"
  # The aliases bake in the checkout path at source time, so a stale ~/.bashrc
  # pointing at a previous clone is worth catching here rather than the first
  # time zbuild runs the wrong tree.
  ALIAS_TARGET="$(
    set +u
    shopt -s expand_aliases
    . "$PROJECT/env.sh" >/dev/null 2>&1
    alias zbuild 2>/dev/null | sed "s/.*='\{0,1\}//; s/'\{0,1\}\$//"
  )"
  case "$ALIAS_TARGET" in
    "$PROJECT"/*) skip "zbuild -> $ALIAS_TARGET" ;;
    *) warn "zbuild points at $ALIAS_TARGET, not this checkout ($PROJECT)" ;;
  esac
else
  warn "env.sh did not source cleanly, or left zbuild/mcucon/ZEPHYR_BASE unset"
  warn "  reproduce with: bash --norc --noprofile -c '. $PROJECT/env.sh'"
fi

step "VS Code machine settings"
# The board-wide half of the editor configuration - watcher excludes for the
# ~4 GB of Zephyr checkout and toolchain, and the auto-update switch the README
# says is deliberately off.
#
# It has to be installed rather than merely documented, because it lives under
# ~/.vscode-server, which a factory restore wipes. Every setting in it is one
# whose default costs you something rather than breaking anything, so nothing
# announces its absence: the board just runs hotter, swaps sooner, and updates
# extensions in the background while you build.
#
# Written only if missing, like /etc/default/unoq-usb: it is a file a person is
# expected to edit, and re-provisioning must not undo that.
# REVERT: rm ~/.vscode-server/data/Machine/settings.json
VSCODE_MACHINE="$HOME/.vscode-server/data/Machine/settings.json"
if [ ! -d "$HOME/.vscode-server" ]; then
  skip "no ~/.vscode-server (VS Code Remote has not connected to this board yet)"
elif [ -f "$VSCODE_MACHINE" ]; then
  skip "$VSCODE_MACHINE exists - leaving it alone"
else
  mkdir -p "$(dirname "$VSCODE_MACHINE")"
  if cp "$PROVISION_DIR/user/vscode-machine-settings.json" "$VSCODE_MACHINE"; then
    did "wrote $VSCODE_MACHINE (reload the window to apply)"
  else
    warn "could not write $VSCODE_MACHINE"
  fi
fi

summary
echo "Open a new shell, or:  source $PROJECT/env.sh"
