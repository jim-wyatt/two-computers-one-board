#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Install everything tools/check.sh needs. Idempotent; safe to re-run.
#
#   ~/two-computers-one-board/tools/install-dev-tools.sh
#
# No sudo and no apt. Debian's shellcheck/shfmt would need root, and this board
# is often used by a non-root user, so those two come from upstream releases
# into ~/.local/bin instead.
#
# Python tooling goes into the project venv rather than a uv tool install,
# because mypy has to import gpiod, pyserial and smpclient to check the code
# that uses them.
#
# Arch is detected rather than assumed: the board is aarch64, but CI runs this
# same script on x86_64.
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
VENV="${UNOQ_VENV:-$PROJECT/.venv}"
BIN="${UNOQ_BIN:-$HOME/.local/bin}"

# Ahead of the system paths, and for the same reason check.sh does it: the
# copies we pin here must be the ones the version checks below see, and the
# ones the gates actually run, rather than a distro or runner-image build that
# happens to be earlier on PATH.
export PATH="$BIN:$PATH"

# PINNED, not "whatever happens to be on PATH", and not "latest".
#
# Both of those were wrong, and the way they were wrong was invisible. A GitHub
# Actions runner ships shellcheck preinstalled, so `command -v shellcheck &&
# skip` meant CI silently linted with the runner's 0.9.0 while the board used
# 0.11.0 - and 0.9.0 enables SC2002 by default where 0.11.0 makes it optional.
# The result was a gate that passed locally and failed in CI with nothing to
# point at, which is exactly the thing check.sh's header promises does not
# happen. Chasing `latest` has the same problem in slow motion: the board
# installs once and CI re-resolves every run, so they drift apart on their own.
#
# Bump these deliberately, and both ends move together.
SHELLCHECK_VERSION="${SHELLCHECK_VERSION:-0.11.0}"
SHFMT_VERSION="${SHFMT_VERSION:-3.14.1}"
BATS_VERSION="${BATS_VERSION:-1.14.0}"
ACTIONLINT_VERSION="${ACTIONLINT_VERSION:-1.7.12}"

case "$(uname -m)" in
  aarch64 | arm64)
    SC_ARCH=aarch64
    SHFMT_ARCH=arm64
    ;;
  x86_64 | amd64)
    SC_ARCH=x86_64
    SHFMT_ARCH=amd64
    ;;
  *)
    echo "unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

mkdir -p "$BIN"

echo "=== Python tooling -> $VENV ==="
[ -x "$VENV/bin/python" ] || uv venv "$VENV"
# Installed from the [dev] and [docs] extras so the versions live in
# pyproject.toml. [docs] is here as well as in provisioning because the docs
# build is a quality gate (tools/check.sh docs) - a broken link should fail for
# whoever is editing, not only on the board.
uv pip install --python "$VENV/bin/python" -q -c "$PROJECT/python/requirements-lock.txt" \
  -b "$PROJECT/python/requirements-lock.txt" \
  -e "$PROJECT/python[dev,docs]"
echo "  ruff $("$VENV"/bin/ruff --version | awk '{print $2}'), mypy $("$VENV"/bin/mypy --version | awk '{print $2}'), mkdocs $("$VENV"/bin/mkdocs --version | awk '{print $3}')"

echo "=== shellcheck $SHELLCHECK_VERSION -> $BIN ==="
have=""
command -v shellcheck >/dev/null 2>&1 &&
  have="$(shellcheck --version | awk '/^version:/ {print $2}')"
if [ "$have" = "$SHELLCHECK_VERSION" ]; then
  echo "  already $SHELLCHECK_VERSION"
else
  [ -n "$have" ] &&
    echo "  found $have on PATH, installing $SHELLCHECK_VERSION over it (CI and local must match)"
  tmp=$(mktemp -d)
  # -f so an HTTP error is an error, rather than an HTML page piped into tar.
  curl -fsSL "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.${SC_ARCH}.tar.xz" |
    tar -xJ -C "$tmp" || {
    rm -rf "$tmp"
    echo "  could not download shellcheck v$SHELLCHECK_VERSION" >&2
    exit 1
  }
  install -m 0755 "$tmp/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" "$BIN/shellcheck"
  rm -rf "$tmp"
  echo "  installed $("$BIN/shellcheck" --version | awk '/^version:/ {print $2}')"
fi

echo "=== shfmt $SHFMT_VERSION -> $BIN ==="
have=""
command -v shfmt >/dev/null 2>&1 && have="$(shfmt --version | tr -d v)"
if [ "$have" = "$SHFMT_VERSION" ]; then
  echo "  already $SHFMT_VERSION"
else
  [ -n "$have" ] &&
    echo "  found $have on PATH, installing $SHFMT_VERSION over it (CI and local must match)"
  curl -fsSL "https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}/shfmt_v${SHFMT_VERSION}_linux_${SHFMT_ARCH}" \
    -o "$BIN/shfmt" || {
    echo "  could not download shfmt v$SHFMT_VERSION" >&2
    exit 1
  }
  chmod +x "$BIN/shfmt"
  echo "  installed $("$BIN/shfmt" --version)"
fi

echo "=== bats $BATS_VERSION -> $BIN ==="
# The shell test runner. Pinned and installed from source like the two above,
# rather than taken from apt: Debian ships 1.11.1, and a runner that differs
# between the board and CI has the same problem a formatter does.
#
# bats is pure shell, so there is no architecture to pick - the same tarball
# works on the board's aarch64 and on an x86_64 runner.
have=""
command -v bats >/dev/null 2>&1 && have="$(bats --version | awk '{print $2}')"
if [ "$have" = "$BATS_VERSION" ]; then
  echo "  already $BATS_VERSION"
else
  [ -n "$have" ] &&
    echo "  found $have on PATH, installing $BATS_VERSION over it (CI and local must match)"
  tmp=$(mktemp -d)
  # tar's stderr is NOT silenced, deliberately and like the shellcheck block
  # above: a truncated or corrupt download fails inside tar, and hiding that
  # message leaves "could not download bats" as the only clue to an extraction
  # problem. -f on curl so an HTTP error page is an error rather than something
  # tar is asked to unpack.
  curl -fsSL "https://github.com/bats-core/bats-core/archive/refs/tags/v${BATS_VERSION}.tar.gz" |
    tar -xz -C "$tmp" || {
    rm -rf "$tmp"
    echo "  could not download or unpack bats v$BATS_VERSION" >&2
    exit 1
  }
  # install.sh lays out bin/ and libexec/ under the prefix; $BIN is $prefix/bin,
  # so hand it the parent.
  "$tmp/bats-core-${BATS_VERSION}/install.sh" "$(dirname "$BIN")" >/dev/null || {
    rm -rf "$tmp"
    echo "  could not install bats v$BATS_VERSION into $(dirname "$BIN")" >&2
    exit 1
  }
  rm -rf "$tmp"
  echo "  installed $("$BIN/bats" --version)"
fi

echo "=== actionlint $ACTIONLINT_VERSION -> $BIN ==="
# Reads .github/workflows the way GitHub will, and runs shellcheck over every
# `run:` block. A workflow is the one kind of file here that could only be
# tested by pushing it and waiting, which is how an action tag that did not
# exist got as far as main.
have=""
command -v actionlint >/dev/null 2>&1 && have="$(actionlint -version | head -1)"
if [ "$have" = "$ACTIONLINT_VERSION" ]; then
  echo "  already $ACTIONLINT_VERSION"
else
  [ -n "$have" ] &&
    echo "  found $have on PATH, installing $ACTIONLINT_VERSION over it (CI and local must match)"
  tmp=$(mktemp -d)
  # shfmt's arch names, not shellcheck's: amd64 and arm64.
  curl -fsSL "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_${SHFMT_ARCH}.tar.gz" |
    tar -xz -C "$tmp" actionlint || {
    rm -rf "$tmp"
    echo "  could not download or unpack actionlint v$ACTIONLINT_VERSION" >&2
    exit 1
  }
  install -m 0755 "$tmp/actionlint" "$BIN/actionlint"
  rm -rf "$tmp"
  echo "  installed $("$BIN/actionlint" -version | head -1)"
fi

echo
echo "Done. Run the gates with:  $PROJECT/tools/check.sh"
echo "Install the pre-commit hook with:  $PROJECT/tools/install-hooks.sh"
command -v shellcheck >/dev/null 2>&1 ||
  echo "NOTE: $BIN is not on your PATH - env.sh adds it."
