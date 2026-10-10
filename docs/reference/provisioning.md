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

## The steps, in the order bootstrap runs them

Steps under `provision/user/` run as you and must **not** be run with `sudo`:
they install into your home directory. The others need root.

| Step | Run as | Does |
|---|---|---|
| `10-optimize-board.sh` | root | Switches off the X11 desktop (~218 MB of memory; nothing is uninstalled) and deletes the ~2 GB of Arduino container images. Disables ModemManager, fwupd and unattended apt. Runs the one `apt-get upgrade` a restored board needs. Adds the `i2c`, `spi` and `gpiod` group memberships and a spidev udev rule. Disables Bluetooth and udisks2. |
| `20-dev-tools.sh` | root | Installs a host C compiler, `wget` and `clangd`. Disables the Arduino services and Docker (~210 MB), and checks `/dev/ttyHS1` has been released. |
| `user/10-host-tools.sh` | you | `uv`, then `cmake`, `ninja` and `west` as uv tools, in `~/.local/bin`. |
| `user/20-zephyr-sdk.sh` | you | The Zephyr SDK, `arm-zephyr-eabi` toolchain only. ~1 GB. |
| `user/30-zephyr-workspace.sh` | you | `west init` and `west update`, with a module filter. ~3.3 GB. The slow one. |
| `user/40-python-venv.sh` | you | The project's `.venv`: the hardware libraries, the `unoq` package installed editable, and the development tools. |
| `user/50-shell-env.sh` | you | Adds `env.sh` to `~/.bashrc`, and installs the git pre-commit hook. |
| `30-mcu-link.sh` | root | Installs `tio`, and `unoq-link.service`, which sets BOOT0 and the serial-link enable at every boot. **Without this the board looks dead after a reboot.** Runs after the venv exists, because it uses it to verify the lines. |
| `35-status-leds.sh` | root | Installs `unoq-leds.service`. Not optional: the LEDs are the board's only output when the network is down. |

Then the firmware is built with `mcu/zbuild.sh` and written with
`mcu/flash-all.sh`: bootloader and application together, because a signed
application flashed by itself has no bootloader in front of it.
`--skip-mcu` leaves both out.

### The optional steps

| Step | Flag | Does |
|---|---|---|
| `40-purge-arduino.sh` | `--with-purge` | Removes the remaining Arduino packages. Backs up the stock MCU firmware first, and checks `/opt/openocd` survives before and after. |
| `50-cpu-bars.sh` | `--with-cpu-bars` | Installs `unoq-cpu-bars.service`. Optional because it holds the serial port: see [mpu.md](mpu.md#at-every-boot). |
| `share/build-image.sh` | either of the next two | Renders this documentation and builds the FAT32 image both of them hand out. `bootstrap.sh` runs it for you; run by hand, it has to come first. |
| `70-learning-web.sh` | `--with-learning` | Serves the course, and the installers if you fetched them, on port 8080. No authentication, on every interface. Adds a read-only mount to `/etc/fstab`. |
| `60-usb-gadget.sh` | `--with-usb-gadget` | Network and the fileshare drive over USB. Always run last, because it takes the USB host port down with it: see [usb.md](usb.md). |
| `80-watchdog.sh` | `--with-watchdog` | Arms the hardware watchdog through a `systemd` drop-in (`RuntimeWatchdogSec=30s`) and re-executes `systemd` to read it. Costs: the board resets itself if `systemd` stalls for 30 seconds, and nobody has yet checked that a long build in deep swap does not cause exactly that. Not validated on hardware; not part of `--everything`. |
| `85-esp-permissions.sh` | `--with-esp-lockdown` | Adds `fmask=0177,dmask=0077` to the `/boot/efi` line of `/etc/fstab`, so the EFI partition is readable by root only, then remounts it and reads the result back. Costs: it edits the entry the board boots from (verified before it is installed, backed up to `/etc/fstab.unoq-esp.bak`), and anything that read `/boot/efi` without root no longer can. Not validated on hardware; not part of `--everything`. |

Any of them can be added later, either by re-running `bootstrap.sh` with the
flag or by running the step directly:

```bash
sudo bash ~/two-computers-one-board/provision/50-cpu-bars.sh
```

A few steps read environment variables that change what they do. They are
listed in [What you can change](configuration.md#provisioning-switches).

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
# 1. uv, then the host tools
curl -LsSf https://astral.sh/uv/install.sh | sh
uv tool install cmake && uv tool install ninja && uv tool install west

# 2. The Zephyr SDK (arm-zephyr-eabi only), into ~/zephyr-sdk-<version>.
#    Unpack the "minimal" archive from the sdk-ng releases page, then, with
#    cmake and wget on PATH:
./setup.sh -t arm-zephyr-eabi -c

# 3. The Zephyr workspace. The version and the module filter are the ones in
#    provision/user/30-zephyr-workspace.sh and west-project-filter.
mkdir -p ~/zephyrproject && cd ~/zephyrproject
uv venv --python 3.13 .venv
uv pip install --python .venv/bin/python west imgtool
.venv/bin/west init -m https://github.com/zephyrproject-rtos/zephyr --mr <version> .
.venv/bin/west config manifest.project-filter -- "<the line in west-project-filter>"
.venv/bin/west update --narrow -o=--depth=1
.venv/bin/west zephyr-export
uv pip install --python .venv/bin/python -r zephyr/scripts/requirements.txt

# 4. The Linux-side Python
#    (plus the hardware libraries named in provision/user/40-python-venv.sh)
cd ~/two-computers-one-board && uv venv .venv
uv pip install --python .venv/bin/python -e python

# 5. The shell shortcuts
echo 'source ~/two-computers-one-board/env.sh' >> ~/.bashrc
```

The module filter keeps the workspace at ~3.3 GB instead of ~7 GB by skipping
vendor HALs for hardware this board does not have.

> [!WARNING]
> Never `rm -rf` a module directory without filtering it out first. west would
> then be managing a project whose checkout has vanished. Change the filter,
> then delete.
