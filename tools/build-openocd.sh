#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Rebuild the OpenOCD that flashes this board's MCU, from source.
#
#   sudo bash ~/two-computers-one-board/tools/build-openocd.sh              # build + self-test
#   sudo bash ~/two-computers-one-board/tools/build-openocd.sh --promote    # ...and replace /opt/openocd
#
# WHY
# ---
# /opt/openocd is owned by no Debian package - `dpkg -S /opt/openocd` finds
# nothing. It was dropped in by an install script, so apt can never reinstall
# it, and it is the ONLY way to flash the STM32U585 (the MPU bit-bangs SWD via
# libgpiod; there is no external probe). That made it a single point of failure.
# This script removes that dependency.
#
# SOURCE
# ------
# Upstream openocd-org/openocd **master**, not a fork and not a release tag.
#
#   - libgpiod v2 (this board has libgpiod.so.3) is supported on master:
#     configure.ac does PKG_CHECK_MODULES([LIBGPIOD], [libgpiod >= 2.0]) and
#     linuxgpiod.c uses the v2 API, falling back to v1. Master is required -
#     the newest tag is still v0.12.0 (2023), which predates that support, so
#     `apt install openocd` (0.12.0) will NOT work.
#   - The STM32U5 flash driver (`stm32l4x`) is upstream.
#   - The adapter .cfg that names this board's SWD pins is kept in this repo
#     (mcu/board-support/); the STM32 target scripts come from OpenOCD itself.
#
# The pinned commit is for reproducibility; override with OPENOCD_COMMIT, or
# set it to `master` to track the tip.
set -euo pipefail

COMMIT="${OPENOCD_COMMIT:-da3920b0a52d}"
REPO="${OPENOCD_REPO:-https://github.com/openocd-org/openocd.git}"
PREFIX="${OPENOCD_PREFIX:-/opt/openocd-rebuilt}"
SRC="${OPENOCD_SRC:-/tmp/openocd-src}"
HERE="$(cd "$(dirname "$0")" && pwd)"
GPIOD_CFG="${GPIOD_CFG:-$HERE/../mcu/board-support/openocd_gpiod.cfg}"
PROMOTE=0
[ "${1:-}" = "--promote" ] && PROMOTE=1

echo "== 1/6 build dependencies =="
apt-get update -qq
apt-get install -y --no-install-recommends \
  build-essential git autoconf automake libtool pkg-config texinfo \
  libgpiod-dev libusb-1.0-0-dev libhidapi-dev libftdi1-dev

echo "== 2/6 source: $REPO @ $COMMIT =="
rm -rf "$SRC"
git clone "$REPO" "$SRC"
git -C "$SRC" checkout "$COMMIT"

# Only jimtcl is required (OpenOCD's embedded TCL interpreter). libjaylink is
# the J-Link probe driver - we bit-bang SWD over GPIO, and --disable-jlink
# below means it is never compiled, so do not clone it. Upstream hosts jimtcl
# on GitHub, so no mirror juggling is needed.
git -C "$SRC" submodule update --init jimtcl

echo "== 3/6 configure =="
cd "$SRC"
./bootstrap
# linuxgpiod is the adapter this board needs; the rest are off to keep the
# build small and dependency-light.
./configure --prefix="$PREFIX" \
  --enable-linuxgpiod \
  --disable-jlink \
  --disable-werror \
  --disable-doxygen-html \
  --disable-doxygen-pdf

echo "== 4/6 build =="
make -j"$(nproc)"
make install

echo "== 5/6 install the board's config files =="
# openocd_gpiod.cfg is kept in this repository, adapted from the one on
# Arduino's stock image - it names the UNO Q's SWD pins, which are documented
# nowhere upstream. The two stm32 target scripts are OpenOCD's
# own (GPL-2.0-or-later) and are taken from the tree we just built rather than
# vendored here, so they always match the binary instead of drifting from a
# copy taken at some past version.
install -m 0644 "$GPIOD_CFG" "$PREFIX/openocd_gpiod.cfg"
echo "  openocd_gpiod.cfg (this repo)"
for f in stm32u5x.cfg stm32x5x_common.cfg; do
  if [ ! -f "$SRC/tcl/target/$f" ]; then
    echo "missing $f in the OpenOCD source tree ($SRC/tcl/target)" >&2
    exit 1
  fi
  install -m 0644 "$SRC/tcl/target/$f" "$PREFIX/$f"
  echo "  $f (from openocd@$COMMIT)"
done

echo "== 6/6 self-test: can it reach the MCU over SWD? =="
# BOOT0 / link-enable must be sane first, or this proves nothing. Derived from
# $HERE and $SUDO_USER rather than hardcoded: this runs under sudo, so
# SUDO_USER is the invoking account - the one that is in the `gpiod` group.
# Hardcoding both meant a checkout anywhere but /home/arduino/two-computers-one-board silently
# self-tested with BOOT0 unset (the `|| true` hides it) and failed confusingly.
LINK_UP="$HERE/../mcu/link-up.sh"
sudo -u "${SUDO_USER:-$(stat -c %U "$HERE")}" "$LINK_UP" || true
if "$PREFIX/bin/openocd" -s "$PREFIX" -s "$PREFIX/share/openocd/scripts" \
  -f "$PREFIX/openocd_gpiod.cfg" -c "init" -c "targets" -c "shutdown" 2>&1 |
  tee /tmp/openocd-selftest.log | grep -q "Cortex-M33"; then
  echo
  echo "SELF-TEST PASSED - the rebuilt binary talks to the MCU."
  grep -E "DPIDR|Cortex-M33" /tmp/openocd-selftest.log | sed 's/^/  /'
else
  echo "SELF-TEST FAILED - see /tmp/openocd-selftest.log" >&2
  echo "/opt/openocd was NOT touched." >&2
  exit 1
fi

echo
if [ "$PROMOTE" = "1" ]; then
  STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo backup)"
  echo "== promoting to /opt/openocd (old one -> /opt/openocd.$STAMP) =="
  [ -d /opt/openocd ] && mv /opt/openocd "/opt/openocd.$STAMP"
  cp -a "$PREFIX" /opt/openocd
  echo "done. Previous install kept at /opt/openocd.$STAMP"
  echo "Verify:  ~/two-computers-one-board/mcu/flash.sh ~/zephyrproject/build/zephyr/zephyr.signed.hex"
else
  echo "Built and verified at $PREFIX (nothing replaced)."
  echo "To use it in place of the unpackaged one:"
  echo "    sudo bash $0 --promote"
  echo "Or point the tooling at it without replacing anything:"
  echo "    export OCD_ROOT=$PREFIX"
fi
