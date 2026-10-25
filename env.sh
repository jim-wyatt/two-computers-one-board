# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Development environment for the Arduino UNO Q (MPU + STM32U585 MCU).
#
#   source ~/two-computers-one-board/env.sh
#
# Add that line to ~/.bashrc to have it always available.
#
# This file is sourced, never executed, so it has no shebang - the directive
# below is what tells shellcheck which shell to assume.
# shellcheck shell=bash

# Where this file lives. The helpers below used to name a fixed path literally,
# which is only right if you cloned to exactly that path. A `git clone` with no
# destination puts the checkout wherever the repository is named, and then
# zbuild, zflash, hpy and mcucon all point at a directory that does not exist,
# while everything else keeps working. 40-shell-env.sh already points ~/.bashrc
# at the real checkout; this makes the rest of the file agree with it.
#
# NO FALLBACK PATH. There used to be one - `${BASH_SOURCE[0]:-$HOME/<repo>/env.sh}`
# - and it quietly reintroduced the exact assumption the paragraph above says
# was removed: sourced from a shell that does not set BASH_SOURCE, it would
# guess a path, be wrong, and every helper would point somewhere that does not
# exist with nothing to say why. Refusing is the honest answer, because there
# is no way to work out where this file is without the shell's help.
if [ -z "${BASH_SOURCE[0]:-}" ]; then
  echo "env.sh: source me from bash - I cannot find myself otherwise" >&2
else
  UNOQ_PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  export UNOQ_PROJECT
fi

# uv, west, cmake, ninja (installed as uv tools) + on-board OpenOCD
export PATH="$HOME/.local/bin:/opt/openocd/bin:$PATH"

# Zephyr / west
#
# From the same settings the provisioning steps and mcu/*.sh read, not from
# paths written out here: with ZEPHYR_WORKSPACE or an SDK override set, this
# exported directories that did not exist, and an SDK directory that does not
# exist is one the build will not look past (see mcu/zbuild.sh). The SDK
# version's default is the pin in provision/user/25-zephyr-sdk.sh, and
# tools/check-zephyr-pin.sh fails if they differ.
_unoq_ws="${ZEPHYR_WORKSPACE:-$HOME/zephyrproject}"
_unoq_sdk="${ZEPHYR_SDK:-$HOME/zephyr-sdk-${ZEPHYR_SDK_VERSION:-1.0.1}}"
export ZEPHYR_BASE="$_unoq_ws/zephyr"
if [ -d "$_unoq_sdk" ]; then
  export ZEPHYR_SDK_INSTALL_DIR="$_unoq_sdk"
fi
export ZEPHYR_TOOLCHAIN_VARIANT=zephyr
export BOARD=arduino_uno_q

unset _unoq_ws _unoq_sdk

# west lives in the workspace venv, not on the global PATH. The workspace is
# the directory ZEPHYR_BASE is in.
west() { "${ZEPHYR_BASE%/zephyr}/.venv/bin/west" "$@"; }

# The three aliases below are double-quoted on purpose, so $UNOQ_PROJECT is
# resolved once here rather than left to expand when you run them. That is what
# SC2139 warns about, and it is the behavior we want: the alias should keep
# pointing at the checkout it was sourced from even if $HOME or the working
# directory changes underneath it. Disabled per line, not per file, so a future
# alias that genuinely wants late expansion still gets flagged.

# MPU-side Python (gpiod, smbus2, pyserial, spidev)
# shellcheck disable=SC2139
alias hpy="$UNOQ_PROJECT/.venv/bin/python"

# MCU helpers
# shellcheck disable=SC2139
alias zbuild="$UNOQ_PROJECT/mcu/zbuild.sh"
# shellcheck disable=SC2139
alias zflash="$UNOQ_PROJECT/mcu/flash.sh"

# Watch the MCU console (lpuart1 -> /dev/ttyHS1). Ctrl-C to stop.
#
# Goes through unoq.mcu's opener rather than calling serial.Serial() directly.
# It used to do the latter, WITHOUT exclusive=True - so this helper quietly
# bypassed the project's own locking and interleaved with whatever else had the
# port. It also meant that when the port was busy you got a raw errno instead of
# being told who had it.
mcucon() {
  "$UNOQ_PROJECT/.venv/bin/python" - <<'PY'
import sys

from unoq.mcu import BAUD, PORT, PortBusy, open_port

try:
    s = open_port(PORT, BAUD, 0.5)
except PortBusy as exc:
    print(exc, file=sys.stderr)
    raise SystemExit(1) from None
print(f"--- {PORT} @{BAUD} (Ctrl-C to stop) ---", file=sys.stderr)
try:
    while True:
        d = s.read(256)
        if d:
            sys.stdout.write(d.decode('utf-8', 'replace')); sys.stdout.flush()
except KeyboardInterrupt:
    s.close()
PY
}
