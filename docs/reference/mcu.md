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
*previous* image, and marking it would roll the MCU back.

**The bootloader refuses downgrades as well.** MCUboot is built with downgrade
prevention, counting the build number (`mcu/mcuboot.conf`): at the reset it
erases a pending image whose version is lower than the running one, and boots
the running one again. Two things still work. MCUboot reverting an image you
never confirmed is a revert, not an upgrade, so it is not checked. And an image
with the same version as the running one is allowed. To go back to older
firmware, check out that source and build it again: `zbuild` gives it a newer
build number, so it goes in like any update.

This takes the bootloader `mcu/flash-all.sh` builds. A board flashed before
this has the old one until `flash-all.sh` runs again, which `bootstrap.sh` does
on every run.

Every `fota` call holds the serial port the way `unoq.MCU` does, with both the
advisory lock and the kernel's exclusive flag, so nothing can write shell
commands into the middle of an upload. If `unoq-cpu-bars` or another program
has the port, the call fails at once with `PortBusy` and names that program;
stop it first.

## Why swap-using-offset, not direct-xip

MCUboot can apply an update in several ways. This project uses
**swap-using-offset**: `CONFIG_BOOT_SWAP_USING_OFFSET=y` in the bootloader and
`CONFIG_MCUBOOT_BOOTLOADER_MODE_SWAP_USING_OFFSET=y` in the app, which is what
Zephyr picks by default. The alternative most often suggested for a part with
this much flash is **direct-xip**. This section is why the project stays where
it is. The sources are MCUboot's
[design notes](https://docs.mcuboot.com/design.html) and the `BOOT_DIRECT_XIP`
entries in its `boot/zephyr/Kconfig`, both in the workspace under
`~/zephyrproject/bootloader/mcuboot/`.

### The flash, as the board file lays it out

| Partition | Offset | Size |
|---|---|---|
| `mcuboot` | `0x000000` | 64 KiB |
| `image-0` (slot 0) | `0x010000` | 416 KiB |
| `image-1` (slot 1) | `0x078000` | 416 KiB |
| `storage` (NVS) | `0x0e0000` | 128 KiB |

That is Zephyr's `boards/arduino/uno_q/arduino_uno_q.dts`, and this project
does not change it. The four partitions fill exactly the first megabyte, which
the file's own comment calls Bank 1, in 8 KiB sectors. The second megabyte is
not used at all.

So there is room for a much bigger application. The firmware is about 89 KiB,
and the ceiling is the slot, a little under 416 KiB once MCUboot's trailer is
taken off, not the chip's 2 MiB.

The part being dual-bank does not come into this choice. Both slots are in the
same bank, and neither mode uses the STM32's hardware bank swap: MCUboot copies
or selects slots by itself, and works the same way on a single-bank part.

### What the two modes do

**Swap-using-offset.** The update is written into slot 1, starting one sector
in. At the reset after `fota.test()`, MCUboot checks the new image's signature
and then exchanges the two slots a sector at a time: slot 0's sector N goes to
slot 1's sector N, then slot 1's sector N+1 comes down into slot 0's sector N.
Only the sectors the images use are moved. The application always runs from
slot 0, so one build fits every update. A revert is the same swap the other
way.

The issue that asked for this evaluation guessed the mode was swap-using-move,
and that move needs a scratch area. Neither is so. Move works without scratch
too, by keeping one spare sector, and offset is the newer mode MCUboot
recommends in its place: one erase cycle per slot per swap, where move does
two on the primary.

**Direct-xip.** Nothing is copied. Each slot holds a complete image linked to
run from that slot's address, and at boot MCUboot runs the valid image with the
higher version from wherever it is. An update goes into whichever slot is not
running now. Plain direct-xip has no probation: the newer image simply wins.
`BOOT_DIRECT_XIP_REVERT` adds one. An image marked for test that is not
confirmed by the next reset is erased, and the other slot boots again.

### What direct-xip would buy

- **No copy at the reset.** For this image the swap moves a dozen or so 8 KiB
  sectors each way. It has not been timed on its own here, but it fits inside
  the 12 to 14 seconds the [Updating safely](../learn/updating-safely.md)
  walkthrough waits after `fota.reset()`, which also covers the boot and the
  link coming back. The upload before it runs for minutes over the UART, and
  direct-xip does not shorten that. An update would end a few seconds sooner;
  it would not become near-instant.
- **Less flash wear.** Each swap erases the used sectors of both slots once
  more. That matters for a device updated very often for years, not for one
  updated by hand.
- **A simpler bootloader path.** MCUboot's own design notes say so: direct-xip
  is "substantially simpler" than swapping, "especially since the bootloader
  must work properly even when it is reset during the middle of an image swap".

### What it would cost

- **Two builds per update.** An image runs only from the slot it was linked
  for, so every release is built twice, once for each slot, and each is signed
  for its slot (`imgtool --pad` for the revert trailer, and `--rom-fixed` so the
  device can reject the wrong one). `zbuild.sh` builds one image today. Zephyr's
  sysbuild can generate the second build, but only as an experimental option,
  and this project builds MCUboot on its own in `flash-all.sh`, not through
  sysbuild. CI would build and check both as well.
- **`fota` choosing the image.** The device already uploads to whichever slot
  is not running. The host would have to read the slot table first and send
  the build linked for that slot. Send the other one and it does not run; with
  `CONFIG_MCUMGR_GRP_IMG_REJECT_DIRECT_XIP_MISMATCHED_SLOT` the upload is at
  least refused instead.
- **The probation, rebuilt.** Without `BOOT_DIRECT_XIP_REVERT` there is no test
  and no confirm: Zephyr's image manager drops the SMP command that sets them,
  so `fota.test()` and `fota.confirm()` would stop working. With it, a failed
  image is erased rather than swapped back. It cannot be marked again by hash,
  as the "Or keep it" step of the chapter does, and has to be uploaded again.
- **Downgrade prevention, configured again.**
  `CONFIG_MCUBOOT_DOWNGRADE_PREVENTION` depends on `!BOOT_DIRECT_XIP`, so
  `mcu/mcuboot.conf` would have to drop it. Direct-xip gets much the same
  result its own way, by never choosing the lower version, but `fota.test()`'s
  explanation and the section above would need rewriting to say so.
- **The chapter rewritten.** "Slot 0 holds what is running" stops being true:
  the running image moves between the slots with each update. Every printed
  slot table, the state diagram, and "it swaps the slots" in
  [Updating safely](../learn/updating-safely.md) would change.
- **FOTA re-verified on hardware.** The revert has been exercised for real in
  this mode: reset without confirming, and the board came back on the old
  image. A new mode starts that proof from nothing: update, revert, confirm,
  refuse a downgrade, and recover with `flash-all.sh`, all on a board.

### Power lost in the middle of a swap

The issue's case for direct-xip was that this board is powered by the same
cable it is updated over, so power can fail during the copy, and direct-xip
has no copy to interrupt.

The board is powered by its USB-C cable, and the update comes over the UART
from the board's own Linux side. Pull that cable during a swap and the MCU
stops partway through. That does not brick it. MCUboot records each sector's
progress in the slot trailers as it goes, and the next boot reads that record
and finishes the swap before it boots anything ("Reset recovery" in the design
notes). Being cut off mid-swap is a case the swap mode is written for, not a
failure it leaves to luck. What direct-xip removes is that code path, not a
way of losing the board.

A cut during the upload, which takes far longer than the swap, is the same in
both modes: the half-written slot fails its signature check and is ignored, and
the running image was never touched.

One thing here is not verified on this board: no swap has been deliberately
interrupted to watch it resume. If the worry is real enough to act on, that
test is the cheaper answer. Cut the power during the seconds after
`fota.reset()`, then read `fota.images()` once the board is back.

### Recommendation

Stay on swap-using-offset. It already works, one image serves every update,
the revert has been seen working on this board, and the downgrade refusal is
built for this mode.
The power-loss case is designed into the swap rather than left open, and the
time direct-xip saves is seconds next to an upload of minutes. Switching would
double the builds, put slot choice into `fota`, rebuild the probation and
rewrite the update chapter, all to remove a risk MCUboot already handles.

Reconsider if one of these changes: the image grows large enough that the
swap time matters, the project moves to sysbuild and gets the second build
from it, or an interrupted swap is ever seen not to resume.

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

### The temperature log

`app temp` is a reading taken when Linux asks. The temperature log is the other
way round: from boot, a `k_timer` in
[`templog.c`](../../mcu/app/src/templog.c) samples the same sensor once a
second, whether or not anything is listening, into a ring of the last 600
samples (ten minutes). Each sample carries a sequence number, counting up from
1 at boot, and the MCU's own uptime in milliseconds, so the record keeps time
by a clock Linux's load cannot delay. The ring is 9.6 KB of the chip's RAM;
with its timer and the 32-sample batch it is copied into, the log costs about
10.5 KB.

Linux collects the record with two commands. Every line is a format in
[`app_proto.h`](../../mcu/app/include/app_proto.h), and
`python/tests/test_contract.py` pins each to the regex `unoq/mcu.py` reads it
with.

```
unoq:~$ app temp log stat
head=610 count=600 size=600 dropped=10 period_ms=1000
unoq:~$ app temp log 4
gap first=5 last=10
seq=11 ms=11002 temp_mc=31250
seq=12 ms=12002 temp_err=-5
...
seq=42 ms=42002 temp_mc=31312
end head=610 more=568
```

| Line | When |
|---|---|
| `gap first=<seq> last=<seq>` | First, and only when samples after `since` were overwritten before anyone asked: the numbers lost, inclusive |
| `seq=<n> ms=<uptime> temp_mc=<millidegrees>` | One per sample, oldest first, at most 32 per reply |
| `seq=<n> ms=<uptime> temp_err=<errno>` | A sample whose sensor read failed. It keeps its number, so a failure is never mistaken for a loss |
| `end head=<seq> more=<n>` | Always, last: the newest sample held, and how many newer than this reply are waiting |
| `head=… count=… size=… dropped=… period_ms=…` | The whole reply to `app temp log stat`. `dropped` counts every sample overwritten, read or not |

`app temp log` with no argument starts at the oldest sample held and reports no
gap. `app temp log <since>` starts after `since`, so `0` means from boot and
reports whatever has been lost since. A `since` beyond the newest sample is
refused with `Error:`: the MCU has restarted since that number was read, and
its count has started again.

From Python, `MCU.temp_log(since)` asks again from the last sample it got until
`more` is 0 and returns a list of `TempSample(seq, ms, temp_c, err)`, with
`temp_c` `None` for a failed read; `MCU.temp_log_stat()` returns the counters.

```python
from unoq import MCU

with MCU() as mcu:
    samples = mcu.temp_log()          # everything held, oldest first
    later = mcu.temp_log(samples[-1].seq)  # only what is new since
```

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
| **Check: fast (skip the MCU build)** | `tools/check.sh --fast` (the pre-commit hook runs `--staged`, which is this cut to the commit) |
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

Four suites run. `ztest.sh` ends by saying how many cases passed; the number
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
- **`templog`** compiles [`mcu/app/src/templog.c`](../../mcu/app/src/templog.c)
  — the firmware's own temperature log — with a fake in place of the sensor,
  and checks the bookkeeping a reader relies on: sequence numbers from 1,
  wraparound, what `since` means at each edge, the gap reported when it is
  older than the oldest sample held, the cap on one reply, the drop count,
  and that the timer samples on its own.

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
| The SDK | `provision/user/25-zephyr-sdk.sh`, `env.sh`, `bootstrap.sh`, the defaults in `mcu/zbuild.sh`, `mcu/flash-all.sh` and `mcu/ztest.sh`, and `.vscode/launch.json` and `.vscode/tasks.json` (`tools/check-zephyr-pin.sh` fails if any differs from the first) |

On a board that already has a workspace, running `bootstrap.sh` again, or just
`provision/user/30-zephyr-workspace.sh`, moves it to the new pin: it fetches
the tag, checks it out, runs `west update`, and reinstalls Zephyr's Python
requirements. If you have changed files inside `~/zephyrproject/zephyr`, it
stops and says so instead of moving the tree under them.

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
