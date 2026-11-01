# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""unoq.scope and MCU.scope_*: the oscilloscope's Linux half, with no board.

The shell is a FakeShell that answers as `app scope` would; the SPI link is
test_spilink's FakeMCU, which answers SCOPE as spi_proto.c does. The bursts
are made here: a sine, a triangle and a flat line, at known frequencies, so
the estimate can be checked against what it should find. MCU.scope_*'s own
parsing is tested against the firmware's formats in test_contract.py; here
are its refusals.
"""

from __future__ import annotations

import io
import math
from pathlib import Path
from typing import Any

import pytest
from test_spilink import FakeMCU

from unoq import mcu, scope
from unoq.mcu import MCUError, ScopeCapture
from unoq.spilink import Burst, SpiLink

RATE = 100_000


def sine(hz: float, n: int = 4096, rate: int = RATE) -> tuple[int, ...]:
    return tuple(round(8192 + 6552 * math.sin(2 * math.pi * hz * i / rate)) for i in range(n))


def summary(samples: tuple[int, ...], id_: int = 5) -> ScopeCapture:
    return ScopeCapture(
        id_, len(samples), float(RATE), min(samples), max(samples), sum(samples) // len(samples)
    )


class FakeShell:
    """MCU's `app scope` methods, recording what was asked."""

    def __init__(self, samples: tuple[int, ...], spi: FakeMCU, fail: str | None = None) -> None:
        self.samples = samples
        self.spi = spi
        self.fail = fail
        self.calls: list[str] = []
        self.closed = False

    def scope_gen(self, wave: str, hz: int) -> float:
        self.calls.append(f"gen {wave} {hz}")
        return hz + 0.001

    def scope_capture(self, n: int, rate_hz: int) -> ScopeCapture:
        self.calls.append(f"capture {n} {rate_hz}")
        if self.fail == "capture":
            raise MCUError("capture failed (-116)")
        self.spi.scope = (5, rate_hz * 1000, self.samples)
        return summary(self.samples)

    def scope_off(self) -> None:
        self.calls.append("off")

    def close(self) -> None:
        self.closed = True


# --- the arithmetic ---------------------------------------------------------


@pytest.mark.parametrize("hz", [50, 1000, 4321, 20_000])
def test_the_frequency_of_a_sine_is_found(hz: int) -> None:
    assert scope.estimate_freq(sine(hz), RATE) == pytest.approx(hz, rel=0.01)


def test_the_frequency_of_a_triangle_is_found() -> None:
    period = 80  # samples: 1250 Hz at 100 kHz
    tri = tuple(abs((i % period) - period // 2) * 400 for i in range(4096))
    assert scope.estimate_freq(tri, RATE) == pytest.approx(1250, rel=0.01)


def test_noise_near_the_middle_is_not_a_crossing() -> None:
    """A square wave with a wobble on each level: one crossing a period."""
    period = 100
    sq = tuple(
        (12000 if (i % period) < period // 2 else 4000) + (40 if i % 2 else -40)
        for i in range(4000)
    )
    assert scope.estimate_freq(sq, RATE) == pytest.approx(1000, rel=0.01)


@pytest.mark.parametrize(
    ("samples", "rate"),
    [
        ((), RATE),  # nothing
        ((8000, 8010, 8005) * 100, RATE),  # no swing: noise
        (sine(10, 4096), RATE),  # under half a period: one crossing at most
        (sine(1000), 0),  # no rate
    ],
)
def test_no_frequency_is_claimed_without_two_periods_of_signal(
    samples: tuple[int, ...], rate: int
) -> None:
    assert scope.estimate_freq(samples, rate) is None


def test_stats_of_a_burst() -> None:
    s = scope.stats(Burst(1, 1000.0, (0, 16383, 8191, 8192)))
    assert (s.n, s.min, s.max, s.mean, s.seconds) == (4, 0, 16383, 8191.5, 0.004)
    assert s.freq_hz is None
    assert scope.stats(Burst(1, 1000.0, ())) == scope.Stats(0, 0, 0, 0.0, 0.0, None)


def test_volts_are_against_the_assumed_reference() -> None:
    assert scope.volts(0) == 0
    assert scope.volts(mcu.SCOPE_ADC_MAX) == pytest.approx(scope.VREF_V)


def test_the_two_links_agree_or_say_where_they_do_not() -> None:
    s = sine(1000)
    assert scope.disagreements(summary(s), Burst(5, RATE, s)) == []
    assert scope.disagreements(summary(s), Burst(6, RATE, s)) == [
        "SPI sent capture 6, the shell took 5"
    ]
    assert scope.disagreements(summary(s), Burst(5, RATE, s[:-1])) == [
        "SPI sent 4095 samples, the shell took 4096"
    ]
    (only,) = scope.disagreements(summary(s), Burst(5, RATE, (0, *s[1:])))
    assert only.startswith("SPI's samples give")


def test_the_csv_has_a_row_a_sample() -> None:
    out = io.StringIO()
    scope.write_csv(out, Burst(1, 1000.0, (0, 16383)))
    assert out.getvalue().splitlines() == [
        "index,t_s,code,volts",
        "0,0.000000000,0,0.0000",
        "1,0.001000000,16383,3.3000",
    ]


# --- run() ------------------------------------------------------------------


def link(spi: FakeMCU) -> SpiLink:
    return SpiLink(spi, gap_s=0)


def test_run_plays_captures_reads_and_stops_what_it_started() -> None:
    spi = FakeMCU()
    shell = FakeShell(sine(1000), spi)
    cap, burst, played = scope.run(shell, link(spi), "sine", 1000, 4096, RATE, keep=False)
    assert shell.calls == ["gen sine 1000", f"capture 4096 {RATE}", "off"]
    assert burst.samples == shell.samples
    assert (cap.id, played) == (5, 1000.001)


def test_run_keeps_the_wave_if_asked_and_leaves_a0_alone_without_one() -> None:
    spi = FakeMCU()
    shell = FakeShell(sine(1000), spi)
    scope.run(shell, link(spi), "triangle", 50, 4096, RATE, keep=True)
    assert "off" not in shell.calls
    shell.calls.clear()
    _, _, played = scope.run(shell, link(spi), None, 50, 4096, RATE, keep=False)
    assert shell.calls == [f"capture 4096 {RATE}"]
    assert played is None


def test_run_stops_the_wave_when_the_capture_fails() -> None:
    spi = FakeMCU()
    shell = FakeShell(sine(1000), spi, fail="capture")
    with pytest.raises(MCUError):
        scope.run(shell, link(spi), "sine", 1000, 4096, RATE, keep=False)
    assert shell.calls[-1] == "off"


# --- main() -----------------------------------------------------------------


def main(argv: list[str], shell: FakeShell, spi: FakeMCU) -> int:
    return scope.main(["--rate", str(RATE), *argv], mcu=lambda: shell, transport=lambda: spi)


def test_main_prints_the_stats(capsys: pytest.CaptureFixture[str]) -> None:
    spi = FakeMCU()
    shell = FakeShell(sine(1000), spi)
    assert main([], shell, spi) == 0
    out = capsys.readouterr().out
    assert "wave sine at 1000 Hz asked, 1000.001 Hz played (TIM7)" in out
    assert "expect about 1640..14744" in out
    assert f"capture 5: 4096 samples at {RATE}.000 Hz, 40.960 ms" in out
    assert "frequency about 1000." in out
    assert "assumed 3.3 V" in out
    assert shell.closed
    assert spi.closed


def test_main_with_no_wave_and_no_signal(capsys: pytest.CaptureFixture[str]) -> None:
    spi = FakeMCU()
    shell = FakeShell((8000,) * 4096, spi)
    assert main(["--wave", "none"], shell, spi) == 0
    out = capsys.readouterr().out
    assert "no wave played: this is whatever is on A0" in out
    assert "frequency: none found" in out
    assert shell.calls == [f"capture 4096 {RATE}"]


def test_main_writes_the_csv(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    spi = FakeMCU()
    shell = FakeShell(sine(1000, 100), spi)
    path = tmp_path / "burst.csv"
    assert main(["--n", "100", "--csv", str(path)], shell, spi) == 0
    assert len(path.read_text().splitlines()) == 101
    assert f"wrote 100 samples to {path}" in capsys.readouterr().out


def test_main_fails_when_the_links_disagree(capsys: pytest.CaptureFixture[str]) -> None:
    spi = FakeMCU()
    shell = FakeShell(sine(1000), spi)
    real = shell.scope_capture

    def lying(n: int, rate_hz: int) -> ScopeCapture:
        cap = real(n, rate_hz)
        return ScopeCapture(cap.id, cap.n, cap.rate_hz, cap.min, cap.max, cap.mean + 1)

    shell.scope_capture = lying  # type: ignore[method-assign]
    assert main([], shell, spi) == 1
    assert "unoq.scope: SPI's samples give" in capsys.readouterr().err


def test_main_reports_a_failed_run(capsys: pytest.CaptureFixture[str]) -> None:
    spi = FakeMCU()
    shell = FakeShell(sine(1000), spi, fail="capture")
    assert main([], shell, spi) == 1
    assert "unoq.scope: capture failed" in capsys.readouterr().err
    assert shell.closed
    assert spi.closed


def test_main_reports_a_port_it_cannot_open(capsys: pytest.CaptureFixture[str]) -> None:
    def busy() -> FakeShell:
        raise MCUError("/dev/ttyHS1 is busy")

    assert scope.main([], mcu=busy, transport=FakeMCU) == 1
    assert "stop unoq-cpu-bars" in capsys.readouterr().err

    def spi_missing() -> FakeMCU:
        raise ImportError("No module named 'spidev'")

    shell = FakeShell(sine(1000), FakeMCU())
    assert scope.main([], mcu=lambda: shell, transport=spi_missing) == 1
    assert "spidev" in capsys.readouterr().err
    assert shell.closed, "the serial port is let go even when SPI cannot open"


@pytest.mark.parametrize(
    ("argv", "why"),
    [
        (["--hz", "0"], "--hz 0"),
        (["--hz", "10001"], "--hz 10001"),
        (["--n", "4096", "--rate", "100"], "at most 500 ms"),
        (["--rate", "300000"], "--rate 300000"),
    ],
)
def test_main_refuses_what_the_firmware_would(
    argv: list[str], why: str, capsys: pytest.CaptureFixture[str]
) -> None:
    with pytest.raises(SystemExit):
        scope.main(argv, mcu=lambda: FakeShell((), FakeMCU()), transport=FakeMCU)
    assert why in capsys.readouterr().err


def test_main_takes_any_hz_with_no_wave(capsys: pytest.CaptureFixture[str]) -> None:
    spi = FakeMCU()
    shell = FakeShell(sine(1000), spi)
    assert main(["--wave", "none", "--hz", "0"], shell, spi) == 0


# --- MCU.scope_* refusals ---------------------------------------------------


def test_the_mcu_checks_its_arguments_before_sending(mcu_factory: Any) -> None:
    board = mcu_factory({})
    with pytest.raises(ValueError, match="wave 'square'"):
        board.scope_gen("square", 100)
    with pytest.raises(ValueError, match="hz 0"):
        board.scope_gen("sine", 0)
    with pytest.raises(ValueError, match="at most 500 ms"):
        board.scope_capture(4096, 100)


@pytest.mark.parametrize(
    ("call", "command", "reply"),
    [
        (lambda b: b.scope_gen("sine", 10), "app scope gen sine 10", ["ok"]),
        (
            lambda b: b.scope_gen("sine", 10),
            "app scope gen sine 10",
            ["ok scope gen wave=sine hz=11 actual_hz=11.000"],
        ),
        (lambda b: b.scope_capture(16, 1000), "app scope capture 16 1000", []),
        (
            lambda b: b.scope_capture(16, 1000),
            "app scope capture 16 1000",
            ["ok scope capture id=1 n=17 rate_hz=1000.000 min=0 max=0 mean=0"],
        ),
        (lambda b: b.scope_stat(), "app scope stat", ["scope?"]),
        (lambda b: b.scope_off(), "app scope off", []),
    ],
)
def test_a_reply_that_does_not_parse_is_an_error(
    mcu_factory: Any, call: Any, command: str, reply: list[str]
) -> None:
    with pytest.raises(MCUError, match="could not parse"):
        call(mcu_factory({command: reply}))


def test_a_firmware_without_the_scope_says_so(mcu_factory: Any) -> None:
    board = mcu_factory({"app scope stat": ["Subcommands:", "  status"]})
    with pytest.raises(MCUError, match="predates it"):
        board.scope_stat()
