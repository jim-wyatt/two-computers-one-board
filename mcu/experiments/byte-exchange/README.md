<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# One byte each way, without the bridge

An experiment, not part of the course: the two computers on an UNO Q exchange
single bytes, `0x23` answered by `0x45`, started from either side, with no RPC
and no library between them but the serial driver.

It was asked for on the Arduino forum:

> Would be glad to see that you post an experiment where a UNO Q user can
> manually control the Router Bridge from both MPU and MCU sides to exchange
> 1-byte data (0x23 <----> 0x45) instead of using the RPC functions.

## What "the Router Bridge" is, underneath

On Arduino's image the bridge is a program, `arduino-router`, that holds a
serial port on the Linux side: `/dev/ttyHS1`, 115200 baud. The microcontroller
is on the other end of that wire.

The router speaks RPC and nothing else. This project found that out by
accident: with the router still running, its own firmware wrote plain bytes
down the wire, and the router logged one line for each of them.

```
arduino-router: ERROR Error in connection err="invalid packet, expected array, got: int8"
```

So a raw `0x23` cannot be sent *through* the bridge. It is thrown away. A
conversation without the RPC functions goes underneath the bridge, on the wire
itself, with the router not running.

| | |
|---|---|
| Linux side | `/dev/ttyHS1`, 115200 8N1 |
| Microcontroller side | `lpuart1`, pins PG7 and PG8 |
| Also needed | GPIO 70 on the Linux side held high. It enables the link, and this project's `unoq-link` service does it at boot |

## The two programs

| File | Runs on | Does |
|---|---|---|
| [`src/main.c`](src/main.c) | the STM32, under Zephyr | Answers `0x23` with `0x45`. Every two seconds sends `0x23` itself and waits half a second for `0x45`. |
| [`exchange.py`](exchange.py) | Linux | The same, the other way round, and prints every byte that crosses. |

Neither prints to the wire. The firmware has no console and no shell, because
the main firmware's prompt and boot banner would arrive on Linux mixed in with
the one byte the experiment is about. It reports on three LEDs instead:

| LED | Means |
|---|---|
| LED 4 green, toggling | a `0x23` arrived from Linux and `0x45` was sent back |
| LED 3 green, toggling | the microcontroller's own `0x23` was answered |
| LED 3 red, on | the microcontroller asked and nobody has answered |

With `exchange.py` not running, LED 3 shows red: the microcontroller is asking
every two seconds and Linux is not listening.

## Run it

On a board set up with this project, logged in over SSH:

```bash
cd ~/two-computers-one-board
sudo systemctl stop unoq-cpu-bars                  # the demo holds the wire
mcu/zbuild.sh mcu/experiments/byte-exchange        # about two minutes
mcu/flash.sh                                       # writes it over the main firmware
.venv/bin/python mcu/experiments/byte-exchange/exchange.py
```

What it printed on the board this was written on, on 2026-10-11:

```
  0.20s  Linux -> MCU    0x23                            (Linux asks)
  0.26s  MCU   -> Linux  0x45                            (its answer)
  0.86s  MCU   -> Linux  0x23    Linux -> MCU    0x45   (the MCU asked)
  1.21s  Linux -> MCU    0x23                            (Linux asks)
  1.26s  MCU   -> Linux  0x45                            (its answer)
  2.21s  Linux -> MCU    0x23                            (Linux asks)
  2.26s  MCU   -> Linux  0x45                            (its answer)
  2.86s  MCU   -> Linux  0x23    Linux -> MCU    0x45   (the MCU asked)
  3.22s  Linux -> MCU    0x23                            (Linux asks)
  3.27s  MCU   -> Linux  0x45                            (its answer)
  4.22s  Linux -> MCU    0x23                            (Linux asks)
  4.27s  MCU   -> Linux  0x45                            (its answer)
  4.87s  MCU   -> Linux  0x23    Linux -> MCU    0x45   (the MCU asked)

Linux asked 5 time(s) and was answered 5.
The MCU asked 3 time(s) and was answered each time.
```

The answer to Linux's byte comes back in about 50 milliseconds. That is not
the wire, which carries a byte in under a tenth of a millisecond at this speed;
it is how often the script looks.

The firmware is 16.7 KB, 4% of the space the bootloader leaves for an
application.

## Put the board back

```bash
mcu/zbuild.sh && mcu/flash-all.sh                  # the main firmware again
sudo systemctl start unoq-cpu-bars
```

## What happens when both sides ask at once

Either end may send `0x23` whenever it likes, so the two can cross: one side
is waiting for its `0x45` and a `0x23` arrives instead. Both programs treat
that the same way. It is the other side's question, so it gets its `0x45`, and
the wait for our own answer carries on. Any other byte is ignored.

That rule is the whole protocol, and it is the part worth noticing. One byte
each way is easy until both ends are allowed to speak first; then something has
to say what a question arriving in the middle of your own means. RPC libraries
exist largely to answer that, and questions like it, once.

## What this is not

- **Not the stock setup.** It was run on a board set up with this project:
  Zephyr on the microcontroller, the router switched off. Doing the same with
  an Arduino sketch on one side and the router stopped on the other is a
  different experiment, and has not been tried.
- **Not tested by the project's gates.** There are no automated tests for
  either file. It was run once, on one board; the output above is that run.
- **Not seen by eye.** The LEDs are described from the code. Nobody was
  looking at the board when the exchange above ran.
