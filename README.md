<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# Two computers, one board

There are two computers on the Arduino UNO Q, and they do not get along by
default: a Qualcomm QRB2210 running Debian Linux, and an STM32U585
microcontroller running Zephyr, wired together on one circuit board.

> This is an independent project. It is not made, reviewed or endorsed by Arduino,
> Qualcomm, STMicroelectronics, the Zephyr Project or anyone else whose hardware
> and software it describes.
> [Credits and trademarks](docs/third-party.md#trademarks-and-affiliation).

This repository does two things about that.

- **It sets the board up** as a Linux-first development environment, built on
  stock upstream tooling (Zephyr, west, OpenOCD, libgpiod) rather than the
  Arduino App framework. One script, safe to re-run.
- **It teaches the whole stack**, in a
  [course of fifteen chapters](https://jim-wyatt.github.io/two-computers-one-board/)
  written for someone who can program and has never done embedded work.

The worked example is a CPU monitor: Linux reads how busy its four cores are,
and the microcontroller draws one bar per core on the LED matrix. It is the
smallest thing that uses both halves of the board for what each is good at.

## Where to start

| You want to | Go to |
|---|---|
| **Learn** how a board like this works | [The course](docs/learn/start-here.md) — it reads fine before you own a board |
| **Set up** a board | [Set up a board](docs/setup.md), or the short version below |
| **Look something up** | [The reference](docs/reference/index.md) — pins, commands, settings, recovery |
| **Fix** something that is not working | [Troubleshooting](docs/reference/troubleshooting.md) |
| **Change** this project | [Working on this project](docs/reference/development.md) |

Everything under [`docs/`](docs/) reads fine here on GitHub, apart from
`docs/index.md`, which is the built site's home page. It is also built into a
site: [online](https://jim-wyatt.github.io/two-computers-one-board/),
served by the board itself, and carried on the USB drive the board presents, so
it works with no network at all.

## Set up a board

You need an UNO Q running the Debian image it shipped with, a USB-C cable that
carries data, and a terminal on the board as the `arduino` user.
[Step 0](docs/setup.md#step-0-get-a-terminal-on-the-board) gets you that
terminal from a factory-fresh board, over the USB cable, in four steps.
Then, on the board:

```bash
git clone https://github.com/jim-wyatt/two-computers-one-board.git ~/two-computers-one-board
cd ~/two-computers-one-board && ./bootstrap.sh
```

> [!WARNING]
> **This changes your board, and you run it at your own risk.** It switches off
> the desktop, Arduino's own services and automatic updates, and replaces the
> firmware on the microcontroller. App Lab and the Arduino workflow stop working until you
> put them back. The stock firmware is copied aside first. Read
> [Set up a board](docs/setup.md) before you run it.

That is the whole setup. It took 19 minutes on a factory-restored board over
home broadband. Most of the download is the Zephyr workspace (~2 GB) and SDK
(~0.8 GB), and it needs about 6 GB free. It has been run on the 4 GB / 32 GB
board; the 2 GB / 16 GB one is untested.
Run it as yourself; it asks for `sudo` where it needs it.

**If it stops, run it again.** Every step reports `changed` or `ok`, and a
second run picks up where the first one died rather than starting over. That is
the recovery path, by design. [Set up a board](docs/setup.md) covers what each
stage does, what success looks like, and what to do when a step fails.

A plain run sets up the whole board the course is taught on, including three
things that each cost you something. Leave any of them out by name:

```bash
./bootstrap.sh --no-cpu-bars       # no LED matrix demo at boot    (it holds the MCU's serial port)
./bootstrap.sh --no-learning       # no course served on :8080     (it has no password, on every network)
./bootstrap.sh --no-usb-gadget     # no network + drive over USB   (it takes the port from adb, and switches SSH on)
./bootstrap.sh --minimal           # none of the three
```

One more is opt-in, because it is hard to undo:

```bash
./bootstrap.sh --with-purge        # remove the Arduino packages
```

## The first five minutes afterwards

Open a new shell, so the shortcuts are loaded, then:

```bash
zbuild      # build the firmware in mcu/app, and sign it
zflash      # write it to the microcontroller
mcucon      # watch the microcontroller's console   (quiet until it prints; Ctrl-C to stop)
```

Talk to the microcontroller from Linux. `hpy` is the project's Python:

```bash
hpy
```

```python
from unoq import MCU
with MCU() as mcu:
    print(mcu.status())            # {'uptime_ms': 12216, 'flip': 0, 'sweeps': 0}
    mcu.bars([25, 50, 75, 100])    # four bars on the LED matrix
    print(mcu.status())            # ...and now 'sweeps' is counting
```

And run the demo:

```bash
hpy -m unoq.cpubars                # your CPU load, one bar per core (Ctrl-C to stop)
```

Only one program can hold the serial line to the microcontroller at a time. The
demo is already running and has it, unless you set up with `--no-cpu-bars`; stop
it before any of the above with `sudo systemctl stop unoq-cpu-bars`.

## The one thing that will bite you

Two GPIO lines on the Linux side control the microcontroller, and are
documented nowhere by the manufacturer:

| `gpiochip1` line | What it is | Symptom when it is wrong |
|---|---|---|
| **37** | The microcontroller's BOOT0 | firmware flashes and *verifies*, and never runs |
| **70** | Serial link enable | the microcontroller transmits, and Linux reads nothing |

`bootstrap.sh` installs a service that sets both at every boot, and `zflash` and
the `unoq` package set them too, so you should never have to. If the board looks
dead after a reboot, this is the first thing to check:
[hardware.md](docs/reference/hardware.md).

## What is in here

```
bootstrap.sh     stock board -> working board, one command
env.sh           the shell shortcuts: zbuild, zflash, mcucon
docs/            the course (learn/) and the reference (reference/)
mcu/             the microcontroller side: the firmware, its tests, build and flash scripts
python/          the Linux side: the unoq package, and its tests
provision/       what bootstrap.sh runs, one numbered script per step
usb/             network and a drive over the USB cable
status/          the status LEDs
share/           the drive image the board hands out
tests/           tests for the shell scripts
tools/           the quality gates, and maintenance scripts
```

[Working on this project](docs/reference/development.md) has the detailed map,
the quality gates, and the conventions.

## Getting help

Start with [Troubleshooting](docs/reference/troubleshooting.md), which is
organised by symptom. If `bootstrap.sh` fails and running it again does not
help, [open an issue](https://github.com/jim-wyatt/two-computers-one-board/issues)
and paste the output from the last `==` heading down. The step name and the
line marked `FAILED` are usually enough to find it.

This was built and tested on the UNO Q (`arduino,imola`). Nothing here has been
tested on any other board.

## Licence

MIT — see [LICENSE](LICENSE). A few files belong to other projects and keep
their own terms; they are listed in [third-party.md](docs/third-party.md).

The software is provided as is, with no warranty of any kind; the licence says
so in full. Product and company names appear only to say accurately what this
software runs on, builds with and talks to, and each belongs to its owner:
[trademarks and affiliation](docs/third-party.md#trademarks-and-affiliation).
