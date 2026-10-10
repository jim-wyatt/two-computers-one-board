# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""
The two MPU GPIO lines the MCU depends on.

These are NOT in the Zephyr board definition and are not documented by Arduino.
They were driven by `arduino-router`; with that service disabled, a board with
perfectly good firmware looks dead. See docs/reference/hardware.md.

    line 37  MCU BOOT0        latched at MCU reset. High/floating -> the STM32
                              boots its ROM bootloader (PC ~0x0bf9xxxx) and the
                              image in flash never runs, despite verifying OK.

    line 70  UART link enable low/floating -> the MCU transmits (LPUART1 CR1
                              shows TE set, ISR shows TC) but /dev/ttyHS1 reads
                              zero bytes.

SWD, for reference: swclk=26 swdio=25 srst/trst=38, same chip.
"""

from __future__ import annotations

import gpiod
from gpiod.line import Direction, Value

GPIOCHIP = "/dev/gpiochip1"
BOOT0_LINE = 37
LINK_ENABLE_LINE = 70
SWD_LINES = {"swdio": 25, "swclk": 26, "srst": 38}


def link_up(chip: str = GPIOCHIP) -> None:
    """Drive BOOT0 low and enable the UART link.

    Idempotent and safe to call repeatedly. The pin state persists after the
    request is released - the SoC pinctrl keeps driving the last value - which
    is why a one-shot works and no daemon is needed.

    BOOT0 is only sampled at MCU reset, so call this *before* resetting or
    flashing the MCU, not after.
    """
    req = gpiod.request_lines(
        chip,
        consumer="unoq-link",
        config={
            BOOT0_LINE: gpiod.LineSettings(direction=Direction.OUTPUT, output_value=Value.INACTIVE),
            LINK_ENABLE_LINE: gpiod.LineSettings(
                direction=Direction.OUTPUT, output_value=Value.ACTIVE
            ),
        },
    )
    req.release()


def link_state(chip: str = GPIOCHIP) -> dict[str, str]:
    """Report the direction of the link lines.

    INPUT means the line is floating and the link is (or will be) broken.

    Direction, not value, and deliberately so: reading the value means
    requesting the line, and requesting it as an input drops the drive - the
    read breaks the link it was meant to check. `gpioget 37` does exactly that.
    This uses get_line_info(), which never requests the line (`gpioinfo` is the
    equivalent from the shell).
    """
    out = {}
    c = gpiod.Chip(chip)
    try:
        for name, off in (("boot0", BOOT0_LINE), ("link_enable", LINK_ENABLE_LINE)):
            out[name] = str(c.get_line_info(off).direction).rsplit(".", 1)[-1]
    finally:
        c.close()
    return out
