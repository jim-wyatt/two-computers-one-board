#!/usr/bin/env python3
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""The Linux end of a one-byte conversation with the microcontroller.

    sudo systemctl stop unoq-cpu-bars          # it holds the wire
    hpy mcu/experiments/byte-exchange/exchange.py
    hpy mcu/experiments/byte-exchange/exchange.py --count 5

Sends 0x23 and expects 0x45 back, once a second. In between it listens: when
the microcontroller sends its own 0x23, this answers 0x45. Every byte that
crosses the wire is printed, with which side started the exchange.

No RPC, no framing, no library but pyserial opening the port. See src/main.c
for the other end, and for what happens when both sides ask at once.
"""

from __future__ import annotations

import argparse
import sys
import time

import serial

ASK = 0x23
ANSWER = 0x45
PORT = "/dev/ttyHS1"
BAUD = 115200


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", default=PORT)
    parser.add_argument(
        "--count", type=int, default=5, help="exchanges to start from this side"
    )
    parser.add_argument("--every", type=float, default=1.0, help="seconds between them")
    parser.add_argument(
        "--within", type=float, default=0.5, help="seconds to wait for an answer"
    )
    args = parser.parse_args()

    started = time.monotonic()

    def say(text: str) -> None:
        print(f"{time.monotonic() - started:6.2f}s  {text}", flush=True)

    asked = answered = heard = 0
    with serial.Serial(args.port, BAUD, timeout=0.05, exclusive=True) as wire:
        wire.reset_input_buffer()
        next_ask = time.monotonic() + 0.2
        answer_due = 0.0
        # Keep listening for a little after the last question, so the
        # microcontroller's own questions in that time are answered too.
        stop_at = 0.0
        while True:
            now = time.monotonic()
            if asked >= args.count and answer_due == 0.0:
                stop_at = stop_at or now + 2.5
                if now >= stop_at:
                    break
            for byte in wire.read(16):
                if byte == ASK:
                    wire.write(bytes([ANSWER]))
                    heard += 1
                    say(
                        f"MCU   -> Linux  0x{byte:02x}    Linux -> MCU    0x{ANSWER:02x}   (the MCU asked)"
                    )
                elif byte == ANSWER and answer_due:
                    answer_due = 0.0
                    answered += 1
                    say(
                        f"MCU   -> Linux  0x{byte:02x}                            (its answer)"
                    )
                else:
                    say(
                        f"MCU   -> Linux  0x{byte:02x}    not part of this conversation"
                    )
            now = time.monotonic()
            if answer_due and now >= answer_due:
                say("no answer")
                answer_due = 0.0
            if not answer_due and asked < args.count and now >= next_ask:
                wire.write(bytes([ASK]))
                asked += 1
                answer_due = now + args.within
                next_ask = now + args.every
                say(
                    f"Linux -> MCU    0x{ASK:02x}                            (Linux asks)"
                )

    print()
    print(f"Linux asked {asked} time(s) and was answered {answered}.")
    print(f"The MCU asked {heard} time(s) and was answered each time.")
    return 0 if answered == asked and heard > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
