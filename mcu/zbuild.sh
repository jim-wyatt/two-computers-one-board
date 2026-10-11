#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Build a Zephyr application for the Arduino UNO Q (STM32U585) with west.
#
#   ./zbuild.sh                                 # this project's firmware, mcu/app
#   ./zbuild.sh -p always                       # the same, pristine
#   ./zbuild.sh samples/hello_world             # a Zephyr sample
#   ./zbuild.sh ~/some/other/app -p always      # any other app, pristine
#
# Afterwards:
#   ./flash.sh                                  # flashes what the first form built
#
# BUILD DIRECTORY
# ---------------
# This project's own app builds into $WS/build - the path the docs, the VS Code
# tasks and launch.json all name. Any *other* app (a Zephyr sample, a second
# project) builds into $WS/build-<name> instead. Sharing one build directory
# would mean a pristine rebuild on every switch, and would repoint this
# project's compile_commands.json at whatever built last, so clangd would
# quietly index the wrong tree. Override with BUILD_DIR=... if you need to.
#
# Board name is the upstream Zephyr one: arduino_uno_q. No Arduino tooling
# is involved - this is stock Zephyr plus the Zephyr SDK.
set -euo pipefail

WS="${ZEPHYR_WORKSPACE:-$HOME/zephyrproject}"
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
BOARD="${BOARD:-arduino_uno_q}"
SDK="${ZEPHYR_SDK:-$HOME/zephyr-sdk-1.0.1}"

# cmake and ninja are in ~/.local/bin, where provision/user/10-host-tools.sh
# installs them, and west runs both by name. An interactive shell has that
# directory on PATH because env.sh puts it there. Nothing else does: not
# bootstrap.sh on its first run, not a VS Code task, not a systemd unit - and
# there this died with "CMake is not installed or cannot be found", on exactly
# the boards that had never been logged into before.
export PATH="$HOME/.local/bin:$PATH"

export ZEPHYR_TOOLCHAIN_VARIANT=zephyr

# WHERE THE TOOLS ARE, ON A BOARD AND ON A CI RUNNER
# --------------------------------------------------
# On the board west and imgtool live in the workspace's own venv and the SDK is
# in $HOME, and this script used to assume all three. A CI runner has none of
# them there: west and imgtool are on PATH, and the SDK is wherever the setup
# action registered it. So CI could not run this script and carried a second
# copy of the build instead - which is how its first version came to skip
# signing without anything pointing that out.
#
# Each one now falls back rather than assumes. An SDK directory that does not
# exist is not exported at all: pointing ZEPHYR_SDK_INSTALL_DIR at nothing
# breaks a build that would otherwise have found the SDK by itself.
WEST="$WS/.venv/bin/west"
[ -x "$WEST" ] || WEST="$(command -v west || true)"
[ -n "$WEST" ] || {
  echo "no west: not in $WS/.venv/bin and not on PATH" >&2
  exit 1
}
IMGTOOL="$WS/.venv/bin/imgtool"
[ -x "$IMGTOOL" ] || IMGTOOL="$(command -v imgtool || true)"
[ -d "$SDK" ] && export ZEPHYR_SDK_INSTALL_DIR="$SDK"

# No app named means this project's own. It is what nearly every build here is,
# and "build" should not need a path typed after it. A first argument that
# starts with a dash is a west option for that default build, not an app.
case "${1:-}" in
  "" | -*) APP="$PROJECT/mcu/app" ;;
  *)
    APP="$1"
    shift
    ;;
esac

# Accept an app path relative to your cwd, or relative to the Zephyr tree
# (e.g. samples/hello_world). Resolve to absolute BEFORE the cd below - west
# runs from $WS, so a relative path would otherwise resolve against the wrong
# directory and fail with a confusing "source directory does not exist".
if [ -d "$APP" ]; then
  APP="$(cd "$APP" && pwd)"
elif [ -d "$WS/zephyr/$APP" ]; then
  APP="$(cd "$WS/zephyr/$APP" && pwd)"
else
  echo "no such app: $APP" >&2
  exit 1
fi

# See BUILD DIRECTORY above. OWN_APP also gates the compile_commands.json link.
case "$APP/" in
  "$PROJECT"/*)
    BUILD="$WS/build"
    OWN_APP=1
    ;;
  *)
    BUILD="$WS/build-$(basename "$APP")"
    OWN_APP=0
    ;;
esac
BUILD="${BUILD_DIR:-$BUILD}"

cd "$WS"
echo "building $APP for $BOARD"
echo "  build dir: $BUILD"
# A BUILD DIRECTORY LEFT BY A CHECKOUT THAT HAS SINCE MOVED
# ----------------------------------------------------------
# CMake records the source directory a build was configured from, and west
# refuses to reuse one configured from somewhere else:
#
#   ERROR: Build directory ".../build" is for application "/home/x/old-name/mcu/app",
#   but source directory "/home/x/new-name/mcu/app" was specified
#
# That is the right refusal for a stranger's build directory and the wrong one
# here, where the "other" application is this same one before the checkout was
# renamed or moved. bootstrap.sh hit it on the board this project is developed
# on: every provisioning step reported nothing to change, the build died on
# this, and the firmware was quietly not flashed - which is how that board came
# to be running an image two months older than its source.
#
# So a build directory configured from a different path is rebuilt from clean,
# and says so. Only when the caller has not already asked for a pristine build,
# and only by the path recorded in the cache - a missing or unreadable cache is
# west's business, not this script's.
#
# -r as well as -f, and the read is allowed to fail. The test used to be -f
# alone, which a cache this user may not read passes: sed then failed, and under
# `set -e` with pipefail a failed assignment ends the script on the spot - so
# the one case the paragraph above hands to west never reached west, and died
# here with sed's message instead of west's.
STALE=()
if [ -f "$BUILD/CMakeCache.txt" ] && [ -r "$BUILD/CMakeCache.txt" ]; then
  was="$(sed -n 's/^APPLICATION_SOURCE_DIR:PATH=//p' "$BUILD/CMakeCache.txt" 2>/dev/null | head -1)" || was=""
  case " $* " in
    *" -p "* | *" --pristine"*) ;;
    *)
      if [ -n "$was" ] && [ "$was" != "$APP" ]; then
        echo "  build dir was configured for $was"
        echo "  which is not $APP - rebuilding from clean"
        STALE=(-p always)
      fi
      ;;
  esac
fi

"$WEST" build -b "$BOARD" -d "$BUILD" "${STALE[@]}" "$APP" "$@"

# clangd reads compile_commands.json from the workspace root. west writes it
# into build/, so link it into both folders you might have open: the Zephyr
# workspace, and this project.
if [ -f "$BUILD/compile_commands.json" ]; then
  ln -sf "$BUILD/compile_commands.json" "$WS/compile_commands.json"
  if [ "$OWN_APP" = 1 ]; then
    # Only this project's own app may repoint this project's clangd index.
    ln -sf "$BUILD/compile_commands.json" "$PROJECT/compile_commands.json"
    echo "linked compile_commands.json (zephyrproject + $(basename "$PROJECT"))"
  else
    echo "linked compile_commands.json (zephyrproject only - $APP is outside $PROJECT)"
  fi
fi

# If the app is built for MCUboot it links into slot0 and MUST be signed -
# MCUboot will refuse the raw image, and flashing zephyr.hex over the
# bootloader would brick the chain. Sign automatically so that cannot happen.
if grep -q "^CONFIG_BOOTLOADER_MCUBOOT=y" "$BUILD/zephyr/.config" 2>/dev/null; then
  VERSION="${IMAGE_VERSION:-0.0.0+$(date +%s 2>/dev/null || echo 0)}"
  echo "signing for MCUboot (version $VERSION)"
  # Both removed before anything can fail, so that no failure below leaves the
  # PREVIOUS build's signed image sitting there. flash.sh takes
  # zephyr.signed.hex by default, and would flash the old firmware and say so.
  rm -f "$BUILD/zephyr/zephyr.signed.bin" "$BUILD/zephyr/zephyr.signed.hex"
  [ -n "$IMGTOOL" ] || {
    echo "no imgtool: not in $WS/.venv/bin and not on PATH - the image cannot be signed" >&2
    exit 1
  }
  # imgtool directly, not `west sign -t imgtool`: Zephyr has deprecated that,
  # and its replacement rebuilds everything whenever the version changes -
  # see mcu/sign-params.py, which reads the two numbers west sign used to.
  KEY="$WS/bootloader/mcuboot/root-rsa-2048.pem"
  PY="$WS/.venv/bin/python"
  [ -x "$PY" ] || PY="$(command -v python3 || true)"
  HEADER="$(sed -n 's/^CONFIG_ROM_START_OFFSET=//p' "$BUILD/zephyr/.config")"
  # Word-split on purpose: it prints "--align N --slot-size N".
  read -r -a FLASH_ARGS < <("$PY" "$PROJECT/mcu/sign-params.py" "$BUILD" "$WS/zephyr") || true
  if [ -z "$HEADER" ] || [ "${#FLASH_ARGS[@]}" -ne 4 ]; then
    echo "could not work out how to sign this image:" >&2
    echo "  header size (CONFIG_ROM_START_OFFSET): ${HEADER:-<not in .config>}" >&2
    echo "  from the devicetree: ${FLASH_ARGS[*]:-<nothing>}" >&2
    exit 1
  fi
  for ext in bin hex; do
    "$IMGTOOL" sign --version "$VERSION" --header-size "$HEADER" \
      "${FLASH_ARGS[@]}" --key "$KEY" \
      "$BUILD/zephyr/zephyr.$ext" "$BUILD/zephyr/zephyr.signed.$ext" >/dev/null || {
      echo "imgtool could not sign zephyr.$ext" >&2
      exit 1
    }
  done
  # And checked, because this is the image the bootloader will be asked to
  # accept: signed with the key it holds, or it does not boot.
  "$IMGTOOL" verify -k "$KEY" "$BUILD/zephyr/zephyr.signed.bin" >/dev/null || {
    echo "the signed image does not verify against $KEY" >&2
    exit 1
  }
  echo "  -> $(basename "$BUILD")/zephyr/zephyr.signed.bin  (upload with unoq.fota)"
  echo "  -> $(basename "$BUILD")/zephyr/zephyr.signed.hex  (flash to slot0 with flash.sh)"
fi

echo
if [ -f "$BUILD/zephyr/zephyr.signed.hex" ]; then
  # MCUboot build: the unsigned hex must NOT be flashed - it links into slot0
  # but has no image header, so the bootloader will refuse to boot it.
  ls -la "$BUILD/zephyr/zephyr.signed.hex" "$BUILD/zephyr/zephyr.signed.bin" 2>/dev/null || true
  echo
  if [ "$OWN_APP" = 1 ] && [ -z "${BUILD_DIR:-}" ]; then
    echo "flash over SWD :  zflash"
  else
    echo "flash over SWD :  zflash $BUILD/zephyr/zephyr.signed.hex"
  fi
  echo "update over UART:  python -c \"from unoq import fota; \\"
  echo "                     fota.upload('$BUILD/zephyr/zephyr.signed.bin'); \\"
  echo "                     fota.test(); fota.reset()\"   # then fota.confirm()"
else
  ls -la "$BUILD/zephyr/zephyr.hex" "$BUILD/zephyr/zephyr.bin" 2>/dev/null || true
  echo
  echo "flash it:  zflash $BUILD/zephyr/zephyr.hex"
fi
