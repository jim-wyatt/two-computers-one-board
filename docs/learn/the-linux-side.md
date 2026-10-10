<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# The Linux side

The big chip runs Debian. Not a cut-down embedded variant with a funny name —
actual Debian, the same distribution that runs on servers. `apt install` works.
Python works. SSH works.

This is the half of the board that will feel familiar, so this page is short.
Its real job is to point out the three places where Linux differs from what you
are used to on a laptop, because those are where the embedded work happens.

## Everything is a file

Linux exposes hardware as files. Not "like files" — actual paths you can `cat`,
open in Python, and redirect into.

This is the single idea that makes the Linux half of embedded work easy. There
is no special API to learn for most things. If you can read a file, you can read
a sensor.

Three filesystems matter, and none of them are on your disk:

- `/proc` — the kernel describing itself: processes, memory, CPU statistics.
- `/sys` — devices and drivers, and knobs to turn them.
- `/dev` — the devices themselves, as streams of bytes you read and write.

**Try it.** Every one of these is a real file being generated as you read it:

```bash
cat /proc/uptime                       # seconds since boot
cat /sys/class/thermal/thermal_zone3/temp   # CPU temperature, in millidegrees
ls /dev/ttyHS1                         # the wire to the microcontroller
ls /sys/class/leds/                    # LEDs you can turn on by writing a 1
```

That last one is worth pausing on. Reading whether an LED is lit is a `cat`,
and turning one on is an `echo`:

```bash
sudo systemctl stop unoq-leds          # a service owns this LED; borrow it
cat /sys/class/leds/unoq:user-blue1/brightness      # 0 = off
echo 1 | sudo tee /sys/class/leds/unoq:user-blue1/brightness
echo 0 | sudo tee /sys/class/leds/unoq:user-blue1/brightness
sudo systemctl start unoq-leds
```

(`sudo tee` is how you write to a file only root may write, from a pipe. And
the first and last lines are there because `unoq-leds` rewrites that LED every
five seconds to report the board's state. Leave it running and your blue light
is overwritten almost at once: two writers, one file, and the last one wins.
[Four lights that tell the truth](four-lights.md) is about that service.)

No library. No driver code. No API to look up. It is a file, and writing to it
changes the physical world.

## `/proc/stat`, which is what this project actually reads

Our worked example needs to know how busy each CPU core is. Linux already
counts this, in `/proc/stat`:

```bash
head -5 /proc/stat
```

```
cpu  12063 118 9541 1015220 1128 2295 1177 0 0 0
cpu0 3216 33 2589 253099 302 640 469 0 0 0
cpu1 2884 27 2245 254282 268 533 232 0 0 0
```

Each row is one core. The numbers are **jiffies** — a count of clock ticks spent
in each state since boot: user time, system time, idle, waiting for disk, and so
on.

Two things about this that trip people up:

1. **They are totals, not rates.** The file cannot tell you "this core is 40%
   busy". It tells you how many ticks it has *ever* spent busy. To get a
   percentage you must read it twice and compare:

   ```
   busy_now - busy_before
   ─────────────────────── × 100
   total_now - total_before
   ```

   That is the entire algorithm in [`unoq/cpu.py`](../../python/unoq/cpu.py), and it
   is why the demo takes one reading, waits, and only then draws its first
   frame: with a single sample there is nothing to subtract.

2. **A core waiting for the disk is not busy.** `iowait` counts as idle in this
   project, deliberately: a core blocked on storage is a core doing nothing, and
   showing it as load would be a lie about the thing the bars claim to display.

## Things start themselves: systemd

On a laptop you start programs by clicking them. On a board with no screen,
something must start them at boot and restart them when they die. On Debian that
is **systemd**, and a thing it manages is called a **unit**.

This project installs several:

```bash
systemctl list-units 'unoq-*' --no-pager
```

```
unoq-cpu-bars.service  loaded active running Arduino UNO Q host CPU load on the LED matrix
unoq-leds.service      loaded active running Show the Arduino UNO Q link state on the board LEDs
unoq-link.service      loaded active exited  Arduino UNO Q MPU<->MCU link (BOOT0 + UART enable GPIOs)
```

Those three are what the course's setup gives you. `unoq-link` says `exited`,
not `running`, and that is success: it sets two pins at boot and has nothing
more to do. The other optional extras add `unoq-learn` and `unoq-usb-gadget`.

Useful commands, which you will use constantly:

```bash
systemctl status unoq-cpu-bars     # is it running? why did it stop?
journalctl -u unoq-cpu-bars -n 50  # the last 50 lines it printed
sudo systemctl restart unoq-cpu-bars
sudo systemctl stop unoq-cpu-bars  # frees the serial port for you to use
```

That last one matters more than it looks. The serial line to the microcontroller
is a single resource, and **only one program can hold it at a time**. If the
demo is running, it has the wire, and your own attempt to talk to the MCU will
fail. Stopping the service is how you take it back.

## The board is not a laptop

Three constraints that shape everything on this side:

**Memory is finite in a way you will notice.** There are around 3.6 GB, shared
with everything. A build that would be unremarkable on a laptop can push this
board into **swap** — parking memory that is not being used right now to make
room. (On this board that is less alarming than it sounds: see
[mpu.md](../reference/mpu.md#swap-in-use-is-not-a-problem-here).)

**Storage is slower and smaller.** The root filesystem is about 10 GB. The
Zephyr source tree alone is ~3.3 GB.

**There is no screen.** Every diagnostic is a log line, a file, or something you
read over the network. This is why so much of this project is about making state
visible — a status command, a log, an LED — rather than assuming you can just
look.

## Try it: watch the demo do its half

Stop the service, and run the same program by hand. It prints nothing; watch
the panel on the board:

```bash
sudo systemctl stop unoq-cpu-bars
cd ~/two-computers-one-board
yes > /dev/null &                                     # one core, flat out, in the background
./.venv/bin/unoq-cpu-bars --count 50 --interval 0.2   # ten seconds of frames
kill %1                                               # stop the load
sudo systemctl start unoq-cpu-bars
```

Fifty frames, then it stops and the panel goes dark. For those ten seconds one
bar stands well above the others: that is the core `yes` is keeping busy. (`&`
runs a command in the background so the prompt comes straight back; `kill %1`
stops the first thing you started that way.)

You have just used the Linux half for the two things it is good at: reading
system state out of a file, and doing arithmetic on it. It never touched an LED.

> [!TIP]
> **Go deeper.** [mpu.md](../reference/mpu.md) covers the Linux-side hardware access in
> detail — the `unoq` Python API, the GPIO lines, and the demo end to end.

## Check yourself

1. Why does reading `/proc/stat` once tell you nothing about how busy a core is?
2. You run your program and it fails to open `/dev/ttyHS1`. What is the most
   likely cause, and what one command would confirm it?
3. Which of these belongs on the Linux side: computing a percentage, or holding a
   pin high for exactly 40 microseconds?

<details markdown="1">
<summary>Answers — try each one first</summary>

1. **Because the numbers are totals, not rates.** Each one counts jiffies spent
   in a state since boot. A percentage only appears when you read the file
   twice and divide the change in busy ticks by the change in total ticks.
2. **Something else already holds the serial port — most likely the demo.**
   Only one program can hold the line at a time.
   `systemctl status unoq-cpu-bars` tells you whether the service is running;
   stopping it gives you the wire back.
3. **Computing a percentage.** That is arithmetic on data Linux already has.
   Holding a pin for exactly 40 microseconds is a timing job, and exact timing
   is what Linux cannot promise.

</details>

Next: [The microcontroller side](the-microcontroller-side.md) — the other chip,
where none of this exists.
