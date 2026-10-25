<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# Provisioning

What `bootstrap.sh` runs, step by step. You rarely need to run these by hand;
they are separate, numbered and individually runnable so you can see exactly
what changes, and so a single step can be repeated.

If you just want a working board, [Set up a board](../setup.md) is the page.
The reasoning behind the design is in
[From factory to this](../learn/from-factory-to-this.md).

## The rules every step follows

- **Idempotent.** That is a stronger claim than "safe to re-run": a second run
  touches nothing. It does not reinstall, does not rewrite a file whose content
  already matches, and does not restart a service that is already correct.
- **Four words of output.** `changed`, `ok`, `warn`, `FAILED`. A second run of a
  healthy board is a wall of `ok`, and that is the signal.
- **Every change says how to undo it.** Each one has a `REVERT:` line in the
  comment above it. Read the script before you run it; that is what they are
  written for.
- **The account and the path are worked out, not assumed.** The owning user,
  their home directory and the checkout location are found when a step runs and
  written into the units it installs. Everything has only ever been *run* as
  `arduino` from `~/two-computers-one-board`, so treat anything else as
  untested.
- **Root runs its own copies, not the checkout.** A step that installs a
  service that runs as root first copies the scripts root runs into
  `/usr/local/lib/unoq/`, and points the unit there. See
  [What root runs](#what-root-runs).

## The steps, in the order bootstrap runs them

The number at the front of each file is its place in the run: `bootstrap.sh`
runs them in number order, and prints the number in the banner above each
one's output. One sequence covers both directories.

Steps under `provision/user/` run as you and must **not** be run with `sudo`:
they install into your home directory. The others need root.

| Step | Run as | Does |
|---|---|---|
| `10-optimize-board.sh` | root | Switches off the X11 desktop (~218 MB of memory; nothing is uninstalled) and deletes the ~2 GB of Arduino container images. Disables ModemManager, fwupd and unattended apt. Runs the one `apt-get upgrade` a restored board needs. Adds the `i2c`, `spi` and `gpiod` group memberships and a spidev udev rule. Disables Bluetooth and udisks2. |
| `15-dev-tools.sh` | root | Installs a host C compiler, `wget` and `clangd`. Disables the Arduino services and Docker (~210 MB), and checks `/dev/ttyHS1` has been released. |
| `user/20-host-tools.sh` | you | `uv`, then `cmake`, `ninja` and `west` as uv tools, in `~/.local/bin`. |
| `user/25-zephyr-sdk.sh` | you | The Zephyr SDK, `arm-zephyr-eabi` toolchain only. ~0.8 GB. |
| `user/30-zephyr-workspace.sh` | you | `west init` and `west update`, with a module filter, without git history, and with only the Python packages the build and tests import. ~2 GB. The long download. |
| `user/35-python-venv.sh` | you | The project's `.venv`: the hardware libraries, the `unoq` package installed editable, and the development tools. |
| `user/40-shell-env.sh` | you | Adds `env.sh` to `~/.bashrc`, and installs the git pre-commit hook. |
| `45-mcu-link.sh` | root | Installs `tio`, refreshes [root's copies of the scripts](#what-root-runs), and installs `unoq-link.service`, which sets BOOT0 and the serial-link enable at every boot. **Without this the board looks dead after a reboot.** Runs after the venv exists, because it uses it to verify the lines. |
| `50-status-leds.sh` | root | Refreshes [root's copies of the scripts](#what-root-runs) and installs `unoq-leds.service`, restarting it if the unit or a script changed. Not optional: the LEDs are the board's only output when the network is down. |

Then, as stage `60`, the firmware is built with `mcu/zbuild.sh` and written
with `mcu/flash-all.sh`: bootloader and application together, because a signed
application flashed by itself has no bootloader in front of it.
`--skip-mcu` leaves both out.

### The rest of the run: what is on by default, and what is asked for

| Step | Runs | Does |
|---|---|---|
| `55-purge-arduino.sh` | `--with-purge` | Removes the remaining Arduino packages. Backs up the stock MCU firmware first, and checks `/opt/openocd` survives before and after. |
| `65-cpu-bars.sh` | on; `--no-cpu-bars` | Installs `unoq-cpu-bars.service`. Optional because it holds the serial port: see [mpu.md](mpu.md#at-every-boot). |
| `share/build-image.sh` (stage `70`) | on, unless both of the next two are off | Renders this documentation and builds the FAT32 image both of them hand out. `bootstrap.sh` runs it for you; run by hand, it has to come first. |
| `75-learning-web.sh` | on; `--no-learning` | Serves the course, and the installers if you fetched them, on port 8080. No authentication, on every interface. Adds a read-only mount to `/etc/fstab`. |
| `80-watchdog.sh` | `--with-watchdog` | Arms the hardware watchdog through a `systemd` drop-in (`RuntimeWatchdogSec=30s`) and re-executes `systemd` to read it. Costs: the board resets itself if `systemd` stalls for 30 seconds, though a clean firmware build with swap 80% full did not cause that on the one board it was tried on. Both timeouts are set to the same value, because this watchdog cannot count past 32 seconds and `systemd`'s ten-minute default for shutdown is refused. Not part of `--everything`. |
| `82-boot-counting.sh` | `--with-boot-counting` | Boots every **new** kernel on trial, through systemd-boot's boot counting. It writes `3` to `/etc/kernel/tries`, so `kernel-install` names the next kernel's entry `…+3.conf`, and installs `unoq-boot-health.service`, which `systemd-bless-boot` waits for. That unit passes once the boot has finished and `sshd` is up, a minute in, and the entry is then marked good. It deliberately does not hang off `boot-complete.target`, where `qbootctl.service` waits before marking the Qualcomm boot slot good: a failed check must not touch the firmware's A/B slots. An entry that fails three boots running is set aside, and the previous kernel boots by itself. The kernel the board runs now is not touched. Costs: none until a kernel is installed, and then a fallback only while the previous kernel is still installed. **Not yet seen through a reboot**: it needs U-Boot to let systemd-boot rename a file on the EFI partition. [Troubleshooting](troubleshooting.md#a-new-kernel-that-did-not-come-up) has the test. Not part of `--everything`. |
| `85-esp-permissions.sh` | `--with-esp-lockdown` | Puts `fmask=0177,dmask=0077` at the end of the options on the `/boot/efi` line of `/etc/fstab` — last, because FAT reads them in order and a `umask=` after them would win — so the EFI partition is readable by root only, then remounts it and reads the result back. Costs: it edits the entry the board boots from (verified before it is installed, backed up to `/etc/fstab.unoq-esp.bak`), and anything that read `/boot/efi` without root no longer can. Run on one board, through a reboot: FAT ignored the new masks on a plain remount, so the step unmounted and mounted again, as it is written to. Not part of `--everything`. |
| `90-cleanup.sh` | always | Gives back what the run downloaded in order to install: apt's `.deb` files, and `uv`'s and `pip`'s download caches. Never the workspace, the SDK or a build directory. Prints free space before and after. `UNOQ_KEEP_CACHES=1` skips it. |
| `95-usb-gadget.sh` | on; `--no-usb-gadget` | Network and the fileshare drive over USB. Refreshes [root's copies of the scripts](#what-root-runs), installs the four USB units, switches `sshd` on, then [hands the USB port over from `adbd`](usb.md#adb-is-disabled-and-ssh-is-switched-on). Always run last, because it takes the USB host port, and `adb shell`, down with it: see [usb.md](usb.md). |

Any of them can be added later, either by re-running `bootstrap.sh` with the
flag or by running the step directly:

```bash
sudo bash ~/two-computers-one-board/provision/65-cpu-bars.sh
```

A few steps read environment variables that change what they do. They are
listed in [What you can change](configuration.md#provisioning-switches).

## What root runs

Six of the eight units run as root: `unoq-link`, `unoq-leds`, `unoq-usb-gadget`,
`unoq-usb-bind`, `unoq-usb-confirm` and `unoq-uplink-fallback`. They used to
execute scripts in the checkout, which is in a home directory. Anything that
could write there could then change what root did at the next boot or cable
plug, with no password asked, and so could a `git pull`.

They now run root-owned copies:

```
/usr/local/lib/unoq/
├── env              the owner's home directory and the checkout, written down
├── mcu/link-up.sh
├── status/leds.sh
└── usb/*.sh         every script in usb/
```

The layout is the repository's, so the scripts still find each other by
relative path. Files are mode `0755`, directories `0755`, all owned by root.
`env` is `0644` and is not a settings file: it is rewritten by the next step.

**Which units point where.** `ExecStart` and every other `Exec` line of a unit
that runs as root name `/usr/local/lib/unoq/…`. The two units that have
`User=` (`unoq-cpu-bars` and `unoq-learn`) run as you from the Python
environment, and still name the checkout. `Documentation=` lines name the
checkout in every unit.

**What installs the copies.** Steps `45`, `50` and `95` each copy the *whole*
set before they install a unit, and each removes anything in the directory
that is not in the set. A step refuses to install a unit that names a script
which is not there.

**What a re-run prints.** Nothing changed:

```
  ok      13 of root's scripts in /usr/local/lib/unoq already match the checkout
```

A script edited in the checkout since the last run:

```
  changed  updated /usr/local/lib/unoq/usb/usb-dhcp.sh
```

That line is the moment the change reaches a root service. Until a step is
run, the board goes on running the old copy.

**Which copy you run yourself.** For commands that only read
(`usb/status.sh`, `status/leds.sh explain`, `usb/wifi.sh status`), run the one
in the checkout, as before. `usb/status.sh` has a section named *what root
runs* that compares the two sets and names any script that differs. For
commands that need `sudo`, either copy works; the one under
`/usr/local/lib/unoq/` is the one the services run.

**A board set up before this.** Its units still name the checkout. Re-running
a step rewrites the units that step installs, and reloads `systemd`. Each step
ends with a `warn` naming any root unit that still runs from the home
directory, until none does. A plain `./bootstrap.sh` covers `unoq-link` and
`unoq-leds`; the four USB units are rewritten by `95-usb-gadget.sh`, which
`bootstrap.sh` runs unless it is given `--no-usb-gadget` or `--minimal`.

**To undo.** Remove the units (each step's `REVERT:` line), then
`sudo rm -r /usr/local/lib/unoq`.

`UNOQ_RUNTIME_DIR` moves the directory; it exists for the tests. See
[What you can change](configuration.md#not-for-changing).

## What is deliberately left alone

> [!WARNING]
> The Qualcomm platform services — `rmtfs`, `tqftpserv`, `qbootctl` — are
> marked do-not-touch. Disabling them can leave the board unbootable.
> `zramswap` also stays: it provides the compressed swap described in
> [mpu.md](mpu.md#swap-in-use-is-not-a-problem-here).

## The same thing by hand

The user-level steps, written out, for when you want to see what the scripts
are doing or reproduce them somewhere else. The scripts are the source of
truth; if this and they disagree, they are right.

```bash
# Versions come from the two lock files; -c pins what is installed and -b
# what builds it. P is this checkout.
P=~/two-computers-one-board
ZL=$P/mcu/requirements-zephyr-lock.txt
PL=$P/python/requirements-lock.txt

# 1. uv, then the host tools
curl -LsSf https://astral.sh/uv/install.sh | sh
for t in cmake ninja west; do uv tool install -c $ZL -b $ZL $t; done

# 2. The Zephyr SDK (arm-zephyr-eabi only), into ~/zephyr-sdk-<version>.
#    Unpack the "minimal" archive from the sdk-ng releases page, then, with
#    cmake and wget on PATH:
./setup.sh -t arm-zephyr-eabi -c

# 3. The Zephyr workspace. The version and the module filter are the ones in
#    provision/user/30-zephyr-workspace.sh and west-project-filter.
mkdir -p ~/zephyrproject && cd ~/zephyrproject
uv venv --python 3.13 .venv
uv pip install --python .venv/bin/python -c $ZL -b $ZL west imgtool
.venv/bin/west init -m https://github.com/zephyrproject-rtos/zephyr --mr <version> --clone-opt=--depth=1 .
.venv/bin/west config manifest.project-filter -- "<the line in west-project-filter>"
.venv/bin/west update --narrow -o=--depth=1
.venv/bin/west zephyr-export
uv pip install --python .venv/bin/python -c $ZL -b $ZL natsort \
  -r zephyr/scripts/requirements-base.txt -r zephyr/scripts/requirements-build-test.txt

# 4. The Linux-side Python
cd $P && uv venv .venv
uv pip install --python .venv/bin/python -c $PL -b $PL gpiod smbus2 pyserial spidev smpclient
uv pip install --python .venv/bin/python -c $PL -b $PL -e 'python[docs]'

# 5. The shell shortcuts
echo 'source ~/two-computers-one-board/env.sh' >> ~/.bashrc
```

The module filter keeps the workspace at ~2 GB by skipping vendor HALs for
hardware this board does not have.

> [!WARNING]
> Never `rm -rf` a module directory without filtering it out first. west would
> then be managing a project whose checkout has vanished. Change the filter,
> then delete.
