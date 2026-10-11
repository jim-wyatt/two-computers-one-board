<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# MPU workflow

The Linux side: direct hardware access, the `unoq` package for talking to the
MCU, and the CPU-bars demo that uses both halves of the board at once.

```bash
hpy your_script.py          # alias for ~/two-computers-one-board/.venv/bin/python
```

## Direct hardware

The MPU's own GPIO / I²C / SPI — separate from the Arduino headers, which are
wired to the MCU.

```python
import gpiod, smbus2, spidev, serial
```

| Interface | Device | Notes |
|---|---|---|
| GPIO | `/dev/gpiochip0..2` | chip1 has 127 lines; also carries SWD + BOOT0 |
| I²C | `/dev/i2c-0..2` | needs the `i2c` group |
| SPI | `/dev/spidev0.0` | needs the `spi` group + udev rule. **It is wired to the MCU**, not a free bus: see [hardware.md](hardware.md#there-is-an-spi-link-between-the-two-chips-and-nothing-here-uses-it) |
| Serial | `/dev/ttyHS1` | the MCU link |

Group membership (`i2c`, `spi`, `gpiod`) and the SPI udev rule are set up by
[`provision/10-optimize-board.sh`](../../provision/10-optimize-board.sh). A new
group takes effect at your next login.

## The `unoq` package

Installed editable from `~/two-computers-one-board/python` into `~/two-computers-one-board/.venv`.

```python
from unoq import MCU, fota, link_up, link_state

link_up()                      # BOOT0 low + UART enable (idempotent)
link_state()                   # {'boot0': 'OUTPUT', 'link_enable': 'OUTPUT'}

with MCU() as mcu:
    mcu.status()               # {'uptime_ms': 12216, 'flip': 0, 'sweeps': 1043712}
    mcu.die_temp()             # 31.25 - the STM32's own temperature, degrees C

    mcu.bars([12, 3, 0, 47])   # LED matrix: one bar per value, 0..100
    mcu.matrix_px(7, 0)        # light one LED - finds the panel's orientation
    mcu.matrix_flip()          # rotate 180 degrees, persisted in NVS
    mcu.matrix_off()

    mcu.cmd('kernel threads')  # any shell command, parsed into lines
```

The class wraps the firmware's own `app` command group and nothing else. The
shell's built-in groups — `gpio`, `i2c`, `device`, `kernel`, `devmem` — are one
`mcu.cmd()` away, or you can type them straight into `tio`; wrapping each in a
Python method bought nothing but more surface to keep in step with Zephyr.

`mcu.die_temp()` is the one temperature on the board Linux cannot read for
itself: every zone in `/sys/class/thermal` belongs to the QRB2210. It is the
STM32U585's internal sensor, converted by Zephyr's driver with the two
calibration values ST programs into each chip at the factory — so it is
calibrated, but it is still a junction temperature from an on-chip sensor, good
to a few degrees and always above the air around the board. It raises `MCUError`
if the firmware could not read the sensor (the shell prints `temp_err=<errno>`
in place of a reading) or is too old to have `app temp`.

`MCU` is a context manager **on purpose** — the UART is a single shared
resource and a stale handle blocks `tio`, `mcucon`, and SMP alike.

`mcu.cmd()` reads until the shell prompt reappears rather than sleeping a fixed
time, so slow commands (`device list`) and fast ones each cost what they should.
It raises `MCUError` on `command not found` and on any line the firmware
prefixes with `Error:`, and `ShellTimeout` if no prompt comes back.

### Temperatures

```python
from unoq import read_temps, hottest

for name, celsius in read_temps():
    print(f"{name:20} {celsius:5.1f}")   # cpuss0-thermal        35.8

hottest(read_temps(), "cpu")             # ('cpuss1-thermal', 36.1)
```

`read_temps()` reads the kernel's thermal zones from `/sys/class/thermal` and
returns `(type, degrees Celsius)` pairs in zone order. It is a list of pairs
rather than a dict because nothing makes a zone's `type` unique, and how many
zones there are is the kernel's business: this board showed six on one kernel
and ten on the next. A zone whose sensor will not answer is left out rather
than raised, and a machine with no thermal zones reads as an empty list.
`hottest()` picks the warmest pair, optionally narrowed by a name prefix, and
returns `None` if nothing matches. Nothing here writes to sysfs.

These are the Linux side's sensors. None of them says anything about the
microcontroller.

### Firmware update

```python
from unoq import fota
fota.images()    # slot table
fota.upload(path); fota.test(); fota.reset(); fota.confirm()
```

See [mcu.md](mcu.md#update-over-serial-no-swd).

## What runs at boot

Eight systemd units, of which a board set up with a plain `./bootstrap.sh` has
the first two. The others arrive with the flag named.

| Unit | What it does | Installed by | Runs as | Kind |
|---|---|---|---|---|
| `unoq-link` | Drives BOOT0 low and the serial-link enable high, so the MCU runs its firmware and `/dev/ttyHS1` carries data | always (`provision/45-mcu-link.sh`) | root | one-shot, stays active |
| `unoq-leds` | Drives LED 1 (connectivity) and LED 2 (does anything need a human) | always (`provision/50-status-leds.sh`) | root | long-running, always restarted |
| `unoq-cpu-bars` | Draws CPU load on the LED matrix. Holds `/dev/ttyHS1` | default; not with `--no-cpu-bars` (`provision/65-cpu-bars.sh`) | you | long-running |
| `unoq-learn` | Serves the documentation and installers over HTTP on port 8080 | default; not with `--no-learning` (`provision/75-learning-web.sh`) | you | long-running |
| `unoq-usb-gadget` | Builds the USB gadget definition and prepares the `br-usb` bridge. Never binds | default; not with `--no-usb-gadget` (`provision/95-usb-gadget.sh`) | root | one-shot, stays active |
| `unoq-usb-bind` | Asks the bind guard, then binds the gadget and brings the USB network up. Not enabled at boot: udev starts it when a USB device controller or the gadget's network interface appears | default; not with `--no-usb-gadget` | root | one-shot, re-run on every plug-in |
| `unoq-usb-confirm` | Waits 120 seconds, then clears the bind guard's counter: this boot survived | default; not with `--no-usb-gadget` | root | one-shot |
| `unoq-uplink-fallback` | If wifi has been turned off and the USB link has given no internet by the deadline, turns wifi back on | default; not with `--no-usb-gadget` | root | one-shot |

"You" is the account that owns the checkout: the unit files are written with
`arduino` and rewritten to the real user and path when they are installed.

The six that run as root do not run the scripts in the checkout. They run
root-owned copies in `/usr/local/lib/unoq/`, which the step that installs each
unit makes first. After editing one of those scripts, run the step again for
the board to use it: see [What root runs](provisioning.md#what-root-runs).
The two that run as you run from the Python environment in the checkout.

The four USB units are explained in
[usb.md](usb.md#you-cannot-switch-the-role-from-software) and
[The bind guard](usb.md#the-bind-guard).

```bash
systemctl list-units 'unoq-*' --all        # which of them this board has, and their state
```

## Swap in use is not a problem here

`free -h` on this board can show about 1 GiB of swap in use. On a
desktop that means the machine is short of memory. Here it does not, because
this board's swap is not what swap usually means.

```bash
free -h
cat /proc/swaps
```

```
Filename        Type       Size      Used     Priority
/dev/zram0      partition  1877576   1076316  100
```

There is **no swap file and no swap partition on the eMMC**. The swap device is
`zram0`: a compressed block device that lives in RAM. "Swapping" here means
compressing cold pages in place, not writing them to flash.

### What it saves

One measurement, 3h41m after boot, with a full development environment running:

| | |
|---|---|
| Pages parked | 1010 MiB |
| Compressed to | 316 MiB (3.20×, `lzo-rle`) |
| Real RAM occupied | 331 MiB |
| **Net RAM saved** | **678 MiB** |

```bash
cat /sys/block/zram0/mm_stat
```

The first three numbers on that line are, in bytes: the size of the pages
parked (`orig_data_size`), what they compressed to (`compr_data_size`), and the
RAM the device really occupies (`mem_used_total`). The kernel documents the
rest in `Documentation/admin-guide/blockdev/zram.rst`.

The ratio is the first divided by the second, 1010 / 316. The saving is the
first less the third, which is a little more than the compressed data. Straight
after boot all three are near zero: nothing has been parked yet.

### Parking or thrashing

Swap being *used* tells you nothing. What matters is whether pages that were
swapped out keep being read back.

```bash
grep -E '^pswp(in|out) ' /proc/vmstat
```

The same measurement gave `pswpout 277888` and `pswpin 15991` since boot. Pages
went in and were read back roughly **1 time in 17**. That is cold memory being
parked and left alone, which is the behaviour you want. Thrashing is the other
case: pages being read back about as fast as they are written out.

### Why this is the right design on eMMC

zram is why a 3.6 GiB board comfortably runs a full IDE, and it costs no flash
wear at all. A conventional swap file on the eMMC would quietly eat write
endurance.

The desktop instinct — swap is in use, so the board is under-provisioned, so
start disabling things — reaches the opposite of the right conclusion.

### Where the memory goes

The deployed system is not the load. From the same session:

| | RSS |
|---|---|
| `unoq-cpu-bars` | 26.6 MiB |
| `unoq-learn` | 20.7 MiB |
| `unoq-leds` | 3.8 MiB |
| `unoq-usb-gadget` | 0.7 MiB |
| **all four services** | **~52 MiB** |
| vscode-server + Claude Code extension + ruff server | **1373 MiB** |

Everything this project installs costs about 52 MiB. The rest is the
development environment running on the board, which is a legitimate thing to do
here. It is why the numbers look alarming during development, and why they will
not look like that for someone who only runs the apps.

---

## CPU bars on the LED matrix

Host CPU load, one bar per core, on the board's 8×13 panel. It is the smallest
thing that uses both halves of the board for what each is good at: Linux reads
`/proc/stat`, the STM32 holds a 100 kHz refresh loop steady while it does.

```bash
sudo systemctl stop unoq-cpu-bars   # if the service is installed: it holds the port
hpy -m unoq.cpubars                 # until Ctrl-C
hpy -m unoq.cpubars --interval 0.25 --count 20
```

`hpy` is the project's Python (an alias from `env.sh`). The same program is
installed as `~/two-computers-one-board/.venv/bin/unoq-cpu-bars`, which is what
the service runs; that directory is not on `PATH`, so type the full path or use
`hpy -m unoq.cpubars`.

```python
from unoq import MCU, CpuSampler

sampler = CpuSampler()              # takes the first reading
with MCU() as mcu:
    mcu.bars(sampler.sample())      # [12, 3, 0, 47] -> four bars
```

`/proc/stat` holds counters since boot, so a single reading is the average since
power-on; keep one `CpuSampler` alive and take differences.

### At every boot

```bash
sudo bash ~/two-computers-one-board/provision/65-cpu-bars.sh      # install + enable
journalctl -u unoq-cpu-bars -f
```

> **It holds `/dev/ttyHS1` open, and locks it.** While the service runs,
> `mcucon`, `tio`, `unoq.MCU` and FOTA are all refused; the Python ones raise
> `PortBusy` and name the process holding the port. Stop it before working on
> the MCU, and start it again afterwards:
>
> ```bash
> sudo systemctl stop unoq-cpu-bars
> ```
>
> The lock is two locks, taken by `open_port()` in
> [`python/unoq/mcu.py`](../../python/unoq/mcu.py). pyserial's
> `exclusive=True` is an advisory `flock`: it stops only another program that
> asks for the same lock, and `tio`, `screen` and `cat` do not. The `TIOCEXCL`
> ioctl is what makes the kernel refuse every later `open()`. See
> [troubleshooting](troubleshooting.md#tio-can-leave-the-port-unusable-after-it-exits)
> for how the second one can outlive the program that set it.
>
> Flashing over SWD (`flash.sh`, `zflash`) is unaffected — that is OpenOCD on
> the GPIO lines, not the UART.

The unit sets `KillSignal=SIGINT`, which is load-bearing rather than
stylistic. systemd's default SIGTERM kills Python outright, so the `finally:`
that blanks the panel never runs and the last frame stays lit indefinitely —
measured: SIGTERM exits 143 with the refresh still sweeping, SIGINT exits 0 with
the panel dark. `Restart=on-failure` covers the case where the MPU reaches
`multi-user.target` before the MCU's shell is answering.

It also declares `Requires=unoq-link.service`, because `/dev/ttyHS1` reads
nothing until that unit has driven the UART-enable GPIO. Ordering alone would
let this start against a silent port and restart forever.

### Which half does what

| | Runs on | File |
|---|---|---|
| Read `/proc/stat`, turn counters into percentages | MPU | [`python/unoq/cpu.py`](../../python/unoq/cpu.py) |
| Send `app bars 12 3 0 47` over `/dev/ttyHS1` | MPU | [`python/unoq/mcu.py`](../../python/unoq/mcu.py) |
| Percentages → 104 grayscale pixels | MCU | [`mcu/app/src/bars.c`](../../mcu/app/src/bars.c) |
| Charlieplex those pixels onto PF0–PF10 | MCU | [`mcu/app/src/matrix.c`](../../mcu/app/src/matrix.c) |

The wire format is whole percentages, so `app bars 100 50 0 0` typed into `tio`
does exactly what the daemon does. Nothing on the MCU knows what a CPU core is,
and nothing on the MPU knows how a bar is drawn.

### Reading the display

Bars are 2 columns wide with a 1-column gap, centred, growing from the bottom.

Eight rows would quantise load into 12.5% steps, so the top pixel of each bar is
dimmed in proportion to the remainder — the 3-bit grayscale is used as a vernier,
giving 56 distinguishable heights instead of 8.

The scale is linear, which has one consequence worth knowing before you decide
the display is broken: a core needs **13%** before it lights one row at full
brightness, and **2%** before it lights anything at all. An idle UNO Q therefore
shows a dark panel with at most a faint dot or two along the bottom edge, and
looks exactly like a service that failed to start. Put some load on before
judging it:

```bash
for i in 1 2 3 4; do (timeout 10 bash -c 'while :; do :; done' &) ; done
```

The dark idle state is deliberate — a baseline glow would be indistinguishable
from a low but real load.

### Orientation

**The panel's rows run in whichever direction your board is mounted**, and the
firmware cannot know which. If the bars hang from the top instead of standing on
the bottom, flip them once:

```
unoq:~$ app matrix px 7 0 7      # lights the bottom-left LED, as you should see it
unoq:~$ app matrix flip          # wrong corner? rotate 180 degrees
ok flip=1
```

`flip` is stored in NVS, so it survives reboots and firmware updates. `app
status` reports it. From Python: `mcu.matrix_px(7, 0)` and `mcu.matrix_flip()`.

### Is it actually running?

A charlieplexed panel is invisible to software — nothing the MCU can read back
tells you what is lit. The one observable is the refresh sweep counter:

```bash
hpy -c "
from unoq import MCU; import time
with MCU() as m:
    t0 = time.monotonic(); a = m.status()['sweeps']
    time.sleep(1)
    t1 = time.monotonic(); b = m.status()['sweeps']
    print(round((b - a) / (t1 - t0)), 'sweeps/s')"
```

Expect **~962/s** while the panel is on (104 LEDs × 10 µs per slot); measured
958. A count stuck at zero means the refresh timer never started; a count that
climbs means the ISR is running whether or not you can see the LEDs from where
you are.

> Divide by the *measured* interval, not by the sleep. A `status()` round trip
> costs ~0.30 s — `cmd()` blocks in `read()` until its timeout even after the
> prompt has arrived — so the obvious `sleep(1); b - a` version reports ~1250
> and looks like a panel refreshing 30% faster than the hardware allows.

The panel starts lazily on the first `app bars`, and `app matrix off` stops the
timer and releases the pins.

### Shell commands

```
app status                      uptime_ms, flip, sweeps
app temp                        temp_mc=<n>: the MCU's die temperature, millidegrees C
app bars <pct> [pct ...]        1..7 values, 0..100 each
app matrix px <row> <col> <lvl> light one LED; row 0..7, col 0..12, lvl 0..7
app matrix flip                 rotate 180 degrees, persisted
app matrix off                  blank the panel, stop the refresh
```

### Why seven bars

Bars are at least one column wide and always separated by one blank column, so
*n* bars need 2*n*−1 columns. Thirteen columns therefore cap it at seven. The
UNO Q's MPU has four cores, so this is not a limit you will meet; a bigger host
gets `cpu0..cpu6` and a warning on stderr, never a silent truncation.

### How the panel works

104 LEDs on eleven pins (PF0–PF10), charlieplexed: each LED is one *ordered*
pair of pins, lit by driving one high, one low, and leaving the other nine
floating as inputs. Eleven pins give 11 × 10 = 110 ordered pairs; the panel uses
the first 104.

Only one LED is ever on. A TIM17 counter callback walks all 104 every 1.04 ms,
and brightness comes from lighting a given LED in *L* of the seven sweeps that
make up a grayscale cycle — so the whole panel redraws at ~137 Hz.

That is why [`matrix.c`](../../mcu/app/src/matrix.c) writes `MODER` and `BSRR`
directly instead of calling `gpio_pin_configure_dt()`: pins must change
*direction*, not just level, 100,000 times a second.

> Upstream Zephyr's `arduino_uno_q` board does not describe the matrix at all.
> The pin pairing and the 10 µs slot were taken from Arduino's own core
> (`ArduinoCore-zephyr`, `loader/matrix.inc`) — the only description of this
> wiring that exists. Nothing else from that core is used here, and the
> devicetree nodes it needs are declared in
> [`mcu/app/boards/arduino_uno_q.overlay`](../../mcu/app/boards/arduino_uno_q.overlay).

## Gotchas

- **PF0–PF10 belong to the panel.** Anything else in the build that claims them
  will fight the refresh ISR. PF11–PF15 are untouched.
- The refresh ISR runs at 100 kHz whenever the panel is on. It is cheap, but it
  is not free — `app matrix off` if you are measuring something timing-sensitive.
- `unoq-cpu-bars` is not on `PATH`: it is installed into the project's venv, at
  `~/two-computers-one-board/.venv/bin/unoq-cpu-bars`. Use that path, or
  `hpy -m unoq.cpubars`.
- **Close the shell handle before using SMP.** `MCU` and `fota` both want the
  same UART, and reopening it immediately after a close drops the first SMP
  frame — which looks exactly like a firmware fault but is a host-side race.
  Leave the `with MCU()` block first, and give it a moment.
- `cbor2` is capped `<6.0.0` by `smp`, and `pydantic` pins `pydantic-core`
  exactly. Both show as "outdated" and **must not** be upgraded — see the
  maintenance notes in [Working on this project](development.md#maintenance).
- Reading `/dev/ttyHS1` returns zero bytes if GPIO line 70 is not driven high.
  `MCU()` calls `link_up()` for you; raw `pyserial` does not.
