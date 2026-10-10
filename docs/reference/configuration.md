<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# What you can change

Every setting this project reads, in one place, with its default. They are all
environment variables. Nearly all begin `UNOQ_`; the few that do not are for
the firmware build and have [their own section](#settings-without-the-prefix).
**Every one has a working default** — a board that sets none of them is a
correctly configured board.

The prefixed names on this page are checked against the code: `tools/check.sh
docs` fails if one exists in a script and not here, or here and not in a
script. The unprefixed ones are not covered by that check.

## How a setting reaches the thing that reads it

There are three routes, and which one applies depends on what runs the script.

| The script is run by | Set the variable in | Then |
|---|---|---|
| a `systemd` unit (the USB link, the LEDs, the uplink fallback) | `/etc/default/unoq-usb` | `sudo systemctl restart <unit>` |
| you, at a prompt (`bootstrap.sh`, anything under `provision/`) | the command line: `UNOQ_TIER2=0 ./bootstrap.sh` | — |
| you, through `sudo` | after `sudo`, not before: `sudo UNOQ_SHARE_SIZE_MB=4000 bash share/build-image.sh` | — |

The third row catches people. `sudo` starts the command with a clean
environment, so `UNOQ_X=1 sudo bash script.sh` sets the variable for `sudo` and
not for the script. `bootstrap.sh` is the exception: it calls `sudo -E` for its
own steps, so variables set in front of `bootstrap.sh` do reach them.

`/etc/default/unoq-usb` is the one file on the board a person is expected to
edit. `provision/60-usb-gadget.sh` writes it once, with the common settings
commented out, and never overwrites it afterwards. Four units read it:
`unoq-usb-gadget`, `unoq-usb-bind`, `unoq-uplink-fallback` and `unoq-leds`.

That script only runs with `--with-usb-gadget`, so a board set up without the
USB extra has no such file. `unoq-leds` is installed on every board and reads
the same file, so to change an LED setting there, create it:

```bash
echo 'UNOQ_LED_INTERVAL=2' | sudo tee -a /etc/default/unoq-usb
sudo systemctl restart unoq-leds
```

The file is plain `NAME=value` lines. A file you create this way is left alone
if you add the USB extra later.

To see what a running unit actually has:

```bash
systemctl show unoq-leds -p Environment -p EnvironmentFiles
sudo cat /proc/"$(systemctl show unoq-leds -p MainPID --value)"/environ | tr '\0' '\n' | grep UNOQ_
```

## The USB link

Read by the scripts under `usb/`. Set these in `/etc/default/unoq-usb`. What
they control is explained in [usb.md](usb.md).

| Variable | Default | What it does |
|---|---|---|
| `UNOQ_USB_DEFAULT_ROUTE` | `1` | `0` stops the USB link ever installing a default route. The board is then reachable from the computer it is plugged into and has no route to the internet through it. |
| `UNOQ_USB_ROUTE_METRIC` | `700` | The metric of that default route. It loses to wifi (600) and ethernet (100) on purpose: a real uplink keeps winning. |
| `UNOQ_USB_PREFER_OVER_WIFI` | `1` | Once a packet has actually reached the internet through the cable, promote the USB route ahead of wifi. `0` leaves it as the last resort always. |
| `UNOQ_USB_ROUTE_METRIC_PREFERRED` | `550` | The metric used for that promotion: below wifi's 600, above ethernet's 100. |
| `UNOQ_USB_PROBE_IPS` | `1.1.1.1 8.8.8.8` | The addresses pinged through the cable to decide whether the internet answers there. |
| `UNOQ_USB_PROFILE_FALLBACK` | `1` | When the computer routes to the internet but will not lease an address, claim one in the numbering its sharing feature uses, and keep it only if it routes. `0` settles for link-local instead. |
| `UNOQ_USB_PROFILE_CONF` | `/etc/unoq/usb-profiles.conf` | Where those known numberings are listed. |
| `UNOQ_USB_DNS_PUBLIC` | `1.1.1.1 8.8.8.8` | Nameservers used when the computer on the other end does not answer DNS. Set it empty to refuse the fallback. |
| `UNOQ_USB_DNS_PROBE_NAME` | `example.com` | The name looked up to decide whether a nameserver is answering. |
| `UNOQ_USB_DNS_TIMEOUT` | `5` | Seconds to wait for that lookup. |
| `UNOQ_GADGET_PRIMARY` | `ncm` | `rndis` for a computer with no NCM driver. Only takes effect when the gadget is built; an existing one must be purged first, and `gadget-up.sh` says so. |
| `UNOQ_USB_BRIDGE` | `br-usb` | The name of the bridge the USB network functions join. |

### The guards

These exist so that a board with wifi off cannot lock you out. Read
[usb.md](usb.md) before changing any of them.

| Variable | Default | What it does |
|---|---|---|
| `UNOQ_USB_BIND_MAX_ATTEMPTS` | `3` | How many boots may try to bind the gadget without one being confirmed good, before the bind guard refuses to try again. |
| `UNOQ_GUARD_WIFI_RESCUE` | `1` | When the guard gives up, turn wifi back on so there is still a way in. `0` leaves the radio alone. |
| `UNOQ_UPLINK_FALLBACK` | `1` | If wifi was turned off and the USB link has produced no route to the internet by the deadline, turn wifi back on. `0` lets the board sit with no uplink. |
| `UNOQ_UPLINK_DEADLINE` | `240` | That deadline, in seconds from `unoq-uplink-fallback` starting at boot. |
| `UNOQ_UPLINK_INTERVAL` | `15` | Seconds between probes while waiting for it. |
| `UNOQ_UPLINK_PROBE_IPS` | `1.1.1.1 8.8.8.8` | The addresses that count as "the internet" for that decision. |
| `UNOQ_PROBE_IP` | `1.1.1.1` | The address `usb/wifi.sh off` pings through the cable first. No answer is a warning, not a refusal. |

## The status LEDs

Read by `status/leds.sh`, which runs as `unoq-leds.service`. Set these in
`/etc/default/unoq-usb`, creating it if it is not there (see
[above](#how-a-setting-reaches-the-thing-that-reads-it)), then
`sudo systemctl restart unoq-leds`.

| Variable | Default | What it does |
|---|---|---|
| `UNOQ_LED_INTERVAL` | `5` | Seconds between passes. Every pass re-reads everything, so this is also how stale a light can be. |
| `UNOQ_LED_NET_EVERY` | `12` | The reachability ping runs on every Nth pass: once a minute at the defaults. |
| `UNOQ_LED_PROBE_IP` | `1.1.1.1` | The address that ping goes to. |
| `UNOQ_LED_BLINK_SLOW_MS` | `1000` | The slow blink (degraded, or in progress): milliseconds lit, then the same again dark. Once every two seconds at the default. |
| `UNOQ_LED_BLINK_FAST_MS` | `250` | The fast blink (needs a human), likewise. Twice a second at the default; do not go below about 170, which is three flashes a second and the ceiling for anything that flashes. Keep it well apart from the slow one: the two rhythms are how the states are told apart without colour. |

These two set LED 1 and LED 2 only. LED 3 and LED 4 blink at the same rates
from the firmware, where they are constants in
`mcu/app/include/status_leds.h`; change one side and the other no longer
matches it.

## The drive and the web server

| Variable | Default | Read by | What it does |
|---|---|---|---|
| `UNOQ_LEARN_PORT` | `8080` | `provision/70-learning-web.sh` | The port that script *checks* after starting the server. It does not move the server: the port is named in `ExecStart` in [`python/unoq-learn.service`](../../python/unoq-learn.service). Change both, or neither. |
| `UNOQ_SHARE_SIZE_MB` | `2600` | `share/build-image.sh` | Size of the FAT32 image that is both the USB drive and the web root. |
| `UNOQ_SHARE_IMG` | `~/unoq-share.img` | `provision/60`, `provision/70`, `share/build-image.sh`, `usb/gadget-up.sh` | Where that image lives. If you move it, set this everywhere it is read, including `/etc/default/unoq-usb`. |
| `UNOQ_SHARE_MOUNT` | `/srv/unoq-share` | `provision/70`, `share/build-image.sh` | Where the image is mounted for the web server. |
| `UNOQ_SHARE` | `/var/lib/unoq-share` | `share/build-image.sh` | The staging directory the image is built from. |

## Provisioning switches

Set on the command line, for one run of `bootstrap.sh` or of the script named.

| Variable | Default | Read by | What it does |
|---|---|---|---|
| `UNOQ_SKIP_APT_UPGRADE` | `0` | `provision/10-optimize-board.sh` | `1` skips the `apt-get upgrade` a restored board needs. Services restart as their packages upgrade, so expect a blip on the link you are connected over when it runs. |
| `UNOQ_TIER2` | `1` | `provision/10-optimize-board.sh` | `0` leaves Bluetooth and `udisks2` enabled. They are disabled by default, not removed. |
| `UNOQ_KEEP_DOCKER_IMAGES` | `0` | `provision/10-optimize-board.sh` | `1` keeps the ~2 GB of Arduino container images. |
| `UNOQ_BACKUP` | `~/uno-q-backup` | `provision/10`, `provision/40` | Where the stock MCU firmware and the list of removed container images are saved. |
| `UNOQ_ALLOW_NO_STOCK_FW` | `0` | `bootstrap.sh`, `provision/40-purge-arduino.sh` | `1` lets the firmware be flashed, and the purge go ahead, with no copy of the stock firmware saved. Only for a board whose copy is already gone. |
| `UNOQ_USER` | whoever ran `sudo` | `provision/lib.sh` | The account that owns the checkout and is written into the units. |
| `UNOQ_VENV` | `<checkout>/.venv` | `provision/user/40-python-venv.sh`, `tools/` | The Python environment. |
| `UNOQ_WATCHDOG_SEC` | `30` | `provision/80-watchdog.sh` | Whole seconds without a ping from `systemd` before the hardware watchdog resets the board. Refused below `10`: a timeout that short resets a board that is merely busy, and does it again after every reboot. Only read with `--with-watchdog`. |

## The MCU control lines

Read by `mcu/link-up.sh`. These are facts about the circuit board, not
preferences; they are variables so the script can be tested without one. See
[hardware.md](hardware.md).

| Variable | Default | What it is |
|---|---|---|
| `UNOQ_GPIOCHIP` | `/dev/gpiochip1` | The GPIO controller both lines are on. |
| `UNOQ_BOOT0_LINE` | `37` | The MCU's BOOT0. |
| `UNOQ_LINK_LINE` | `70` | The line that enables the serial link. |

## Settings without the prefix

Read by the firmware build, flash and toolchain scripts. They have no `UNOQ_`
prefix because most are names Zephyr's own tools already use. Set them on the
command line for one run, for example `BUILD_DIR=/tmp/b zbuild`.

| Variable | Default | Read by | What it does |
|---|---|---|---|
| `ZEPHYR_WORKSPACE` | `~/zephyrproject` | `provision/user/30-zephyr-workspace.sh`, `mcu/zbuild.sh`, `mcu/flash.sh`, `mcu/flash-all.sh`, `mcu/ztest.sh` | Where the west workspace is. If you move it, set this for every one of those scripts. |
| `ZEPHYR_SDK` | `~/zephyr-sdk-1.0.1` | `mcu/zbuild.sh`, `mcu/flash-all.sh`, `mcu/ztest.sh` | Where the Zephyr SDK (the cross-compiler) is installed. |
| `ZEPHYR_SDK_VERSION` | `1.0.1` | `provision/user/20-zephyr-sdk.sh` | Which SDK release that step downloads, into `~/zephyr-sdk-<version>`. A pin: see the note below. |
| `ZEPHYR_VERSION` | `v4.4.2` | `provision/user/30-zephyr-workspace.sh` | Which Zephyr release the workspace is created at. A pin: see the note below. |
| `BOARD` | `arduino_uno_q` | `mcu/zbuild.sh`, `mcu/flash-all.sh` | The Zephyr board to build for. `env.sh` exports the same value. |
| `BUILD_DIR` | `~/zephyrproject/build` for this project's app, `build-<name>` for any other | `mcu/zbuild.sh` | The build directory. With it set, `zflash` no longer finds the image by itself: name it, as `zbuild` prints at the end. |
| `IMAGE_VERSION` | `0.0.0+<seconds since 1970>` | `mcu/zbuild.sh` | The version signed into the image, which `fota.images()` reports. The default makes every build distinguishable. |
| `MCUBOOT_BUILD` | `~/zephyrproject/build-mcuboot` | `mcu/flash-all.sh` | Where the bootloader is built. |
| `OCD_ROOT` | `/opt/openocd` | `mcu/flash.sh`, `provision/40-purge-arduino.sh` | The OpenOCD installation used for SWD. Point it at a rebuilt copy to try one without replacing the original. |
| `STOCK_FW` | `~/uno-q-backup/zephyr-arduino_uno_q_stm32u585xx.hex` | `mcu/restore-arduino-firmware.sh` | The Arduino firmware image that script flashes. |
| `OPENOCD_COMMIT` | `da3920b0a52d` | `tools/build-openocd.sh` | The upstream OpenOCD commit that script builds. |
| `OPENOCD_PREFIX` | `/opt/openocd-rebuilt` | `tools/build-openocd.sh` | Where that build is installed. |

> [!NOTE]
> `ZEPHYR_VERSION` and `ZEPHYR_SDK_VERSION` can be overridden, and should not
> be changed casually. The Zephyr version is also written in `west.yml` for CI,
> and a gate fails when the two disagree; the SDK path is written into
> `env.sh` and the `ZEPHYR_SDK` defaults above. Changing either is an upgrade
> with its own checklist: see [mcu.md](mcu.md#upgrading-zephyr).

## Not for changing

These exist so the test suite can point a script at a temporary directory or a
fake program instead of the real board. Nothing on a running system sets them,
and setting one will mostly make a script look in the wrong place.

| Variable | Default | What it stands in for |
|---|---|---|
| `UNOQ_STATE_DIR` | `/var/lib/unoq` | Where the bind guard's counter and the last DHCP lease are kept. |
| `UNOQ_USB_DHCP_STATE` | `/run/unoq-usb-dhcp.state` | The current lease, as `usb/status.sh` reports it. |
| `UNOQ_USB_PROFILE_STATE` | `/run/unoq-usb-profile.state` | The address claimed when no lease was offered. |
| `UNOQ_RESOLV_CONF` | `/etc/resolv.conf` | The resolver configuration `usb-dhcp.sh` edits. |
| `UNOQ_GADGET_DIR` | `/sys/kernel/config/usb_gadget/unoq` | The gadget's configfs directory. |
| `UNOQ_LED_DIR` | `/sys/class/leds` | The kernel's LED directory. |
| `UNOQ_BIND_GUARD` | `usb/bind-guard.sh` | The guard `leds.sh` asks whether it has given up. |
| `UNOQ_RUNTIME_DIR` | `/usr/local/lib/unoq` | Where provisioning puts [root's copies of the scripts](provisioning.md#what-root-runs), and where `usb/status.sh` looks for them. Everything in that directory that is not one of them is deleted, so it is never pointed at a directory with anything else in it. |
| `UNOQ_IN_BOOTSTRAP` | unset | Set by `bootstrap.sh` for the steps it runs, so that a warning about the board as a whole is printed once at the end instead of after every step. |
| `UNOQ_AUTOIPD` | `/usr/sbin/avahi-autoipd` | The link-local address daemon. |
| `UNOQ_NSLOOKUP` | `nslookup` | The resolver probe. |
| `UNOQ_WATCHDOG_CONF_DIR` | `/etc/systemd/system.conf.d` | Where `80-watchdog.sh` writes its `systemd` drop-in. |
| `UNOQ_WATCHDOG_SYSFS` | `/sys/class/watchdog` | Where `80-watchdog.sh` looks for a watchdog device. |
| `UNOQ_FSTAB` | `/etc/fstab` | The mount table `85-esp-permissions.sh` edits. Its backup is written beside it. |

## Development only

Read by the scripts under `tools/`, on whatever machine runs the quality gates.

| Variable | Default | What it does |
|---|---|---|
| `UNOQ_BIN` | `~/.local/bin` | Where `install-dev-tools.sh` puts `shellcheck`, `shfmt` and `bats`. |
| `UNOQ_SITE` | `share/learn` | The built site the diagram checks inspect. |
| `UNOQ_DIAGRAM_PORT` | `8099` | The port `check-diagrams.sh` serves the site on while it renders. |
| `UNOQ_DIAGRAM_BROWSER` | the first Chromium or Chrome on `PATH` | The browser `check-diagrams.sh` drives. CI sets it to the pinned one that `install-diagram-browser.sh` fetches. |
| `UNOQ_DIAGRAM_BUDGET_MS` | `8000` | How long each page is given to draw its diagrams before it is reported as not drawn. |
| `UNOQ_DIAGRAM_PAGE_TIMEOUT` | `45` | Seconds the browser is given to start, and to answer on any one page, before it is killed and the gate fails. |

## Set for you

`UNOQ_PROJECT` is exported by [`env.sh`](../../env.sh): the path of the
checkout, worked out from where `env.sh` itself is. The `zbuild`, `zflash`,
`mcucon` and `hpy` shortcuts are built from it. Read it; do not set it.

`UNOQ_OWNER_HOME` and `UNOQ_CHECKOUT` are not environment variables at all.
They are two lines in `/usr/local/lib/unoq/env`, which provisioning writes
beside [root's copies of the scripts](provisioning.md#what-root-runs): the
home directory of the account the board belongs to, and the checkout the
copies were made from. `usb/gadget-up.sh` reads the first to find the drive
image, and `usb/status.sh` reads the second. The file is rewritten by every
step that installs a root unit, so an edit to it does not last. To move the
drive image, set `UNOQ_SHARE_IMG`.

## What is not a variable

Some numbers that look tunable are fixed, and on purpose:

- **The serial port and its speed** (`/dev/ttyHS1`, 115200) are constants in
  [`python/unoq/mcu.py`](../../python/unoq/mcu.py). The firmware has to agree,
  so changing one end here would only break the link.
- **The LED matrix geometry** lives in
  [`mcu/app/include/app_proto.h`](../../mcu/app/include/app_proto.h) and is
  pinned to the Python copy by a test.
- **The Zephyr and SDK versions** are pins more than settings. The variables
  that hold them are listed under
  [Settings without the prefix](#settings-without-the-prefix), and changing
  them is an upgrade with its own checklist: see
  [mcu.md](mcu.md#upgrading-zephyr).
