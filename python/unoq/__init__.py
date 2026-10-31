# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""
unoq - talk to the Arduino UNO Q's STM32U585 from the Linux side.

    from unoq import MCU, link_up

    link_up()                      # BOOT0 low + UART enable (safe to re-run)
    with MCU() as mcu:
        print(mcu.status())        # {'uptime_ms': 12216, 'flip': 0, 'sweeps': 9620}
        mcu.bars(CpuSampler().sample())   # CPU load on the LED matrix
        mcu.cmd('gpio set gpioh 11 1')    # or any other shell command

Wraps the Zephyr shell running on lpuart1 (/dev/ttyHS1). Firmware updates over
the same UART are in `fota`. The hardware notes are in docs/reference/hardware.md.
"""

# cpubars and powerlog are entry points, not part of the API, and is deliberately not
# imported here: `python -m unoq.cpubars` warns if the package has already
# pulled the module in. Import them directly - `from unoq import cpubars`.
from . import fota
from .cpu import CpuSampler, read_cpu_times
from .cpufreq import Policy, read_policies
from .link import BOOT0_LINE, LINK_ENABLE_LINE, link_state, link_up
from .mcu import (
    MCU,
    JitterHist,
    JitterStat,
    MCUError,
    PortBusy,
    ShellTimeout,
    TempLogStat,
    TempSample,
    open_port,
    port_holders,
)
from .thermal import hottest, read_temps

__all__ = [
    "fota",
    "MCU",
    "JitterHist",
    "JitterStat",
    "MCUError",
    "PortBusy",
    "ShellTimeout",
    "TempSample",
    "TempLogStat",
    "open_port",
    "port_holders",
    "link_up",
    "link_state",
    "BOOT0_LINE",
    "LINK_ENABLE_LINE",
    "CpuSampler",
    "read_cpu_times",
    "read_temps",
    "hottest",
    "Policy",
    "read_policies",
]
__version__ = "1.1.0"
