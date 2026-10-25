<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# Troubleshooting

Symptom → cause. Most of these cost real time to diagnose the first time.

## What a healthy boot looks like

Read this before chasing anything in the logs. A boot with **zero failed units
and every service working** still prints a dozen alarming lines at priority
`err` and `warning`. None of them is a fault.

### The test

A line that is there on **every boot** is scenery. Compare this boot with the
previous one:

```bash
sudo journalctl -b -p err -o cat | sort | uniq -c      # this boot
sudo journalctl -b -1 -p err -o cat | sort | uniq -c   # the previous one
```

A line that is new is the one worth reading. The count is a weaker signal than
it sounds: on the board this was last checked on (10 October 2026, kernel
7.0.0) one boot had 13 lines at `err` and the next had 17, and the whole
difference was the `tmux-spawn` line below, which is printed once for every
terminal pane you open.

The health check itself is short:

```bash
systemctl --failed                         # must list nothing
systemctl list-units 'unoq-*' --all        # none of them "failed"
```

### Lines every healthy boot prints

At priority `err`:

```
pm4125_codec 1c40000.spmi:pmic@0:audio-codec@f000: missing qcom,mbhc-buttons-vthreshold-microvolt entry
va_macro a730000.codec: qcom,dmic-sample-rate dt entry missing
qcom-soundwire a610000.soundwire: din-ports (0) mismatch with controller (1)
qcom-soundwire a610000.soundwire: dout-ports (5) mismatch with controller (6)
qcom-soundwire a740000.soundwire: din-ports (3) mismatch with controller (4)
MultiMedia1: ASoC: no backend DAIs enabled for MultiMedia1, possibly missing ALSA mixer-based routing or UCM profile
qcom_q6v5_pas ab00000.remoteproc: timeout waiting for ssctl service
/usr/lib/udev/rules.d/90-alsa-restore.rules:18 GOTO="alsa_restore_std" has no matching label, ignoring.
CPUidle PSCI: failed to create CPU PM domains ret=-517
CPUidle PSCI: CPU 0 failed to PSCI idle
CPUidle PSCI: Failed to create psci-cpuidle device
Bluetooth: hci0: Frame reassembly failed (-84)
Failed to start tmux-spawn-….scope - tmux child pane … launched by process …
```

And at `warning`, the two that look worst:

```
! Random seed file '/boot/efi/loader/random-seed' is world accessible, which is a security hole! !
File /var/log/journal/…/system.journal corrupted or uncleanly shut down, renaming and replacing.
```

| Lines | What it is |
|---|---|
| `pm4125_codec`, `va_macro`, `qcom-soundwire`, `MultiMedia1: ASoC` | The vendor devicetree describing audio hardware this board does not expose. Not this project's. |
| `90-alsa-restore.rules … no matching label` | A Debian packaging wart in the ALSA udev rules. |
| `CPUidle PSCI: …` | Real, and not harmless in the long run: the CPU cores have no idle states on this kernel. It breaks nothing you will notice. Tracked as [issue #39](https://github.com/jim-wyatt/two-computers-one-board/issues/39). |
| `Random seed file … world accessible` | Real, and small. `/boot/efi` is FAT, which has no permission bits, so every file on it reads as `755` whatever you `chmod`. `./bootstrap.sh --with-esp-lockdown` fixes it with mount options; see [provisioning](provisioning.md). |
| `system.journal corrupted or uncleanly shut down` | The board lost power without being shut down, which is how most people turn it off. It reads like data loss and is the journal starting a new file. |
| `tmux-spawn-….scope` | From your login session, not the board: a cgroup delegation problem in `systemd --user`. One line per terminal pane. Harmless to the services. |
| `qcom_q6v5_pas … ssctl`, `Bluetooth: hci0: Frame reassembly failed` | Seen on consecutive healthy boots. Nobody has explained them. |

The last row is listed because those lines pass the test above, not because
anyone knows what they mean.

### Two minutes of userspace is deliberate

`systemd-analyze` reports a little over two minutes of userspace time. That is
not a slow boot. `unoq-usb-confirm.service` waits 120 seconds on purpose before
it declares the boot healthy and clears the bind guard's counter, and the boot
is not "finished" until it has:

```bash
systemd-analyze blame | head -3
```

```
2min 116ms unoq-usb-confirm.service
   19.934s unoq-usb-gadget.service
    6.661s dev-mmcblk0p68.device
```

Everything else is up long before that. See
[From power to prompt](../learn/from-power-to-prompt.md).

### What each unit logs when it is working

```bash
sudo journalctl -b -u unoq-usb-gadget -o cat      # or any other unit
```

Taken from a healthy boot with the USB-C port in **host** mode and the board on
wifi. With the port plugged into a computer the USB lines differ: there will be
a bind attempt, and a lease.

```
unoq-link             UNO Q link up: BOOT0(line 37)=0  UART-enable(line 70)=1  on /dev/gpiochip1
unoq-usb-gadget       gadget built (c.1 = ncm.usb0 + mass_storage)
                      built only, not binding (--build)
                      created br-usb
                      no gadget interfaces yet - the bridge is up and waiting
                      asking for 192.168.137.210 again (last address on this link)
unoq-usb-confirm      already confirmed
unoq-uplink-fallback  wifi is already on - nothing to do
unoq-learn            serving /srv/unoq-share on port 8080
```

Three things here read like problems and are not.

**`built only, not binding` and `no gadget interfaces yet` look like a failure
to start.** They are the gadget being prepared and then waiting. Nothing can
bind until the port is plugged into a computer; see [usb.md](usb.md).

**`unoq-uplink-fallback` logging at all looks like a fallback fired.** The
opposite: it checked, and there was nothing for it to do.

**`bind attempt 1/3`, when the port is plugged into a computer, looks like a
retry.** It is the first and only attempt. The counter belongs to the bind
guard, and `unoq-usb-confirm` clearing it two minutes later is the success
signal.

`unoq-usb-bind`, `unoq-usb-confirm` and `unoq-uplink-fallback` show as
`inactive (dead)` once they have run. They are one-shot jobs, and that is what
finished looks like.

## The board looks dead

**Firmware flashed and "Verified OK", but nothing runs.**
BOOT0 (`gpiochip1` line 37) is high or floating, so the STM32 booted its ROM
bootloader instead of your image. Confirm by reading the PC — anything around
`0x0bf9xxxx` is ROM, not flash:

```bash
/opt/openocd/bin/openocd -s /opt/openocd -f /opt/openocd/openocd_gpiod.cfg \
  -c init -c "reset run" -c "sleep 1000" -c halt -c "reg pc" -c shutdown
```

Fix: `~/two-computers-one-board/mcu/link-up.sh`, then re-flash. Check `unoq-link.service` is
enabled so it survives reboots.

**`/dev/ttyHS1` reads zero bytes, but the MCU seems fine.**
The UART link-enable (`gpiochip1` line 70) is not driven high. The MCU
transmits happily into a disconnected path. Same fix: `link-up.sh`.

To prove the MCU is actually alive and transmitting, check `LPUART1` — `CR1`
should show UE/TE/RE set (`0x2d`) and `ISR` should show TC/TXE:

```
mdw 0x46002400 1    # CR1
mdw 0x4600241c 1    # ISR
```

**The link was fine until I inspected it.**
You ran `gpioget` on line 37 or 70. It requests the line as an input, which drops
the drive — reading these pins breaks them. The values it returns (`37=active`,
`70=inactive`) look like a diagnosis but are just the floating state you created.
Fix: `link-up.sh`. Check them non-destructively instead:

```bash
gpioinfo -c gpiochip1 37 70      # both must say `output`
```

See [hardware.md](hardware.md#the-two-gpios-nobody-documents).

**`Device or resource busy` on `/dev/ttyHS1`, or `PortBusy` from Python.**
Something else holds it — the `unoq-cpu-bars` service, `tio`, `mcucon`, a stale
Python handle, or (if it were re-enabled) `arduino-router`. The usual answer is
`sudo systemctl stop unoq-cpu-bars`; the full entry, with the message text, is
[under LED matrix](#the-serial-port-is-busy). If nothing appears to hold it,
see [the note on `tio`](#tio-can-leave-the-port-unusable-after-it-exits).

**LED 3 is yellow.**
The MCU is running a firmware image that has not been confirmed, so the next
reset puts the previous one back. That is what an update over serial looks like
until you confirm it. To keep the image:

```bash
sudo systemctl stop unoq-cpu-bars
hpy -c "from unoq import fota; fota.confirm(); print(fota.images())"
sudo systemctl start unoq-cpu-bars
```

To reject it, reset the MCU without confirming. See
[mcu.md](mcu.md#update-over-serial-no-swd).

**LED 3 and LED 4 are dark, and so is the matrix.**
The microcontroller is not running this project's firmware: nothing is driving
its two LEDs. Within about two and a half minutes LED 2 starts blinking red
as well, because the demo gives up trying to reach it and
`systemctl --failed` lists `unoq-cpu-bars.service`. Put the firmware back,
then start the demo again:

```bash
~/two-computers-one-board/mcu/zbuild.sh && ~/two-computers-one-board/mcu/flash-all.sh
sudo systemctl reset-failed unoq-cpu-bars && sudo systemctl start unoq-cpu-bars
```

The one known cause that is not something you did: Arduino's
`arduino-burn-bootloader.service`, which writes the stock bootloader over the
chip at boot. Setup disables it; `systemctl is-enabled arduino-burn-bootloader`
should say `disabled`.

**LED 3 is red.**
A part of the firmware failed to start. At present that means the LED matrix:
the MCU's boot output says `LED matrix unavailable`. See
[LED matrix](#led-matrix).

**LED 4 is red.**
The MCU has not received one of the firmware's `app` commands for four seconds.
On a board without `unoq-cpu-bars` that is the normal state: nothing is talking
to it. On a board with the service, check it is running:

```bash
systemctl status unoq-cpu-bars
journalctl -u unoq-cpu-bars -n 20 --no-pager
```

If the service is running and LED 4 is still red, the serial link is not
carrying data. Run `~/two-computers-one-board/mcu/link-up.sh` and see the
entries above.

**LED 2 is red.**
Something needs a person: a systemd unit has failed, or the USB bind guard has
reached its limit.

```bash
systemctl --failed
~/two-computers-one-board/usb/bind-guard.sh status
```

Fix the unit and `sudo systemctl reset-failed <unit>`, or see
[the bind guard](usb.md#the-bind-guard). The LED follows within about five
seconds. What all four LEDs mean: `~/two-computers-one-board/status/leds.sh
explain`.

## Serial output is wrong or missing

**A stock Zephyr sample prints nothing.**
Upstream defaults `zephyr,console` to `usart1`, which is the *Arduino header
pins*, not the MPU link. Override to `lpuart1` — see
[`mcu/app/boards/arduino_uno_q.overlay`](../../mcu/app/boards/arduino_uno_q.overlay).

**Shell prompt fights with application output.**
Do not `printk` on a timer when the shell is enabled. Expose a shell command
instead and let the MPU poll it.

## Build and flash

**`nothing built yet: … zephyr.signed.hex is missing - run zbuild first`.**
`zflash` (`mcu/flash.sh`) with no image named flashes this project's own build,
and there is not one yet. Run `zbuild`, then `zflash` again.

**`openocd missing at /opt/openocd/bin/openocd`.** `flash.sh` looks for OpenOCD
under `/opt/openocd`, and it is not there. Check with `ls /opt/openocd/bin/`. To
build it again, see [Rebuilding OpenOCD](development.md#rebuilding-openocd). If
you have a copy somewhere else, name it: `OCD_ROOT=/path/to/openocd zflash`.

**`MISSING: <tool> - run tools/install-dev-tools.sh`** from `tools/check.sh`. A
quality gate's tool is not installed, and a missing tool is a failure, not a
skip. Run the command it names:
`~/two-computers-one-board/tools/install-dev-tools.sh` (no `sudo`, no `apt`).

**`west flash` fails with `stm32cubeprogrammer not found`.**
That is the board's default runner and it is not installed. Use `-r openocd`,
or `zflash`.

**`west flash -r openocd` crashes in `samefile()`.**
Zephyr's runner resolves board support in-tree and `uno_q` ships no `support/`
directory (`runners/openocd.py:92`). Restore it:

```bash
cp -r ~/two-computers-one-board/mcu/board-support/support ~/zephyrproject/zephyr/boards/arduino/uno_q/
```

Needed again after a Zephyr version bump.

**Two errors on every flash:**
`Translation from khz to adapter speed not implemented` and
`Execution of event reset-init failed`. Harmless — the bitbang adapter has no
configurable speed. Programming and verify still succeed.

**Board stops booting after flashing.**
You probably flashed the unsigned `zephyr.hex` over the MCUboot chain. It links
into slot0 with no image header, so the bootloader refuses it. Recover with
`~/two-computers-one-board/mcu/flash-all.sh`.

**`native_sim` fails with a `CONFIG_64BIT` error.**
Use `native_sim/native/64` — the plain target is 32-bit and this is aarch64.

**`Error finding board: arduino_uno_q` / `No module named 'jsonschema'`.**
Something configured `mcu/app` with a bare `cmake` instead of `west`, so
`list_boards.py` ran under `/usr/bin/python`. Zephyr's script dependencies live
only in `~/zephyrproject/.venv`, which is the interpreter `west` uses.

Usually the culprit is the **CMake Tools extension**: it prompts on open, writes
`cmake.sourceDirectory` into `.vscode/settings.json` itself, and then configures
into a stray `two-computers-one-board/build/` on every window open. It is listed under
`unwantedRecommendations` — uninstall it, and delete both the setting and the
directory. Build with the **MCU: build** task (`zbuild.sh`); `clangd` needs
nothing from CMake Tools, only the `compile_commands.json` that build symlinks.

## SMP / MCUmgr

**`mcumgr: command not found` in the shell.**
Expected. SMP-over-shell registers no command; the shell sniffs SMP frames out
of the byte stream.

**SMP times out right after using the shell.**
The UART needs a settle delay between handles. `unoq` does this for you; raw
scripts must close, sleep, then open.

**MCUmgr features silently missing.**
`CONFIG_MCUMGR_TRANSPORT_SHELL` disables itself without `CONFIG_BASE64` and
`CONFIG_CRC`. Kconfig warns but the build succeeds — check the generated
`.config`, not just the build log.

## LED matrix

**The panel stays dark.**
It starts lazily — nothing is lit until the first `app bars` or `app matrix px`.
After that, check `sweeps` in `app status` is climbing by ~962/s: a count stuck
at zero means the refresh timer never started, and the boot log says `LED matrix
unavailable` if `gpiof` or `timers17` were missing from the devicetree.

**The bars hang from the top instead of standing on the bottom.**
The panel's orientation depends on how the board is mounted and the firmware
cannot know it. `app matrix flip` rotates 180° and stores that in NVS.

**`app bars` says `usage` or `outside 0..100`.**
One to seven values, each 0..100. `unoq.MCU.bars()` clamps percentages for you
but raises on the wrong *number* of bars — see [mpu.md](mpu.md#cpu-bars-on-the-led-matrix).

**Something else on PF0..PF10 misbehaves.**
Those eleven pins are the matrix. The refresh ISR retakes them every 10 µs, so
any other user of them will lose. PF11–PF15 are untouched.

### The serial port is busy

**`/dev/ttyHS1` is "device busy" — `mcucon`, `tio` and `unoq.MCU` all fail.**
The boot service is probably running and holding the port open.
`sudo systemctl stop unoq-cpu-bars`, and start it again when you have finished.
Flashing over SWD is unaffected.

Since [#55] `unoq.MCU` and `mcucon` report this properly. `unoq.MCU` raises `PortBusy` (and `mcucon` prints it),
which names the process holding the port and the command to stop it, instead of
surfacing a bare `errno 16`:

```
unoq.mcu.PortBusy: /dev/ttyHS1 is flagged exclusive. Open right now: unoq-cpu-bars (pid 812).
  Stop it first - for the demo that is:  systemctl stop unoq-cpu-bars
```

The other form of the message begins the same way and continues `but no process
this user can see has it open`. That is the case in the note below, and the
message ends with the fix: `systemctl restart unoq-cpu-bars`.

> ### `tio` can leave the port unusable after it exits
>
> This is the confusing one, and it looks like a hardware fault.
>
> There are **two different locks** on a serial port and they do not see each
> other. `flock` — which is what pyserial's `exclusive=True` takes — is
> *advisory*: it stops another pyserial caller and nothing else. `TIOCEXCL` —
> which is what `tio` and `screen` set — is enforced by the kernel, and any
> later `open()` fails with `EBUSY`.
>
> **`TIOCEXCL` is per-tty state, cleared only when the *last* file descriptor
> closes.** `unoq-cpu-bars.service` holds the port open permanently. So a `tio`
> that is killed rather than quit cleanly can leave the flag set with nothing
> to show for it:
>
> ```console
> $ sudo lsof /dev/ttyHS1
> unoq-cpu- 255481 arduino 3uW CHR 237,1 0t0 149 /dev/ttyHS1
> $ hpy -c "import os; os.open('/dev/ttyHS1', os.O_RDWR)"
> OSError: [Errno 16] Device or resource busy
> ```
>
> The only process listed is the one that has always had it open and is not the
> cause. Nothing in `lsof` explains the `EBUSY`, because the flag outlives the
> process that set it.
>
> ```bash
> sudo systemctl restart unoq-cpu-bars   # closes every fd, clearing the flag
> ```
>
> `unoq.MCU` now takes both locks itself (`open_port()` in
> `python/unoq/mcu.py`), which mostly closes this off: `tio` can
> no longer open the port while the service is running, so it cannot flag it.
> `tio` **waits silently** rather than reporting the refusal — it retries by
> default, so it looks like a hang. That is the port being held, not a fault.

[#55]: https://github.com/jim-wyatt/two-computers-one-board/issues/55

**The panel is stuck showing an old frame.**
Something killed the daemon with SIGTERM instead of SIGINT, so the cleanup that
blanks it never ran. `app matrix off`, or `hpy -c "from unoq import MCU;
MCU().matrix_off()"`. The systemd unit sets `KillSignal=SIGINT` to avoid this.

**You edited a script and the board still does what it did before.**
The services that run as root do not run the scripts in the checkout. They run
root-owned copies in `/usr/local/lib/unoq/`, and those change only when a
provisioning step is run. `usb/status.sh` says whether the two differ, under
*what root runs*. To refresh every copy:

```bash
sudo bash ~/two-computers-one-board/provision/50-status-leds.sh
```

When each script then takes effect is listed in
[Trying a script change on the board](development.md#trying-a-script-change-on-the-board).

**A provisioning step warns that units "still run as root from the checkout".**
The board was set up before root had its own copies, and the step that
installed those units has not been run since. Run the step the warning names.
A run with `--no-usb-gadget` or `--minimal` does not run `95-usb-gadget.sh`,
so the four USB units need that step, or a plain `./bootstrap.sh`.

**A service fails with `status=203/EXEC` after you move the checkout.**
A virtualenv is **not relocatable**. Its console scripts carry an absolute
shebang, so after `mv ~/old-name ~/new-name` the file at the new path still
begins `#!/home/you/old-name/.venv/bin/python`. systemd reports

```
Failed at step EXEC spawning .../.venv/bin/unoq-cpu-bars: No such file or directory
status=203/EXEC
```

which names the *script*, not the interpreter that is actually missing. **Delete** the venv and
rebuild it — do not try to repair it in place:

```bash
rm -rf ~/two-computers-one-board/.venv
bash  ~/two-computers-one-board/provision/user/35-python-venv.sh
bash  ~/two-computers-one-board/tools/install-dev-tools.sh    # dev extras
sudo systemctl restart unoq-cpu-bars unoq-learn
```

The `rm -rf` is not belt-and-braces. Re-running the install over a moved venv
fixes only the packages it reinstalls: `uv` sees everything else as already
present and never rewrites those shebangs. That leaves a venv where `python`
works and `mypy`, `clang-format` and `mkdocs` all fail with

```
cannot execute: required file not found
```

which is `execve` reporting the *interpreter* is missing, not the script.

Re-running the provisioning scripts rewrites the units for the new path;
`install_unit` now refuses to install a unit whose interpreter is missing, so
this is caught at provisioning time rather than at the next boot.

**`unoq-cpu-bars: command not found`.**
The program is installed into the project's Python environment, at
`~/two-computers-one-board/.venv/bin/unoq-cpu-bars`, and that directory is not
on `PATH`. Type the full path, or use `hpy -m unoq.cpubars`. Stop the service
first if it is running: it holds the serial port.

## USB and network

The USB link has its own list, with the one command that prints the whole
picture: [usb.md](usb.md#troubleshooting). The entries here are the messages
you meet before you get that far.

**`<hostname>.local` does not resolve.**
First check the name: run `hostname` on the board, and use that with `.local`
on the end. The name is published by `avahi-daemon` on the board:

```bash
systemctl is-active avahi-daemon
```

`provision/95-usb-gadget.sh` installs and enables it. If it is active and the
name still does not resolve from your computer, connect by number instead:
`~/two-computers-one-board/usb/status.sh` prints the board's address on the USB
link, and `ip -br addr` prints all of them.

**`no network access - the SDK, Zephyr and PyPI all need to be reachable`**
from `bootstrap.sh`. Its first check fetches `https://github.com` and gives up
after 20 seconds. Nothing has been changed yet. Get the board online, confirm
with `curl -I https://github.com`, and run `./bootstrap.sh` again.

**`the gadget is not bound to a UDC - nothing would be left`** from
`usb/wifi.sh off` or `check`. The board is not a USB device to anything right
now, so turning wifi off would leave no way in. The script has refused, and
wifi is still on. Plug the USB-C port into a computer, then look at
`~/two-computers-one-board/usb/status.sh`.

**`no computer on br-usb: no gateway, and no IPv4 or IPv6 neighbor either`**
from the same command. The gadget is bound, and nothing on the other end of the
cable has answered. Check the cable carries data, and that the computer shows a
new network adapter. If the computer is meant to share its internet connection,
turn that on there.

**`REFUSING to bind: 3 consecutive boots never confirmed`** in the journal.
The bind guard has stopped the USB gadget binding, because the board kept
rebooting soon after doing so. Wifi has been turned back on so that you can
reach it. Cause, how to look, and the two commands that clear it:
[the bind guard](usb.md#the-bind-guard).

**`/srv/unoq-share has no content`** from `provision/75-learning-web.sh` or
`./bootstrap.sh`. The web server serves the drive image, and
the image has not been built. Build it, then run the step again:

```bash
sudo bash ~/two-computers-one-board/share/fetch-vscode.sh     # ~1.8 GB, needs internet
sudo bash ~/two-computers-one-board/share/build-image.sh
sudo bash ~/two-computers-one-board/provision/75-learning-web.sh
```

## Toolchain

**`apt install openocd` does not work.**
Debian ships 0.12.0 (2023), predating libgpiod v2. Rebuild from upstream master:
`sudo bash ~/two-computers-one-board/tools/build-openocd.sh`.

**Packages look outdated but must not be upgraded.**
`cbor2` (<6 by `smp`), `pydantic-core` (pinned exactly by `pydantic`), and
Zephyr's own venv pins. See
[Working on this project](development.md#maintenance).

**An extension "update" will not install.**
`--install-extension <id> --force` does not bump versions — name the version
explicitly. If that reports *"not found"*, that version has no build for this
board (**linux-arm64**); publishers routinely ship x64 and Windows first.

Do **not** read "not found" as "already current" — a newer arm64 build may
exist *below* the version you tried. `check-versions.sh` reports the newest
arm64-installable version, which is the one to name. To see every build:

```bash
~/two-computers-one-board/tools/check-versions.sh          # arm64-correct
```

Use `…/server/bin/code-server` to install; the `remote-cli/code` binary needs a
live VS Code session and is not on `PATH`.

## Recovery

Back to stock Arduino firmware:

```bash
~/two-computers-one-board/mcu/restore-arduino-firmware.sh
```

Works even though `~/.arduino15` is gone, provided you copied the stock image
off the board first. It is Arduino's build, so this repository does not ship it
— see [third-party.md](../third-party.md). Point `STOCK_FW` at your copy.

**`no stock MCU firmware found`** from `provision/55-purge-arduino.sh` or
`./bootstrap.sh --with-purge`. The purge deletes the only copy of Arduino's
firmware image on the board, so it refuses to run until one has been saved.
Nothing has been removed. The message prints what to do; in short:

```bash
find ~/.arduino15 -name '*stm32u585xx*.hex'
mkdir -p ~/uno-q-backup && cp <that file> ~/uno-q-backup/
```

then run the purge again. If the image is already gone and you accept that,
`sudo UNOQ_ALLOW_NO_STOCK_FW=1 bash ~/two-computers-one-board/provision/55-purge-arduino.sh`
(the variable goes after `sudo`, or it does not reach the script).
`bootstrap.sh` prints a shorter warning with the same first words during its
preflight, and carries on with everything else, but it does not flash the
microcontroller. To flash anyway, run `mcu/flash-all.sh` yourself, or run
`UNOQ_ALLOW_NO_STOCK_FW=1 ./bootstrap.sh`.

**No network reaches the board at all.**
If the USB gadget will not bind and wifi is off, the MPU's serial console,
`/dev/ttyMSM0`, still offers a login and shows kernel messages from the first
boot line. Which pads it comes out on is not yet verified — see
[hardware.md](hardware.md#the-third-uart-the-mpus-own-console).

### A new kernel that did not come up

With `--with-boot-counting` ([provisioning.md](provisioning.md)), a newly installed kernel's boot entry has a try counter, and `bootctl list` shows it:

```
id: f182…-7.0.1+2-1.conf      two tries left, one used
id: f182…-7.0.1+0-3.conf      bad: three boots and never marked good
```

An entry at `+0` is sorted below every good one, so the board boots the previous kernel without anyone touching it. That is the safety net working, not a fault. To find out why the new kernel failed, look at its boot. `journalctl --list-boots` lists them, and in a failed one `systemctl status unoq-boot-health` says whether the boot never finished or `sshd` never came up. Once the cause is fixed, reinstall the kernel package, which writes a fresh entry with a full counter. To keep the old kernel for good, remove the new one.

**The test that has not been run yet.** Boot counting needs U-Boot to let systemd-boot rename a file on the EFI partition. One reboot shows whether it does. It boots the kernel the board already runs, through a second, counted entry, so the worst case is an ordinary boot:

```bash
sudo bash ~/two-computers-one-board/provision/82-boot-counting.sh   # if it is not installed yet
cd /boot/efi/loader/entries
E="$(ls *.conf | head -1)"                                          # the current entry
sudo sh -c "sed 's/^title .*/title counting test/' '$E' > unoq-test+1.conf"
sudo bootctl set-oneshot unoq-test+1.conf                           # boot it once
sudo reboot
```

If `set-oneshot` is refused (U-Boot may not keep EFI variables written from Linux), change the `default` line of `/boot/efi/loader/loader.conf` to `unoq-test*` instead, and put it back afterwards. Then, a few minutes after the board is back:

| `ls /boot/efi/loader/entries` shows | Means |
|---|---|
| `unoq-test.conf` | It all works: the try was counted, the health check passed, and the entry was marked good. |
| `unoq-test+0-1.conf` | The count works, but the entry was not marked good. `systemctl status unoq-boot-health systemd-bless-boot` |
| `unoq-test+1.conf`, unchanged | Nothing was renamed: either it did not boot this entry (`bootctl status`, *Current Entry*), or U-Boot cannot write the partition, and boot counting cannot work on this board. |

Afterwards, `sudo rm /boot/efi/loader/entries/unoq-test*.conf`.
