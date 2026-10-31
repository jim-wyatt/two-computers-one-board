# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""unoq.spilink: the SPI link's frames, its retries, its benchmark and its CLI.

No device is opened. Two fakes stand in for /dev/spidev0.0:

- FakeSpiDev replays recorded transactions byte for byte, for the tests that
  are about exactly what goes on the wire.
- FakeMCU is the slave's behavior in Python - answer each request one
  transaction later - with knobs to miss, damage or refuse transactions, for
  the tests that are about what SpiLink does when the link misbehaves.

The constants are checked against mcu/app/include/spi_proto.h itself, the
same way test_contract.py checks app_proto.h.
"""

from __future__ import annotations

import re
import struct
import sys
from collections.abc import Callable
from pathlib import Path
from types import SimpleNamespace
from typing import Any, ClassVar

import pytest

from unoq import spilink
from unoq.spilink import (
    ECHO,
    ERROR,
    MAX_PAYLOAD,
    NOP,
    RESPONSE,
    STAT,
    TEMPLOG,
    XFER_LEN,
    BenchRow,
    Frame,
    FrameError,
    LinkError,
    RemoteError,
    SpidevTransport,
    SpiLink,
    decode,
    encode,
    pad,
)

HEADER = Path(__file__).resolve().parents[2] / "mcu" / "app" / "include" / "spi_proto.h"

# --- the contract -----------------------------------------------------------

_DEFINE = re.compile(r"^#define\s+(SPI_PROTO_\w+)\s+(.+?)\s*$", re.MULTILINE)
_ARITHMETIC = re.compile(r"^[\w\s()+\-*/]+$")


def header_macros() -> dict[str, int]:
    """Every integer SPI_PROTO_ #define, expressions resolved in order."""
    text = HEADER.read_text().replace("\\\n", " ")
    found: dict[str, int] = {}
    for name, body in _DEFINE.findall(text):
        body = body.split("/*")[0].strip()
        if not _ARITHMETIC.match(body):  # pragma: no cover - a string macro
            continue
        expanded = re.sub(r"\b[A-Za-z_]\w*\b", lambda m: str(found.get(m.group(), "?")), body)
        # eval() on a string screened by _ARITHMETIC: numbers and operators.
        found[name] = int(eval(expanded.replace("/", "//")))
    return found


@pytest.fixture(scope="module")
def firmware() -> dict[str, int]:
    return header_macros()


@pytest.mark.parametrize(
    "name",
    [
        "XFER_LEN",
        "MAGIC",
        "HEADER_LEN",
        "CRC_LEN",
        "OVERHEAD",
        "MAX_PAYLOAD",
        "NOP",
        "ECHO",
        "TEMPLOG",
        "STAT",
        "RESPONSE",
        "ERROR",
        "ERROR_LEN",
        "ERR_MAGIC",
        "ERR_CRC",
        "ERR_LENGTH",
        "ERR_TYPE",
        "ERR_REQUEST",
        "ERR_RANGE",
        "ERR_UNAVAILABLE",
        "TEMPLOG_REQ_LEN",
        "TEMPLOG_SINCE",
        "TEMPLOG_HDR_LEN",
        "TEMPLOG_SAMPLE_LEN",
        "TEMPLOG_MAX",
        "STAT_COUNT",
        "STAT_LEN",
    ],
)
def test_constant_matches_the_firmware(firmware: dict[str, int], name: str) -> None:
    assert getattr(spilink, name) == firmware[f"SPI_PROTO_{name}"]


def test_every_firmware_constant_has_a_python_twin(firmware: dict[str, int]) -> None:
    missing = [n for n in firmware if not hasattr(spilink, n.removeprefix("SPI_PROTO_"))]
    assert not missing, f"spi_proto.h defines {missing}, which spilink.py does not"


def test_the_struct_formats_are_the_documented_sizes() -> None:
    assert struct.calcsize("<IIIIH") == spilink.TEMPLOG_HDR_LEN
    assert struct.calcsize("<IQiB") == spilink.TEMPLOG_SAMPLE_LEN
    assert struct.calcsize("<BI") == spilink.TEMPLOG_REQ_LEN
    assert struct.calcsize("<BBI") == spilink.ERROR_LEN


# --- frames -----------------------------------------------------------------

# Recorded from the firmware's own test (mcu/tests/spi_proto, the layout test):
# ECHO, seq 0x42, payload aa bb.
RECORDED_ECHO = bytes.fromhex("5551014202 00aabb34f9".replace(" ", ""))


def test_the_crc_is_ccitt_false() -> None:
    assert spilink.crc16(b"123456789") == 0x29B1
    assert spilink.crc16(b"") == 0xFFFF


def test_encode_matches_the_firmware_byte_for_byte() -> None:
    assert encode(ECHO, 0x42, b"\xaa\xbb") == RECORDED_ECHO
    assert decode(RECORDED_ECHO) == Frame(ECHO, 0x42, b"\xaa\xbb")


@pytest.mark.parametrize("size", [0, 1, 255, MAX_PAYLOAD])
def test_frames_round_trip_padded(size: int) -> None:
    payload = bytes(i & 0xFF for i in range(size))
    wire = pad(encode(TEMPLOG, 7, payload))
    assert len(wire) == XFER_LEN
    assert decode(wire) == Frame(TEMPLOG, 7, payload)


def test_encode_refuses_more_than_a_transaction() -> None:
    with pytest.raises(ValueError, match="at most"):
        encode(ECHO, 1, bytes(MAX_PAYLOAD + 1))


@pytest.mark.parametrize(
    ("wire", "why"),
    [
        (b"UQ\x00", "shorter"),
        (bytes(XFER_LEN), "magic"),
        (b"\xff" * XFER_LEN, "magic"),
        (RECORDED_ECHO[:-1], "length"),
        (RECORDED_ECHO[:4] + b"\xff\xff" + RECORDED_ECHO[6:], "length"),
        (RECORDED_ECHO[:6] + b"\xab" + RECORDED_ECHO[7:], "CRC"),
    ],
)
def test_decode_refuses_what_is_not_a_frame(wire: bytes, why: str) -> None:
    with pytest.raises(FrameError, match=why):
        decode(wire)


def test_templog_answer_decodes() -> None:
    payload = struct.pack("<IIIIH", 12, 4, 10, 3, 2)
    payload += struct.pack("<IQiB", 11, 11000, 21011, 1)
    payload += struct.pack("<IQiB", 12, 12000, -5, 0)
    batch = spilink.decode_templog(payload)
    assert (batch.head, batch.gap_first, batch.gap_last, batch.more) == (12, 4, 10, 3)
    assert batch.samples == (
        spilink.Sample(11, 11000, 21011, True),
        spilink.Sample(12, 12000, -5, False),
    )


def test_templog_answer_of_the_wrong_size_is_refused() -> None:
    with pytest.raises(FrameError, match="for 1 samples"):
        spilink.decode_templog(struct.pack("<IIIIH", 0, 0, 0, 0, 1))


def test_stat_answer_of_the_wrong_size_is_refused() -> None:
    with pytest.raises(FrameError, match="STAT"):
        spilink.decode_stat(b"\x00" * 15)


def test_templog_request_says_whether_since_is_given() -> None:
    assert spilink.templog_request(None) == b"\x00\x00\x00\x00\x00"
    assert spilink.templog_request(258) == b"\x01\x02\x01\x00\x00"


def test_a_remote_error_names_its_code() -> None:
    assert "since is past" in str(RemoteError(spilink.ERR_RANGE, TEMPLOG, 3))
    assert "error 99" in str(RemoteError(99, TEMPLOG, 0))


# --- the fakes --------------------------------------------------------------


class FakeSpiDev:
    """The spidev module's SpiDev, replaying recorded transactions."""

    replies: ClassVar[list[bytes]] = []

    def __init__(self) -> None:
        self.opened: tuple[int, int] | None = None
        self.mode = -1
        self.bits_per_word = -1
        self.max_speed_hz = -1
        self.sent: list[tuple[bytes, int]] = []
        self.closed = False

    def open(self, bus: int, cs: int) -> None:
        self.opened = (bus, cs)

    def xfer2(self, data: list[int], speed_hz: int) -> list[int]:
        self.sent.append((bytes(data), speed_hz))
        return list(self.replies.pop(0))

    def close(self) -> None:
        self.closed = True


FAKE_SPIDEV = SimpleNamespace(SpiDev=FakeSpiDev)


class FakeMCU:
    """spi_link.c and spi_proto.c in miniature: each transaction carries the
    answer to the one before.

    miss:    transaction numbers (from 0) the slave was not listening for. It
             sends nothing useful and keeps its pending answer.
    corrupt: transaction numbers whose request arrives damaged.
    refuse:  a request type answered with this error code instead.
    """

    def __init__(
        self,
        miss: set[int] | None = None,
        corrupt: set[int] | None = None,
        refuse: dict[int, int] | None = None,
        echo_wrong: bool = False,
    ) -> None:
        self.pending = encode(NOP | RESPONSE, 0)
        self.n = 0
        self.miss = miss or set()
        self.corrupt = corrupt or set()
        self.refuse = refuse or {}
        self.echo_wrong = echo_wrong
        self.speeds: list[int] = []
        self.stat = [0, 0, 0, 0]
        self.closed = False
        self.templog_payload = b""

    def answer(self, rx: bytes) -> bytes:
        try:
            req = decode(rx)
        except FrameError:
            self.stat[2] += 1
            return encode(ERROR, 0, struct.pack("<BBI", spilink.ERR_MAGIC, 0, 0))
        self.stat[1] += 1
        if req.type in self.refuse:
            return encode(ERROR, req.seq, struct.pack("<BBI", self.refuse[req.type], req.type, 0))
        if req.type == STAT:
            return encode(STAT | RESPONSE, req.seq, struct.pack("<IIII", *self.stat))
        if req.type == TEMPLOG:
            return encode(TEMPLOG | RESPONSE, req.seq, self.templog_payload)
        payload = req.payload[::-1] if self.echo_wrong and req.type == ECHO else req.payload
        return encode(req.type | RESPONSE, req.seq, payload)

    def xfer(self, data: bytes, speed_hz: int) -> bytes:
        assert len(data) == XFER_LEN, "every transaction is exactly XFER_LEN"
        n = self.n
        self.n += 1
        self.speeds.append(speed_hz)
        self.stat[0] += 1
        if n in self.miss:
            self.stat[3] += 1
            return b"\x00" * XFER_LEN
        up = pad(self.pending)
        if n in self.corrupt:
            data = data[:6] + bytes([data[6] ^ 1]) + data[7:]
        self.pending = self.answer(data)
        return up

    def close(self) -> None:
        self.closed = True


def link(mcu: Any, **kw: Any) -> SpiLink:
    return SpiLink(mcu, gap_s=0, **kw)


# --- SpidevTransport --------------------------------------------------------


def test_spidev_transport_opens_mode_0_and_replays() -> None:
    FakeSpiDev.replies = [RECORDED_ECHO]
    t = SpidevTransport(module=FAKE_SPIDEV)
    dev = t._dev
    assert dev.opened == (0, 0)
    assert (dev.mode, dev.bits_per_word) == (0, 8)
    assert t.xfer(b"\x01\x02", 4_000_000) == RECORDED_ECHO
    assert dev.sent == [(b"\x01\x02", 4_000_000)]
    t.close()
    assert dev.closed


def test_spidev_transport_imports_spidev_by_default(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setitem(sys.modules, "spidev", FAKE_SPIDEV)
    assert SpidevTransport()._dev.opened == (0, 0)


def test_a_request_over_recorded_transactions() -> None:
    """The exact bytes of one request: the request, then a NOP collecting it."""
    FakeSpiDev.replies = [pad(encode(NOP | RESPONSE, 0)), pad(encode(ECHO | RESPONSE, 1, b"hi"))]
    t = SpidevTransport(module=FAKE_SPIDEV)
    slept: list[float] = []
    lk = SpiLink(t, speed_hz=2_000_000, gap_s=0.001, sleep=slept.append)
    assert lk.echo(b"hi") == b"hi"
    assert t._dev.sent == [
        (pad(encode(ECHO, 1, b"hi")), 2_000_000),
        (pad(encode(NOP, 1)), 2_000_000),
    ]
    assert slept == [0.001, 0.001]


# --- SpiLink ----------------------------------------------------------------


def test_seq_runs_1_to_255_and_never_0() -> None:
    lk = link(FakeMCU())
    seqs = [lk.next_seq() for _ in range(256)]
    assert seqs[0] == 1
    assert seqs[254] == 255
    assert seqs[255] == 1
    assert 0 not in seqs


def test_the_services() -> None:
    mcu = FakeMCU()
    mcu.templog_payload = struct.pack("<IIIIH", 1, 0, 0, 0, 1) + struct.pack("<IQiB", 1, 9, 8, 1)
    lk = link(mcu)
    assert lk.echo(b"abc") == b"abc"
    assert lk.request(NOP).type == NOP | RESPONSE
    assert lk.templog(0).samples == (spilink.Sample(1, 9, 8, True),)
    st = lk.stat()
    assert st.transactions == 7  # two per request, and this one's first half
    assert (st.requests, st.bad_frames, st.spi_errors) == (7, 0, 0)
    assert (lk.polls, lk.resends) == (4, 0)
    lk.close()
    assert mcu.closed


def test_a_missed_poll_is_polled_again() -> None:
    lk = link(FakeMCU(miss={1}))
    assert lk.echo(b"x") == b"x"
    assert (lk.polls, lk.resends) == (2, 0)


def test_a_missed_request_is_sent_again() -> None:
    lk = link(FakeMCU(miss={0}))
    assert lk.echo(b"x") == b"x"
    assert lk.resends == 1


def test_a_damaged_request_is_sent_again() -> None:
    lk = link(FakeMCU(corrupt={0}))
    assert lk.echo(b"x") == b"x"
    assert lk.resends == 1


def test_a_stale_answer_is_skipped() -> None:
    mcu = FakeMCU()
    mcu.pending = encode(ECHO | RESPONSE, 9, b"old")
    lk = link(mcu, retries=1)
    # The first transaction brings up "old", which is ignored as the request's
    # reply; the poll brings the real one.
    assert lk.echo(b"new") == b"new"
    # And one whose seq is wrong at poll time: miss the request, so the poll
    # brings up the NOP answer from before it.
    mcu2 = FakeMCU(miss={0})
    mcu2.pending = encode(ECHO | RESPONSE, 77, b"older")
    lk2 = link(mcu2)
    assert lk2.echo(b"z") == b"z"


def test_a_refusal_is_raised() -> None:
    lk = link(FakeMCU(refuse={TEMPLOG: spilink.ERR_RANGE}))
    with pytest.raises(RemoteError) as info:
        lk.templog(99)
    assert (info.value.code, info.value.req_type) == (spilink.ERR_RANGE, TEMPLOG)


def test_a_transient_error_is_not_raised_but_resent() -> None:
    lk = link(FakeMCU(refuse={ECHO: spilink.ERR_CRC}), retries=2)
    with pytest.raises(LinkError, match="after 2 tries") as info:
        lk.echo(b"x")
    assert not isinstance(info.value, RemoteError)
    assert lk.resends == 2


def test_an_error_about_another_request_is_not_raised() -> None:
    """An error frame with our seq but another type, or a short payload, is
    not this request's refusal: resend."""
    mcu = FakeMCU()
    lk = link(mcu, retries=2)
    real = mcu.answer
    seq_type = iter(
        [
            encode(ERROR, 1, struct.pack("<BBI", spilink.ERR_TYPE, STAT, 0)),
            encode(ERROR, 1, b"\x04"),
        ]
    )

    def odd(rx: bytes) -> bytes:
        f = decode(rx)
        return next(seq_type, None) or real(rx) if f.type == ECHO else real(rx)

    mcu.answer = odd  # type: ignore[method-assign]
    with pytest.raises(LinkError):
        lk.echo(b"x")


def test_nothing_ever_answering_gives_up() -> None:
    lk = link(FakeMCU(miss=set(range(100))), retries=3)
    with pytest.raises(LinkError, match="after 3 tries"):
        lk.stat()
    assert lk.polls == 3


# --- the benchmark ----------------------------------------------------------


def ticking(step: float) -> Callable[[], float]:
    t = [0.0]

    def clock() -> float:
        t[0] += step
        return t[0]

    return clock


def test_bench_counts_verified_echoes_and_the_mcus_errors() -> None:
    mcu = FakeMCU(miss={5})
    lk = link(mcu)
    row = spilink.bench_rate(lk, 2_000_000, seconds=1.0, payload_len=100, clock=ticking(0.1))
    assert mcu.speeds[-1] == 2_000_000
    # The first answer belongs to the stat before the run, and is not counted.
    assert row.transactions == row.good + row.bad + 1
    # The missed transaction loses two answers: its own, which comes up as
    # zeros, and the next, which brings up the answer it should have had.
    assert row.bad == 2
    assert row.good > 0
    assert row.spi_errors == 1
    assert row.bytes_per_s == pytest.approx(row.good * 100 / row.seconds)


def test_bench_notices_an_echo_that_came_back_different() -> None:
    lk = link(FakeMCU(echo_wrong=True))
    row = spilink.bench_rate(lk, 1_000_000, seconds=0.5, payload_len=10, clock=ticking(0.1))
    assert row.good == 0
    assert row.bad == row.transactions - 1


def test_bench_without_stat_still_measures() -> None:
    lk = link(FakeMCU(refuse={STAT: spilink.ERR_UNAVAILABLE}))
    lk.stat = lambda: (_ for _ in ()).throw(LinkError("no"))  # type: ignore[method-assign]
    rows = spilink.bench(lk, [500_000], seconds=0.3, payload_len=4, clock=ticking(0.1))
    assert rows[0].spi_errors is None
    assert rows[0].good > 0


def test_bench_over_every_rate() -> None:
    lk = link(FakeMCU())
    rows = spilink.bench(lk, seconds=0.2, payload_len=8, clock=ticking(0.1))
    assert [r.speed_hz for r in rows] == list(spilink.BENCH_RATES)


def test_a_row_with_no_time_has_no_rate() -> None:
    assert BenchRow(1, 0, 0, 0, 0.0, 10, None).bytes_per_s == 0.0


def test_the_table() -> None:
    rows = [
        BenchRow(500_000, 10, 9, 0, 1.0, 1000, 0),
        BenchRow(8_000_000, 10, 5, 4, 1.0, 1000, None),
    ]
    text = spilink.format_bench(rows)
    assert "500 kHz" in text
    assert "8 MHz" in text
    assert "9.0" in text  # KB/s
    assert "0.8" in text  # 9000 / 11520
    assert "11.5 KB/s" in text
    assert text.splitlines()[2].split()[5] == "-"


def test_rates_parse() -> None:
    assert spilink._rates("1e6,500000,") == [1_000_000, 500_000]


# --- the command line -------------------------------------------------------


def run(argv: list[str], mcu: FakeMCU, capsys: pytest.CaptureFixture[str]) -> tuple[int, str]:
    rc = spilink.main(["--gap-us", "0", *argv], transport=lambda: mcu)
    out, err = capsys.readouterr()
    assert mcu.closed
    return rc, out + err


def test_cli_echo(capsys: pytest.CaptureFixture[str]) -> None:
    rc, out = run(["echo", "hello"], FakeMCU(), capsys)
    assert (rc, out) == (0, "hello\n")


def test_cli_stat(capsys: pytest.CaptureFixture[str]) -> None:
    rc, out = run(["stat"], FakeMCU(), capsys)
    assert rc == 0
    assert out.startswith("transactions=1 requests=1")


def test_cli_templog(capsys: pytest.CaptureFixture[str]) -> None:
    mcu = FakeMCU()
    mcu.templog_payload = (
        struct.pack("<IIIIH", 12, 4, 10, 0, 2)
        + struct.pack("<IQiB", 11, 11000, 21011, 1)
        + struct.pack("<IQiB", 12, 12000, -5, 0)
    )
    rc, out = run(["templog", "--since", "3"], mcu, capsys)
    assert rc == 0
    assert out.splitlines() == [
        "gap first=4 last=10",
        "seq=11 ms=11000 temp_mc=21011",
        "seq=12 ms=12000 temp_err=-5",
        "end head=12 more=0",
    ]


def test_cli_templog_without_a_gap(capsys: pytest.CaptureFixture[str]) -> None:
    mcu = FakeMCU()
    mcu.templog_payload = struct.pack("<IIIIH", 0, 0, 0, 0, 0)
    rc, out = run(["templog"], mcu, capsys)
    assert (rc, out) == (0, "end head=0 more=0\n")


def test_cli_bench(capsys: pytest.CaptureFixture[str]) -> None:
    # The real clock, for a twentieth of a second: the fake answers at once.
    rc, out = run(
        ["bench", "--rates", "1000000", "--seconds", "0.05", "--size", "16"], FakeMCU(), capsys
    )
    assert rc == 0
    assert "1 MHz" in out


def test_cli_bench_refuses_an_oversize_payload(capsys: pytest.CaptureFixture[str]) -> None:
    with pytest.raises(SystemExit):
        spilink.main(["bench", "--size", str(MAX_PAYLOAD + 1)], transport=FakeMCU)
    assert "--size" in capsys.readouterr().err


def test_cli_reports_a_link_error(capsys: pytest.CaptureFixture[str]) -> None:
    rc, out = run(["templog", "--since", "9"], FakeMCU(refuse={TEMPLOG: spilink.ERR_RANGE}), capsys)
    assert rc == 1
    assert "spilink: MCU refused" in out
