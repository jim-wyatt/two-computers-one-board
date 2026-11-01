<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# MPU workflow

The Linux side: direct hardware access, the `unoq` package for talking to the
MCU, the CPU-bars demo that uses both halves of the board at once, and
`unoq-jitter`, which uses the MCU to time how well Linux keeps a schedule.

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

### CPU frequency and the governor

```python
from unoq import read_policies

for p in read_policies():
    print(p.name, p.cpus, p.governor, p.cur_khz)   # policy0 (0, 1, 2, 3) schedutil 2016000
```

`read_policies()` reads `/sys/devices/system/cpu/cpufreq/policy*/` and returns
one `Policy` per clock domain: the CPUs it clocks (`related_cpus`), the driver,
the current governor and the ones available, the floor, ceiling and current
frequency in kHz, the available frequencies, and `time_in_state` as
`(kHz, seconds)` pairs. A file the driver does not provide reads as `None` or
`()` in that field alone; a machine without cpufreq reads as an empty list. Like
`read_temps()`, it never writes.

What this board reports, read under kernel 7.0.0:

| | |
|---|---|
| Policies | one, `policy0`, clocking all four cores (`related_cpus` is `0 1 2 3`) |
| Driver | `qcom-cpufreq-hw`, the SoC's own frequency hardware |
| Governor | `schedutil`, the kernel's built-in default (`CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL`) |
| Available governors | `ondemand userspace performance schedutil` |
| Frequencies (MHz) | 300, 614.4, 864, 1017.6, 1305.6, 1420.8, 1612.8, 1804.8, 2016 |
| `stats/time_in_state` | present (`CONFIG_CPU_FREQ_STAT=y`) |

One policy means one decision: there is no fast cluster to park, so a governor
here moves all four cores together. `powersave` and `conservative` are not built
into this kernel and cannot be chosen.

**Why it matters here.** The board is normally powered by the same USB-C cable
that carries the gadget, from a computer's port, and it is a sink at
`power_operation_mode` `default`: USB default current, no PD contract. The
gadget asks the host for 500 mA (`MaxPower` in
`/sys/kernel/config/usb_gadget/*/configs/c.1/`; a board that has not rebooted
since that changed still asks for 250), and 500 mA is all a USB 2 port owes it,
for four cores and an MCU. Binding the gadget re-enumerates the port, and doing
that under load can brown the board out, which at every boot becomes a reboot
loop. That is the reasoning in the header of
[`usb/bind-guard.sh`](../../usb/bind-guard.sh), and the guard is what breaks the
loop ([The bind guard](usb.md#the-bind-guard)). The guard recovers from a
brownout; the governor is the lever left for making one less likely, because it
sets how much current the cores can ask for at once. Whether a different one
helps, and what it costs, is a measurement, not a guess — so nothing in this
repository changes the governor yet.

**Measuring it.** The procedure below needs a USB power meter inline between the
computer's port and the board, and it switches the governor by hand. A governor
set this way does not survive a reboot: the next boot is back on `schedutil`.
Do it **over wifi**, not over the USB link, because the bind step drops the
link.

1. Log what the board is doing next to what the meter reads. `unoq-powerlog`
   appends a row every `--interval` seconds (default 5) to the CSV you name:
   the time, your `--label`, each policy's governor and current frequency,
   every thermal zone, and each core's load. It only reads, and the only file it
   writes is that CSV. Several runs can share one file; the label tells them
   apart. If the command is not on your `PATH` yet, re-run the editable install,
   or use `python -m unoq.powerlog`, which works either way.

    ```bash
    unoq-powerlog ~/governors.csv --label idle-schedutil --count 60   # 5 minutes
    ```

    Start the meter's own log at the same time, or note its reading against
    the CSV's `time` column (Unix seconds).

2. For each governor to compare — `schedutil`, `ondemand` and `performance` —
   switch to it and confirm:

    ```bash
    G=ondemand
    echo $G | sudo tee /sys/devices/system/cpu/cpufreq/policy0/scaling_governor
    cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor
    ```

    Then, with that governor:

    - **Idle**, 5 minutes: `unoq-powerlog ~/governors.csv --label idle-$G --count 60`
      with nothing else running.
    - **A reproducible load**: the firmware tests build Zephyr for native_sim
      and keep all four cores busy for a minute or more. In one terminal run
      `unoq-powerlog ~/governors.csv --label load-$G`, and in another
      `~/two-computers-one-board/tools/check.sh mcu`; stop the logger with
      Ctrl-C once the build ends.
    - **One gadget bind under load**, the event that browns a board out. While
      that load is running and the logger is still going:

        ```bash
        sudo ~/two-computers-one-board/usb/gadget-down.sh    # unbind, keep the definition
        sudo systemctl start unoq-usb-bind                   # bind again, through the guard
        ```

        Note the meter's peak. If the board resets, that is the answer for that
        governor; the logger's file ends at its last row, which is flushed to
        disk as it is written. The guard counted the attempt, and it clears
        itself two minutes into a boot that stays up (`usb/bind-guard.sh
        status`).

3. Put the default back:

    ```bash
    echo schedutil | sudo tee /sys/devices/system/cpu/cpufreq/policy0/scaling_governor
    ```

`userspace` is in the list too, but it holds whatever frequency it is given in
`scaling_setspeed` rather than choosing one; it is only useful as a fixed
reference, such as the 300 MHz floor. Capping `scaling_max_freq` under
`schedutil` is the other lever worth measuring, once the governors have been
compared. The comparison worth recording is mean current at idle, mean and peak
under load, and the peak at the bind, per governor, with the build's wall-clock
time as the cost.

### Firmware update

```python
from unoq import fota
fota.images()    # slot table
fota.upload(path); fota.test(); fota.reset(); fota.confirm()
```

See [mcu.md](mcu.md#update-over-serial-no-swd).

## What runs at boot

Ten systemd units. A plain `./bootstrap.sh` installs eight of them; `--no-cpu-bars`,
`--no-learning` and `--no-usb-gadget` (or `--minimal`, for all three) leave out
the ones named. `--with-temp-log` installs the ninth, `unoq-temp-log`, in place
of `unoq-cpu-bars`, and `--with-buildlight` the tenth, `unoq-buildlight`, in
place of either: all three hold the serial port.

| Unit | What it does | Installed by | Runs as | Kind |
|---|---|---|---|---|
| `unoq-link` | Drives BOOT0 low and the serial-link enable high, so the MCU runs its firmware and `/dev/ttyHS1` carries data | always (`provision/45-mcu-link.sh`) | root | one-shot, stays active |
| `unoq-leds` | Drives LED 1 (connectivity) and LED 2 (does anything need a human) | always (`provision/50-status-leds.sh`) | root | long-running, always restarted |
| `unoq-cpu-bars` | Draws CPU load on the LED matrix. Holds `/dev/ttyHS1` | default; not with `--no-cpu-bars` (`provision/65-cpu-bars.sh`) | you | long-running |
| `unoq-temp-log` | Keeps the MCU's temperature log in `/var/lib/unoq/templog`. Holds `/dev/ttyHS1`, and conflicts with `unoq-cpu-bars` | with `--with-temp-log`, instead of `unoq-cpu-bars` (`provision/66-temp-log.sh`) | you | long-running |
| `unoq-buildlight` | Shows a GitHub Actions workflow's latest run on the LED matrix. Holds `/dev/ttyHS1`, and conflicts with `unoq-cpu-bars` and `unoq-temp-log` | with `--with-buildlight`, instead of either (`provision/67-buildlight.sh`) | you | long-running |
| `unoq-learn` | Serves the documentation and installers over HTTP on port 8080, and the temperature log at `/data/` | default; not with `--no-learning` (`provision/75-learning-web.sh`) | you | long-running |
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
The four that run as you run from the Python environment in the checkout.

The four USB units are explained in
[usb.md](usb.md#do-not-switch-the-role-from-software) and
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
parked and left alone, which is the behavior you want. Thrashing is the other
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

Bars are 2 columns wide with a 1-column gap, centered, growing from the bottom.

Eight rows would quantize load into 12.5% steps, so the top pixel of each bar is
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
app temp log [since]            the temperature log after seq `since` (all of it without),
                                at most 32 samples, then `end head=<n> more=<n>`
app temp log stat               head=, count=, size=, dropped=, period_ms=
app bars <pct> [pct ...]        1..7 values, 0..100 each
app matrix px <row> <col> <lvl> light one LED; row 0..7, col 0..12, lvl 0..7
app matrix frame <r0> ... <r7>  a whole picture: eight rows of 13 digits 0..7; ok frame lit=<n>
app matrix flip                 rotate 180 degrees, persisted
app matrix off                  blank the panel, stop the refresh
app reset                       why the MCU last reset: reset=watchdog,pin and similar
app hang yes                    stall on purpose, so the watchdog resets the MCU in 8 s
```

The last two belong to the MCU's watchdog, described in
[mcu.md](mcu.md#the-watchdog), and `app matrix frame` in
[mcu.md](mcu.md#drawing-a-whole-frame).

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
  `hpy -m unoq.cpubars`. The same goes for `unoq-jitter` (`hpy -m unoq.jitter`),
  which a venv installed before it existed doesn't have until the editable
  install is run again (`bash provision/user/35-python-venv.sh`).
- **Close the shell handle before using SMP.** `MCU` and `fota` both want the
  same UART, and reopening it immediately after a close drops the first SMP
  frame — which looks exactly like a firmware fault but is a host-side race.
  Leave the `with MCU()` block first, and give it a moment.
- `cbor2` is capped `<6.0.0` by `smp`, and `pydantic` pins `pydantic-core`
  exactly. Both show as "outdated" and **must not** be upgraded — see the
  maintenance notes in [Working on this project](development.md#maintenance).
- Reading `/dev/ttyHS1` returns zero bytes if GPIO line 70 is not driven high.
  `MCU()` calls `link_up()` for you; raw `pyserial` does not.

---

## Temperature log

The MCU samples its die temperature once a second on its own timer and keeps
the last ten minutes in a ring (`mcu/app/src/templog.c`). Each sample carries a
sequence number from 1 and the MCU's uptime when it was taken. `unoq-temp-log`
is the Linux half: every ten seconds it collects what is new and appends it to
a CSV file, with the host's own thermal zones beside it. The course chapter
[Two clocks, one record](../learn/two-clocks-one-record.md) walks through why
it is built this way.

```bash
sudo bash ~/two-computers-one-board/provision/66-temp-log.sh   # install + enable
journalctl -u unoq-temp-log -f
```

Then open `http://<board>:8080/data/` for the graph, if the web server is
installed (`75-learning-web.sh`; re-run it on a board set up before the
logger existed, so that it serves `/data/`).

> **It replaces the CPU-bars demo.** Both hold `/dev/ttyHS1`, so the units say
> `Conflicts=` on each other and the step disables the demo. To go back:
>
> ```bash
> sudo systemctl disable --now unoq-temp-log
> sudo bash ~/two-computers-one-board/provision/65-cpu-bars.sh
> ```
>
> A plain `./bootstrap.sh` re-run on a board with the logger keeps the logger.

By hand, with the service stopped:

```bash
hpy -m unoq.templog --dir /tmp/tl --interval 2 --count 5
```

```python
from unoq.mcu import MCU

with MCU() as mcu:
    print(mcu.temp_log_stat())        # TempLogStat(head=..., count=..., ...)
    print(mcu.temp_log()[-3:])        # the newest three TempSample(seq, ms, temp_c, err)
```

### The file

`/var/lib/unoq/templog/temps.csv`, one row per sample:

| Column | What it is |
|---|---|
| `time` | Linux wall-clock seconds, worked out from the MCU's clock: the time of the pull, minus how much older than the newest sample of that pull this one is |
| `seq` | The MCU's sequence number. Starts again at 1 when the MCU restarts |
| `mcu_ms` | The MCU's uptime when it took the sample |
| `mcu_temp_c` | The die temperature, °C. Empty when the read failed |
| `mcu_err` | The negative errno of a failed read; empty otherwise |
| `note` | On a row of its own: `gap <first>-<last>` for samples the MCU overwrote before they were read, or `mcu-restart` |
| `linux_<zone>` | One per thermal zone, as `unoq.thermal.read_temps()` names them. Filled on the newest row of each pull only, because they were read once, then |

The columns are fixed when the file is created; a zone the kernel adds later
is not added to an existing file. The page beside it, `index.html`, is written
by the daemon when it starts and draws the file with no outside assets.

### Carrying on, and noticing

On start it reads the end of the file, finds the last sample, and asks the MCU
for everything after it. The MCU keeps ten minutes, so a daemon stopped for less
than that loses nothing; stopped for longer, the samples it missed become a
`gap` row rather than a silent jump.

Each pull asks again for the newest sample it already has, and checks that the
MCU still holds the same one under that number. If not, or if the MCU's newest
number is below it, the MCU has restarted: it writes `mcu-restart` and starts
from the oldest sample the new boot holds. The one case it cannot tell is an
MCU that restarted while the daemon was stopped for longer than the ring holds:
that is written as a gap, and the times are still right, because every time is
worked out afresh from the pull.

### Cost

On the MCU, about 10.5 KB of RAM, always: the log runs whether or not anything
reads it. On Linux, one Python process, a pull of a few hundred bytes every ten
seconds, and about 4 MB of disk a day. The file is never trimmed; delete it, or
its older part, whenever you like.

| Variable | Default | What it does |
|---|---|---|
| `UNOQ_TEMPLOG_DIR` | `/var/lib/unoq/templog` | Where the daemon writes. `--dir` overrides it |
| `UNOQ_TEMPLOG_INTERVAL` | `10` | Seconds between pulls. `--interval` overrides it |

The unit passes both as arguments, so these are for running it by hand.

## Build light

`unoq-buildlight` turns the panel into a build light. Once a minute it asks
GitHub for the latest run of one workflow on one branch, and draws what it
finds with [`MCU.matrix_frame()`](mcu.md#drawing-a-whole-frame):

| State | When | Panel |
|---|---|---|
| `passing` | The latest run finished `success`, `neutral` or `skipped` | a check mark |
| `failing` | It finished any other way: `failure`, `timed_out`, stopped by someone, ... | a cross |
| `running` | It hasn't finished: `queued`, `in_progress`, `waiting`, ... | a bar sweeping left to right, four frames a second |
| `unreachable` | No network, an HTTP error, a body that isn't the expected shape, or no runs on that branch yet | a question mark |
| `rate-limited` | GitHub said to slow down (`403` or `429` with its rate-limit headers or message) | the same question mark |

```bash
sudo bash ~/two-computers-one-board/provision/67-buildlight.sh   # install + enable
sudoedit /etc/unoq/buildlight.env && sudo systemctl restart unoq-buildlight
journalctl -u unoq-buildlight -f       # one line per change of state
```

> **It replaces the CPU-bars demo, or the temperature logger.** All three hold
> `/dev/ttyHS1`, so its unit says `Conflicts=` on both and the step disables
> whichever is enabled. To go back:
>
> ```bash
> sudo systemctl disable --now unoq-buildlight
> sudo bash ~/two-computers-one-board/provision/65-cpu-bars.sh
> ```
>
> A plain `./bootstrap.sh` re-run on a board with the light keeps the light.

By hand, with the service stopped, one poll and one picture that stays up:

```bash
(set -a; . /etc/unoq/buildlight.env; unoq-buildlight --once)
```

The subshell keeps the token out of your shell's environment. Leave out the
file and it watches this project's `ci.yml` on `main`, with no token.

### The request

`GET https://api.github.com/repos/{repo}/actions/workflows/{workflow}/runs?branch={branch}&per_page=1`,
with `urllib`, so nothing beyond the standard library. It's the documented
endpoint for one workflow's runs, newest first. The state is worked out by
`state_from(status, headers, body)`, a pure function with no clock and no
network in it, so each answer GitHub can give is a test, against responses
recorded in `python/tests/fixtures/buildlight/`.

**The rate limit.** Without a token, GitHub allows 60 requests an hour from
one address, and a 60-second interval would spend all of them. So every
request after the first is conditional: it sends back the last answer's
`ETag` as `If-None-Match`, and while nothing has changed GitHub answers `304`,
which it does not count against the limit. When an answer says no requests
are left (`x-ratelimit-remaining: 0`), the next poll waits for
`x-ratelimit-reset`. A `retry-after` is waited out too. Polls that get no
answer double the wait each time, up to 15 minutes, and the first good answer
puts it back.

**The token** is optional for a public repository and needed for a private
one. Use a fine-grained token with read-only access to Actions on that one
repository. It goes in `/etc/unoq/buildlight.env` (`0640`, root and your
group), and the daemon reads it from the environment only. There is no flag
for it, because a flag would be visible in `ps`. It is sent as
`Authorization: Bearer` and is never printed: the journal says "with a token"
and nothing more. The repository holds no token, and the step that writes the
file writes the line commented out.

### Cost

On the MCU, nothing new: a frame is one shell command, and the bar is four of
them a second, while a run is going. On Linux, one Python process and one
small HTTPS request a minute. When the daemon stops, it blanks the panel, so
a dead build light is dark rather than a check mark nobody is updating.
`--once` leaves its picture up, since that's the point of running it.

| Variable | Default | What it does |
|---|---|---|
| `UNOQ_BUILDLIGHT_REPO` | `jim-wyatt/two-computers-one-board` | The repository, `owner/name`. `--repo` overrides it |
| `UNOQ_BUILDLIGHT_WORKFLOW` | `ci.yml` | The workflow file or id. `--workflow` overrides it |
| `UNOQ_BUILDLIGHT_BRANCH` | `main` | The branch. `--branch` overrides it |
| `UNOQ_BUILDLIGHT_INTERVAL` | `60` | Seconds between polls. `--interval` overrides it |
| `UNOQ_BUILDLIGHT_TOKEN` | none | Read from the environment only |

---

## Jitter

`unoq-jitter` measures how well Linux keeps a schedule, using the MCU as the
stopwatch. It arms the firmware's `app jitter` with a period, then writes
`app jitter tick` down the UART on that schedule for `--seconds`. At the end
it prints three histograms side by side. The firmware half, its pins and its
formats are in [mcu.md](mcu.md#jitter).

```bash
sudo systemctl stop unoq-cpu-bars       # it holds /dev/ttyHS1
unoq-jitter --seconds 30                # a tick every 20 ms, nothing else running
unoq-jitter --seconds 30 --load spin    # the same with every core busy
unoq-jitter --seconds 30 --pwm 1000     # and a 1 kHz square wave, D3 to D2
```

| Option | Default | What it does |
|---|---|---|
| `--period` | `0.02` | Seconds between ticks, 0.0001 to 10 |
| `--seconds` | `30` | How long to tick for |
| `--load` | `none` | `spin` keeps every core busy, with the same workload `python -m unoq.heat` uses, for the length of the run |
| `--pwm HZ` | off | Also runs a square wave of 16 to 10000 Hz on D3 and measures its period on D2 |

**The jumper.** `--pwm` needs one jumper wire from **D3 to D2**. Without it,
the PWM column stays at `n 0`, and the tool says so. The tick columns need no
wire.

**The three columns.** Each one uses the firmware's bins, ±50 µs out to
±5000 µs, with negative early and positive late. Below the bins are `n`
and the minimum, maximum and mean in µs.

- **Linux, late**: Linux's own view. For each tick, how long after its
  deadline the tool was running again, read on `CLOCK_MONOTONIC` just before
  the write. It can't be early, so only the late half fills. It doesn't see
  what happens after the write: the kernel's serial driver, the wire, or the
  MCU.
- **MCU tick, interval**: the MCU's view of Linux. Each tick is timestamped
  on arrival on TIM5, at 1 MHz. The column is each interval between two
  arrivals minus the period, so it holds everything from Linux deciding to
  write to the shell parsing the line. A tick that is always 3 ms late doesn't
  show here, because only a change in lateness moves an interval. One late tick
  shows twice: once late, then early on the interval after it.
- **MCU pwm, period**: the MCU's own timing, with no software in the path.
  TIM3 makes the wave and TIM2 captures it, both from one 160 MHz clock. This
  is the column that shows what hardware timing looks like next to the
  other two.

The heading names the period, the load (and how many cores it took), and
the PWM. It also gives how many ticks were written and how many deadlines
were missed.

**How the deadlines are kept.** Tick *k* is due at *start + k × period*,
computed from *k* rather than by adding periods up. Each wait is to that
deadline, measured on the monotonic clock: Python's `time.sleep()` on Linux
is `clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME)`. A late wake-up then
delays one tick, not every tick after it, which a plain `sleep(period)` in a
loop would do. A deadline missed by a whole period or more is skipped and
counted rather than sent late in a burst. The MCU sees it as one interval a
whole period late. The writes go through `MCU.send()`, which doesn't wait for
the shell's prompt, because waiting would add the MCU's reply time to the
schedule. The first tick comes one second after the start, so a `spin` load
is already running and the governor has reacted to it.

**Exit codes.** 0 when the table is printed. 1 if the port is busy (the message
names who has it), if the firmware predates `app jitter`, or if the MCU stops
answering. 2 for a bad option. 130 or 143 for Ctrl-C or SIGTERM. However it
ends, the ticks and the PWM are stopped and the load is gone.

**The numbers** come from the owner's run on this board. This page has none
yet, and the course chapter on jitter will be written once the board has
supplied them.
