<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# Reference

Written for someone who already knows the material and wants the exact detail —
pin numbers, register values, unit names, recovery procedures, and the things
that took days to work out.

If any of it reads as dense, that is the intent. The
[course](../learn/start-here.md) is where the ideas are explained; these pages
are where you come back to check a number.

## Which page

<div class="grid cards" markdown>

-   :material-chip:{ .lg .middle } **[Hardware](hardware.md)**

    ---

    Board anatomy: the five GPIO lines between the two chips, the three UARTs, the
    LED matrix wiring, the four RGB LEDs, SWD, and the flash layout.

    **Read this first.** More debugging time is lost to the GPIO table at the
    top of it than to anything else on this board.

-   :material-penguin:{ .lg .middle } **[MPU — the Linux side](mpu.md)**

    ---

    Direct hardware access from Linux, the `unoq` Python package, what runs at
    boot, and the CPU-bars demo end to end.

-   :material-memory:{ .lg .middle } **[MCU — the STM32 side](mcu.md)**

    ---

    Build, flash over SWD, update over serial, the interactive shell, on-chip
    debugging, the firmware tests, and upgrading Zephyr.

-   :material-usb-port:{ .lg .middle } **[USB](usb.md)**

    ---

    IP over USB in both directions, the fileshare drive, why the port's role
    cannot be switched from software, and the bind guard.

-   :material-tune:{ .lg .middle } **[What you can change](configuration.md)**

    ---

    Every setting the project reads, with its default, and where to set it so
    that it actually takes effect.

-   :material-lifebuoy:{ .lg .middle } **[Troubleshooting](troubleshooting.md)**

    ---

    Symptom first. What you saw, what it usually means, and what to run next.

-   :material-clipboard-text-clock:{ .lg .middle } **[What a clean board revealed](clean-board-findings.md)**

    ---

    The unedited log from taking a factory-restored board through
    `bootstrap.sh`, and what turned up afterwards. Of the first seventeen
    findings, only two announced themselves as errors.

-   :material-progress-wrench:{ .lg .middle } **[Provisioning](provisioning.md)**

    ---

    What `bootstrap.sh` runs, step by step: what each one changes, which need
    root, and the same thing by hand.

-   :material-source-branch:{ .lg .middle } **[Working on this project](development.md)**

    ---

    The source layout, the quality gates, the tests, CI, and the maintenance
    and recovery procedures.

-   :material-book-alphabet:{ .lg .middle } **[Glossary](../glossary.md)**

    ---

    Every term the course introduces, defined once, linked to the chapter that
    teaches it.

</div>

## The commands that matter

Everything below assumes `source ~/two-computers-one-board/env.sh`, which `~/.bashrc` already
does.

### Firmware

```bash
zbuild                                   # build this project's firmware, and sign it
zflash                                   # write that build to the MCU over SWD
mcucon                                   # watch the MCU console (Ctrl-C to leave)
~/two-computers-one-board/mcu/ztest.sh                    # firmware tests, on the host
```

### Talking to the MCU from Python

```python
from unoq import MCU
with MCU() as mcu:
    print(mcu.status())                  # uptime, orientation, sweep counter
    mcu.bars([25, 50, 75, 100])          # drive the panel directly
    mcu.matrix_off()
```

> [!WARNING]
> `unoq-cpu-bars.service` holds `/dev/ttyHS1` while it runs. Stop it before
> using the shell or the Python API: `sudo systemctl stop unoq-cpu-bars`.

### The board's own state

```bash
~/two-computers-one-board/usb/status.sh                   # the whole USB picture in one read
~/two-computers-one-board/status/leds.sh explain             # what the LED colors mean
systemctl --failed                       # what needs a human
journalctl -u unoq-cpu-bars -n 50        # or any other unit
```

### Documentation

```bash
tools/build-docs.sh                      # render docs/ -> share/learn/
tools/build-docs.sh --serve              # live preview on :8000
sudo bash share/build-image.sh           # render, then push onto the drive and web server
```

### Quality gates

```bash
tools/check.sh                           # all of them
tools/check.sh --fast                    # skip the two slow gates: firmware tests, diagram render
tools/check.sh --fix                     # reformat in place, then check
```

## Where the source is

| | |
|---|---|
| `mcu/app/` | The firmware — `main.c`, `matrix.c` (charlieplex driver), `bars.c` (rasterizer), `status_leds.c` |
| `python/unoq/` | The Linux-side package — `link.py`, `mcu.py`, `fota.py`, `cpu.py`, `thermal.py`, and the two daemons `cpubars.py` and `learn.py` |
| `usb/` | The composite gadget, the bridge, the bind guard |
| `net/` | The uplink: switching the wifi radio off safely, and bringing it back when nothing else routes out |
| `status/` | The status LEDs |
| `provision/` | Root setup, numbered in order; `provision/user/` is the half that must not be root |
| `docs/` | This site, and the course |

Two paths are load-bearing inside a checkout and must not move: `python/` (the
editable install target) and `provision/lib.sh` (every script sources it by
relative path).
