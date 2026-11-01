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

# What each pinned download must hash to. The versions above pinned which
# release to ask for, and nothing checked what came back: whatever bytes
# arrived were installed into ~/.local/bin and run by every gate, here and in
# CI. A bump is now two edits: the version, and its lines here.
#
# tool        version  arch     sha256
#
# The shellcheck, shfmt and actionlint lines are release assets, and agree with the
# digests GitHub lists for them (and with actionlint's own checksums.txt).
# bats publishes no assets, so its line is the hash of the source archive
# GitHub generates for the tag. GitHub keeps those stable; if it ever does not,
# this fails loudly instead of installing something else.
#
# A version chosen with one of the variables above has no line here, so it is
# refused unless its hash is given too: SHELLCHECK_SHA256=..., SHFMT_SHA256=...,
# BATS_SHA256=..., ACTIONLINT_SHA256=...
DEV_TOOL_SUMS='
shellcheck  0.11.0   aarch64  12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588
shellcheck  0.11.0   x86_64   8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
shfmt       3.14.1   arm64    5f2db09dae91fca848f7adbdd014632e921a383863a2ad7e0450ad3aba0c6489
shfmt       3.14.1   amd64    76e77641faa025814b77f153b29796b8e6fa2fca03e0c76a691608b86c7ea7bf
bats        1.14.0   any      bb537b70b15b732f6d8827dd6578e3d8ce166636ce1f18ea9a074184fcce9177
actionlint  1.7.12   arm64    325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6
actionlint  1.7.12   amd64    8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
'

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

# fetch <tool> <version> <arch> <url> <file> - download to <file>, and keep it
# only if it hashes to what is recorded for that tool, version and arch.
fetch() {
  local tool="$1" version="$2" arch="$3" url="$4" out="$5" var want got
  var="$(tr '[:lower:]' '[:upper:]' <<<"$tool")_SHA256"
  want="${!var:-}"
  [ -n "$want" ] || want="$(awk -v t="$tool" -v v="$version" -v a="$arch" \
    '$1 == t && $2 == v && $3 == a { print $4 }' <<<"$DEV_TOOL_SUMS")"
  if [ -z "$want" ]; then
    echo "  no checksum recorded for $tool $version ($arch): add its line to DEV_TOOL_SUMS, or set $var" >&2
    return 1
  fi
  # -f so an HTTP error is an error, rather than an HTML page saved as the tool.
  curl -fsSL "$url" -o "$out" || {
    echo "  could not download $tool v$version" >&2
    return 1
  }
  got="$(sha256sum "$out" | cut -d' ' -f1)"
  if [ "$got" != "$want" ]; then
    rm -f "$out"
    echo "  $tool v$version did not match its checksum - not installed" >&2
    echo "    expected $want" >&2
    echo "    got      $got" >&2
    echo "    from     $url" >&2
    return 1
  fi
}

echo "=== Python tooling -> $VENV ==="
[ -x "$VENV/bin/python" ] || uv venv "$VENV"
# Installed from the [dev] and [docs] extras so the versions live in
# pyproject.toml. [docs] is here as well as in provisioning because the docs
# build is a quality gate (tools/check.sh docs) - a broken link should fail for
# whoever is editing, not only on the board. [ble] because the tests import
# unoq.blesensor, which imports jeepney.
uv pip install --python "$VENV/bin/python" -q -c "$PROJECT/python/requirements-lock.txt" \
  -b "$PROJECT/python/requirements-lock.txt" \
  -e "$PROJECT/python[dev,docs,ble]"
echo "  ruff $("$VENV"/bin/ruff --version | awk '{print $2}'), mypy $("$VENV"/bin/mypy --version | awk '{print $2}'), zensical $("$VENV"/bin/zensical --version | awk '{print $NF}')"

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
  if ! { fetch shellcheck "$SHELLCHECK_VERSION" "$SC_ARCH" \
    "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.${SC_ARCH}.tar.xz" \
    "$tmp/shellcheck.tar.xz" &&
    tar -xJ -C "$tmp" -f "$tmp/shellcheck.tar.xz"; }; then
    rm -rf "$tmp"
    echo "  could not install shellcheck v$SHELLCHECK_VERSION" >&2
    exit 1
  fi
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
  tmp=$(mktemp -d)
  # Into a temporary file first, not straight over $BIN/shfmt: a download that
  # failed its check must leave the old one where it was.
  fetch shfmt "$SHFMT_VERSION" "$SHFMT_ARCH" \
    "https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}/shfmt_v${SHFMT_VERSION}_linux_${SHFMT_ARCH}" \
    "$tmp/shfmt" || {
    rm -rf "$tmp"
    echo "  could not install shfmt v$SHFMT_VERSION" >&2
    exit 1
  }
  install -m 0755 "$tmp/shfmt" "$BIN/shfmt"
  rm -rf "$tmp"
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
  # problem.
  if ! { fetch bats "$BATS_VERSION" any \
    "https://github.com/bats-core/bats-core/archive/refs/tags/v${BATS_VERSION}.tar.gz" \
    "$tmp/bats.tar.gz" &&
    tar -xz -C "$tmp" -f "$tmp/bats.tar.gz"; }; then
    rm -rf "$tmp"
    echo "  could not download or unpack bats v$BATS_VERSION" >&2
    exit 1
  fi
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
  if ! { fetch actionlint "$ACTIONLINT_VERSION" "$SHFMT_ARCH" \
    "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_${SHFMT_ARCH}.tar.gz" \
    "$tmp/actionlint.tar.gz" &&
    tar -xz -C "$tmp" -f "$tmp/actionlint.tar.gz" actionlint; }; then
    rm -rf "$tmp"
    echo "  could not download or unpack actionlint v$ACTIONLINT_VERSION" >&2
    exit 1
  fi
  install -m 0755 "$tmp/actionlint" "$BIN/actionlint"
  rm -rf "$tmp"
  echo "  installed $("$BIN/actionlint" -version | head -1)"
fi

echo
echo "Done. Run the gates with:  $PROJECT/tools/check.sh"
echo "Install the pre-commit hook with:  $PROJECT/tools/install-hooks.sh"
command -v shellcheck >/dev/null 2>&1 ||
  echo "NOTE: $BIN is not on your PATH - env.sh adds it."
