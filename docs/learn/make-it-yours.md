<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# Make it yours

You have been through the whole stack: two processors, the wire between them, the
toolchain, the display, safe updates, the USB gadget, and how to find out what is
wrong. This page is about what to do next, because reading about embedded
development is not the same as doing any.

> [!NOTE]
> **In this chapter**
>
> - the six ideas from the course that are not about this board at all
> - things to build, from an afternoon to a project, each using both halves
>   of the board
> - where the open work is, what to run before you change anything, and
>   where the files are
>
> **You need:** the whole course. This is the last chapter, and its recap is
> the course's.

## What you actually learned

Worth naming, because most of it is not about this board:

- **Which half a job belongs on.** Timing determinism versus throughput and
  convenience. This is the transferable skill.
- **Two computers with no shared memory** must serialize, frame, and tolerate
  failure — the same discipline as any distributed system, at 2 cm.
- **Cross-compilation**: the machine you build on need not be the machine you run
  on, and the toolchain is named after its target.
- **Bootloaders and probation**: try the new thing, fall back if it does not
  confirm itself. You saw the identical pattern in firmware updates and in the USB
  bind guard.
- **Testing what has no hardware in it.** `bars.c` is tested on a laptop because
  the arithmetic was kept separate from the pins.
- **Checks that cannot fail are not checks.**

## Things to build, roughly by effort

### Small — an afternoon

**Put the CPU temperature on the matrix.** The zones are already there:

```bash
cat /sys/class/thermal/thermal_zone3/temp
```

`unoq.thermal` already reads them (`read_temps()`, `hottest()`), and
`MCU.die_temp()` asks the microcontroller for its own. What is left is the
demo: turn a temperature into bar heights, as `unoq/cpu.py` does with load, and
make it a second mode of the existing one.

**Change what a status LED says.** All four are in use — see
[Four lights that tell the truth](four-lights.md) — but what each one reports is
a decision, and you may want a different one. LED 1 and LED 2 are driven by
`status/leds.sh`, LED 3 and LED 4 by `mcu/app/src/status_leds.c`. Pick a state
you care about, decide which color it deserves, and check your choice against
that chapter's rule: a change in the light must tell you something you did not
already know.

**Scroll text on the matrix.** 8×13 is enough for a font if you are careful, and
it makes you think hard about where the frame buffer lives and who owns the
timing.

### Medium — a weekend

**Read a real sensor over I²C.** The Qwiic connector is right there, the buses are
enabled, and `smbus2` is already installed. A temperature or distance sensor sampled
by the *microcontroller* at an exact interval, with Linux only displaying it, is
this project's architecture applied to something new. The BME680 behind
`--with-ble-sensor` is one worked example of the wiring; your sensor and
your split can be different.

**Add a serial console over USB.** The kernel has a CDC-ACM gadget function. Add
it and your laptop gets a COM port that is the MCU's console — no SSH needed.

**Make the microcontroller do something Linux cannot.** Generate a precise pulse
train; measure a pulse width to the microsecond; bit-bang a protocol. Anything
where being 2 ms late is a failure.

### Larger — a project

**Something with a real deadline.** A closed-loop controller: read, decide, act,
every N milliseconds without exception. This is where determinism stops being an
abstraction.

**Use the watchdog.** `./bootstrap.sh --with-watchdog` arms the Linux side's
hardware watchdog, so a wedged kernel resets the board instead of sitting there.
The microcontroller's own watchdog is already armed by the firmware, and
[Debugging without a screen](debugging-without-a-screen.md) made it fire;
if you add work of your own to the firmware, decide what it should watch.

**Use the empty microcontroller.** The application is about 110 KB of
2048 KB. The chip is about 95% empty.

## Where the open work is

The repository's [issues](https://github.com/jim-wyatt/two-computers-one-board/issues) list
real gaps, each written up with what was measured and why it matters — the
CDC-ACM console, the SPI link to the microcontroller, choosing a CPU governor
against the power budget, the CPU cores that never idle, and the mostly-empty
MCU flash.

They are deliberately not just "TODO: do X". Each says what is there now, what it
would buy, and what to be careful of. Several have a defensible *opposite*
answer — the one about the flash argues that the current bootloader strategy,
slow as it is, has been through a real rollback, and that is worth something.

## Before you change anything

The project has quality gates, and running them is faster than finding out later:

```bash
~/two-computers-one-board/tools/check.sh              # everything
~/two-computers-one-board/tools/check.sh --fast       # skip the two slow gates
~/two-computers-one-board/tools/check.sh python       # one area
```

Lint, formatting, strict type checking, tests at 100% coverage, shell linting, C
formatting, and the MCU test suites. The coverage gate is a ratchet: new code
needs a test.

If you add a page to this course, it is markdown in `docs/learn/`, with an
entry in the `nav:` list in `mkdocs.yml`. Then:

```bash
~/two-computers-one-board/tools/build-docs.sh
```

renders `docs/` into `share/learn/`, and fails on a broken link. That is the
copy to open and read. To put it on the drive and the web server as well, on a
board that has those extras:

```bash
sudo bash ~/two-computers-one-board/share/build-image.sh
```

which runs the same render itself and then copies the result into the drive
image. **Test every command you write down.** One of the pages in this course
claimed a measurement that turned out to be wrong the first time it was actually
run, and it was only caught because someone ran it.

## Where things are

The four places a newcomer edits first:

| | |
|---|---|
| `mcu/app/` | The firmware: `main.c`, `matrix.c` (the driver), `bars.c` (the arithmetic) |
| `mcu/app/include/app_proto.h` | The contract both sides agree on |
| `python/unoq/` | The Linux side: `cpu.py`, `thermal.py`, `mcu.py`, `fota.py`, `link.py`, the daemons `cpubars.py` and `learn.py`, and one module per later chapter's tool — `templog.py`, `jitter.py`, `heat.py`, `buildlight.py`, `blesensor.py` among them |
| `docs/` | This course, and the reference it links into |

The rest — `usb/`, `status/`, `provision/`, `share/`, `tools/`, `tests/` — is
described in
[Working on this project](../reference/development.md#where-things-are).

> [!TIP]
> **Go deeper** — [Further reading](../further-reading.md) is the annotated
> list of the free material this whole course is built on, grouped by which
> chapter it extends. If you only open three: **Operating Systems: Three Easy
> Pieces**, the **Zephyr documentation**, and **Bootlin's training slides**.

## Finally

The reference documentation — [hardware.md](../reference/hardware.md),
[mcu.md](../reference/mcu.md), [mpu.md](../reference/mpu.md),
[usb.md](../reference/usb.md),
[configuration.md](../reference/configuration.md),
[provisioning.md](../reference/provisioning.md),
[troubleshooting.md](../reference/troubleshooting.md) and
[development.md](../reference/development.md) —
will read very differently now than it would have on day one. It is written for
someone who knows what you now know, and it contains things that cost real days
to discover, like the two undocumented GPIO lines that make the difference
between a working board and one that looks dead.

That is the point of a learning path: not to replace the hard material, but to
get you to where it makes sense.

Go and build something that has to happen on time.

From here: the [reference index](../reference/index.md) for looking things up,
and the [glossary](../glossary.md) for any word that still does not sit right.
