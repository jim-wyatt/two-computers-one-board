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
brings up the matrix, arms the watchdog (see [below](#the-watchdog)), and
returns — there is no main loop, because everything
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

### The watchdog

The MCU watches itself. [`guard.c`](../../mcu/app/src/guard.c) arms the
STM32's independent watchdog (IWDG) at the top of `main()`, and the chip resets
itself if the watchdog is not fed for 8 seconds. It is the other half of LED 4:
LED 4 is the MCU noticing that Linux has gone quiet, and this is the MCU
recovering when it is the one that has stopped. Linux's own watchdog is a
separate thing, armed by `bootstrap.sh --with-watchdog`
([`provision/80-watchdog.sh`](../../provision/80-watchdog.sh)).

**What it watches.** It is fed from one place: the status-LED beat, a work item
on the system workqueue four times a second
([`status_leds.c`](../../mcu/app/src/status_leds.c)). And the beat feeds it only
if the LED panel's refresh count has moved on since the previous beat, or the
panel is off on purpose (before the first frame, or after `app matrix off`). So
the feed stops if:

- the system workqueue is stuck, because a work item never returns or a thread
  holds the scheduler locked;
- the panel's timer interrupt has stopped while the panel is meant to be on.

A shell command that spins on its own is not caught: the shell is a
preemptible thread, and the cooperative workqueue still runs ahead of it. That
one shows as LED 4 on the far side, because the MCU stops answering.

**Why 8 seconds.** It has to outlast the longest stall the firmware makes on
purpose, and those are all flash operations of a few milliseconds each. A FOTA
upload erases slot 1 one 8 KiB sector at a time as the image arrives
(`CONFIG_IMG_ERASE_PROGRESSIVELY`), on the SMP thread, so the workqueue runs
between sectors; even the whole 416 KiB slot is 52 sectors, a fraction of a
second. A settings write may erase one NVS sector. The longest reply on the
link, a 32-sample log batch, is about a tenth of a second. Eight seconds is
well over ten times all of that, and still short enough that a hung MCU is back
before you have finished wondering why the panel froze. The IWDG counts its
own 32 kHz oscillator, so the range is about 125 µs to 131 s and 8 s is in it:
Zephyr's driver sets prescaler 64 and reload 3999. That oscillator is good to a
few percent, so "8 s" is about 8 s.

**MCUboot is not affected.** The app arms the watchdog, and MCUboot runs before
the app. An update is uploaded with the watchdog armed and fed, then the chip
resets, and the reset stops the IWDG: once started, only a reset stops it.
MCUboot then swaps the images with no watchdog running, however long that
takes, and the new image arms its own in `main()`. Two things could change
that. MCUboot can arm a watchdog of its own, but only when its build has
`CONFIG_WATCHDOG`, and the one `mcu/flash-all.sh` builds does not. And the
option bytes can start the IWDG in hardware at every reset. The chip ships in
software mode and nothing here writes option bytes; a board in hardware mode
could never have run the firmware before this one, which fed nothing, because
it would have reset every half second. A watchdog reset in the middle of an
upload leaves a partial image in slot 1, which MCUboot's signature check
refuses, so the running image is unharmed. That an update still completes with
the watchdog armed is the thing to check on the board, with one FOTA, test and
confirm, after flashing this firmware.

**The commands.**

```
unoq:~$ app reset
reset=watchdog,pin
unoq:~$ app hang yes
hanging: the watchdog resets the MCU in 8000 ms
```

`app reset` says why the MCU last reset: the flags RCC recorded, read through
Zephyr's `hwinfo` once at boot and cleared then, so that the next reset starts
from a clean record. The line is `APP_RESET_FMT` in
[`app_proto.h`](../../mcu/app/include/app_proto.h), and the names come from a
table in [`guard.h`](../../mcu/app/include/guard.h), most telling first:

| Line | Means |
|---|---|
| `reset=watchdog,pin` | The watchdog fired: the firmware stalled |
| `reset=software,pin` | The firmware reset itself: an update, `kernel reboot`, SMP's reset |
| `reset=brownout,pin` | Power came up, or dipped. This part records a power-on as a brownout |
| `reset=pin` | The reset line was pulled from outside: Linux, or the debugger |
| `reset=none` | No flag was set |
| `reset=unknown` | The flags could not be read, or one has no name in the table |

`pin` is on nearly every line because the STM32 drives its own reset pin
whatever started the reset, so the pin flag comes with every cause. Only `pin`
alone means the pin really was pulled.

`app hang yes` stalls the MCU on purpose, to watch the watchdog fire. It locks
the scheduler and spins, so the status-LED beat never runs again and the
watchdog is never fed again. Interrupts still run, so the panel keeps its last
frame: the refresh count climbing is not enough to feed the dog on its own,
which is the point. It needs the word `yes`, because it takes the shell down
with it. See [the exercise](../learn/debugging-without-a-screen.md#try-it-let-the-watchdog-fire).

From Python, `MCU.reset_cause()` returns the names as a list
(`["watchdog", "pin"]`, or `[]` for `none`), and `unoq-cpu-bars` logs it once
when it starts, so `journalctl -u unoq-cpu-bars` shows it. The watchdog and
`hwinfo` cost about 1.7 KB of flash and 24 bytes of RAM.

### Drawing a whole frame

`app matrix px` lights one LED and blanks the rest. `app matrix frame` draws a
whole picture in one command: eight words, one per row from row 0, each exactly
13 characters, each character a brightness level from `0` (off) to `7` (full).
It is one line; it is broken here only to fit the page.

```
unoq:~$ app matrix frame 0000000000000 0007700077000 0077770777700 0077777777700
                         0007777777000 0000777770000 0000077700000 0000007000000
ok frame lit=37
```

The reply is `APP_MATRIX_FRAME_FMT` in
[`app_proto.h`](../../mcu/app/include/app_proto.h), with the number of LEDs the
frame lit. A row that is short, long, or holds anything but `0`..`7` is refused
with an `Error: row N: ...` line, and every row is checked before any pixel
changes, so a refused frame leaves the panel as it was. Row 0, column 0 is the
corner `app matrix px 0 0 7` lights, and the frame is turned by the flip setting
in force when it arrives, the same way a pixel is. Like `px`, it stops a redraw
from bringing back the CPU bars. The new frame goes to the refresh buffer in one
copy with interrupts off, so the panel never shows the rows arriving one by one.

The line is 129 bytes and 11 words. The shell takes up to 255 bytes
(`CONFIG_SHELL_CMD_BUFF_SIZE`, 256 by default, one for the terminator) and 20
words (`CONFIG_SHELL_ARGC_MAX`), and neither is set in
[`prj.conf`](../../mcu/app/prj.conf). `test_contract.py` fails if either is ever
set below what a frame needs.

From Python, `MCU.matrix_frame()` takes the eight rows as strings, checks them
with the same rule before sending anything (a bad row raises `ValueError`), and
raises `MCUError` if the MCU's count of lit LEDs is not the frame's:

```python
from unoq import MCU

HEART = [
    "0000000000000",
    "0007700077000",
    "0077770777700",
    "0077777777700",
    "0007777777000",
    "0000777770000",
    "0000077700000",
    "0000007000000",
]

with MCU() as mcu:
    mcu.matrix_frame(HEART)
```

A glyph is easier to draw as `#` and `.` and convert, with levels for shading:

```python
GLYPH = """
.............
..#.......#..
...#.....#...
....#...#....
.....#.#.....
......#......
.............
.............
"""
rows = [line.replace(".", "0").replace("#", "7") for line in GLYPH.split()]
```

Stop `unoq-cpu-bars` first, or its next update replaces the picture: it owns
`/dev/ttyHS1` while it runs. The command costs 336 bytes of flash and no RAM: it draws into the frame buffer `px` already uses.

### Jitter

The course says the MCU is there because Linux cannot keep time. `app jitter`
measures it. Linux sends `app jitter tick` on a fixed schedule, and the MCU
writes down how far from the schedule each one arrived. Beside it, the MCU
keeps the same record for a square wave its own timers make and measure, with
no software in the path. The two histograms side by side are the difference
between scheduled timing and hardware timing, measured on this board ([the course chapter](../learn/jitter-measured.md) has the numbers). The
record is [`jitter.c`](../../mcu/app/src/jitter.c); the timers are set up in
[`main.c`](../../mcu/app/src/main.c) and the
[overlay](../../mcu/app/boards/arduino_uno_q.overlay).

**What is measured.**

- **tick**: each `app jitter tick` is timestamped as soon as its handler runs,
  on TIM5, a free-running 32-bit counter at 1 MHz. The interval since the
  previous tick, minus the period `app jitter arm` was given, is one
  deviation. What it includes is everything between Linux deciding to send
  and the MCU's shell parsing the line: Linux's scheduling, the 115200-baud
  wire (a 17-byte line takes about 1.5 ms to send, but only a change in that
  time shows up as jitter), and the shell. The kernel's own cycle counter
  could not do this: on this board it is LPTIM1 on the 32768 Hz crystal,
  about 30 µs a count.
- **pwm**: TIM3 drives a square wave out of D3, and TIM2 captures its period
  on D2 at the full 160 MHz timer clock (6.25 ns a count). Both timers run
  from that one clock, so whatever spread this histogram shows belongs to the
  hardware, not to two crystals disagreeing.

**The pins.** One jumper wire, from D3 to D2.

| Header | Pin | Timer | Use |
|---|---|---|---|
| D3 | PB0 | TIM3_CH3, 1 MHz count, 16-bit | PWM out, 50% duty |
| D2 | PB3 | TIM2_CH2, 160 MHz count, 32-bit | PWM capture in, pulled down |
| none | none | TIM5, 1 MHz count, 32-bit | the tick timestamps; wraps every 71.6 minutes |

The header mapping is Zephyr's
[`arduino_r3_connector.dtsi`](https://github.com/zephyrproject-rtos/zephyr/blob/main/boards/arduino/uno_q/arduino_r3_connector.dtsi).
Neither pin is used by the panel (PF0..PF10), `spi3` (PG9, PG10, PB5, PG12),
`lpuart1` (PG5..PG8), the status LEDs (PH10..PH15), or anything the board
file enables on the header. PB3 comes out of reset as JTDO/TRACESWO, which the
SWD debugging here does not use. TIM2, TIM3 and TIM5 were all unused; the
panel has TIM17. Without the jumper, D2's pull-down keeps the capture quiet
and the pwm histogram stays at `n=0`. The tick half needs no wire.

**The commands.** Every line is a format in
[`app_proto.h`](../../mcu/app/include/app_proto.h), pinned by
`python/tests/test_contract.py`.

```
unoq:~$ app jitter arm 10000
ok jitter arm period_us=10000
unoq:~$ app jitter pwm 100
ok jitter pwm hz=100 period_us=10000
unoq:~$ app jitter tick
unoq:~$ app jitter stat
jitter src=tick period_us=10000 n=997 min_ns=-400000 max_ns=6100000 mean_ns=2100 bins=0,0,0,0,1,2,3,900,50,20,10,5,3,2,1
jitter src=pwm period_us=10000 n=499 min_ns=0 max_ns=0 mean_ns=0 bins=0,0,0,0,0,0,0,499,0,0,0,0,0,0,0
unoq:~$ app jitter off
ok jitter off
```

(The `stat` numbers above are an illustration of the format, not a
measurement.)

| Command | What it does |
|---|---|
| `app jitter arm <period_us>` | Sets the expected period (100..10000000 µs) and clears both histograms. The next tick starts a run; each one after it adds a deviation |
| `app jitter tick` | Timestamps its own arrival. Prints nothing on success, and an `Error:` line if not armed |
| `app jitter pwm <hz>` | Square wave of 16..10000 Hz on D3, captured on D2. Replies with the period TIM3 really runs at (1000000 / hz, whole µs), and clears the pwm histogram |
| `app jitter stat` | One line per histogram, `tick` then `pwm` |
| `app jitter off` | Stops the ticks, the PWM and the capture. The histograms and periods stay, to be read |

In a `stat` line, `n` counts intervals and `min_ns`, `max_ns` and `mean_ns`
are deviations from `period_us` in nanoseconds: negative is early, positive
late, and all three are 0 when `n` is 0. `bins` is 15 counts, earliest first.
The edges are ±50, 100, 200, 500, 1000, 2000 and 5000 µs. The middle bin holds
|d| ≤ 50 µs, each bin out holds up to the next edge, and the two outermost
hold everything beyond 5000 µs:

```
<-5000  -5000..-2000  -2000..-1000  -1000..-500  -500..-200  -200..-100  -100..-50
-50..50
50..100  100..200  200..500  500..1000  1000..2000  2000..5000  >5000
```

A tick that Linux misses entirely shows up as one interval a whole period
late, not as a lost sample. A deviation is clamped to ±2.1 s (an `int32` of
nanoseconds), far past the last bin. The record is two 80-byte histograms. With
the timers, the PWM and counter drivers and the commands, `app jitter` costs
about 6.8 KB of flash and 0.5 KB of RAM.

From Python, `MCU.jitter_arm()`, `jitter_pwm()` and `jitter_off()` check
their replies; `MCU.jitter_stat()` returns a `JitterStat(tick, pwm)` of two
`JitterHist`s, and raises if a line's bins do not add up to its `n`.
`unoq.mcu.JITTER_BIN_LABELS` names the bins. `MCU.jitter_tick()` is
fire-and-forget: it goes through `MCU.send()`, which writes the line without
waiting for the prompt, because waiting would put the MCU's reply time into
the schedule being measured. `send()` throws away whatever is waiting to be
read before it writes. Otherwise unread replies would fill the input until
the kernel held the MCU off with RTS, the shell would block, and ticks would
arrive late for reasons that have nothing to do with Linux. The next `cmd()`
reads past the replies still arriving to its own command's echo.

```python
import time
from unoq import MCU

with MCU() as mcu:
    mcu.jitter_arm(10_000)
    mcu.jitter_pwm(100)            # needs the D3-D2 jumper
    next_t = time.monotonic()
    for _ in range(1000):
        next_t += 0.010
        time.sleep(max(0.0, next_t - time.monotonic()))
        mcu.jitter_tick()
    stat = mcu.jitter_stat()
    mcu.jitter_off()
print(stat.tick.max_ns, stat.pwm.max_ns)
```

### The scope

PA4, header A0, is two things at once on the STM32U585: output 1 of `dac1`
and channel 9 of `adc1`. So the MCU can play a wave out of the pin with its
DAC and sample the same pin with its ADC, and read its own output with no
wire at all. `app scope` is that, and it is the first thing in the firmware
that moves data by DMA. Linux asks for a burst on the shell and collects the
samples over [the SPI link](hardware.md#the-protocol-on-the-spi-link): a burst
of 4096 samples is 8 KB, most of a second of the serial line and about 40 ms
of the SPI link at 2 MHz. The arithmetic is
[`scope.c`](../../mcu/app/src/scope.c), and the hardware and the commands are
[`scope_hw.c`](../../mcu/app/src/scope_hw.c).

**How it runs.**

| Half | Paced by | Moved by | CPU per sample |
|---|---|---|---|
| Generator: `dac1` channel 1 plays a 64-point table round and round | TIM7's update event, the DAC's trigger | GPDMA1 channel 15, cyclic, memory to DAC | none |
| Capture: `adc1` channel 9 takes n samples into RAM | TIM6's update event, the ADC's trigger | GPDMA1 channel 14, one block, ADC to memory | none; one interrupt when the burst is in |

Both timers count the 160 MHz APB1 timer clock, so a rate is whatever whole
division of 160 MHz is nearest to the one asked for, and the replies say what
it came to. The wave is 64 DAC codes a period around 2048, 1638 either side:
about 0.33 V to 2.97 V with a 3.3 V reference, kept off the rails, where the
DAC's output buffer is not linear. The ADC is 14-bit, so a sample reads about
four times the DAC code behind it, about 1640 to 14744.

**Why it is register-level.** Zephyr's drivers stop short of this. The STM32
DAC driver (`drivers/dac/dac_stm32.c`) writes one value from software, with
no trigger and no DMA. The STM32 ADC driver (`drivers/adc/adc_stm32.c`)
starts every conversion from software; with `CONFIG_ADC_STM32_DMA` it moves
one sequence, one sample per channel, per DMA transfer, and repeats are timed
by a kernel timer. Neither has a timer trigger. So the timers, the DAC and the
ADC's trigger are set with STM32Cube LL. What Zephyr has is used: its GPDMA
driver moves the data (in cyclic mode for the DAC), and its clock control
turns the clocks on. `CONFIG_DAC` stays off, so no driver claims `dac1`.

**Sharing `adc1`.** The die temperature reads `adc1` through Zephyr's ADC
driver every second, for the log. A capture borrows the converter: it takes
the same lock the temperature reads take, saves the registers the driver
relies on, programs its own, and puts them back when the burst is in, with the
ADC disabled, as the driver's next read expects. A capture is held to 500 ms,
so a temperature sample can be up to that late, and is never lost.

**The pins.** None to wire for the loopback: the DAC and the ADC share A0.

| Header | Pin | Use |
|---|---|---|
| A0 | PA4 | `dac1` OUT1 and `adc1` IN9 |
| none | none | TIM6 (the ADC's trigger), TIM7 (the DAC's), GPDMA1 channels 14 and 15 |

PA4 is not used by the panel (PF0..PF10), `spi3` (PG9, PG10, PB5, PG12),
`lpuart1` (PG5..PG8), `usart1` (PB6, PB7), `i2c2` (PB10, PB11), `spi2` (PB13,
PB14, PB15, PB9), the status LEDs (PH10..PH15) or jitter's PB0 and PB3. TIM6
and TIM7 were unused; jitter has TIM2, TIM3 and TIM5, and the panel TIM17.
Nothing else in this build uses the GPDMA. With the generator off the DAC lets
go of the pin, and a capture reads whatever is on A0, from 0 to 3.3 V. Never
drive A0 from outside while the generator is on: the two outputs would fight.

**The commands.** Every line is a format in
[`app_proto.h`](../../mcu/app/include/app_proto.h), pinned by
`python/tests/test_contract.py`.

```
unoq:~$ app scope gen sine 1000
ok scope gen wave=sine hz=1000 actual_hz=1000.000
unoq:~$ app scope capture 4096 100000
ok scope capture id=1 n=4096 rate_hz=100000.000 min=1641 max=14741 mean=8191
unoq:~$ app scope stat
scope wave=sine hz=1000.000 id=1 n=4096 rate_hz=100000.000 busy=0 failed=0
unoq:~$ app scope off
ok scope off
```

(The `capture` numbers are what the table should give, not a measurement.)

| Command | What it does |
|---|---|
| `app scope gen <sine\|triangle> <hz>` | Plays the wave at 1..10000 Hz out of A0, replacing whatever was playing. Replies with the frequency TIM7 really gives |
| `app scope capture <n> <rate_hz>` | Takes n samples (16..4096) at 100..250000 a second, at most 500 ms of them, and replies when they are in, with the capture's id, the rate TIM6 gave, and the smallest, largest and mean sample |
| `app scope stat` | The wave playing (`off` at 0.000 if none), the capture that can be read (id 0 if none), whether one is running, and how many have failed |
| `app scope off` | Stops the wave. The last capture stays, to be read |

The ids count captures since boot from 1. A failed capture (a DMA error, or
no completion within the burst's length plus 100 ms) is counted in `failed`
and leaves nothing to read: its buffer is half overwritten.

**The SPI service.** `SCOPE` (type 0x04) returns a capture in pieces of up to
501 samples. A request is the capture's id (0 for whichever is held) and an
offset; an answer is the id, the rate in millihertz, the capture's n, the
offset, the count, and that many 16-bit samples. A reader asks again with
offset plus count until it reaches n, naming the id the first answer gave, so
a capture taken in the middle of a read is an error (`ERR_STALE`) and never a
burst stitched from two. Before any good capture, or while one is running,
the service answers `ERR_UNAVAILABLE`. The layout is in
[`spi_proto.h`](../../mcu/app/include/spi_proto.h), tested by
`mcu/tests/spi_proto` and `python/tests/test_spilink.py`.

**Limits.** The capture's top rate, 250 kHz, leaves room under the ADC's own
conversion time: 68 cycles of sampling and about 17 of conversion at 14 bits,
on a 40 MHz ADC clock, is about 2 µs. The wave's top, 10 kHz, is a 640 kHz
update rate, under the DAC's rated 1 Msps. At 10 kHz a period is 64 steps;
nothing smooths them, so the ADC sees the staircase. The buffer is 8 KB, and
the whole of `app scope` costs about 6.9 KB of flash and 9.8 KB of RAM.

**Try it.** Build and update the firmware ([Update over
serial](#update-over-serial-no-swd)), stop the demo so that the serial port is
free, and run:

```bash
sudo systemctl stop unoq-cpu-bars
hpy -m unoq.scope                                   # 1 kHz sine, 4096 samples at 100 kHz
hpy -m unoq.scope --wave triangle --hz 250 --rate 20000
hpy -m unoq.scope --csv burst.csv                   # and every sample, for a spreadsheet
hpy -m unoq.spilink scope                           # the last capture's raw codes
```

`unoq.scope` plays the wave, takes the burst on the shell, reads it over SPI,
and prints the smallest, largest and mean sample in codes and volts, and the
frequency from the rising crossings of the middle. It checks the samples that
came over SPI against the MCU's own summary on the shell, and fails if they
differ. The volts assume a 3.3 V reference. It stops a wave it started,
unless `--keep`; `--wave none` leaves A0 alone and shows what is on it.

From Python, `MCU.scope_gen()`, `scope_capture()`, `scope_stat()` and
`scope_off()` drive the shell, and `SpiLink.scope_read(id)` collects the
samples:

```python
from unoq import MCU
from unoq.spilink import SpidevTransport, SpiLink

with MCU() as mcu:
    mcu.scope_gen("sine", 1000)
    cap = mcu.scope_capture(4096, 100_000)
    mcu.scope_off()
link = SpiLink(SpidevTransport())
burst = link.scope_read(cap.id)
link.close()
print(cap, min(burst.samples), max(burst.samples))
```

### The BME680: `app env`

A Bosch BME680 on a breakout, wired to the header's I2C, gives the board the
air around it: temperature, relative humidity, pressure, and the resistance
of the part's gas sensor, which falls as volatile organic compounds rise.
Zephyr's driver (`drivers/sensor/bosch/bme680`) does the reading and Bosch's
compensation; [`env.c`](../../mcu/app/src/env.c) turns its values into the
line Linux reads, and [`env_sensor.c`](../../mcu/app/src/env_sensor.c) is the
device and the command. The wiring, and what Linux makes of it, are in
[mpu.md](mpu.md#bluetooth-sensor).

> **Untested on hardware.** No BME680 has been fitted yet, and Zephyr has no
> emulator for it, so `mcu/tests/env` feeds `env.c` the values the driver
> would build. That the driver finds the part and reads it is still to be
> seen.

**The bus and the address.** `i2c2`, which the board file already enables at
400 kHz on PB10 (SCL) and PB11 (SDA), the header pins past AREF. The overlay
declares one `bosch,bme680` node, `env_bme680`, at **0x77**: the address of
Adafruit's and SparkFun's breakouts, with the part's SDO pin high. Breakouts
that tie SDO low answer at 0x76, Pimoroni's and many unbranded ones among
them; build for those with

```bash
mcu/zbuild.sh -- -DUNOQ_BME680_ADDR=0x76
```

a CMake variable that `mcu/app/CMakeLists.txt` passes to the overlay's
preprocessor. It holds for that build directory until a pristine build, and
anything but the part's two addresses stops the build.

**With no part.** The driver reads the chip ID at boot. With nothing there,
or the part on the other address, it fails, the device is not ready
(`device_is_ready()`), and everything else boots as before; `main()` prints
`env: no BME680 at 0x77 on i2c2` on the console, and `app env` answers with
an error. A part wired in afterwards is not seen until the MCU restarts.

**The command.** The line is `APP_ENV_FMT` in
[`app_proto.h`](../../mcu/app/include/app_proto.h), pinned on both sides:
by `mcu/tests/env` here and `python/tests/test_contract.py` there.

```
unoq:~$ app env
temp_mc=21530 humidity_mpct=45123 pressure_pa=101325 gas_ohm=52345
unoq:~$ app env
Error: env_err=-19
```

(The numbers are an example, not a measurement.)

| Field | Unit | The driver's resolution |
|---|---|---|
| `temp_mc` | millidegrees Celsius | 0.01 °C |
| `humidity_mpct` | thousandths of a percent of relative humidity, 0 to 100000 | 0.001 % |
| `pressure_pa` | pascals | 1 Pa |
| `gas_ohm` | ohms | 1 ohm |

All four come from one forced measurement: the driver starts it, waits up to
250 ms for it (about 200 ms of that is the gas sensor's hot plate, at 320 °C),
and reads them together. The shell thread waits; nothing else does. An error
is `Error: env_err=<negative errno>`: `-19` (`ENODEV`) for no part, and
anything else from the read, `-11` (`EAGAIN`) for a measurement that did not
finish, or `-34` (`ERANGE`) for a value no BME680 can give.
`unoq.MCU.env()` returns an `EnvReading`, and raises `EnvError` with the errno
for either; a firmware without the command is a plain `MCUError` that says to
update it.

**Cost.** `CONFIG_SENSOR` was already on for the die temperature;
`CONFIG_BME680` adds the driver. Against the same tree without it, the build
grows by 2376 bytes of flash (114576 to 116952) and 80 bytes of RAM (42960 to
43040).

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

Nine suites run. `ztest.sh` ends by saying how many cases passed; the number
is not repeated here, where it would be wrong the next time one was added.

- **`bars`** compiles [`mcu/app/src/bars.c`](../../mcu/app/src/bars.c) — the
  firmware's own rasterizer, not a copy — and checks the drawing rules on the
  host, because a charlieplexed panel cannot be read back on the board. These
  are the only place the drawing rules are checked at all, so they assert
  properties (bars stay in their columns, height never falls as load rises,
  rotation is a true rotation) rather than a few remembered frames.
- **`guard`** tests the two functions in
  [`mcu/app/include/guard.h`](../../mcu/app/include/guard.h) the watchdog
  depends on: whether a beat feeds it (a refreshing panel does, a panel off on
  purpose does, a panel meant to be on whose count has stopped does not), and
  the names `app reset` gives the reset causes, which must be single words,
  with the cause before `pin`, none dropped and none cut short.
- **`jitter`** compiles [`mcu/app/src/jitter.c`](../../mcu/app/src/jitter.c)
  — the firmware's own jitter record — and feeds it made-up timestamps in place
  of the timers: every bin edge from both sides, the clamp, min, max and mean,
  the `bins=` string at its widest, the first tick after arming, an interval
  across the 32-bit counter's wrap, a missed tick, stop and re-arm.
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
- **`spi_proto`** tests the SPI link's frames and services in [`spi_proto.c`](../../mcu/app/src/spi_proto.c), which [`spi_link.c`](../../mcu/app/src/spi_link.c) runs on `spi3` as a slave; the protocol is in [hardware.md](hardware.md#the-protocol-on-the-spi-link).
- **`scope`** compiles [`mcu/app/src/scope.c`](../../mcu/app/src/scope.c), the
  scope's arithmetic, without the DAC, ADC, timers or DMA it feeds: the sine
  and triangle tables (in range, odd about the middle, peaks where they
  should be), the timer division at every wave and capture rate (within half
  a count, prescaler as small as will do), the burst's bookkeeping (nothing
  readable while the DMA writes, after a failure, or across two captures),
  and how long the shell lets a capture hold `adc1`.
- **`env`** compiles [`mcu/app/src/env.c`](../../mcu/app/src/env.c), the half
  of `app env` with no device in it, and hands it the `sensor_value`s the
  BME680 driver builds, since Zephyr has no emulator for the part: the units
  `app env` prints, the sign of a temperature below zero in both halves of a
  `sensor_value`, the humidity cap, every value refused and the reading left
  alone when one is, the widest line fitting its buffer, and a buffer one
  byte short refused rather than cut.

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
