<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# Start here

You have an Arduino UNO Q. It looks like an Arduino board, and it is one — but
there is a second, much larger computer on it, and that is what makes it
interesting.

This course teaches you **hybrid MPU + MCU development**: writing software that
runs across two very different processors that share one circuit board, and
getting them to cooperate.

If those letters mean nothing to you yet, good. That is what the next chapter is
for.

> [!NOTE]
> This is an independent project. It is not made, reviewed or endorsed by Arduino,
> Qualcomm, STMicroelectronics, the Zephyr Project or anyone else whose hardware
> and software it describes.
> It is one person's account of one board.
> [Credits and trademarks](../third-party.md#trademarks-and-affiliation).

## Who this is for

Someone who has written programs before — a first or second year computing
student, or anyone comfortable in Python or C — and who has not done embedded
development.

Concretely, you will get the most from this if you already know:

- what a **variable**, a **function** and a **loop** are, in any language
- how to open a **terminal** and run a command in it
- roughly what an **operating system** does

You do **not** need to know: electronics, C, Linux administration, real-time
systems, how a compiler works, or what a "toolchain" is. Every one of those gets
introduced when it first matters, and never before.

## What you will be able to do at the end

- Explain what a microprocessor and a microcontroller each are, and argue about
  which one a given job belongs on.
- Build a program for a microcontroller on a completely different kind of
  computer, and load it onto the chip.
- Send data between the two processors and have each one do the half of the work
  it is suited to.
- Update the microcontroller's software over a wire, safely, so that a bad
  update undoes itself instead of leaving you with a dead board.
- Debug a program that has no screen, no keyboard and no error messages.

The worked example running through all of it is small enough to hold in your
head: **Linux measures how busy its four CPU cores are, and the microcontroller
draws that as four bars of light on an 8×13 LED grid.** It is deliberately
unglamorous. It is also using both halves of the board for exactly what each is
good at, which is the whole point.

## What is actually on the board

Two computers. Not one computer with a helper chip — two, each with its own
processor, its own memory, and its own software.

| | The big one (MPU) | The small one (MCU) |
|---|---|---|
| Chip | Qualcomm QRB2210 | STMicroelectronics STM32U585 |
| Processor | 4 cores, 64-bit | 1 core, 32-bit |
| Memory | ~2–4 GB | 786 KB |
| Runs | Debian Linux | Zephyr, or nothing at all |
| Good at | Networking, storage, AI, anything big | Doing one thing at an exact time |

The rest of this course is largely about that table: why a board would have both,
what changes when you write software for each, and how they talk.

## How to read this

The chapters are meant to be read in order — each one assumes the one before
it, and each ends with a link to the next. The full list is at the bottom of
this page.

Any term you do not recognise is in the [glossary](../glossary.md).

Three kinds of thing appear on every page:

**Concepts** explain an idea before you use it. Read these.

**Try it** blocks are commands to run on the board. You learn embedded
development by watching real hardware do something, and being surprised.

**No board yet?** Read anyway. Most Try it blocks show what the board printed,
so the ideas stand without one, and the first chapters ask for very little.
Come back and run them when it arrives.

> [!TIP]
> **Go deeper** boxes like this one point at the reference documentation —
> [hardware.md](../reference/hardware.md), [mcu.md](../reference/mcu.md), [usb.md](../reference/usb.md) and friends.
> Those pages are written for someone who already knows the material and wants
> the exact detail, including things that took days to work out. They will feel
> dense right now. Come back to them; that is what they are for.

## What you need

- The board, and a USB-C cable that carries **data** (charge-only cables look
  identical and are extremely common — if nothing works, suspect the cable
  first).
- A computer to plug it into.
- Nothing else. No soldering, no extra parts, no oscilloscope.

If your board has not been set up yet, [Set up a board](../setup.md) walks you
through it: one script, about an hour, mostly waiting. The next-to-last page of
the course explains what that script did and why. You can read the first few
chapters while it runs.

> [!IMPORTANT]
> **Set the board up with a plain `./bootstrap.sh`.** The exercises use the
> worked example — CPU load on the LED matrix — running as a service, and a
> plain run installs it. Many of them start with
> `sudo systemctl stop unoq-cpu-bars` and end by starting it again, because the
> service holds the one wire to the microcontroller and you are about to borrow
> it. If you set up with `--no-cpu-bars` or `--minimal`, add the demo and
> nothing else with
> `sudo bash ~/two-computers-one-board/provision/65-cpu-bars.sh`.

## A warning that will save you an afternoon

Everything in this course happens on real hardware. Real hardware fails in ways
software does not: a cable is faulty, a chip is held in reset, a program runs
but you cannot see any evidence of it.

When something does not work, resist the urge to change your code first. Ask
instead: **how would I know if this were working?** Most of the debugging tools
in this course exist to answer that question, and the habit of asking it is more
valuable than anything else here.

## The chapters

**What is actually here**

1. [Two computers on one board](two-computers.md)
2. [The Linux side](the-linux-side.md)
3. [The microcontroller side](the-microcontroller-side.md)
4. [From power to prompt](from-power-to-prompt.md)

**Making them cooperate**

5. [How they talk](how-they-talk.md)
6. [From source to chip](from-source-to-chip.md)
7. [How the build knows your hardware](how-the-build-knows-your-hardware.md)
8. [The LED matrix](the-led-matrix.md)

**Living with real hardware**

9. [Updating safely](updating-safely.md)
10. [One cable, many devices](one-cable-many-devices.md)
11. [Four lights that tell the truth](four-lights.md)
12. [Debugging without a screen](debugging-without-a-screen.md)

**Making it yours**

13. [Knowing it works](knowing-it-works.md)
14. [From factory to this](from-factory-to-this.md)
15. [Make it yours](make-it-yours.md)

Ready? The board has two computers on it, and they are more different than they
look.

Next: [Two computers on one board](two-computers.md).
