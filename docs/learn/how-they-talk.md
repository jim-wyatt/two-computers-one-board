<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# How they talk

Two computers, no shared memory. To cooperate they must send bytes down a wire.
This page is about that wire, the two extra wires that make it usable, and why
"just send the data" is harder than it sounds.

## Serial, from the bottom

The connection is a **UART** — a universal asynchronous receiver/transmitter.
Strip the name and it is this: one wire for each direction, and a byte is sent
by wiggling the voltage on it in a pattern both ends have agreed on.

There is no clock wire. That is what "asynchronous" means, and it is the reason
both ends must agree in advance on **how fast** to wiggle. That speed is the
**baud rate**, and ours is 115200 — roughly 115,200 signal changes per second,
about 11 KB/s of actual data.

If the two ends disagree about the baud rate, you do not get an error. You get
garbage: the receiver samples at the wrong moments and reconstructs bytes that
were never sent. A screenful of `ÿ<ÿ?ÿ` almost always means a baud mismatch, not
a broken cable.

On Linux the wire appears as a file:

```bash
ls -l /dev/ttyHS1
```

Reading that file gives you bytes the microcontroller sent. Writing to it sends
bytes back. That really is the whole interface.

## The two wires nobody documents

Here is where this board bites people, and it is the reason
[hardware.md](../reference/hardware.md) exists.

Two GPIO pins on the Linux side control the microcontroller. They are on
`gpiochip1`, and they are documented nowhere official:

| Line | What it does | What you see when it is wrong |
|---|---|---|
| **37** | MCU **BOOT0** | Firmware flashes *and verifies*, but never runs |
| **70** | UART link enable | MCU transmits, `/dev/ttyHS1` reads nothing |

**BOOT0** decides *what the microcontroller runs when it starts*. High, and the
chip boots a small program burned into it at the factory that waits for someone
to send it new firmware. Low, and it runs your program. The pin is only sampled
at reset, so it must be set *before* the chip restarts, not after.

The failure this produces is nasty because everything reports success. Your
firmware writes correctly. Verification passes. The chip is simply running a
different program — the factory bootloader — which does not blink your LEDs.

**The link enable** turns on the path between the two chips. Without it the
microcontroller happily transmits into a disconnected wire, and Linux reads an
eternally empty file. Both sides are working. No error is available anywhere.

`unoq-link.service` sets both at boot:

```bash
systemctl status unoq-link
```

> **This is the single most useful thing on this page.** If the board ever looks
> dead — flashed fine, running nothing; or connected fine, saying nothing —
> suspect these two pins before anything else.

## Bytes are not messages

You have a wire that carries bytes. You want to send a *value*. Those are not
the same thing, and the gap is called **framing**.

Say the microcontroller sends the number 1234. You read the file and get `12`.
Is that the whole message? Is more coming? Has 34 been lost, or is it merely
late? The wire cannot tell you — bytes arrive when they arrive, in any grouping.

```mermaid
sequenceDiagram
    participant M as MCU
    participant W as the wire
    participant L as Linux
    M->>W: "1234\n"
    W-->>L: read() → "12"
    Note over L: is that all?<br/>is more coming?<br/>was 34 lost?
    W-->>L: read() → "34\n"
    Note over L: the newline is the<br/>only thing that said<br/>"that was a message"
```

Every serial protocol solves this somehow:

- **A terminator**: send text and agree that a newline ends a message. Simple,
  human-readable, and what a shell does.
- **A length prefix**: say how many bytes are coming, then send exactly that
  many.
- **Fixed size**: agree every message is exactly 8 bytes.

This project uses the first. The microcontroller runs a **shell**, the same one
you typed at in [The microcontroller side](the-microcontroller-side.md), and the "protocol" is: send a command line,
read text back until the prompt returns.

```c
/* mcu/app/include/app_proto.h - the format both sides agree on */
#define APP_STATUS_FMT "uptime_ms=%lld flip=%d sweeps=%u"
```

The MCU prints that; Python parses it. It is not the fastest possible design,
and that is a deliberate trade: you can debug it by hand with `tio`, which
matters far more here than saving bytes.

## Why the Python side is more complicated than you would expect

Reading a reply sounds like `read()` and done. In practice
[`unoq/mcu.py`](../../python/unoq/mcu.py) copes with all of this:

- **The shell echoes your command back**, so the first thing you read is what you
  just sent, not the answer.
- **Output is wrapped in ANSI escape codes** for colour, which must be stripped.
- **Bytes dribble in.** One `read()` rarely returns a whole reply; you must keep
  reading until you see the prompt.
- **The reply might never come.** If the MCU is reset, or held in the wrong boot
  mode, you wait forever unless you impose a timeout.

That last point is why the project's tests **fake the serial port deliberately
badly** — echoing commands, wrapping output in escape codes, dribbling bytes a
few at a time. A fake that answers instantly and perfectly would let broken code
pass.

## Try it: have the conversation by hand

First be the Python library yourself. Stop the demo, which is holding the wire,
and open it in `tio`, the serial terminal:

```bash
sudo systemctl stop unoq-cpu-bars
tio /dev/ttyHS1 -b 115200
```

Press Enter to get a prompt, then type the command the library sends:

```
unoq:~$ app status
uptime_ms=12216 flip=0 sweeps=1043712
unoq:~$
```

Your numbers will differ. Everything on that screen crossed the wire: the
characters you typed came back as the shell's echo, then the reply line in
exactly the format `APP_STATUS_FMT` promises, then the prompt that says the
reply is over. Leave `tio` with `Ctrl-t q`.

Now let Python do the same thing:

```bash
cd ~/two-computers-one-board
./.venv/bin/python -c "
from unoq import MCU
with MCU() as mcu:
    print(mcu.status())
"
sudo systemctl start unoq-cpu-bars
```

It prints the same three fields — `uptime_ms`, `flip` and `sweeps` — as a
Python dictionary. The library sent the line you typed, threw
away the echo and the colour codes, read until the prompt came back, and split
what was left on spaces and `=`.

One after the other, and not side by side in two windows, for a reason: **only
one program can hold the wire at a time**. The library opens `/dev/ttyHS1`
exclusively, and a second program that tries is refused with a message saying
the port is taken. That is deliberate. Two readers on one serial line each get
fragments of the other's conversation, which is a far worse failure than a
clean refusal. It is also why the exercise starts by stopping the demo.

## The other direction

So far Linux asks a question and the MCU answers it. The demo sends *data* the
other way: twice a second, Linux measures how busy each core is and pushes four
percentages down the wire. The MCU decides which pixels that means.

```
unoq:~$ app bars 100 50 25 0
ok bars=4
```

Notice that the MCU still answers. Every frame gets an `ok bars=4` back, and the
Python side waits for it — and for the prompt after it — before it does anything
else. Is that wait worth having?

Here, yes. At two frames a second there is half a second between frames and the
round trip is a small fraction of that, so waiting costs nothing you could
see. And the reply buys something: it is the only thing that tells Linux the
other end is still there. If the MCU has been reset, or the link has gone down,
the wait times out and the program finds out, instead of carrying on sending
frames to nobody.

Now change the numbers. At a thousand frames a second the same choice would be
wrong: waiting for each reply would cap the frame rate at the round-trip time of
the wire, and a dropped frame would not matter, because the next one replaces it
a millisecond later. There you would stream the frames and not wait.

**Choosing whether a message needs an answer is a real design decision.** The
right answer depends on how often you send, what a lost message costs, and what
the reply tells you that you could not learn otherwise.

> [!TIP]
> **Go deeper** — [Beej's Guide to Network Programming](https://beej.us/guide/bgnet/)
> is nominally about sockets and is the friendliest explanation anywhere of the
> lesson on this page: bytes are not messages. For framing schemes with a proper
> worst case, read
> [Consistent Overhead Byte Stuffing](https://en.wikipedia.org/wiki/Consistent_Overhead_Byte_Stuffing);
> for why a checksum you invented is weaker than you think, Ross Williams'
> [Painless Guide to CRC Error Detection](https://www.zlib.net/crc_v3.txt).
> [SparkFun's serial tutorial](https://learn.sparkfun.com/tutorials/serial-communication)
> covers the electrical layer this page skims over.

## Check yourself

1. `/dev/ttyHS1` reads nothing at all, and the MCU is definitely running. Which
   of the two control pins do you suspect, and why?
2. Your terminal fills with `ÿ?ÿ<`. What is wrong, and is it a hardware fault?
3. The demo waits for the MCU to confirm every frame. What does that wait cost
   here, and what does it buy? When would waiting be the wrong choice?

<details markdown="1">
<summary>Answers — try each one first</summary>

1. **Line 70, the UART link enable.** Without it the microcontroller transmits
   into a disconnected wire and Linux reads an eternally empty file, with no
   error anywhere. BOOT0 (line 37) wrong looks different: the firmware flashes
   and verifies but never runs.
2. **A baud rate mismatch, and no, it is not a hardware fault.** The receiver
   is sampling at the wrong moments and reconstructing bytes that were never
   sent. Both ends must agree on the speed in advance; ours is 115200.
3. **It costs almost nothing and it buys knowing the link is alive.** At two
   frames a second the round trip is a small part of the half second between
   frames, and a reply that never comes is how Linux learns the MCU has gone
   away. Waiting would be the wrong choice at a high frame rate — a thousand a
   second, say — where it would cap the rate at the round-trip time of the
   wire and where a lost frame is replaced almost at once anyway.

</details>

Next: [From source to a running chip](from-source-to-chip.md) — turning source
code into something the chip can run, and getting it there.
