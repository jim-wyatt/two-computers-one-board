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
| **Deletes what it downloaded in order to install**: apt's package files, and the download caches of `uv` and `pip`. Nothing that is installed, and nothing of yours. | The home partition is 8 GB, and none of it is needed again. | `UNOQ_KEEP_CACHES=1` |
| **Adds a line to `~/.bashrc`**, a git pre-commit hook in the checkout, and VS Code machine settings if there are none. | The shell shortcuts, and settings that suit a small board. | Delete the line. |

[SECURITY.md](https://github.com/jim-wyatt/two-computers-one-board/blob/main/SECURITY.md)
says what you are trusting when you run it.

## Before you start

- **An Arduino UNO Q** running the Debian image it shipped with. This has been
  run on the model with 4 GB of memory and 32 GB of storage.
  [The smaller model](#the-2-gb-model) is untested.
- **A computer** to type on: Windows, macOS or Linux.
- **A USB-C cable that carries data**, between the two. Charge-only cables look
  identical and are common. If the board powers up and your computer never
  notices it, suspect the cable first.
- **The name and password of a wifi network** the board can use. The script
  downloads about 3 GB.
- **About 6 GB of free space** in the board's home directory. A factory-fresh
  board has about 7 GB, and the script checks. It ends up using 3.3 GB.
- **About 20 minutes**, most of which needs no attention.
  [How long each part took](#how-long-it-takes) is below.

You do not need a screen, a keyboard or a network cable for the board, and you
do not need to install anything from Arduino.

## Step 0: get a terminal on the board

Everything in this project is typed into a terminal *on the board*. A
factory-fresh board gives you one over the USB cable, using a small tool called
`adb`. It needs no network and no password, which is exactly why it is the way
in to a board that has neither yet.

### 1. Install `adb` on your computer

| Your computer | Type this in a terminal |
|---|---|
| Windows | `winget install Google.PlatformTools`, then close the terminal and open a new one |
| macOS | `brew install android-platform-tools` (needs [Homebrew](https://brew.sh)) |
| Debian or Ubuntu | `sudo apt install adb` |

`adb` is Google's tool for talking to Android devices over USB. The board is
not an Android device; it just speaks the same protocol on its USB port.

### 2. Plug the board in and open a terminal on it

Connect the board to your computer with the USB-C cable. That powers it too.
Give it a minute to start, then on your computer:

```bash
adb devices
```

```
List of devices attached
1269931879      device
```

One line with a number and the word `device` means your computer can see the
board. (Your number will be different.) Then:

```bash
adb shell
```

```
arduino@uno-q:~$
```

That prompt is the board. Everything from here on is typed there.

> [!TIP]
> **Nothing listed?** Try another cable first, then another USB port. An empty
> list with a cable that works usually means the board is still starting; wait
> a minute and run `adb devices` again.

### 3. Give the board a password

The `arduino` user has no password yet, and the setup needs one for `sudo`.

```bash
sudo arduino-passwd
```

Choose one you will remember. You will type it once when the setup starts, and
again whenever you log in over SSH later.

### 4. Connect the board to wifi

```bash
nmcli device wifi connect "your network name" --ask
```

It asks for the wifi password, and says `successfully activated` when it is
on. Check that the internet is really there:

```bash
curl -sI https://github.com | head -1
```

```
HTTP/2 200
```

That is the whole of step 0. The board has a password, it is online, and you
have a terminal on it.

> [!NOTE]
> **What has been checked.** These four steps and the whole setup that follows
> were run on a board freshly restored to the factory image, from a Windows 11
> computer, through to the board reappearing on the cable as a network adapter
> and a drive. The macOS and Linux install commands for `adb` are the standard
> ones and were not run as part of that. If you already use SSH or a screen
> and keyboard, any terminal logged in as `arduino` works just as well;
> Arduino's [user manual](https://docs.arduino.cc/tutorials/uno-q/user-manual/)
> and [SSH guide](https://docs.arduino.cc/tutorials/uno-q/ssh/) cover those,
> and [Updating the image](https://docs.arduino.cc/tutorials/uno-q/update-image/)
> is how you put the factory image back.

> [!NOTE]
> **If your board has been used before** — an App Lab project on it, packages
> removed, a previous attempt at this — the script will still do the right
> thing: it changes only what is not already as it should be. What this project
> has *verified* is a board freshly restored to the factory image.

## Run it

```bash
git clone https://github.com/jim-wyatt/two-computers-one-board.git ~/two-computers-one-board
cd ~/two-computers-one-board
./bootstrap.sh --with-cpu-bars      # what the course expects; plain ./bootstrap.sh also works
```

Run it as yourself, not with `sudo`. It prints what it is about to change,
waits ten seconds in case you want to stop it with Ctrl-C, then asks for your
password once. It uses `sudo` only for the steps that need it, so that
everything in your home directory stays owned by you.

Then leave it alone. Keep the terminal open and the cable in; there is nothing
to answer until it finishes.

### What you will see

Each stage prints a banner, then one line for everything it looked at:

```
########## 25  Zephyr SDK (you) ##########

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
| `10`, `15` | Switches off the desktop and the Arduino services that hold the hardware, upgrades the installed packages, and installs a compiler. |
| `20`, `25` | Installs the build tools and the Zephyr SDK, the cross-compiler for the microcontroller (~0.8 GB). |
| `30` | Downloads Zephyr itself (~2 GB). **This is the long download.** |
| `35`, `40` | Sets up Python and the `unoq` package, and the shell shortcuts. |
| `45`, `50` | Makes the two control lines to the microcontroller correct at every boot, and starts the status LEDs. |
| `60` | Builds this project's firmware and writes it to the microcontroller. |
| `65` | With `--with-cpu-bars`: the demo, as a service that starts at boot. |
| `90` | Gives back the disk space the downloads borrowed, and says how much. |

The numbers are the order things run in, and each is the start of a file name:
stage `25` is `provision/user/25-zephyr-sdk.sh`. The gaps are the
[optional extras](#the-optional-extras), which have numbers of their own.
Stages `20` to `40` run as you, and their banners say so; the others run as
root. [Provisioning](reference/provisioning.md) has what each one changes and
how to undo it.

### How long it takes

One run, timed from start to finish: a board just restored to the factory
image, on wifi to a home broadband connection, set up from `adb shell` with
`--with-cpu-bars --with-usb-gadget`. The board was sampled every five seconds.
Yours will differ with your connection; use this to know which parts are slow
and that a quiet terminal is normal.

| Stage | Took |
|---|---|
| The notice, and typing the password | 20 seconds |
| `10` switching things off and upgrading 144 packages | 7 minutes 21 seconds |
| `15` a compiler, and Arduino's services off | 1 minute 24 seconds |
| `20` build tools | 16 seconds |
| `25` Zephyr SDK | 42 seconds |
| `30` Zephyr | 2 minutes 21 seconds |
| `35`, `40` Python and shell | 37 seconds |
| `45`, `50` control lines and LEDs | 32 seconds |
| `60` building and signing the firmware | 2 minutes 50 seconds |
| `60` building the bootloader and flashing both | 2 minutes 28 seconds |
| `65` the demo service | 5 seconds |
| `70` the drive image | 37 seconds |
| `90` giving disk space back | 5 seconds |
| `95` the USB gadget | 47 seconds |
| **All of it** | **20 minutes 25 seconds** |

Then, with `--with-usb-gadget` from `adb shell`: the shell closed 24 seconds
after the run ended, and 21 seconds after that the board was back on the same
cable as a network adapter and a drive.

The two long silences are `10`, while packages upgrade, and the firmware
build. Neither prints much. Both are working.

A second run, when there is nothing left to install, took 90 seconds. Nearly
all of that is the firmware being built and flashed again.

### What it uses

Measured during the same run, on the 4 GB board:

| | |
|---|---|
| Most memory in use at once | 1.4 GB, while the firmware compiles. Every other stage stayed under 0.8 GB. |
| Swap used | 3 MB |
| Home directory when it finished | 3.9 GB used of 8 GB: 3.3 GB more than the factory image |
| `/` when it finished | 1.6 GB *less* than the factory image, because Arduino's container images go |

### The 2 GB model

The UNO Q is also sold with 2 GB of memory and 16 GB of storage. **Nobody has
run this on one**, so here is what the numbers above say and do not say.

Memory is probably not the obstacle: the peak was 1.4 GB, for the few minutes
the firmware compiles, and the board has compressed swap behind that. Expect
that stage to be slower.

Storage is the unknown. The setup needs 3.3 GB in the home directory, and on
the 32 GB model that directory has an 8 GB partition to itself. How the 16 GB
model is divided has not been looked at. Before you start, check:

```bash
df -h /home/arduino
```

If it shows less than 6 GB available, the script will warn and carry on. Below
about 4 GB it is unlikely to finish. If you try it, an
[issue](https://github.com/jim-wyatt/two-computers-one-board/issues) saying
what happened, either way, would settle the question for everyone after you.

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

    - **The firmware.** Stage `60` builds it and flashes it
      again on every run, and says `changed` for each. That is deliberate: it
      is how a board ends up running the firmware in the checkout.
    - **The drive image**, if you asked for `--with-learning` or
      `--with-usb-gadget`. Stage `70` renders the documentation onto it again
      each time.

    For a run that is nothing but `ok`, leave the firmware out and do not ask
    for the drive:

    ```bash
    ./bootstrap.sh --skip-mcu
    ```

2. **Look at the four small LEDs**, in a row at the end of the board opposite
   the USB-C port. Steady green on all four is a healthy board. From the edge
   inwards:

    | | Steady green means |
    |---|---|
    | LED 4, nearest the edge | the microcontroller is hearing from Linux |
    | LED 3 | the new firmware is running, and has confirmed itself |
    | LED 2 | nothing on the Linux side has failed |
    | LED 1 | the board can reach the internet |

    LED 4 is green only with `--with-cpu-bars`, because that demo is what talks
    to the microcontroller; without it LED 4 blinks red, which is correct. One
   that blinks red is telling you something specific;
   [Four lights](learn/four-lights.md) says what, or run
   `~/two-computers-one-board/status/leds.sh explain`.

3. **Look at the LED grid**, if you set it up with `--with-cpu-bars`. Four bars of
   light on the LED grid, moving. That is Linux measuring its four processor
   cores and the microcontroller drawing them: both halves working, and
   talking.

4. **Or ask the microcontroller directly**, if you did not. Open a new shell,
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

Either of the last two means both halves of the board work and can talk to
each other.
Go to [Start here](learn/start-here.md).

## When it stops

**Run it again.** That is not a figure of speech. A download that timed out, a
mirror that was briefly down, a board that lost power: the second run skips
everything that finished and picks up at the step that did not.

If the same step fails twice, the output tells you where to look:

- The **banner** above the failure names the stage, and the stage is a script
  you can read: `25` is `provision/user/25-zephyr-sdk.sh`.
- The line marked **`FAILED`** says what went wrong, and where the tool that
  failed had something to say, its own output is printed just above.
- The firmware build and flash at the end keep their logs in
  `/tmp/zbuild-bootstrap.log` and `/tmp/zflash-bootstrap.log`.

Then look in [Troubleshooting](reference/troubleshooting.md), which is arranged
by symptom. If it is not there,
[open an issue](https://github.com/jim-wyatt/two-computers-one-board/issues)
with the output from the last banner down.

> [!TIP]
> You can run one stage by itself. `bash provision/user/25-zephyr-sdk.sh` runs
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
| `--with-usb-gadget` | Plug the board into a computer and it appears as a network connection and a drive. | `adb` stops working, because it needs the same USB port: the step switches SSH on first, and from then on you log in with `ssh arduino@<board name>.local` and your password. If you ran the setup from `adb shell`, **that shell closes about twenty seconds after the run ends**, which is the hand-over and not a crash. The USB-C port can also no longer host devices, so anything plugged into it, a network dongle included, stops working. Read [usb.md](reference/usb.md) first. |
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
