#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Build MicroPython's Zephyr port for the UNO Q's MCU, as an MCUboot test image
# signed with this project's key.
#
#   mcu/micropython/build.sh             # fetch the pinned tag, build, sign, check
#   mcu/micropython/build.sh -p          # the same, pristine
#   mcu/micropython/build.sh --clean     # and then delete the source and build
#
# The result is $MPY_HOME/zephyr.signed.bin, by default
# /srv/arduino-home/micropython/zephyr.signed.bin on a board whose Zephyr
# workspace lives there. Try it with unoq.fota and DO NOT confirm it: the next
# reset puts this project's firmware back by itself. The script prints how.
# docs/reference/mcu.md, "MicroPython, as a test image", has what works on it
# and what does not.
#
# THE PIN
# -------
# MicroPython is pinned the way Zephyr is: a tag, written once, here. Its
# commit is written beside it, so a tag that moves upstream stops the build
# instead of quietly building something else.
#
# Each MicroPython release builds its Zephyr port against one Zephyr release,
# the ZEPHYR_VERSION in its tools/ci.sh. v1.29.0's is v4.4.0, and this project
# pins v4.4.2: the same minor release, so the same APIs. That is checked on
# every run, against the workspace's own zephyr/VERSION, because moving the
# Zephyr pin is the change most likely to break this without anyone noticing
# (docs/reference/mcu.md, "Upgrading Zephyr"). A different major.minor fails;
# MPY_ZEPHYR_MISMATCH_OK=1 builds anyway, for someone finding out whether it
# still works.
#
# WHERE IT GOES
# -------------
# Beside the Zephyr workspace, not in $HOME: on the board this is developed
# on, $HOME is a small partition of its own and the workspace is a symlink to
# the big one. The source is about 80 MB and a build about 50 MB.
#
# HOW IT IS BUILT AND SIGNED
# --------------------------
# By mcu/zbuild.sh, with the port as the app, so the image is signed exactly
# as this project's firmware is: the same key, header size, alignment, slot
# size, and a version stamped from the clock. That stamp is what gets it past
# the bootloader's downgrade prevention, so it has to be newer than the
# firmware running at the time. Built a while ago and since overtaken by a new
# firmware build, run this again: nothing recompiles, and the image is signed
# with a new stamp.
#
# zbuild links the workspace's compile_commands.json to whatever it built.
# This puts the link back afterwards, so clangd goes on indexing this
# project's firmware.
set -euo pipefail

MICROPYTHON_VERSION="${MICROPYTHON_VERSION:-v1.29.0}"
MICROPYTHON_COMMIT="${MICROPYTHON_COMMIT:-0fd6c573ea815774668bbb16b8e197c8822368b2}"
MICROPYTHON_REPO="${MICROPYTHON_REPO:-https://github.com/micropython/micropython}"

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$HERE/../.." && pwd)"
WS="${ZEPHYR_WORKSPACE:-$HOME/zephyrproject}"

usage() {
  sed -n '7,9p' "$0" | sed 's/^# \{0,1\}//'
}

PRISTINE=()
CLEAN=0
while [ $# -gt 0 ]; do
  case "$1" in
    -p | --pristine) PRISTINE=(-p always) ;;
    --clean) CLEAN=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

[ -d "$WS/zephyr" ] || {
  echo "no Zephyr workspace at $WS (set ZEPHYR_WORKSPACE)" >&2
  exit 1
}
# Beside the workspace, by its real path: ~/zephyrproject may be a symlink to
# the partition with the space, and that is the partition this should use.
MPY_HOME="${MPY_HOME:-$(dirname "$(cd "$WS" && pwd -P)")/micropython}"
SRC="$MPY_HOME/src"
BUILD="$MPY_HOME/build"
OUT="$MPY_HOME/zephyr.signed.bin"
mkdir -p "$MPY_HOME"

# --- fetch the pinned tag ----------------------------------------------------
if [ ! -d "$SRC/.git" ]; then
  echo "fetching MicroPython $MICROPYTHON_VERSION into $SRC"
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$MICROPYTHON_VERSION" "$MICROPYTHON_REPO" "$SRC"
elif [ "$(git -C "$SRC" rev-parse HEAD)" != "$MICROPYTHON_COMMIT" ]; then
  echo "moving $SRC to MicroPython $MICROPYTHON_VERSION"
  git -C "$SRC" fetch -q --depth 1 origin tag "$MICROPYTHON_VERSION"
  git -C "$SRC" -c advice.detachedHead=false checkout -q "$MICROPYTHON_VERSION"
fi
head="$(git -C "$SRC" rev-parse HEAD)"
if [ "$head" != "$MICROPYTHON_COMMIT" ]; then
  cat >&2 <<EOF
MicroPython $MICROPYTHON_VERSION is commit $head,
and this script pins it at $MICROPYTHON_COMMIT.

Either the tag has moved upstream or $SRC has been changed by hand. Delete
$SRC to fetch it again; if the tag really has moved, find out why before
changing the pin.
EOF
  exit 1
fi
# The port's frozen manifest requires a package from micropython-lib, which is
# a submodule. Only that one: the rest are other ports' SDKs.
if grep -q 'path = lib/micropython-lib$' "$SRC/.gitmodules" 2>/dev/null; then
  git -C "$SRC" submodule update -q --init --depth 1 lib/micropython-lib
fi

# --- the Zephyr it was written for ------------------------------------------
# tools/ci.sh:  ZEPHYR_VERSION=v4.4.0
mpy_zephyr="$(sed -n 's/^ZEPHYR_VERSION=v\{0,1\}\([0-9][0-9.]*\).*/\1/p' "$SRC/tools/ci.sh" 2>/dev/null | head -1)"
# zephyr/VERSION:  VERSION_MAJOR = 4 / VERSION_MINOR = 4 / PATCHLEVEL = 2
ver() { sed -n "s/^$1[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p" "$WS/zephyr/VERSION" 2>/dev/null | head -1; }
ws_zephyr="$(ver VERSION_MAJOR).$(ver VERSION_MINOR).$(ver PATCHLEVEL)"
if [ -z "$mpy_zephyr" ] || [ "$ws_zephyr" = ".." ]; then
  echo "could not read the Zephyr versions: MicroPython's ${mpy_zephyr:-?}, the workspace's ${ws_zephyr}" >&2
  exit 1
fi
if [ "${mpy_zephyr%.*}" != "${ws_zephyr%.*}" ]; then
  if [ "${MPY_ZEPHYR_MISMATCH_OK:-0}" = 1 ]; then
    echo "warning: MicroPython $MICROPYTHON_VERSION is built against Zephyr $mpy_zephyr; this is $ws_zephyr" >&2
  else
    cat >&2 <<EOF
MicroPython $MICROPYTHON_VERSION's Zephyr port is built against Zephyr
$mpy_zephyr (its tools/ci.sh), and the workspace is Zephyr $ws_zephyr.

Pin a MicroPython release made for this Zephyr in $0, or set
MPY_ZEPHYR_MISMATCH_OK=1 to try anyway.
EOF
    exit 1
  fi
fi
echo "MicroPython $MICROPYTHON_VERSION, made for Zephyr $mpy_zephyr; building with $ws_zephyr"

# --- build and sign ------------------------------------------------------------
# The overlay REPLACES the port's own board overlay (DTC_OVERLAY_FILE turns
# boards/<board>.overlay off); its comment says why. The board's .conf still
# applies, with mcuboot.conf on top.
#
# A build from other inputs is redone from clean. MicroPython collects its
# interned strings (qstrs) by preprocessing each source file, and a source
# file that has not changed is not preprocessed again, even when the
# devicetree it expands has. Renaming a partition in the overlay then fails
# to compile, ten minutes in, with "MP_QSTR_<new name> undeclared". So the
# inputs are written down beside the build, and a change to any of them makes
# the next build pristine.
FROM="$MICROPYTHON_COMMIT $(cat "$HERE/mcuboot.conf" "$HERE/arduino_uno_q.overlay" | sha256sum | cut -d' ' -f1)"
STAMP="$BUILD/micropython-built-from"
if [ ${#PRISTINE[@]} -eq 0 ] && [ -d "$BUILD" ] && [ "$(cat "$STAMP" 2>/dev/null)" != "$FROM" ]; then
  echo "the last build in $BUILD was from other inputs - rebuilding from clean"
  PRISTINE=(-p always)
fi

LINK="$WS/compile_commands.json"
was_link="$(readlink "$LINK" 2>/dev/null || true)"
rm -f "$OUT" "$STAMP"
status=0
BUILD_DIR="$BUILD" "$PROJECT/mcu/zbuild.sh" "$SRC/ports/zephyr" "${PRISTINE[@]}" -- \
  -DEXTRA_CONF_FILE="$HERE/mcuboot.conf" \
  -DDTC_OVERLAY_FILE="$HERE/arduino_uno_q.overlay" || status=$?
if [ -n "$was_link" ]; then
  ln -sfn "$was_link" "$LINK"
elif [ "$(readlink "$LINK" 2>/dev/null)" = "$BUILD/compile_commands.json" ]; then
  rm -f "$LINK"
fi
[ "$status" = 0 ] || exit "$status"

# --- check what was built ----------------------------------------------------
SIGNED="$BUILD/zephyr/zephyr.signed.bin"
[ -f "$SIGNED" ] || {
  echo "no signed image at $SIGNED - zbuild signs only an MCUboot build (is CONFIG_BOOTLOADER_MCUBOOT=y?)" >&2
  exit 1
}
echo "$FROM" >"$STAMP"

# The REPL has to be where Linux can reach it. Read from the devicetree the
# build actually used, not from the overlay that was meant to set it.
if ! grep -qE '^[[:space:]]*zephyr,console = &lpuart1;' "$BUILD/zephyr/zephyr.dts"; then
  echo "the console is not lpuart1 in $BUILD/zephyr/zephyr.dts - the REPL would not be on /dev/ttyHS1" >&2
  exit 1
fi

# imgtool's own check is the image plus its trailer against the slot. An
# update is written one sector into slot 1 (swap-using-offset), so the
# headroom asked for here is that sector and one more for the trailer.
PY="$WS/.venv/bin/python"
[ -x "$PY" ] || PY="$(command -v python3)"
read -r -a SIGN_ARGS < <("$PY" "$PROJECT/mcu/sign-params.py" "$BUILD" "$WS/zephyr")
slot="${SIGN_ARGS[3]}"
size="$(stat -c %s "$SIGNED")"
SECTOR=8192
if [ "$size" -gt $((slot - 2 * SECTOR)) ]; then
  echo "the image is $size bytes, and an update into the $slot-byte slot can be at most $((slot - 2 * SECTOR))" >&2
  exit 1
fi

IMGTOOL="$WS/.venv/bin/imgtool"
[ -x "$IMGTOOL" ] || IMGTOOL="$(command -v imgtool)"
version="$("$IMGTOOL" verify -k "$WS/bootloader/mcuboot/root-rsa-2048.pem" "$SIGNED" | sed -n 's/^Image version: //p')"

cp "$SIGNED" "$OUT"
if [ "$CLEAN" = 1 ]; then
  rm -rf "$BUILD" "$SRC"
  echo "removed $BUILD and $SRC"
fi

cat <<EOF

MicroPython $MICROPYTHON_VERSION as an MCUboot test image (zbuild's hint above
about fota.confirm() is not for this one: confirming it keeps it):

  $OUT
  version $version, $size bytes of a $slot-byte slot ($((size * 100 / slot))%)
  console on lpuart1, /dev/ttyHS1 at 115200

Try it (stop whatever holds the port first: sudo systemctl stop unoq-cpu-bars):

  hpy -c "from unoq import fota; fota.upload('$OUT'); fota.test(); fota.reset()"
  tio /dev/ttyHS1 -b 115200

Go back - reset WITHOUT confirming. fota.reset() needs this project's
firmware to answer SMP, and MicroPython does not, so reset from its REPL:

  >>> import machine; machine.reset()

MCUboot finds the image unconfirmed and swaps this project's firmware back.
EOF
