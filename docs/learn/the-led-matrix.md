<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# The LED matrix

104 LEDs, in 8 rows and 13 columns. This page is about how they are lit, because
the answer explains why the job belongs on the microcontroller at all — and it
is the clearest example in the whole project of a timing problem masquerading as
a display problem.

## The problem: not enough pins

The obvious way to control 104 LEDs is 104 wires. The chip does not have 104
spare pins, and even if it did, the board would be a mess.

The trick is that **you do not have to light them all at once**. Light one, very
briefly, then the next, and so on, fast enough that your eye cannot follow. This
is **multiplexing**, and it works because of **persistence of vision**: your
visual system blurs anything faster than roughly 50 times per second into a
steady image.

So the matrix is never actually showing a picture. It is showing one LED at a
time, extremely fast, and your eye assembles it. Photograph one with a fast
shutter and you catch a single dot.

This board goes further and uses **charlieplexing**, which exploits the fact that
LEDs conduct in one direction only. With *n* pins you can address *n × (n − 1)*
LEDs — 11 pins gets you 110, enough for 104 — by driving one pin high, one low,
and leaving all the others floating so no current flows through them.

The cost is that only one LED can be lit at any instant, so the refresh loop has
to be quick and utterly regular.

## Why this cannot be Linux's job

Here is the number that makes the argument:

```c
/* mcu/app/include/app_proto.h */
#define APP_MATRIX_SWEEPS_PER_S 962
```

The microcontroller sweeps the whole panel about **a thousand times a second**
(962 is the figure the timing was designed around; measured, it is nearer 1100).
Each sweep visits 104 LEDs, so it is switching pins roughly **100,000 times a
second** — one every 10 microseconds.

Recall from [Two computers on one board](two-computers.md) what happens when
Linux is asked to hit an exact moment: it
usually does, and occasionally it is 2 milliseconds late because the kernel had
something else to do. Two milliseconds is **200 slots**. The display would not
glitch subtly; a visible chunk of the panel would go dark, at random, forever.

The microcontroller is not faster than the four Linux cores. It is *reliable*,
and that is the whole requirement.

**Try it — measure the sweeps yourself:**

```bash
sudo systemctl stop unoq-cpu-bars
cd ~/two-computers-one-board
./.venv/bin/python -c "
from unoq import MCU
import time

def rate(mcu, label):
    a = int(mcu.status()['sweeps']); time.sleep(2)
    b = int(mcu.status()['sweeps'])
    print(f'{label}: {(b - a) / 2:.0f} sweeps per second')

with MCU() as mcu:
    mcu.matrix_off()
    rate(mcu, 'panel dark ')
    mcu.bars([50, 50, 50, 50])
    rate(mcu, 'panel lit  ')
    mcu.matrix_off()
"
sudo systemctl start unoq-cpu-bars
```

```
panel dark :    0 sweeps per second
panel lit  : 1102 sweeps per second
```

**Both numbers are informative.**

A dark panel sweeps *zero* times. The driver does not scan a display with
nothing on it — there is no point burning 100,000 pin operations a second to
show darkness, and on a board this power-conscious that restraint is deliberate.
So if you ever measure this and get 0, the microcontroller is not stuck; it has
simply been given nothing to draw.

And the lit figure is ~1100, not the 962 in the header. That constant is the
*design* figure the timing was calculated from; the measured rate is what the
hardware actually manages, which depends on how long each slot really takes.
Both are true, and the gap between a nominal constant and a measured value is
worth being suspicious about in general — here it is benign, but the only reason
we know that is that somebody measured.

## Grey, from a panel that has no grey

The LEDs are single-colour blue and can only be on or off. Yet the bars fade.

The trick is the same one again, applied to brightness: an LED that should be
at level 3 of 7 is lit on three sweeps out of every seven, and left dark on the
other four. Too fast to see, so your eye reports "less bright".
This is **pulse-width modulation** — brightness as a *fraction of time on*.

```c
#define APP_MATRIX_MAX_LEVEL 7      /* 0 = off, 7 = fully on */
```

Eight levels from a panel with two states, bought entirely with timing.

## Splitting the work

Now the design decision this whole project exists to demonstrate. Drawing a bar
chart involves three jobs, of very different kinds:

| Job | Where | Why |
|---|---|---|
| How busy is each core? | Linux | It is arithmetic on `/proc/stat`, a file only Linux has |
| How tall is each bar? | MCU | Arithmetic again — percentage to pixels — with no hardware in it, which is why it can be tested off the chip |
| Which LED is lit *right now*? | MCU | 10 μs of slack, forever |

Linux measures and sends percentages; the microcontroller decides the pixels.

```mermaid
flowchart TB
  A["/proc/stat<br/><small>counters</small>"] --> B["cpu.py<br/><small>percentages</small>"]
  B -->|"4 numbers,<br/>twice a second"| C["bars.c<br/><small>rasteriser</small>"]
  C --> D["104 brightness<br/>values"]
  D --> E["matrix.c<br/><small>interrupt handler, every 10 µs</small>"]
  E --> F(["the panel"])
```

The message between them is tiny: four percentages, one per core. The measuring
happens on Linux; the drawing, and everything time-critical, happens on the
microcontroller; the wire between carries almost nothing.

The rasteriser — the code that turns "core 2 is at 47%" into which pixels are
lit — lives in `mcu/app/src/bars.c`. It is **pure arithmetic with no hardware in
it at all**, which is why it can be tested without the microcontroller: on the
board's Linux side, as an ordinary program.

```bash
~/two-computers-one-board/mcu/ztest.sh        # the firmware tests, nothing flashed
```

Those tests build for `native_sim` — a fake Zephyr "board" that is really just a
Linux program. The rasteriser cannot tell the difference, because it never
touches a pin. **Separating the calculation from the hardware is what made it
testable**, and that is a habit worth taking to every embedded project you
touch.

## Try it: drive it yourself

Stop the demo and put your own pattern up:

```bash
sudo systemctl stop unoq-cpu-bars
cd ~/two-computers-one-board
./.venv/bin/python -c "
from unoq import MCU
with MCU() as mcu:
    for pct in (0, 25, 50, 75, 100):
        mcu.bars([pct] * 4)
        print('bars at', pct, '%')
        __import__('time').sleep(1)
"
sudo systemctl start unoq-cpu-bars
```

Then load a core and watch the real thing respond:

```bash
yes > /dev/null & sleep 6; kill %1
```

That keeps one core flat out for six seconds: `&` starts `yes` in the
background, `sleep 6` waits, and `kill %1` stops the background job.

> [!TIP]
> **Go deeper.** Which pin pair lights which LED, and how long each gets, are
> facts read out of Arduino's own core for this panel. No code or table was
> copied; they are credited in [Credits](../third-party.md#derived-work).
> The driver is `mcu/app/src/matrix.c`; the rasteriser is `bars.c`.

## Check yourself

1. You photograph the panel at 1/4000 s and see one lit dot. Is the board broken?
2. The panel's LEDs are only on or off. How does a bar show half brightness?
3. `bars.c` is tested without any hardware. What property of that code makes that
   possible, and what would break it?
4. You read the sweep counter twice and it has not moved. Give two very
   different explanations, and say how you would tell them apart.

<details markdown="1">
<summary>Answers — try each one first</summary>

1. **No.** The panel only ever lights one LED at any instant. It moves on fast
   enough that persistence of vision assembles the picture, and a fast shutter
   simply catches what is really there.
2. **By being lit for only part of the time.** This is pulse-width modulation:
   brightness as a fraction of time on, switched too fast to see. Level 3 of 7
   is on for three parts in seven, so your eye reports "less bright".
3. **It is pure arithmetic with no hardware in it.** That lets it build for
   `native_sim`, where it cannot tell the difference because it never touches
   a pin. Making it touch one — writing a register or driving the panel from
   inside `bars.c` — would break that.
4. **Either the panel is dark, or the microcontroller really is stuck.** The
   driver does not scan a display with nothing on it, so a dark panel sweeps
   zero times and that is healthy. To tell them apart, give it something to
   draw — `mcu.bars([50, 50, 50, 50])` — and read the counter again: it should
   now climb by about 1100 a second.

</details>

Next: [Updating safely](updating-safely.md) — replacing the firmware on a
running board without being able to visit it.
