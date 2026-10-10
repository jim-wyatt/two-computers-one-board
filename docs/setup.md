<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# Set up a board

One script takes an Arduino UNO Q from the state it shipped in to the board the
[course](learn/start-here.md) is taught on. This page is what to have ready,
what you will see while it runs, how to tell it worked, and what to do when it
does not.

You do not need to understand what the script does to run it. The chapter
[From factory to this](learn/from-factory-to-this.md) explains it afterwards,
when you have the vocabulary.

## What you are agreeing to

> [!WARNING]
> **This changes your board, and you run it at your own risk.**
>
> Even with no options, the script switches off the desktop, Arduino's own
> services and automatic updates, and replaces the firmware on the
> microcontroller. App Lab and the Arduino workflow stop working until you put
> them back. The list is just below.
>
> It has been tested on one kind of board in one state: an UNO Q freshly
> restored to the factory image. There is no warranty of any kind — the
> [licence](https://github.com/jim-wyatt/two-computers-one-board/blob/main/LICENSE)
> says so in full — and nobody who made your board has reviewed any of this.
>
> What makes that a reasonable thing to do anyway: every change is written down
> with the command that undoes it, the stock firmware is copied aside before
> anything touches it, and [Recovery](reference/development.md#recovery) says
> how to go back.

### What a plain `./bootstrap.sh` changes

Nothing here needs an option to happen. Each line is a deliberate choice for a
board used as a headless development machine, and each can be put back.

| It does this | Because | To keep things as they were |
|---|---|---|
| **Replaces the firmware on the microcontroller** with this project's, behind a bootloader. Whatever sketch was running is gone. | It is what the course is taught on. The stock image is copied to `~/uno-q-backup` first, and if no copy can be made the flash is skipped and the run says so. | `./bootstrap.sh --skip-mcu` |
| **Switches off the desktop.** The board boots to a text login; if you are sitting at a screen plugged into it, that session ends. | Nothing here uses it, and it is ~218 MB of memory. | Run it over SSH. To undo: the `REVERT:` line in `provision/10-optimize-board.sh` |
| **Switches off Arduino's services and Docker,** and deletes the Arduino container images (~2 GB). App Lab stops working. | They hold the serial port and the control lines this project needs. | `UNOQ_KEEP_DOCKER_IMAGES=1` keeps the images. The services cannot stay on. |
| **Switches off automatic package updates** and the firmware updater. | Background work on a board with 3.6 GiB, competing with a compiler. | Updating is now yours to do: `sudo apt update && sudo apt upgrade` |
| **Upgrades every installed package**, once. | A freshly restored board needs it. | `UNOQ_SKIP_APT_UPGRADE=1` |
| **Switches off Bluetooth and `udisks2`.** | Nothing here uses them. | `UNOQ_TIER2=0` |
| **Installs services that run at every boot**, as root: the control lines to the microcontroller, and the status LEDs. They run copies of this checkout's scripts, kept in `/usr/local/lib/unoq/` and owned by root. | Without the first, the microcontroller looks dead after a reboot. The copies are so that changing a file in your home directory does not change what root runs. | — |
| **Pings `1.1.1.1` about once a minute.** | It is how the status LED knows whether there is a route out. | `UNOQ_LED_PROBE_IP`, in [What you can change](reference/configuration.md) |
| **Adds a line to `~/.bashrc`**, a git pre-commit hook in the checkout, and VS Code machine settings if there are none. | The shell shortcuts, and settings that suit a small board. | Delete the line. |

[SECURITY.md](https://github.com/jim-wyatt/two-computers-one-board/blob/main/SECURITY.md)
says what you are trusting when you run it.

## Before you start

- **An Arduino UNO Q** running the Debian image it shipped with.
- **A USB-C cable that carries data.** Charge-only cables look identical and are
  common. If the board powers up and nothing else works, suspect the cable
  first.
- **A terminal on the board**, logged in as the `arduino` user. Every command
  in this project is typed there. SSH from your own computer is the comfortable
  way to get one.
- **A network connection on the board.** The script downloads about 4.5 GB.
- **About 6 GB of free space** in the home directory. The script checks.
- **Somewhere between 40 and 60 minutes**, most of which needs no attention.

### Getting a terminal the first time

This project starts from a board you can already log into, and getting there is
Arduino's ground rather than this project's. Their pages for this board cover
it:

- [UNO Q user manual](https://docs.arduino.cc/tutorials/uno-q/user-manual/) —
  first power-up, and getting the board onto your network.
- [SSH](https://docs.arduino.cc/tutorials/uno-q/ssh/) — logging in from your
  own computer, which is the terminal every command here is typed into.
- [Updating the image](https://docs.arduino.cc/tutorials/uno-q/update-image/)
  — putting the factory image back, which is also how you undo everything this
  project does.

Those are Arduino's instructions, not this project's, and they have not been
checked against it step by step. Once `ssh arduino@<your board>` gives you a
prompt, you are where this page begins.

> [!NOTE]
> **If your board has been used before** — an App Lab project on it, packages
> removed, a previous attempt at this — the script will still do the right
> thing: it changes only what is not already as it should be. What this project
> has *verified* is a board freshly restored to the factory image, using
> Arduino's procedure linked above.

## Run it

```bash
git clone https://github.com/jim-wyatt/two-computers-one-board.git ~/two-computers-one-board
cd ~/two-computers-one-board
./bootstrap.sh --with-cpu-bars      # what the course expects; plain ./bootstrap.sh also works
```

Run it as yourself, not with `sudo`. It asks for your password once and uses
`sudo` only for the steps that need it, so that everything in your home
directory stays owned by you.

### What you will see

Each stage prints a banner, then one line for everything it looked at:

```
########## u20 Zephyr SDK ##########

== Zephyr SDK 1.0.1 (aarch64) ==
  changed  SDK unpacked to /home/arduino/zephyr-sdk-1.0.1
  changed  arm-zephyr-eabi installed

== verify ==
  ok      arm-zephyr-eabi-gcc (Zephyr SDK 1.0.1) 14.3.0
  ok      at /home/arduino/zephyr-sdk-1.0.1/gnu/arm-zephyr-eabi/bin/arm-zephyr-eabi-gcc

2 changed, 2 already correct.
```

There are four words, and they are the whole vocabulary:

| | Means |
|---|---|
| `changed` | This was not how it should be, and now it is. |
| `ok` | This was already right. Nothing was touched. |
| `warn` | Something is unusual. The run carries on; read the line. |
| `FAILED` | The run stops here. The line says what went wrong. |

### The stages

| Stage | What it does |
|---|---|
| preflight | Checks the board, `sudo`, free space and the network. Copies the stock microcontroller firmware somewhere safe. |
| `10`, `20` | Switches off the desktop and the Arduino services that hold the hardware, and installs a compiler. |
| `u10`, `u20` | Installs the build tools and the Zephyr SDK, the cross-compiler for the microcontroller (~1 GB). |
| `u30` | Downloads Zephyr itself (~3.3 GB). **This is the slow one**, and most of the hour. |
| `u40`, `u50` | Sets up Python and the `unoq` package, and the shell shortcuts. |
| `30`, `35` | Makes the two control lines to the microcontroller correct at every boot, and starts the status LEDs. |
| MCU firmware | Builds this project's firmware and writes it to the microcontroller. |
| `50` | With `--with-cpu-bars`: the demo, as a service that starts at boot. |

Stages starting with `u` run as you. The others run as root.
[Provisioning](reference/provisioning.md) has what each one changes and how to
undo it.

## How to tell it worked

The run ends with `########## done ##########` and a short list of things to
try. Then:

1. **Run it a second time.** This is the real test.

    ```bash
    ./bootstrap.sh
    ```

    On a correctly set up board every line of every provisioning stage — the
    ones with a number in the banner — is `ok`, and each of them ends
    `0 changed`. Those are idempotent: there is nothing to do, so they are
    quick.

    Two parts of the run are not, and report `changed` every time:

    - **The firmware.** The `MCU firmware` section builds it and flashes it
      again on every run, and says `changed` for each. That is deliberate: it
      is how a board ends up running the firmware in the checkout.
    - **The drive image**, if you asked for `--with-learning` or
      `--with-usb-gadget`. Stage `65` renders the documentation onto it again
      each time.

    For a run that is nothing but `ok`, leave the firmware out and do not ask
    for the drive:

    ```bash
    ./bootstrap.sh --skip-mcu
    ```

2. **Look at the board**, if you set it up with `--with-cpu-bars`. Four bars of
   light on the LED grid, moving. That is Linux measuring its four processor
   cores and the microcontroller drawing them: both halves working, and
   talking.

3. **Or ask the microcontroller directly**, if you did not. Open a new shell,
   so the shortcuts are loaded, and:

    ```bash
    hpy -c "from unoq import MCU; print(MCU().status())"
    ```

    ```
    {'uptime_ms': 12216, 'flip': 0, 'sweeps': 0}
    ```

    That answer came from the other computer on the board. `uptime_ms` is how
    long its firmware has been running; run the command again and it will have
    gone up. `sweeps` counts redraws of the LED grid and stays at 0 until
    something is drawn.

    (With `--with-cpu-bars` this command says the port is busy, and names the
    service holding it. That is correct: only one program can use the wire to
    the microcontroller at a time, and the demo has it.)

Either of those means both halves of the board work and can talk to each other.
Go to [Start here](learn/start-here.md).

## When it stops

**Run it again.** That is not a figure of speech. A download that timed out, a
mirror that was briefly down, a board that lost power: the second run skips
everything that finished and picks up at the step that did not.

If the same step fails twice, the output tells you where to look:

- The **banner** above the failure names the stage, and the stage is a script
  you can read: `u20` is `provision/user/20-zephyr-sdk.sh`.
- The line marked **`FAILED`** says what went wrong, and where the tool that
  failed had something to say, its own output is printed just above.
- The firmware build and flash at the end keep their logs in
  `/tmp/zbuild-bootstrap.log` and `/tmp/zflash-bootstrap.log`.

Then look in [Troubleshooting](reference/troubleshooting.md), which is arranged
by symptom. If it is not there,
[open an issue](https://github.com/jim-wyatt/two-computers-one-board/issues)
with the output from the last banner down.

> [!TIP]
> You can run one stage by itself. `bash provision/user/20-zephyr-sdk.sh` runs
> just the SDK step; the root stages want `sudo bash`. Each is as safe to
> re-run as the whole.

## The optional extras

Each of these is left out by default because it takes something away, and you
should know what before you agree to it.

**For the course, use `--with-cpu-bars`.** Its exercises are built around the
demo running as a service. The chapter on USB wants `--with-usb-gadget` as
well, and says so when you get there; nothing else needs an extra.

| Flag | Gives you | Costs you |
|---|---|---|
| `--with-cpu-bars` | The CPU-bars demo on the LED matrix from boot. | That service holds the serial line to the microcontroller. Stop it (`sudo systemctl stop unoq-cpu-bars`) before using the shell or the Python API. |
| `--with-usb-gadget` | Plug the board into a computer and it appears as a network connection and a drive. | The USB-C port can no longer host devices, so anything plugged into it, a network dongle included, stops working. Read [usb.md](reference/usb.md) first. |
| `--with-learning` | The course, served by the board on port 8080. | A small web server with no password, listening on every network the board is on. Anyone who can reach the board can read what it serves. |
| `--with-purge` | A few hundred MB of disk back, by removing the remaining Arduino packages. (The ~2 GB of container images go in the default run.) | It is the one step that is hard to undo. The stock firmware is backed up first. |
| `--everything` | All four. | All four. |
| `--with-watchdog` | The board resets itself if its kernel hangs, instead of waiting for someone to pull the cable. | It also resets if `systemd` merely stalls for 30 seconds. It has survived a clean firmware build with swap 80% full on one board, which is one measurement and not a promise. Not included in `--everything`. |
| `--with-esp-lockdown` | The EFI partition, and the random seed on it, readable by root only. Run on one board, through a reboot. | It edits the line of `/etc/fstab` the board boots from. The edit is checked before it is installed and the old file is kept as `/etc/fstab.unoq-esp.bak`. Not included in `--everything`. |

You can add any of them later by running `bootstrap.sh` again with the flag.
Everything already done is skipped.

## Next

- [Start here](learn/start-here.md) — the course, from the beginning.
- [The commands that matter](reference/index.md#the-commands-that-matter) — if
  you would rather poke at it first.
- [What you can change](reference/configuration.md) — every setting, in one
  place.
