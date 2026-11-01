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
> The script switches off the desktop, Arduino's own services and automatic
> updates, replaces the firmware on the microcontroller, and takes the USB port
> from `adb`, switching SSH on in its place. App Lab and the Arduino workflow
> stop working until you put them back. The list is just below.
>
> It has been tested on one kind of board in one state: an UNO Q freshly
> restored to the factory image. There is no warranty of any kind — the
> [license](https://github.com/jim-wyatt/two-computers-one-board/blob/main/LICENSE)
> says so in full — and nobody who made your board has reviewed any of this.
>
> What makes that a reasonable thing to do anyway: every change is written down
> with the command that undoes it, the stock firmware is copied aside before
> anything touches it, and [Recovery](reference/development.md#recovery) says
> how to go back.

### What a plain `./bootstrap.sh` changes

Nothing here needs an option to happen. `./bootstrap.sh --minimal` leaves out
the three rows about the demo, the web server and the USB port, and nothing
else. Each line is a deliberate choice for a
board used as a headless development machine, and each can be put back.

| It does this | Because | To keep things as they were |
|---|---|---|
| **Replaces the firmware on the microcontroller** with this project's, behind a bootloader. Whatever sketch was running is gone. | It is what the course is taught on. The stock image is copied to `~/uno-q-backup` first, and if no copy can be made the flash is skipped and the run says so. | `./bootstrap.sh --skip-mcu` |
| **Switches off the desktop.** The board boots to a text login; if you are sitting at a screen plugged into it, that session ends. | Nothing here uses it, and it is ~218 MB of memory. | It cannot be kept on. Use `adb` or SSH, not a screen plugged into the board. To undo afterwards: the `REVERT:` line in `provision/10-optimize-board.sh` |
| **Switches off Arduino's services and Docker,** and deletes the Arduino container images (~2 GB). App Lab stops working. | They hold the serial port and the control lines this project needs. | `UNOQ_KEEP_DOCKER_IMAGES=1` keeps the images. The services cannot stay on. |
| **Switches off automatic package updates** and the firmware updater. | Background work on a board with 3.6 GiB, competing with a compiler. | Updating is now yours to do: `sudo apt update && sudo apt upgrade` |
| **Upgrades every installed package**, once. | A freshly restored board needs it. | `UNOQ_SKIP_APT_UPGRADE=1` |
| **Switches off Bluetooth and `udisks2`.** | Nothing here uses them. | `UNOQ_TIER2=0` |
| **Installs services that run at every boot**, as root: the control lines to the microcontroller, and the status LEDs. They run copies of this checkout's scripts, kept in `/usr/local/lib/unoq/` and owned by root. | Without the first, the microcontroller looks dead after a reboot. The copies are so that changing a file in your home directory does not change what root runs. | — |
| **Pings `1.1.1.1` about once a minute.** | It is how the status LED knows whether there is a route out. | `UNOQ_LED_PROBE_IP`, in [What you can change](reference/configuration.md) |
| **Runs the CPU-bars demo from boot**: Linux measures its four cores, the microcontroller draws them on the LED grid. | It is the worked example the whole course is built on. It holds the one serial line to the microcontroller, so stop it (`sudo systemctl stop unoq-cpu-bars`) before using the shell or the Python API yourself. | `./bootstrap.sh --no-cpu-bars` |
| **Serves the course on port 8080**, from the board, with no password, on every network the board is on. | So the course is one address away from the computer next to it, and works with no internet. Anyone who can reach the board can read what it serves, which is this documentation. | `./bootstrap.sh --no-learning` |
| **Makes the USB port a network link and a drive.** `adb` stops working, because it needs the same port; SSH is switched on first, and is how you log in from then on. The port can no longer host devices such as a keyboard or a network dongle. | One cable then gives your computer the board's network, its name (`uno-q.local`) and the course as files. | `./bootstrap.sh --no-usb-gadget` keeps `adb` and leaves SSH as it was. |
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
- **About 20 minutes**, most of which needs no attention: 19 the last time it
  was timed.
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

**It prints nothing and waits.** There is no prompt, and what you type does
not appear. Type the password you want, once, and press Enter; you are back at
the `$` prompt and it is set. It looks exactly like a command that has hung,
and it has not.

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
./bootstrap.sh
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
| `65` | The CPU-bars demo, as a service that starts at boot. |
| `70`, `75` | Builds the drive image with this documentation on it, and starts the web server that serves it. |
| `90` | Gives back the disk space the downloads borrowed, and says how much. |
| `95` | Hands the USB port over from `adb` to the network link and the drive. Always last. |

The numbers are the order things run in, and each is the start of a file name:
stage `25` is `provision/user/25-zephyr-sdk.sh`. The gaps are the
[opt-in extras](#options), which have numbers of their own.
Stages `20` to `40` run as you, and their banners say so. So does `60`, the
firmware: it builds in your workspace, and must not be run with `sudo`. The
others run as root. [Provisioning](reference/provisioning.md) has what each
one changes and
how to undo it.

### How long it takes

One run, timed from start to finish: a board just restored to the factory
image, on wifi to a home broadband connection, set up from `adb shell` with a
plain `./bootstrap.sh`. The board was sampled every five seconds. Yours will
differ with your connection; use this to know which parts are slow and that a
quiet terminal is normal.

| Stage | Took |
|---|---|
| The notice, and typing the password | 30 seconds |
| `10` switching things off and upgrading 144 packages | 6 minutes 35 seconds |
| `15` a compiler, and Arduino's services off | 1 minute 13 seconds |
| `20` build tools | 16 seconds |
| `25` Zephyr SDK | 21 seconds |
| `30` Zephyr | 2 minutes 1 second |
| `35`, `40` Python and shell | 37 seconds |
| `45`, `50` control lines and LEDs | 31 seconds |
| `60` building and signing the firmware | 2 minutes 45 seconds |
| `60` building the bootloader and flashing both | 2 minutes 28 seconds |
| `65` the demo service | 11 seconds |
| `70` the drive image | 37 seconds |
| `75`, `90` the web server, and giving disk space back | 10 seconds |
| `95` the USB gadget | 44 seconds |
| **All of it** | **18 minutes 59 seconds** |

Then, because it was started from `adb shell`: the shell closed 25 seconds
after the run ended, and 20 seconds after that the board was back on the same
cable as a network adapter and a drive. The restart the run asks for took 42
seconds until the board could be logged into again.

An earlier run of the same kind, a day before and with two of the options given
by hand, took 20 minutes 25 seconds. The stages were within seconds of these.

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

The run ends with `########## done ##########`. If you started it from
`adb shell`, that shell then closes by itself, about twenty seconds later: the
board is handing its USB port over from `adb` to the network link. Nothing has
gone wrong. (With `--no-usb-gadget` or `--minimal` there is no hand-over: the
shell stays open, `adb` goes on working, and step 3 below does not apply.)

1. **Look at the four small LEDs**, in a row at the end of the board opposite
   the USB-C port. You do not need to be logged in for this. Steady green on
   all four is a healthy board. From the edge inwards:

    | | Steady green means |
    |---|---|
    | LED 4, nearest the edge | the microcontroller is hearing from Linux |
    | LED 3 | the new firmware is running, and has confirmed itself |
    | LED 2 | nothing on the Linux side has failed |
    | LED 1 | the board can reach the internet |

    One that blinks red is telling you something specific:
    [Four lights](learn/four-lights.md) says what. (Set up with
    `--no-cpu-bars`, LED 4 blinks red, which is correct: nothing is talking to
    the microcontroller.)

2. **Look at the LED grid.** Four bars of light, moving. That is Linux
   measuring its four processor cores and the microcontroller drawing them:
   both halves working, and talking.

3. **Log back in, over the same cable**, unless you left the USB link out.
   Your computer now sees the board as a
   network adapter and a drive called `UNO-Q`. From a terminal on your
   computer:

    ```bash
    ssh arduino@uno-q.local
    ```

    The password is the one you set in step 0. The first time, `ssh` asks
    whether you trust the board; answer `yes`. The course is in a browser on
    the same computer, at `http://uno-q.local:8080/`.

4. **Restart the board once.** The run upgraded the board's packages, and says
   so in its last lines; a restart puts everything on the new versions.

    ```bash
    sudo reboot
    ```

    It is back in about half a minute, and the LEDs and the grid should look
    the same as before. That is worth looking for: it shows the setup survives
    a restart, which is where a board is most likely to surprise you.

5. **Run it a second time, if you want proof.**

    ```bash
    cd ~/two-computers-one-board && ./bootstrap.sh
    ```

    It takes a minute and a half. Every numbered stage reports `ok` and ends
    `0 changed`, because there is nothing left to do, with three exceptions
    that say `changed` on every run: the firmware (stage `60`, built and
    flashed again each time, which is how a board ends up running the firmware
    in the checkout), the drive image (stage `70`, rendered again), and the
    USB hand-over (stage `95`, which rebuilds the link). For a run that is
    nothing but `ok`:

    ```bash
    ./bootstrap.sh --minimal --skip-mcu
    ```

    That changes nothing already installed; leaving something out of a later
    run does not remove it.

If you set up with `--no-cpu-bars`, there are no bars to look at. Ask the
microcontroller directly instead. Open a new shell, so the shortcuts are
loaded, and:

```bash
hpy -c "from unoq import MCU; print(MCU().status())"
```

```
{'uptime_ms': 12216, 'flip': 0, 'sweeps': 0}
```

That answer came from the other computer on the board. `uptime_ms` is how long
its firmware has been running; run the command again and it will have gone up.
(With the demo running, the same command says the port is busy and names the
service holding it. That is correct: only one program can use the wire to the
microcontroller at a time, and the demo has it.)

Green lights and moving bars mean both halves of the board work and can talk
to each other. Go to [Start here](learn/start-here.md).

## When it stops

**Run it again.** That is not a figure of speech. A download that timed out, a
mirror that was briefly down, a board that lost power: the second run skips
everything that finished and picks up at the step that did not.

If the same step fails twice, the output tells you where to look:

- The **banner** above the failure names the stage, and the stage is a script
  you can read: `25` is `provision/user/25-zephyr-sdk.sh`.
- The line marked **`FAILED`** says what went wrong, and where the tool that
  failed had something to say, its own output is printed just above.
- The firmware stage (`60`) keeps its build and flash logs in
  `/tmp/zbuild-bootstrap.log` and `/tmp/zflash-bootstrap.log`.

Then look in [Troubleshooting](reference/troubleshooting.md), which is arranged
by symptom. If it is not there,
[open an issue](https://github.com/jim-wyatt/two-computers-one-board/issues)
with the output from the last banner down.

> [!TIP]
> You can run one stage by itself. `bash provision/user/25-zephyr-sdk.sh` runs
> just the SDK step; the root stages want `sudo bash`. Each is as safe to
> re-run as the whole.

## Options

A plain run sets up everything the course uses. The options are for leaving
something out, or for adding one of the things that are not for everybody.

### Leaving something out

| Option | Leaves out | You would, if |
|---|---|---|
| `--no-cpu-bars` | The CPU-bars demo at boot. | You want the serial line to the microcontroller for yourself from the start. The course's exercises assume the demo is there. |
| `--no-learning` | The web server on port 8080. | The board is on a network where a page with no password should not be. The same pages are still on the drive. |
| `--no-usb-gadget` | The network link and drive over USB. | You want to keep `adb`, or you use the USB-C port for a dock, a keyboard or a network dongle. SSH is left as it was, which on a factory-fresh board is off. |
| `--minimal` | All three. | You want the toolchain, the firmware and the status LEDs, without the demo, the web server or the USB link. |
| `--skip-mcu` | Building and flashing the firmware. | You want the microcontroller left exactly as it is. |

If you ran the setup from `adb shell` without `--no-usb-gadget`, **that shell
closes about twenty seconds after the run ends.** That is the hand-over to the
USB network link, not a crash; log in again with
`ssh arduino@<board name>.local` and your password. [usb.md](reference/usb.md)
has the detail.

### Adding something

| Option | Gives you | Costs you |
|---|---|---|
| `--with-purge` | A few hundred MB of disk back, by removing the remaining Arduino packages. (The ~2 GB of container images go in the default run.) | It is the one step that is hard to undo. The stock firmware is backed up first. |
| `--with-temp-log` | The microcontroller's temperature, sampled once a second on its own clock, kept on Linux with the board's own temperatures beside it, and graphed at `http://<board name>.local:8080/data/`. The chapter [Two clocks, one record](learn/two-clocks-one-record.md) is about it. | The CPU-bars demo: both need the one serial line, so this replaces it. About 4 MB of disk a day. A later plain run keeps the logger; `sudo systemctl disable --now unoq-temp-log && sudo bash provision/65-cpu-bars.sh` brings the demo back. |
| `--with-buildlight` | A build light: the LED matrix shows whether a GitHub Actions workflow last passed (a check), failed (a cross), is running (a moving bar), or can't be read (a question mark). It watches this project's `ci.yml` until you change `/etc/unoq/buildlight.env`. | The CPU-bars demo, for the same reason as the logger, and it can't be had with `--with-temp-log`. One request a minute to `api.github.com`. A later plain run keeps it; `sudo systemctl disable --now unoq-buildlight && sudo bash provision/65-cpu-bars.sh` brings the demo back. |
| `--with-ble-sensor` | The board as a Bluetooth sensor: a BME680 breakout wired to the header (3.3 V, GND, SDA, SCL) reports temperature, humidity and pressure to a phone, as the standard Environmental Sensing service that nRF Connect and similar apps read with no setup. Wiring and the phone's view are in [mpu.md](reference/mpu.md#bluetooth-sensor). | The CPU-bars demo, for the same reason as the logger, and it can't be had with `--with-temp-log` or `--with-buildlight`. Bluetooth is switched back on, which the default run switches off, and anything in range can read the values. Needs the part, and has not been tried with one yet. A later plain run keeps it; `sudo systemctl disable --now unoq-ble-sensor && sudo bash provision/65-cpu-bars.sh` brings the demo back. |
| `--with-watchdog` | The board resets itself if its kernel hangs, instead of waiting for someone to pull the cable. | It also resets if `systemd` merely stalls for 30 seconds. It has survived a clean firmware build with swap 80% full on one board, which is one measurement and not a promise. |
| `--with-boot-counting` | A new kernel boots on trial. If it doesn't come up with SSH three boots running, the board goes back to the previous kernel by itself. | Nothing until the next kernel is installed. |
| `--with-rescue-entry` | A rescue boot entry: SSH over the USB cable, at `ssh root@169.254.77.1`, from a system that mounts neither root. Reached on purpose, or when every kernel has failed its tries. It needs your SSH key on the board first (`ssh-copy-id`). | About 40 MB on the EFI partition. It has not been booted on a board yet; [Troubleshooting](reference/troubleshooting.md#booting-the-rescue-entry-once) has the safe way to try it once. |
| `--with-recovery` | `--with-boot-counting` and `--with-rescue-entry` together. | Both of the above. |
| `--with-esp-lockdown` | The EFI partition, and the random seed on it, readable by root only. Run on one board, through a reboot. | It edits the line of `/etc/fstab` the board boots from. The edit is checked before it is installed and the old file is kept as `/etc/fstab.unoq-esp.bak`. |

You can change your mind later by running `bootstrap.sh` again with a
different set. Everything already done is skipped. Leaving an option out on a
later run does not remove what an earlier run installed;
[Provisioning](reference/provisioning.md) has the command that undoes each.

`--with-cpu-bars`, `--with-learning`, `--with-usb-gadget` and `--everything`
are still accepted, for commands copied from older pages. `--everything` adds
`--with-purge` and `--with-boot-counting`.

## Next

- [Start here](learn/start-here.md) — the course, from the beginning.
- [The commands that matter](reference/index.md#the-commands-that-matter) — if
  you would rather poke at it first.
- [What you can change](reference/configuration.md) — every setting, in one
  place.
