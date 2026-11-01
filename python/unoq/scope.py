# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""
The two-chip oscilloscope: one chip makes a wave and samples it, the other reads it.

    python -m unoq.scope                                # a 1 kHz sine, 4096 samples at 100 kHz
    python -m unoq.scope --wave triangle --hz 250 --rate 20000
    python -m unoq.scope --wave none                    # whatever is on A0 already
    python -m unoq.scope --csv burst.csv                # and every sample, to a file

The MCU's DAC plays the wave out of A0 (PA4), and its ADC samples the same
pin: on the STM32U585, PA4 is DAC1's output 1 and ADC1's channel 9 at once,
so the loop needs no wire. Both are paced by timers and moved by DMA (see
mcu/app/include/scope.h). This side asks for a burst on the serial shell
(MCU.scope_capture) and reads the samples over the SPI link
(SpiLink.scope_read), because a burst of 4096 is 8 KB and the serial line
moves about 11 KB/s.

It prints the smallest, largest and mean sample, in ADC codes and in volts,
and the frequency estimated from the rising crossings of the middle. The
volts assume the ADC's reference is 3.3 V; the codes are what was measured.
The MCU's own summary of the burst, printed by `app scope capture`, is
checked against the samples that came over SPI: two links, one answer.

It needs /dev/ttyHS1 and /dev/spidev0.0 to itself: stop the demo first
(sudo systemctl stop unoq-cpu-bars). The procedure is in
docs/reference/mcu.md, "The scope".
"""

from __future__ import annotations

import argparse
import contextlib
import csv
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from typing import IO, Protocol

from .mcu import (
    MCU,
    SCOPE_ADC_MAX,
    SCOPE_BURST_MS_MAX,
    SCOPE_DAC_AMPLITUDE,
    SCOPE_DAC_MAX,
    SCOPE_DAC_MID,
    SCOPE_N_MAX,
    SCOPE_N_MIN,
    SCOPE_RATE_HZ_MAX,
    SCOPE_RATE_HZ_MIN,
    SCOPE_WAVE_HZ_MAX,
    SCOPE_WAVE_HZ_MIN,
    SCOPE_WAVES,
    MCUError,
    ScopeCapture,
    scope_capture_valid,
)
from .spilink import Burst, FrameError, LinkError, SpidevTransport, SpiLink, Transport

VREF_V = 3.3
"""What the volts are worked out against: the board's analog reference, as
far as this side knows. An assumption, so the codes are printed too."""
DEFAULT_WAVE = "sine"
DEFAULT_HZ = 1000
DEFAULT_N = 4096
DEFAULT_RATE = 100_000
NOISE_CODES = 64
"""Peak to peak below this many codes (0.4% of full scale) is no signal to
find a frequency in."""


class ScopeShell(Protocol):
    """The parts of MCU this uses."""

    def scope_gen(self, wave: str, hz: int) -> float: ...
    def scope_capture(self, n: int, rate_hz: int) -> ScopeCapture: ...
    def scope_off(self) -> None: ...
    def close(self) -> None: ...


@dataclass(frozen=True)
class Stats:
    n: int
    min: int
    max: int
    mean: float
    seconds: float
    freq_hz: float | None  # None: no signal, or under two periods of it


def volts(code: float) -> float:
    return code * VREF_V / SCOPE_ADC_MAX


def estimate_freq(samples: Sequence[int], rate_hz: float) -> float | None:
    """Rising crossings of the middle, with hysteresis of a tenth of the
    swing either side so noise near the middle is not counted as a crossing.
    Periods between the first and the last crossing, over the time between
    them."""
    if not samples or rate_hz <= 0:
        return None
    lo, hi = min(samples), max(samples)
    if hi - lo < NOISE_CODES:
        return None
    mid = (lo + hi) / 2
    hyst = (hi - lo) / 10
    rising: list[int] = []
    low = False
    for i, s in enumerate(samples):
        if s <= mid - hyst:
            low = True
        elif s >= mid + hyst and low:
            rising.append(i)
            low = False
    if len(rising) < 2:
        return None
    return (len(rising) - 1) * rate_hz / (rising[-1] - rising[0])


def stats(burst: Burst) -> Stats:
    s = burst.samples
    if not s:
        return Stats(0, 0, 0, 0.0, 0.0, None)
    return Stats(
        len(s),
        min(s),
        max(s),
        sum(s) / len(s),
        len(s) / burst.rate_hz,
        estimate_freq(s, burst.rate_hz),
    )


def disagreements(cap: ScopeCapture, burst: Burst) -> list[str]:
    """Where the samples that came over SPI differ from what the MCU said of
    them on the shell. Empty when the two links agree."""
    s = burst.samples
    found = []
    if burst.id != cap.id:
        found.append(f"SPI sent capture {burst.id}, the shell took {cap.id}")
    if len(s) != cap.n:
        found.append(f"SPI sent {len(s)} samples, the shell took {cap.n}")
    elif s and (min(s), max(s), sum(s) // len(s)) != (cap.min, cap.max, cap.mean):
        found.append(
            f"SPI's samples give min {min(s)} max {max(s)} mean {sum(s) // len(s)}, "
            f"the shell said {cap.min} {cap.max} {cap.mean}"
        )
    return found


def write_csv(out: IO[str], burst: Burst) -> None:
    w = csv.writer(out)
    w.writerow(["index", "t_s", "code", "volts"])
    for i, code in enumerate(burst.samples):
        w.writerow([i, f"{i / burst.rate_hz:.9f}", code, f"{volts(code):.4f}"])


def report(st: Stats, cap: ScopeCapture, wave: str | None, hz: int, played: float | None) -> str:
    lines = []
    if wave is not None and played is not None:
        lines.append(f"wave {wave} at {hz} Hz asked, {played:.3f} Hz played (TIM7)")
        lo = SCOPE_DAC_MID - SCOPE_DAC_AMPLITUDE
        hi = SCOPE_DAC_MID + SCOPE_DAC_AMPLITUDE
        scale = (SCOPE_ADC_MAX + 1) / (SCOPE_DAC_MAX + 1)
        lines.append(
            f"expect about {round(lo * scale)}..{round(hi * scale)}: the DAC plays {lo}..{hi}"
            f" of {SCOPE_DAC_MAX}, the ADC reads 14 bits"
        )
    else:
        lines.append("no wave played: this is whatever is on A0")
    lines.append(
        f"capture {cap.id}: {st.n} samples at {cap.rate_hz:.3f} Hz, {st.seconds * 1000:.3f} ms"
    )
    lines.append(f"min  {st.min:>6} ({volts(st.min):.3f} V)")
    lines.append(f"max  {st.max:>6} ({volts(st.max):.3f} V)")
    lines.append(f"mean {st.mean:>8.1f} ({volts(st.mean):.3f} V)")
    if st.freq_hz is None:
        lines.append("frequency: none found (no swing, or under two periods of it)")
    else:
        lines.append(f"frequency about {st.freq_hz:.1f} Hz")
    lines.append(f"volts against an assumed {VREF_V} V reference")
    return "\n".join(lines)


def run(
    shell: ScopeShell,
    link: SpiLink,
    wave: str | None,
    hz: int,
    n: int,
    rate: int,
    keep: bool,
) -> tuple[ScopeCapture, Burst, float | None]:
    """Play the wave (unless wave is None), take the burst on the shell, read
    it over SPI. A wave this started is stopped again unless keep."""
    played = shell.scope_gen(wave, hz) if wave is not None else None
    try:
        cap = shell.scope_capture(n, rate)
        burst = link.scope_read(cap.id)
    finally:
        if played is not None and not keep:
            shell.scope_off()
    return cap, burst, played


def main(
    argv: list[str] | None = None,
    mcu: Callable[[], ScopeShell] = MCU,
    transport: Callable[[], Transport] = SpidevTransport,
) -> int:
    parser = argparse.ArgumentParser(
        prog="python -m unoq.scope",
        description=(
            "Play a wave out of the MCU's DAC on A0, sample the same pin with its ADC, "
            "and read the burst over the SPI link."
        ),
    )
    parser.add_argument(
        "--wave",
        choices=(*SCOPE_WAVES, "none"),
        default=DEFAULT_WAVE,
        help="what the DAC plays; none leaves A0 alone (default %(default)s)",
    )
    parser.add_argument("--hz", type=int, default=DEFAULT_HZ, help="the wave (default %(default)s)")
    parser.add_argument("--n", type=int, default=DEFAULT_N, help="samples (default %(default)s)")
    parser.add_argument(
        "--rate", type=int, default=DEFAULT_RATE, help="samples a second (default %(default)s)"
    )
    parser.add_argument("--csv", metavar="FILE", help="write every sample to FILE")
    parser.add_argument("--keep", action="store_true", help="leave the wave playing afterwards")
    args = parser.parse_args(argv)

    wave = None if args.wave == "none" else args.wave
    if wave is not None and not SCOPE_WAVE_HZ_MIN <= args.hz <= SCOPE_WAVE_HZ_MAX:
        parser.error(f"--hz {args.hz} is outside {SCOPE_WAVE_HZ_MIN}..{SCOPE_WAVE_HZ_MAX}")
    if not scope_capture_valid(args.n, args.rate):
        parser.error(
            f"--n {args.n} at --rate {args.rate}: the rate is "
            f"{SCOPE_RATE_HZ_MIN}..{SCOPE_RATE_HZ_MAX} Hz, n {SCOPE_N_MIN}..{SCOPE_N_MAX}, "
            f"and the burst at most {SCOPE_BURST_MS_MAX} ms"
        )

    with contextlib.ExitStack() as stack:
        try:
            shell = mcu()
            stack.callback(shell.close)
            link = SpiLink(transport())
            stack.callback(link.close)
        except (MCUError, OSError, ImportError) as err:
            print(
                f"unoq.scope: {err}\n"
                "Is the demo stopped (sudo systemctl stop unoq-cpu-bars: it holds "
                "/dev/ttyHS1), and is /dev/spidev0.0 there?",
                file=sys.stderr,
            )
            return 1
        try:
            cap, burst, played = run(shell, link, wave, args.hz, args.n, args.rate, args.keep)
        except (MCUError, OSError, LinkError, FrameError) as err:
            print(f"unoq.scope: {err}", file=sys.stderr)
            return 1

    print(report(stats(burst), cap, wave, args.hz, played))
    problems = disagreements(cap, burst)
    for p in problems:
        print(f"unoq.scope: {p}", file=sys.stderr)
    if args.csv:
        with open(args.csv, "w", newline="") as f:
            write_csv(f, burst)
        print(f"wrote {len(burst.samples)} samples to {args.csv}")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
