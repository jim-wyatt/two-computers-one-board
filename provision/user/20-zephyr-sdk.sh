#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# The Zephyr SDK (arm-zephyr-eabi toolchain). Runs as YOU, not root.
#
#   bash ~/two-computers-one-board/provision/user/20-zephyr-sdk.sh
#
# Idempotent, and resumable: the download is ~1 GB and lands in a temp file
# that is only moved into place once it has been verified, so an interrupted
# run does not leave a half-SDK that later steps would try to use.
#
# Only the arm-zephyr-eabi toolchain is installed. The full SDK carries a dozen
# architectures this board will never build for.
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"

[ "$(id -u)" = 0 ] && fail "run this WITHOUT sudo - it installs into \$HOME"

# The SDK's setup.sh refuses to start unless cmake is on PATH, and cmake is in
# ~/.local/bin, where 10-host-tools.sh put it a minute ago. On a board that has
# been logged into before, ~/.profile adds that directory. On a fresh one it did
# not exist at login, so nothing added it - and this was the one user step that
# did not add it itself. bootstrap.sh therefore died here on exactly the boards
# it is written for, and passed on every board it had been developed on.
export PATH="$HOME/.local/bin:$PATH"

SDK_VERSION="${ZEPHYR_SDK_VERSION:-1.0.1}"
SDK_DIR="$HOME/zephyr-sdk-$SDK_VERSION"
TOOLCHAIN="arm-zephyr-eabi"

case "$(uname -m)" in
  aarch64 | arm64) SDK_ARCH=aarch64 ;;
  x86_64 | amd64) SDK_ARCH=x86_64 ;;
  *) fail "unsupported architecture: $(uname -m)" ;;
esac

# WHERE THE COMPILER ACTUALLY IS
# ------------------------------
# SDK 1.0.1 nests the toolchains one level down, in gnu/:
#
#   ~/zephyr-sdk-1.0.1/gnu/arm-zephyr-eabi/bin/arm-zephyr-eabi-gcc
#
# Earlier SDKs put them at the top level, which is the path this script used to
# name in both places it looks. That was wrong twice over. The verify step at
# the end failed on a perfectly good install - setup.sh had just reported
# success - and, worse, the "already installed?" check above the download used
# the same path, so it never matched and every re-run downloaded and extracted
# the whole SDK again. A script whose header promises idempotence.
#
# So the path is resolved rather than assumed, and both layouts are accepted:
# the version is overridable with ZEPHYR_SDK_VERSION, and which layout a given
# version uses is not this script's business to hardcode.
toolchain_gcc() {
  local d
  for d in "$SDK_DIR/gnu/$TOOLCHAIN" "$SDK_DIR/$TOOLCHAIN"; do
    if [ -x "$d/bin/$TOOLCHAIN-gcc" ]; then
      echo "$d/bin/$TOOLCHAIN-gcc"
      return 0
    fi
  done
  return 1
}

step "Zephyr SDK $SDK_VERSION ($SDK_ARCH)"
if GCC="$(toolchain_gcc)"; then
  skip "$SDK_DIR already has $TOOLCHAIN"
else
  # Checked BEFORE the download, not discovered after it: setup.sh needs both,
  # and finding that out costs 100 MB and several minutes if it is left to it.
  command -v cmake >/dev/null 2>&1 ||
    fail "cmake is not on PATH - run provision/user/10-host-tools.sh first"
  command -v wget >/dev/null 2>&1 ||
    fail "wget is not installed - sudo apt-get install -y wget
        (provision/20-dev-tools.sh does this; setup.sh downloads the toolchain with it)"

  BASE="https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v$SDK_VERSION"
  TARBALL="zephyr-sdk-${SDK_VERSION}_linux-${SDK_ARCH}_minimal.tar.xz"
  TMP="$(mktemp -d)"
  # shellcheck disable=SC2064  # $TMP must expand now, not at trap time
  trap "rm -rf '$TMP'" EXIT

  echo "  downloading $TARBALL (~100 MB minimal + toolchain)..."
  curl -fL --progress-bar "$BASE/$TARBALL" -o "$TMP/sdk.tar.xz" ||
    fail "download failed - check network access"

  # The release publishes a sha256 for every file in it. This catches a
  # truncated or corrupted download before it is unpacked into $HOME and its
  # setup.sh run - it used to be extracted and executed on trust. It is the
  # same server vouching for its own file, so it is a check on the transfer,
  # not on the publisher. A version with no published sum (an override, a
  # pre-release) is unpacked anyway, and says so.
  echo "  verifying..."
  want=""
  curl -fsSL "$BASE/sha256.sum" -o "$TMP/sha256.sum" 2>/dev/null &&
    want="$(awk -v f="$TARBALL" '$2 == f {print $1}' "$TMP/sha256.sum" 2>/dev/null)"
  if [ -n "$want" ]; then
    got="$(sha256sum "$TMP/sdk.tar.xz" | cut -d' ' -f1)"
    [ "$got" = "$want" ] ||
      fail "checksum mismatch for $TARBALL - not unpacking it
        published: $want
        received:  $got
        Run this again; if it repeats, the download is being altered on the way."
    echo "  checksum matches the one published with the release"
  else
    warn "no published checksum found for $TARBALL - unpacking it unverified"
  fi

  echo "  extracting..."
  tar -xJf "$TMP/sdk.tar.xz" -C "$HOME" || fail "extract failed"
  [ -d "$SDK_DIR" ] || fail "expected $SDK_DIR after extract, not found"
  did "SDK unpacked to $SDK_DIR"

  echo "  installing the $TOOLCHAIN toolchain..."
  # -c registers the SDK with CMake's package registry, which is how west
  # finds it without ZEPHYR_SDK_INSTALL_DIR being set in every shell.
  #
  # Its output is kept and shown on failure. It used to go to /dev/null, which
  # turned "requires 'cmake' to be installed and available in the PATH" - a
  # complete diagnosis - into "SDK setup.sh failed", which is none.
  if ! (cd "$SDK_DIR" && ./setup.sh -t "$TOOLCHAIN" -c) >"$TMP/setup.log" 2>&1; then
    tail -n 20 "$TMP/setup.log" | sed 's/^/    /' >&2
    fail "SDK setup.sh failed - its own output is above"
  fi
  did "$TOOLCHAIN installed"
fi

step "verify"
# Re-resolved rather than reusing the value from above, because the install
# branch is what created it and the whole point of this step is to check that
# what setup.sh reported actually landed on disk.
if GCC="$(toolchain_gcc)"; then
  skip "$("$GCC" --version | head -1)"
  skip "at $GCC"
else
  fail "no $TOOLCHAIN-gcc under $SDK_DIR after install - looked in gnu/$TOOLCHAIN
        and $TOOLCHAIN. If the SDK has moved things again, find it with:
          find $SDK_DIR -name '$TOOLCHAIN-gcc'"
fi

summary
