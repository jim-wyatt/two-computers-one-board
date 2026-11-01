<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# Debugging without a screen

The microcontroller has no display, no error dialog, and no way to tell you it
has crashed. It either does the thing or it does not.

This page is the most useful one in the course, because the habits here apply
long after you have forgotten which GPIO does what.

> [!NOTE]
> **In this chapter**
>
> - the one question to ask before changing any code
> - a ladder of five checks, cheapest first, from "is it running" to a real
>   debugger
> - the silent failures this board actually produces, and how many are
>   configuration rather than code
> - why a check that has never failed proves nothing — and two ways to make
>   one fail on purpose: a locked serial port, and a watchdog
>
> **You need:** [How they talk](how-they-talk.md) for the two control lines
> and [The Linux side](the-linux-side.md) for systemd and the journal. Both
> Try it blocks borrow the serial line from the demo; the second one
> deliberately hangs the microcontroller and lets it reset itself.

## The only question that matters

When something does not work, the instinct is to change the code and try again.
Resist it. Ask instead:

> **How would I know if this were working?**

If you cannot answer, changing the code is guessing. You will change five things,
one of which fixes it, and you will not know which — and you will not have
learned anything transferable.

Most tools below exist purely to answer that question.

## The ladder

Work up it. Each rung costs more effort than the one before, so do not start at
the top. Check the plug before opening the case.

### 1. Is it running at all?

```bash
systemctl status unoq-cpu-bars       # Linux side
```

```
● unoq-cpu-bars.service - Arduino UNO Q host CPU load on the LED matrix
     Loaded: loaded (/etc/systemd/system/unoq-cpu-bars.service; enabled; preset: enabled)
     Active: active (running) since Sun 2026-11-01 17:40:22 UTC; 5h 32min ago
```

`active (running)` and a start time hours ago is a healthy answer. `failed`,
or a start time seconds ago on a service that should have been up for hours,
is the first clue. Then ask the microcontroller itself. The service above holds the serial port,
so stop it first and start it again afterwards:

```bash
sudo systemctl stop unoq-cpu-bars
hpy -c "from unoq import MCU; print(MCU().status())"
sudo systemctl start unoq-cpu-bars
```

`hpy` is the project's Python, one of the shortcuts `env.sh` defines.
`uptime_ms` climbing means the microcontroller is alive. If it is *small*, the
chip reset recently — which is itself a large clue.

### 2. What did it say?

```bash
journalctl -u unoq-cpu-bars -n 50 --no-pager
journalctl -b -1 -u unoq-usb-bind          # the PREVIOUS boot
```

```
-- Boot 5b66a06da4f94d949a83273ffa7285f9 --
Nov 01 17:40:22 uno-q systemd[1]: Started unoq-cpu-bars.service - Arduino UNO Q host CPU load on the LED matrix.
Nov 01 17:40:26 uno-q unoq-cpu-bars[457]: MCU last reset: brownout,pin
```

The last lines of the first command, on this board. The demo's first line
after it starts says why the microcontroller last reset — here `brownout`,
which is what power being applied looks like to the chip. You will see that
line again at the end of this chapter, saying something else.

That second one matters more than it looks. If something reset the board, the
evidence is in the boot *before* the one you are in. `journalctl --list-boots`
shows you what is available.

### 3. Talk to the chip directly

```bash
sudo systemctl stop unoq-cpu-bars
tio /dev/ttyHS1
```

A prompt means the firmware is running and its shell thread is scheduled. That
single fact eliminates an enormous amount. Leave `tio` with Ctrl-T then `q`,
and put the service back with `sudo systemctl start unoq-cpu-bars`.

### 4. `printf`, honestly

`Serial.print` / `printk` is not beneath you; it is the most-used embedded
debugger there is. Its limits are worth knowing, though: printing takes time, so
it *changes the timing of the thing you are debugging*. A bug that disappears
when you add a print is usually a timing bug, and the print is the cause of the
disappearance.

### 5. A real debugger

Because SWD is wired up, you can halt the processor and inspect it — set
breakpoints, read variables, single-step, look at registers.

In VS Code, the Run panel has **Debug (attach to running MCU)** and
**Debug (flash then run)**.
Underneath, OpenOCD talks SWD over GPIO and `arm-zephyr-eabi-gdb` connects to it.

This is the rung people skip, and it is the one that answers questions the others
cannot: *where exactly* is it stuck.

## Failure modes that look like nothing

Embedded failures are often silent. A catalog of the ones this board actually
produces:

| Symptom | Very likely cause |
|---|---|
| Flashes and verifies, never runs | BOOT0 pin — chip is in the factory bootloader |
| MCU clearly alive, `/dev/ttyHS1` empty | UART enable pin |
| Terminal shows `ÿ?ÿ<` | Baud rate mismatch, not a fault |
| Serial port busy | `unoq-cpu-bars.service` holds it — stop it |
| Board "dead" after a reboot | `unoq-link.service` did not run |
| Flashed a signed app to a blank chip, nothing | No bootloader in front of it |

Notice how many are *configuration*, not code. On embedded, that ratio is normal.

## The lesson this project learned the hard way

While preparing this board from a factory restore, seventeen real bugs were found in
the setup scripts — and **five of them reported success**. A check looked for a
file at a path that had moved. An identity check parsed its input wrongly and
never matched anything, on any board, ever. A verification tested three of the
five things it installed.

They are written up in [clean-board-findings.md](../reference/clean-board-findings.md), and
the pattern is worth carrying with you:

> **A check that cannot fail is indistinguishable from a check that always
> passes.** You only find out by running it somewhere it should have failed.

A unit test with no assertion in it is the same thing: it goes green, and it
has checked nothing.

The practical version, for your own code:

- If a check has never failed, you do not know it works. Break something on
  purpose and confirm it complains.
- A warning that scrolls past in a hundred lines of output is not a warning.
- Prefer "refuse to continue" to "warn and carry on" whenever continuing does
  something irreversible.

## Make the invisible visible

The general technique: when you cannot observe the thing, arrange for it to leave
a trace.

- **Counters.** The `sweeps` counter exists so Linux can prove the panel is being
  refreshed without seeing it. Counters cost almost nothing and answer "is this
  loop running?" definitively.
- **A pin and a scope.** Toggle a spare GPIO at the start and end of a routine
  and an oscilloscope — an instrument that draws voltage against time — shows
  its duration exactly, without changing its timing much.
- **An LED.** Crude, always available, needs no host.
- **One status command.** `usb/status.sh` prints everything about the USB stack in
  a fixed order. When you cannot watch a failure happen, a consistent snapshot
  afterwards is the next best thing.

## Try it: break something deliberately

The best way to trust a diagnostic is to see it react. Take the serial port away
and watch the error:

```bash
sudo systemctl start unoq-cpu-bars      # the service grabs /dev/ttyHS1
hpy -c "
from unoq import MCU
with MCU() as mcu: print(mcu.status())
"
```

What comes back begins like this (the process name and number
will differ):

```
unoq.mcu.PortBusy: /dev/ttyHS1 is flagged exclusive. Open right now: unoq-cpu-bars (pid 812).
  Stop it first - for the demo that is:  systemctl stop unoq-cpu-bars
```

It fails immediately, says why, and says what to do. Now confirm *that* is the
reason, rather than assuming:

```bash
sudo fuser -v /dev/ttyHS1
sudo systemctl stop unoq-cpu-bars
hpy -c "
from unoq import MCU
with MCU() as mcu: print(mcu.status())
"
sudo systemctl start unoq-cpu-bars
```

You have just practiced the whole method: observe the failure, form a specific
hypothesis, test *it* rather than changing code, confirm.

### Why that error message is worth having

That clean refusal is not how it behaved originally, and the story is a good
one to carry with you.

Linux does not stop two processes opening the same serial port. Both succeed,
and their conversations interleave — each one reading fragments of the other's
replies. Measured on this board while writing this page: **eight attempts
alongside the running demo produced six correct answers and two failures**,
reporting

```
device reports readiness to read but returned no data
(device disconnected or multiple access on port?)
```

which reads like the cable fell out.

**Mostly working is worse than not working.** A clean failure is found in the
first five minutes. Something that works 75% of the time survives your testing,
ships, and fails in front of someone else — and the error message points at
hardware rather than at the actual cause.

The fix took two locks, because the first one turned out not to lock.

The obvious one is pyserial's `exclusive=True`. This project used it, and its
comments said that made the kernel refuse a second opener. It does not. That
flag takes an *advisory* lock (`flock`), which stops another program only if
that program asks for the same lock. `tio`, `screen` and `cat` do not ask, and
walk straight through it.

The second is an `ioctl` — a catch-all system call for device settings that
`read` and `write` cannot express — called `TIOCEXCL`, set on the port
straight after opening it. That one the kernel enforces: any later `open()` of the port by an ordinary
user fails with "device busy". `open_port()` in `python/unoq/mcu.py` takes
both, and turns either refusal into the `PortBusy` message you saw, naming the
process that has the port open.

The documentation had always said to stop the service first; the second lock is
what turned that from advice into a rule the machine enforces. The first is a
small example of this page's main lesson: a lock that had never been seen to
refuse anything was assumed to work.

When you find yourself writing "remember to X first" in a README, ask whether
the code could simply make X unnecessary or impossible to forget.

> [!TIP]
> **Go deeper** — [Julia Evans' blog](https://jvns.ca/) is the best free
> writing on the Linux side of this: `strace`, sockets, permissions, all
> illustrated and all honest about what is confusing.
> [Interrupt](https://interrupt.memfault.com/blog/) is its equivalent for
> firmware — fault handlers, coredumps and post-mortem debugging on chips with
> no operating system to help you.

## Try it: let the watchdog fire

The MCU has a watchdog of its own: a timer that resets the chip unless the
firmware keeps proving it is alive. Here that proof is fed four times a second,
and only while the LED panel's refresh is making progress. The way to trust it
is the same as the way to trust the error above: make it fire.

The demo owns the serial port, so stop it, and open a console you can type
into. `mcucon` only watches; `tio` types as well:

```bash
sudo systemctl stop unoq-cpu-bars
tio /dev/ttyHS1 -b 115200             # Ctrl-T then q to leave
```

At the prompt, ask why the MCU last reset, then hang it on purpose:

```
unoq:~$ app reset
reset=software,pin
unoq:~$ app hang yes
hanging: the watchdog resets the MCU in 8000 ms
```

(Your first answer depends on how the MCU last started; `software` after an
update, `brownout` after power was applied.) Now the prompt does not come back.
The command has locked the scheduler and is spinning, so nothing else on the
MCU gets to run, including the beat that feeds the watchdog. Count. About eight
seconds later the boot banner scrolls past in `tio`:

```
=== UNO Q MCU up: arduino_uno_q/stm32u585xx ===
reset cause: watchdog,pin
watchdog armed: 8000 ms, fed while the panel refresh runs
```

Press Enter for a prompt, and ask again:

```
unoq:~$ app reset
reset=watchdog,pin
```

`watchdog` is the cause. `pin` comes with nearly every reset on this chip,
because it pulls its own reset pin whatever started the reset. Leave `tio`
and start the demo again; its first line in the journal says the same thing:

```bash
sudo systemctl start unoq-cpu-bars
journalctl -u unoq-cpu-bars -n 5      # "MCU last reset: watchdog,pin"
```

What you saw is the method of this whole page, turned on a safety net:
**until it has fired once, you do not know it works.** A watchdog that is fed
from the wrong place looks exactly like a good one, right up to the day it
does not reset a hung board. If the panel had a frame on it when you hung the
MCU, notice that it stayed lit: the refresh interrupt kept running, and a
watchdog fed from the refresh alone would never have fired. That is why it is
fed from the workqueue — the thread that runs queued work items, which a
locked scheduler stops — and only when the refresh is moving too.

**The watchdog and firmware updates.** An update is uploaded with the watchdog
armed, so the upload must keep feeding it: every flash erase it does is a few
milliseconds, and the timeout is eight seconds. The swap MCUboot does
afterwards runs before the firmware has armed anything. Seeing one update go
all the way through, upload, test, reset and confirm, with this firmware
running is the check that matters; [Updating safely](updating-safely.md)
walks through one. The reasoning is in
[MCU workflow](../reference/mcu.md#the-watchdog).

## Check yourself

1. Your firmware works until you remove a `printk`, then fails. What kind of bug
   is this, and why does the print "fix" it?
2. A setup script prints "all packages already current" every time. What would
   convince you that it is true?
3. The board reset five minutes ago and you want to know why. Which command?

<details markdown="1">
<summary>Answers — try each one first</summary>

1. **A timing bug.** Printing takes time, so it changes the timing of the thing
   you are debugging. The `printk` was not fixing anything; the delay it added
   was hiding the fault, and removing it brought the fault back.
2. **Seeing it say something else when it should.** A check that cannot fail is
   indistinguishable from a check that always passes. Break something on
   purpose — run it somewhere it should have failed — and confirm it
   complains. Until it has failed once, you do not know it works.
3. **`journalctl -b -1`, the previous boot.** If something reset the board, the
   evidence is in the boot before the one you are in; the chapter's example is
   `journalctl -b -1 -u unoq-usb-bind`. `journalctl --list-boots` shows you
   what is available.

</details>

## What to remember

- Before changing code, ask **how would I know if this were working?** If
  you cannot answer, a change is a guess.
- **Climb the ladder from the bottom**: is it running (`systemctl status`,
  `uptime_ms`); what did it say (`journalctl`, and `-b -1` for the boot
  before); talk to the chip (`tio`); `printk`; a real debugger over SWD.
- Most silent failures on this board are **configuration, not code**: BOOT0,
  the link enable, the baud rate, a port someone else holds, a missing
  bootloader.
- **A check that cannot fail is indistinguishable from one that always
  passes.** Break something on purpose and watch it complain — the port
  lock, the watchdog, your own tests.
- **Make the invisible visible**: a counter, a spare pin, an LED, one status
  command that always prints the same things in the same order.
- Printing changes timing. A bug that vanishes when you add a print is a
  **timing bug**, and the print is hiding it.

Next: [catching all of that before the wire, so the board is not where you find
out you were wrong](knowing-it-works.md).
