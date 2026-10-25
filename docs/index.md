---
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
hide:
  - navigation
  - toc
---

<div class="hero" markdown>

# There are two computers on this board, and they do not get along by default

The Arduino UNO Q runs **Debian Linux on a quad-core 64-bit processor** and
**Zephyr on a 32-bit microcontroller**, on one circuit board, wired together.
This is a course in making them cooperate — written for someone who can program,
and has never done embedded development.

[Start the course](learn/start-here.md){ .md-button .md-button--primary }
[Set up a board](setup.md){ .md-button }
[Browse the reference](reference/index.md){ .md-button }

</div>

This is an independent project. It is not made, reviewed or endorsed by Arduino,
Qualcomm, STMicroelectronics, the Zephyr Project or anyone else whose hardware
and software it describes.
[Credits and trademarks](third-party.md#trademarks-and-affiliation).

## The thing you will build

Linux measures how busy its four CPU cores are. It sends those four numbers down
a serial line to the microcontroller. The microcontroller draws them as four
bars of light on an 8&times;13 LED grid, refreshing the panel about a thousand
times a second so your eye sees a steady picture instead of a flicker.

It is deliberately unglamorous, and every part of it is load-bearing. Linux
cannot draw that panel — you will measure exactly why. The microcontroller
cannot read `/proc/stat` — it has no filesystem, no processes and 786 KB of
memory. Neither chip can do the job alone, which is the entire argument for a
board that has both.

<div class="split" markdown>

<div markdown>
### The big one — MPU

Qualcomm QRB2210. Four 64-bit cores, gigabytes of memory, Debian 13, a network
stack, a package manager and a filesystem.

**Good at** networking, storage, AI models, anything large or open-ended.

**Bad at** doing something at an exact microsecond. The kernel will preempt you
whenever it likes, and it is right to.
</div>

<div markdown>
### The small one — MCU

STMicroelectronics STM32U585. One 32-bit Cortex-M33 core, 786 KB of RAM, Zephyr
RTOS, and nothing between your code and the pins.

**Good at** timing you can rely on, and hardware you talk to directly.

**Bad at** everything the big one is good at. There is no filesystem to read and
no network to reach.
</div>

</div>

## The course

Fifteen short chapters and an introduction, meant in order. Each one introduces an idea, then puts
you in front of the real board to watch it happen.

<div class="grid cards" markdown>

-   :material-numeric-1-circle-outline:{ .lg .middle } **What is actually here**

    ---

    Two processors, two kinds of software, and the vocabulary to argue about
    which job belongs where. Then a tour of each side on its own terms.

    [:octicons-arrow-right-24: Start here](learn/start-here.md)

-   :material-numeric-2-circle-outline:{ .lg .middle } **Making them cooperate**

    ---

    A serial line, a framing protocol, a cross-compiler, and a panel of LEDs
    that only exists because of persistence of vision.

    [:octicons-arrow-right-24: How they talk](learn/how-they-talk.md)

-   :material-numeric-3-circle-outline:{ .lg .middle } **Living with real hardware**

    ---

    Firmware updates that undo themselves when they go wrong, one USB cable
    pretending to be three devices, and debugging a program that cannot print.

    [:octicons-arrow-right-24: Updating safely](learn/updating-safely.md)

-   :material-numeric-4-circle-outline:{ .lg .middle } **Making it yours**

    ---

    What to build next, where the unfinished work is, and how to change this
    project without breaking the board.

    [:octicons-arrow-right-24: Knowing it works](learn/knowing-it-works.md)

</div>

## Why this exists

Most embedded tutorials stop at blinking an LED, and most Linux tutorials never
mention that a computer can miss a deadline. The interesting engineering is in
between: two processors with genuinely different strengths, a wire between them,
and a set of decisions about who does what.

This project is a factory-fresh UNO Q turned into a working development board
one script at a time, with everything that went wrong written down. The course
teaches the stack. The [reference](reference/hardware.md) records the detail,
including the parts that took days to work out. The
[findings log](reference/clean-board-findings.md) is the unedited list of things
that were wrong the first time.

<div class="grid cards" markdown>

-   :material-book-open-variant:{ .lg .middle } **Reference**

    ---

    The exact detail, for someone who already knows the material: pin
    assignments, protocol framing, `systemd` units, recovery procedures.

    [:octicons-arrow-right-24: Hardware](reference/hardware.md) &middot;
    [MPU](reference/mpu.md) &middot;
    [MCU](reference/mcu.md) &middot;
    [USB](reference/usb.md)

-   :material-lifebuoy:{ .lg .middle } **When it breaks**

    ---

    It will. Symptom-first: what you saw, what it usually means, and what to
    run next.

    [:octicons-arrow-right-24: Troubleshooting](reference/troubleshooting.md)

-   :material-school-outline:{ .lg .middle } **Further reading**

    ---

    The free material this course is built on — Zephyr, the kernel docs,
    Bootlin, Beej, Nand2Tetris — annotated with what each one is actually good
    for.

    [:octicons-arrow-right-24: Further reading](further-reading.md)

-   :material-github:{ .lg .middle } **The source**

    ---

    Every script, sketch and test, MIT licensed. The provisioning is the
    project: you should be able to reproduce this board from a factory reset.

    [:octicons-arrow-right-24: On GitHub](https://github.com/jim-wyatt/two-computers-one-board)

</div>

## Four ways to read this

You are looking at one of them. All four come from the same markdown, and the
three built sites from the same command, so they cannot disagree about what the
board does.

| Where | How you get there | Needs |
|---|---|---|
| **GitHub** | The `docs/` folder in the repository | A browser |
| **The published site** | [jim-wyatt.github.io/two-computers-one-board](https://jim-wyatt.github.io/two-computers-one-board/) | A network |
| **The board** | `http://<board>:8080/` — served by `unoq-learn` | The board running |
| **The USB drive** | The `UNO-Q` drive that appears when you plug the board in | Nothing at all |

> [!TIP]
> The drive is the point of the third one. Open it on a laptop with no network,
> no account and no installed tools, and the whole course is there — search
> included.
