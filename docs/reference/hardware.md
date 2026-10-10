<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# The hardware, honestly

The UNO Q is two computers sharing a board.

| | **MPU** (Linux side) | **MCU** (real-time side) |
|---|---|---|
| Part | Qualcomm QRB2210 (`arduino,imola`) | STM32U585 Cortex-M33 |
| Runs | Debian, Python, your services | Zephyr firmware |
| Memory | 3.6 GiB shared | 2 MB flash / 786 KB RAM (768 KB of it in Zephyr's memory map) |
| Reached via | native Linux syscalls | SWD, or a serial link |

Most Arduino-header GPIO is wired to the **MCU**, not the MPU. The MPU has its
own separate GPIO / I²C / SPI — that is what [`unoq`](mpu.md) talks to.

```mermaid
flowchart TB
  subgraph MPU["QRB2210 — Debian Linux"]
    U["USB-C<br/><small>host or device,<br/>decided by the cable</small>"]
    W["wifi / BT"]
    E["eMMC 29 GB"]
    L12["LED 1 · LED 2<br/><small>/sys/class/leds</small>"]
  end
  subgraph MCU["STM32U585 — Zephyr"]
    M["8×13 LED matrix<br/><small>PF0..PF10</small>"]
    L34["LED 3 · LED 4"]
    H["Arduino headers<br/><small>GPIO, I²C, SPI</small>"]
  end
  MPU ---|"lpuart1 → /dev/ttyHS1<br/><small>115200</small>"| MCU
  MPU ---|"gpio 37 BOOT0 · gpio 38 NRST"| MCU
  MPU ---|"gpio 70 serial link enable"| MCU
  MPU ---|"gpio 25/26 SWD"| MCU
```

Every line between the two boxes is one this project drives, and getting any of
them wrong makes a working board look broken. They are the subject of the next
section.

---

> [!NOTE]
> Everything on this page was found by observing one running board. None of it
> has been confirmed by Arduino, Qualcomm or ST, and it may be different on
> another board revision or software image. Check it against your own board
> before you rely on it.

## The two GPIOs nobody documents

**Read this before debugging anything.** `arduino-router` used to drive two MPU
GPIO lines the MCU depends on. That service is now disabled, so these must be
set by us — and when they are wrong, a perfectly good board looks broken.

| `gpiochip1` line | Function | Symptom when wrong |
|---|---|---|
| **37** | MCU **BOOT0**, latched at reset | Firmware flashes *and verifies*, but never runs. PC sits around `0x0bf9xxxx` — the STM32 ROM bootloader. |
| **70** | **UART link enable** | MCU transmits fine (`LPUART1 CR1=0x2d`, TC/TXE set) but `/dev/ttyHS1` reads zero bytes. |
| 25 / 26 / 38 | SWD swdio / swclk / srst | — |

```bash
~/two-computers-one-board/mcu/link-up.sh      # BOOT0=0, link-enable=1
```

### They are documented, in the bootloader

"Nobody documents" was true of everything Arduino publishes and false of what
Arduino ships. U-Boot lives in the `boot_a` / `boot_b` partitions, and its
embedded devicetree names all five lines and sets their power-on state:

```bash
sudo dd if=/dev/disk/by-partlabel/boot_a bs=1M count=16 2>/dev/null \
  | strings -n 4 | grep -A2 -E '^mcu-.*-state$'
```

| Name in U-Boot's devicetree | GPIO | What this project calls it |
|---|---|---|
| `mcu-swdio-state` | 25 | SWD swdio |
| `mcu-swclk-state` | 26 | SWD swclk |
| `mcu-boot0-state` | 37 | BOOT0 |
| `mcu-nrst-state` | 38 | SWD srst |
| `mcu-spi-rdy-state` | 70 | UART link enable |

Two things follow. The states these lines are in before Linux starts are set by
U-Boot, not by anything on the rootfs — which is why they are sane at boot even
with `arduino-router` disabled.

And the last row disagrees with itself. Line 70 is empirically what makes
`/dev/ttyHS1` produce bytes, which is why this project calls it a UART enable.
U-Boot calls it an **SPI ready** line. Both descriptions can be true of one pin,
and the next section is the other half of that story.

### There is an SPI link between the two chips, and nothing here uses it

U-Boot's name for line 70 is not a mislabel. Linux's own devicetree describes
an SPI device called the MCU:

```bash
ls /sys/bus/spi/devices/                                   # spi0.0
cat /sys/bus/spi/devices/spi0.0/of_node/compatible; echo   # arduino,unoq-mcu
readlink -f /sys/bus/spi/devices/spi0.0/of_node
```

```
/sys/firmware/devicetree/base/soc@0/geniqup@4ac0000/spi@4a94000/mcu@0
```

| | |
|---|---|
| Controller | `spi@4a94000`, a Qualcomm GENI SPI master, `status = "okay"` |
| Device | `mcu@0`, chip select 0, `compatible = "arduino,unoq-mcu"` |
| Driver | `spidev` — no protocol driver, just raw access |
| Seen from Linux as | `/dev/spidev0.0`, group `spi` (your user is in it) |

So the port this project had been treating as a spare SPI bus is wired to the
microcontroller. On the other side, Zephyr's board definition enables two SPI
controllers: `spi2`, which goes to the Arduino header, and `spi3` on PG9, PG10,
PB5 and PG12, which the header does not account for.

What is established, and what is not:

- **Established:** the link exists in the devicetree on the Linux side, and
  U-Boot names line 70 as its ready signal.
- **Not verified:** that `spi3` is the microcontroller's end of it, which chip
  is meant to be the master in practice, and what Arduino's own firmware sends
  over it. Nothing has been transferred across it from this project.
- **Not used:** this project's firmware has no SPI code, and everything —
  frames for the LED matrix, the shell, firmware updates — goes down the
  115200 serial line. A frame for the panel costs about 9 ms there. This is
  the obvious faster path, and it is open work:
  [issue #28](https://github.com/jim-wyatt/two-computers-one-board/issues/28).

One practical consequence today: **do not use `/dev/spidev0.0` as if it were a
free bus for your own peripherals.** Whatever you clock out of it goes to the
STM32.

`flash.sh` calls this automatically, and `unoq.MCU` calls it on construction.
`unoq-link.service` applies it at boot.

Pin state **persists after the `gpioset` process exits** — the SoC pinctrl keeps
driving the last value — which is why a one-shot is enough and no daemon is
needed. BOOT0 is only sampled at MCU reset, so set it *before* resetting.

> ### Never `gpioget` these two lines
>
> `gpioget` **requests the line as an input**, and that drops the drive the same
> way a reboot without `unoq-link.service` would. Reading the pins is enough to
> break the link — you get plausible-looking values back (`37=active`,
> `70=inactive`, i.e. exactly the broken state) and the MCU goes quiet.
>
> Check them without touching them. `gpioinfo` only reads line *info*, never
> requests the line:
>
> ```bash
> gpioinfo -c gpiochip1 37 70      # both must say `output`
> hpy -c "from unoq.link import link_state; print(link_state())"
> ```
>
> `output` means driven. `input` means floating — run `link-up.sh`. This is why
> `unoq.link.link_state()` reports *direction* rather than value: there is no way
> to read the value that does not also destroy it.

> `mcu/link-up.sh` is referenced by `/etc/systemd/system/unoq-link.service`.
> **Do not move or rename it** without reinstalling that unit.

---

## The MCU's two UARTs

The STM32 has two serial ports, and they are **not** interchangeable. The Linux
side has a third of its own — see
[the next section](#the-third-uart-the-mpus-own-console).

| Node | Pins | Goes to |
|---|---|---|
| `lpuart1` | PG7/PG8 + RTS/CTS on PG6/PG5 | **the Linux MPU** → `/dev/ttyHS1` |
| `usart1` | PB6/PB7 | the Arduino header pins (D0/D1) |

Upstream Zephyr's `arduino_uno_q` board defaults `zephyr,console` to **`usart1`**,
so a stock `hello_world` prints to the *header pins* and you see nothing from
Linux. Override it in a board overlay — see
[`mcu/app/boards/arduino_uno_q.overlay`](../../mcu/app/boards/arduino_uno_q.overlay).

The RTS/CTS pair on `lpuart1` is the giveaway: hardware flow control means a
board-to-board link.

## The third UART: the MPU's own console

`/dev/ttyMSM0` is a serial port on the **Linux** side, and it has nothing to do
with the MCU. It is the kernel console.

| | |
|---|---|
| Hardware | Qualcomm GENI serial at `4a90000.serial` — a *different* port from `/dev/ttyHS1` (`4a88000.serial`) |
| Role | The kernel console: `/sys/class/tty/console/active` reads `tty0 ttyMSM0` |
| Selected by | Devicetree, not the kernel command line — `chosen/stdout-path = serial0:115200n8`, and there is no `console=` in `/proc/cmdline` |
| Held by | `serial-getty@ttyMSM0.service` → `agetty`, offering a login prompt |

```bash
cat /sys/class/tty/console/active        # tty0 ttyMSM0
cat /proc/cmdline                        # no console= in it
systemctl status serial-getty@ttyMSM0
```

The two Linux serial ports have unrelated names because of Qualcomm's history.
**MSM** is *Mobile Station Modem*. The GENI serial driver registers plain PIO
ports as `ttyMSM*` and DMA-capable high-speed ports as `ttyHS*` — the same
peripheral block in two flavours.

### It is the last recovery path

If the USB gadget will not bind, wifi is off, and no network reaches the board,
this port still gives a root login. It also carries kernel messages from the
first boot line onwards, before any network exists.

That is exactly the failure `usb/bind-guard.sh` and `usb/uplink-fallback.sh`
are written for. This port is the escape hatch underneath both.

### It is a login for anyone who can touch the board

Anyone with a UART adapter and the right pads gets a password prompt. That is
normal for a development board, and worth knowing about one that sits on a
desk. If you do not want it:

```bash
sudo systemctl disable --now serial-getty@ttyMSM0
```

Doing so also removes the recovery login described above.

### Where it comes out is not verified

**Which physical pads this port lands on is not visible from software** and
needs the schematic. Everything else in this section was confirmed on the
running board; the pinout was not. There is deliberately no pin table here.
See [issue #38](https://github.com/jim-wyatt/two-computers-one-board/issues/38).

---

## The LED matrix

104 blue LEDs in an 8×13 grid, wired to the **MCU** on **PF0–PF10** and
charlieplexed: each LED is one *ordered* pair of those eleven pins, lit by
driving one high, one low, and leaving the other nine as inputs. Eleven pins
give 110 ordered pairs; the panel uses the first 104, in that order.

Upstream Zephyr's `arduino_uno_q` board **does not mention the matrix at all**,
and neither does the datasheet. The wiring is recorded in exactly one place —
Arduino's own core (`ArduinoCore-zephyr`, `loader/matrix.inc`) — which is where
this project's pin map and 10 µs refresh slot come from. Nothing else from that
core is used; the driver is
[`mcu/app/src/matrix.c`](../../mcu/app/src/matrix.c) and the devicetree nodes it
needs (`gpiof`, `timers17`) are declared in the app's board overlay.

PF11–PF15 are *not* part of the panel — PF14/PF15 reach the Arduino header — so
the driver masks only the low eleven pins when it tri-states the port.

See [mpu.md](mpu.md#cpu-bars-on-the-led-matrix) for the display built on this.

## The four RGB LEDs

Separate from the 8x13 matrix, and split across both processors. This trips
people up, because only half of them are visible from Linux.

| | Driven by | Named |
|---|---|---|
| **LED 1** | Linux | `unoq:user-red1` / `-green1` / `-blue1` |
| **LED 2** | Linux | `unoq:panic-red2` / `unoq:wlan-green2` / `unoq:bt-blue2` |
| **LED 3** | **STM32** | `led3_red` / `led3_green` / `led3_blue` |
| **LED 4** | **STM32** | `led4_red` / `led4_green` / `led4_blue` |

They sit above the matrix, opposite the USB-C port.

### Six sysfs entries are two LEDs

`/sys/class/leds/unoq:*` lists six writable channels, and it is very natural to
read that as six indicators. It is not: they are the red, green and blue
channels of two RGB packages, and the `-1` / `-2` suffixes are the only hint.

**sysfs cannot tell you this.** Every channel gets its own directory and its own
`brightness` file whether it is one package or six, and they all hang off the
same `gpio-leds` platform node. Lighting four channels to mean four separate
things produces two cyan LEDs, which is how this was discovered.

### `mmc0::` is not one of them

There is a seventh entry, `mmc0::`, and it is a different animal:

```
unoq:user-red1  ->  platform/leds/leds/...            (gpio-leds)
mmc0::          ->  platform/soc@0/4744000.mmc/leds/  (the MMC controller)
```

The MMC subsystem registers it so a board *can* wire an activity light to it.
Nothing is wired to it here. It has `max_brightness 255` where the real ones
have 1, and it will never light.

### The disk-activity triggers do not fire

`mmc0`, `disk-activity` and `disk-write` are all offered in every LED's trigger
list, and all of them accept being selected. **None of them do anything.**
Measured with 400 MB of `O_DIRECT` writes in flight, sampling brightness 400
times: on in **zero** samples, for all three.

Being listed is not being implemented. If you want disk activity on a LED here,
you must sample `/sys/block/mmcblk0/stat` yourself - that counter does move.

### What this project shows on them

`status/leds.sh` (Linux) and `mcu/app/src/status_leds.c` (firmware):

| | LED 1 | LED 2 | LED 3 | LED 4 |
|---|---|---|---|---|
| **steady** — fine | green: internet reachable | green: all units healthy | green: image **confirmed** | green: MPU spoke recently |
| **slow blink**, once every 2 s — degraded, or in progress | blue: cable, but no route beyond | — | yellow: image **unconfirmed**, reverts on reset | — |
| **fast blink**, twice a second — needs a human | red: no uplink at all | red: unit failed / bind guard tripped | red: subsystem failed | red: MPU silent >4s |
| **dark** — nothing is driving it | `unoq-leds` is not running | `unoq-leds` is not running | the firmware is not running | the firmware is not running |

Read it by row. The rhythm identifies the state by itself, and no LED uses the
same rhythm for two states, so none of this depends on telling red from green.
The colour is a second witness, not the only one. Both blinks are lit half the
time.

LED 1 and LED 2 are blinked by the kernel's `timer` LED trigger, which
`leds.sh` selects and then leaves alone until the state changes: every write to
`delay_on` or `delay_off` restarts the blink, so rewriting an unchanged state
would make it stutter. LED 3 and LED 4 are redrawn by the firmware every
250 ms from one counter, so the red and green channels of yellow cannot fall
out of step. If a kernel offers no `timer` trigger, `leds.sh` shows the colour
steady and says so once in its log.

LED 4 is worth understanding: it shows the *absence* of traffic. A blink per
message would be a clock - `cpubars` sends twice a second, so it would blink
twice a second forever and mean nothing. The tick stopping is the news, and it
is news Linux cannot deliver, because a host that has stopped talking cannot
report that it stopped.

`~/two-computers-one-board/status/leds.sh explain` prints the current scheme; `... test` cycles the
states so you can learn which physical LED is which, and
`... show 1 blue slow` puts one LED into one colour and rhythm by hand (stop
`unoq-leds` first, or its next pass puts the truth back).

## How the MPU flashes the MCU

There is no external debug probe. The MPU bit-bangs SWD on its own GPIO lines
using OpenOCD's `linuxgpiod` driver:

```
Info : Linux GPIOD JTAG/SWD bitbang driver (libgpiod v2)
Info : SWD DPIDR 0x0be12477
Info : [stm32u5.cpu] Cortex-M33 r0p4 processor detected
```

No root needed — your user is in the `gpiod` group.

> **`/opt/openocd` is owned by no Debian package.** `dpkg -S /opt/openocd` finds
> nothing; it was placed there by an install script, so apt will never reinstall
> it. Copy it somewhere safe (`cp -a /opt/openocd ~/uno-q-backup/`) before you
> purge anything, and note that it is reproducible from source — see
> [Working on this project](development.md#rebuilding-openocd).

`apt install openocd` does **not** substitute: Debian ships 0.12.0 (2023), which
predates the libgpiod v2 support this board needs.

---

## Flash layout

```
0x08000000  boot_partition   64K   MCUboot (38K used)
0x08010000  slot0           416K   running signed app
0x08078000  slot1           416K   staged update
0x080e0000  storage         128K   NVS (settings, boot counter)
```

Two 416K slots out of 2 MB of flash, which is why
[the MCU is 96% empty](https://github.com/jim-wyatt/two-computers-one-board/issues/12) is
an open question rather than a boast — the part has two banks and this layout
uses one.

Images link at `0x08010000` and must be **signed** — MCUboot refuses a raw
image. See [mcu.md](mcu.md).
