<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# MCU workflow

Firmware for the STM32U585, built with stock Zephyr + west. No Arduino tooling.

```
~/zephyrproject/      west workspace, Zephyr v4.4.2, board `arduino_uno_q`
~/zephyr-sdk-1.0.1/   Zephyr SDK (arm-zephyr-eabi)
```

## Build

```bash
zbuild                                       # this project's app, mcu/app
zbuild -p always                             # the same, as a pristine rebuild
zbuild samples/hello_world                   # any upstream Zephyr sample
zbuild ~/some/other/app                      # or an app of your own, by path
```

With no app named, `zbuild` builds this project's firmware. A first argument
that starts with a dash is passed to `west build` for that default build.

(`zbuild` / `zflash` are aliases from [`env.sh`](../../env.sh); the scripts are
`mcu/zbuild.sh` and `mcu/flash.sh`.)

`zbuild` signs automatically when `CONFIG_BOOTLOADER_MCUBOOT=y`, and links
`compile_commands.json` into both this project and the Zephyr workspace so
clangd works in either.

**Each app gets its own build directory.** This project's app builds into
`~/zephyrproject/build` — the path named by every doc, VS Code task and
`launch.json`. Anything else builds into `~/zephyrproject/build-<name>`:

```bash
zbuild                         # -> ~/zephyrproject/build
zbuild samples/hello_world     # -> ~/zephyrproject/build-hello_world
```

So switching between apps never forces a pristine rebuild, and building a
sample never repoints this project's `compile_commands.json` at foreign code —
which would leave clangd quietly indexing the wrong tree. Only this project's
own app updates its index. Override the directory with `BUILD_DIR=...`.

## Signing

`zbuild` signs every image built for MCUboot (`CONFIG_BOOTLOADER_MCUBOOT=y`, as this project's is), because MCUboot refuses one that is not, and then
checks the signature against the key before it reports the build as done. It
calls `imgtool` itself, with the slot size and flash alignment read from the
build's own devicetree by `mcu/sign-params.py`; `west sign -t imgtool`, which
used to do this, is deprecated.

The key is MCUboot's published sample key (`bootloader/mcuboot/root-rsa-2048.pem` in
the workspace), which everyone has. So the signature shows an image is intact,
not whose it is. For anything you deploy, generate a key of your own with
`imgtool keygen`, build the bootloader with its public half
(`CONFIG_BOOT_SIGNATURE_KEY_FILE`), and keep the private half off the device.

## Flash over SWD

```bash
zflash                                                  # what zbuild just built
zflash ~/zephyrproject/build-hello_world/zephyr/zephyr.hex    # or any other image
```

With no image named, `zflash` writes
`~/zephyrproject/build/zephyr/zephyr.signed.hex` — this project's firmware, and
always the signed one. If there is no build yet it says so and touches nothing.

> **Never flash the unsigned `zephyr.hex` over a MCUboot chain.** It links into
> slot0 but has no image header, so the bootloader refuses it and the board
> stops booting. Use `zephyr.signed.hex`.

Full recovery — bootloader + app together:

```bash
~/two-computers-one-board/mcu/flash-all.sh
```

Every flash prints two harmless errors first:

```
Error: Translation from khz to adapter speed not implemented
Error: [stm32u5.cpu] Execution of event reset-init failed
```

The `linuxgpiod` bitbang adapter has no configurable speed, so that reset event
cannot run. Programming and verification still succeed.

## Update over serial (no SWD)

The MCU runs MCUboot, so routine updates go over the UART.

```python
from unoq import fota
fota.upload("~/zephyrproject/build/zephyr/zephyr.signed.bin")
fota.test()      # mark pending
fota.reset()     # MCUboot swaps slot1 -> slot0
fota.confirm()   # keep it
```

**The revert is the point.** An image that boots but is never confirmed is
rolled back on the next reset — verified: swapped to v0.2.0, reset without
confirming, and the board returned to v0.0.0 by itself.

`fota.images()` reports the slot table, and the image version in it is how you
tell which build is actually running after a swap.

`fota.test()` with no argument marks the image in the inactive slot only if its
version is newer than the running one. `zbuild` stamps every build with the
time, so a fresh upload always is. After a confirm, though, that slot holds the
*previous* image, and marking it would roll the MCU back. To go back to an older
image on purpose, pass its hash: `fota.test(h)` takes the image `h` names,
whatever its version.

Every `fota` call holds the serial port the way `unoq.MCU` does, with both the
advisory lock and the kernel's exclusive flag, so nothing can write shell
commands into the middle of an upload. If `unoq-cpu-bars` or another program
has the port, the call fails at once with `PortBusy` and names that program;
stop it first.

## Interactive shell

The app runs a Zephyr shell on the same UART.

```bash
tio /dev/ttyHS1 -b 115200      # Ctrl-T then q to exit
mcucon                         # or the env.sh helper (Ctrl-C)
```

```
unoq:~$ app status
uptime_ms=12216 flip=0 sweeps=1043712
unoq:~$ app bars 100 50 25 0
ok bars=4
```

`sweeps` counts LED-matrix refresh passes — see [mpu.md](mpu.md#is-it-actually-running).

The `app` commands and their arguments are listed in
[mpu.md](mpu.md#shell-commands).

Command groups: `app` (yours), `gpio`, `i2c`, `device`, `kernel`, `devmem` —
poke hardware without rebuilding. Drive any of them from Python with
[`unoq.MCU.cmd()`](mpu.md#the-unoq-package).

SMP/MCUmgr shares this UART. It registers **no** `mcumgr` command — the shell
detects SMP frames in the byte stream, so `mcumgr: command not found` is
expected, not a fault.

## What the firmware is

[`mcu/app/src/main.c`](../../mcu/app/src/main.c) is the `app` shell command group
and nothing else. `main()` loads the persisted panel orientation, claims the
two status LEDs and sets LED 3 from whether the running image is confirmed,
brings up the matrix, and returns — there is no main loop, because everything
that runs after init runs on its own: the shell has its own thread, the panel
is refreshed from a timer ISR inside `matrix.c`, and the status LEDs are
re-checked once a second by a work item in
[`status_leds.c`](../../mcu/app/src/status_leds.c).

One byte of state is persisted in NVS (`storage_partition`): the panel
orientation set by `app matrix flip`. That is a property of how the board is
mounted rather than of the running session, so it survives power cycles and
firmware updates.

`app temp` reads the chip's internal die temperature sensor through ADC1 —
`CONFIG_SENSOR` and `CONFIG_STM32_TEMP` in
[`prj.conf`](../../mcu/app/prj.conf), on devicetree nodes Zephyr's board file
already enables — and the driver applies ST's factory calibration values, so
the reading is calibrated but no better than a few degrees.

## Debugging

Open this folder in VS Code and pick **Debug (attach to running MCU)** or
**Debug (flash then run)** in the Run panel. OpenOCD runs on the board; you get
breakpoints, memory view, and peripheral registers decoded from
`.vscode/STM32U585.svd` (202 peripherals).

## VS Code tasks

**Terminal → Run Task** lists these, from
[`.vscode/tasks.json`](../../.vscode/tasks.json). Each is a thin wrapper round a
command documented on this page or in
[Working on this project](development.md#the-quality-gates).

| Task | What it runs |
|---|---|
| **MCU: build** | `mcu/zbuild.sh` on this project's app: build, sign, refresh `compile_commands.json` |
| **MCU: build (pristine)** | The same with `-p always`, from a clean build directory |
| **MCU: flash (SWD)** | `mcu/flash.sh` with the signed image |
| **MCU: update over serial (FOTA)** | Upload, mark for test and reset. No SWD. Reverts unless confirmed |
| **MCU: confirm firmware** | `fota.confirm()`: keep the running image |
| **MCU: flash bootloader + app (recovery)** | `mcu/flash-all.sh`: the whole MCUboot chain over SWD |
| **MCU: console** | `tio /dev/ttyHS1 -b 115200`. Ctrl-T then `q` to leave |
| **MCU: status** | Prints the link GPIO state and `MCU().status()` |
| **MCU: link up (BOOT0 + UART enable)** | `mcu/link-up.sh`, for a board that looks dead or a silent `/dev/ttyHS1` |
| **Test: host (native_sim)** | `mcu/ztest.sh`: the firmware tests, run on the board's Linux side |
| **Test: on target** | `mcu/ztest.sh -p arduino_uno_q` |
| **Test: python (pytest + coverage)** | `pytest`, all against fakes |
| **Check: all quality gates** | `tools/check.sh` |
| **Check: fast (skip the MCU build)** | `tools/check.sh --fast`, which is what the pre-commit hook runs |
| **Check: reformat in place** | `tools/check.sh --fix` |
| **Maint: check dependency versions** | `tools/check-versions.sh` |

The serial tasks (FOTA, confirm, console, status) need the port: stop
`unoq-cpu-bars` first if it is installed.

## Tests

```bash
~/two-computers-one-board/mcu/ztest.sh                    # native_sim - runs on the MPU, no flashing
~/two-computers-one-board/mcu/ztest.sh -p arduino_uno_q   # cross-compile for the board
```

Use `native_sim/native/64`; plain `native_sim` is 32-bit and fails on aarch64
with a `CONFIG_64BIT` error.

Three suites run. `ztest.sh` ends by saying how many cases passed; the number
is not repeated here, where it would be wrong the next time one was added.

- **`bars`** compiles [`mcu/app/src/bars.c`](../../mcu/app/src/bars.c) — the
  firmware's own rasterizer, not a copy — and checks the drawing rules on the
  host, because a charlieplexed panel cannot be read back on the board. These
  are the only place the drawing rules are checked at all, so they assert
  properties (bars stay in their columns, height never falls as load rises,
  rotation is a true rotation) rather than a few remembered frames.
- **`link_protocol`** tests
  [`mcu/app/include/app_proto.h`](../../mcu/app/include/app_proto.h), the contract
  that `main.c`, these tests and `unoq/mcu.py` all depend on agreeing.
- **`status_leds`** tests the three functions in
  [`mcu/app/include/status_leds.h`](../../mcu/app/include/status_leds.h) that
  decide what LED 3 and LED 4 show: which color and which rhythm each state
  gets, and that no two states of one LED share a rhythm. They touch no
  hardware, which is why they can run on the host. One of them holds the fast
  blink under three flashes a second.

### The MCU suite tests the firmware, not a copy of it

`app_proto.h` holds the MPU↔MCU contract: the `app status` format string, the
panel geometry, the bar limits, the settings key. Three parties depend on it
agreeing —

```
mcu/app/src/main.c        produces the status line, validates bars
mcu/tests/link_protocol/  tests these definitions directly
python/unoq/mcu.py        parses the status line, calls `app bars`
```

— so the test includes the same header `main.c` does. It used to keep its own
copy of the range check and format string, which meant it could not fail when
the firmware changed. Confirmed by mutation: renaming `uptime_ms=` in the header
now fails the suite.

**A change to that header is a protocol change.** Update `unoq/mcu.py` and its
tests in the same commit. On the Python side,
`python/tests/test_contract.py` parses the header and fails if the panel
constants in `unoq/mcu.py` drift from the firmware's.

See [Working on this project](development.md#the-quality-gates) for the full
gate list.

## Upgrading Zephyr

The versions are written in more than one place, and the gates catch only some
of the disagreements, so change all of them in one commit:

| What | Where |
|---|---|
| Zephyr | `west.yml` and `provision/user/30-zephyr-workspace.sh` (`tools/check-zephyr-pin.sh` fails if they differ) |
| Zephyr's Python packages | `tools/update-constraints.sh`, which reads the version from the step above and rewrites `mcu/requirements-zephyr-lock.txt` |
| The SDK | `provision/user/25-zephyr-sdk.sh`, `env.sh`, `bootstrap.sh`, the defaults in `mcu/zbuild.sh`, `mcu/flash-all.sh` and `mcu/ztest.sh`, and `.vscode/launch.json` and `.vscode/tasks.json` |

Then re-copy the OpenOCD board support that Zephyr's runner
needs and that is not upstream:

```bash
cp -r ~/two-computers-one-board/mcu/board-support/support ~/zephyrproject/zephyr/boards/arduino/uno_q/
```

Also check the SDK requirement — Zephyr's `SDK_VERSION` file states it
(v4.4.x wants SDK 1.0.1; v4.3.0 wanted 0.17.4).

The C style is Zephyr's, copied into this repo the same way, so re-copy it too
and re-run the gate — upstream does change it between releases:

```bash
cp ~/zephyrproject/zephyr/.clang-format ~/two-computers-one-board/.clang-format
~/two-computers-one-board/tools/check.sh c
```

## Gotchas

- `CONFIG_MCUMGR_TRANSPORT_SHELL` **silently disables itself** without
  `CONFIG_BASE64` and `CONFIG_CRC`. Kconfig warns; the build still succeeds.
- `west flash -r openocd` needs `zephyr/boards/arduino/uno_q/support/openocd.cfg`,
  which is **not** upstream — Zephyr's runner resolves board support in-tree and
  crashes on `samefile()` without it (`runners/openocd.py:92`). The canonical
  copy lives in `mcu/board-support/`; re-copy it with the command under
  [Upgrading Zephyr](#upgrading-zephyr).
- The default flash runner is `stm32cubeprogrammer`, which is not installed.
  Always pass `-r openocd`, or just use `zflash`.
