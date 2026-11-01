# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""
Talk to the MCU over the SPI link: /dev/spidev0.0 on this side, spi3 on its.

    python -m unoq.spilink bench                 # bytes per second, per clock
    python -m unoq.spilink echo hello
    python -m unoq.spilink templog --since 120
    python -m unoq.spilink stat
    python -m unoq.spilink scope                 # the last `app scope capture`

The serial line carries the shell, the panel and firmware updates at 115200
baud, about 11 KB/s. Four other pins were always wired to the MCU as well
(docs/reference/hardware.md has the experiment), and this module, with
the firmware's spi_link.c, is the protocol that puts them to use.

Linux is the master and the MCU the slave, so the MCU cannot speak first. Each
transaction is exactly XFER_LEN bytes both ways: a request goes down while the
answer to the previous one comes up. SpiLink.request() therefore costs two
transactions, the request and a NOP that collects its answer, and bench()
pipelines instead: every transaction carries a new ECHO down and the last one's
answer up. The frame - magic, type, seq, length, payload, CRC16 - is described
in mcu/app/include/spi_proto.h, and tests/test_spilink.py checks the numbers
below against that header.

The transport is injectable. SpidevTransport is the real one and is the only
code here that opens a device; the tests hand SpiLink a fake.
"""

from __future__ import annotations

import argparse
import binascii
import importlib
import struct
import sys
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from typing import Any, Protocol

# --- the contract: mcu/app/include/spi_proto.h ------------------------------

XFER_LEN = 1024
MAGIC = 0x5155
HEADER_LEN = 6
CRC_LEN = 2
OVERHEAD = HEADER_LEN + CRC_LEN
MAX_PAYLOAD = XFER_LEN - OVERHEAD

NOP = 0x00
ECHO = 0x01
TEMPLOG = 0x02
STAT = 0x03
SCOPE = 0x04
RESPONSE = 0x80
ERROR = 0x7F
ERROR_LEN = 6

ERR_MAGIC = 1
ERR_CRC = 2
ERR_LENGTH = 3
ERR_TYPE = 4
ERR_REQUEST = 5
ERR_RANGE = 6
ERR_UNAVAILABLE = 7
ERR_STALE = 8

TEMPLOG_REQ_LEN = 5
TEMPLOG_SINCE = 0x01
TEMPLOG_HDR_LEN = 18
TEMPLOG_SAMPLE_LEN = 17
TEMPLOG_MAX = (MAX_PAYLOAD - TEMPLOG_HDR_LEN) // TEMPLOG_SAMPLE_LEN

STAT_COUNT = 4
STAT_LEN = STAT_COUNT * 4

SCOPE_REQ_LEN = 6
SCOPE_HDR_LEN = 14
SCOPE_SAMPLE_LEN = 2
SCOPE_MAX = (MAX_PAYLOAD - SCOPE_HDR_LEN) // SCOPE_SAMPLE_LEN

# --- this side --------------------------------------------------------------

BUS = 0
CHIP_SELECT = 0  # /dev/spidev0.0
DEFAULT_SPEED_HZ = 1_000_000
# How long to leave the MCU between transactions. It has to decode one request
# and build the next answer before Linux clocks again; a transaction that
# starts sooner is missed and retried, which costs more than the wait.
DEFAULT_GAP_S = 0.0005
DEFAULT_RETRIES = 4
BENCH_RATES = (500_000, 1_000_000, 2_000_000, 4_000_000, 8_000_000, 16_000_000)
BENCH_SECONDS = 2.0
# 115200 baud, 8N1: ten bit times a byte.
UART_BYTES_PER_S = 115200 // 10

_ERROR_NAMES = {
    ERR_MAGIC: "no frame",
    ERR_CRC: "bad CRC",
    ERR_LENGTH: "bad length",
    ERR_TYPE: "unknown request type",
    ERR_REQUEST: "wrong payload for this request",
    ERR_RANGE: "out of range (TEMPLOG: since is past the newest sample; SCOPE: offset past n)",
    ERR_UNAVAILABLE: "service unavailable",
    ERR_STALE: "a newer capture replaced the one asked for",
}
# Errors that say the request was damaged on the way, not that it was wrong:
# sending it again is the answer.
_TRANSIENT = frozenset({ERR_MAGIC, ERR_CRC, ERR_LENGTH})


class FrameError(ValueError):
    """Bytes that are not a frame: wrong magic, impossible length, or bad CRC."""


class LinkError(RuntimeError):
    """No answer came back, after every retry."""


class RemoteError(LinkError):
    """The MCU answered, and its answer was an error frame."""

    def __init__(self, code: int, req_type: int, detail: int) -> None:
        self.code = code
        self.req_type = req_type
        self.detail = detail
        name = _ERROR_NAMES.get(code, f"error {code}")
        super().__init__(f"MCU refused request 0x{req_type:02x}: {name} (detail {detail})")


@dataclass(frozen=True)
class Frame:
    type: int
    seq: int
    payload: bytes


@dataclass(frozen=True)
class Sample:
    seq: int
    ms: int
    value: int  # millidegrees if ok, else the negative errno
    ok: bool


@dataclass(frozen=True)
class TempBatch:
    head: int
    gap_first: int  # 0: no gap
    gap_last: int
    more: int
    samples: tuple[Sample, ...]


@dataclass(frozen=True)
class Stat:
    transactions: int
    requests: int
    bad_frames: int
    spi_errors: int


@dataclass(frozen=True)
class ScopeChunk:
    """One SCOPE answer: part of a capture."""

    id: int
    rate_mhz: int
    n: int
    offset: int
    samples: tuple[int, ...]


@dataclass(frozen=True)
class Burst:
    """A whole capture, as `app scope capture` took it: 14-bit ADC codes, one
    every 1 / rate_hz seconds."""

    id: int
    rate_hz: float
    samples: tuple[int, ...]


def crc16(data: bytes) -> int:
    """CRC-16/CCITT-FALSE, the firmware's spi_proto_crc16()."""
    return binascii.crc_hqx(data, 0xFFFF)


def encode(type_: int, seq: int, payload: bytes = b"") -> bytes:
    """One frame, unpadded."""
    if len(payload) > MAX_PAYLOAD:
        raise ValueError(f"payload is {len(payload)} bytes, at most {MAX_PAYLOAD} fit")
    head = struct.pack("<HBBH", MAGIC, type_, seq, len(payload)) + payload
    return head + struct.pack("<H", crc16(head))


def decode(buf: bytes) -> Frame:
    """The frame at the start of a transaction; whatever follows it is padding."""
    if len(buf) < HEADER_LEN:
        raise FrameError("shorter than a header")
    magic, type_, seq, length = struct.unpack_from("<HBBH", buf)
    if magic != MAGIC:
        raise FrameError(f"magic 0x{magic:04x}, not 0x{MAGIC:04x}")
    if length > MAX_PAYLOAD or OVERHEAD + length > len(buf):
        raise FrameError(f"length {length} does not fit")
    (crc,) = struct.unpack_from("<H", buf, HEADER_LEN + length)
    if crc != crc16(buf[: HEADER_LEN + length]):
        raise FrameError("bad CRC")
    return Frame(type_, seq, bytes(buf[HEADER_LEN : HEADER_LEN + length]))


def pad(frame: bytes) -> bytes:
    """A frame as one whole transaction."""
    return frame + bytes(XFER_LEN - len(frame))


def templog_request(since: int | None) -> bytes:
    return struct.pack("<BI", 0 if since is None else TEMPLOG_SINCE, since or 0)


def decode_templog(payload: bytes) -> TempBatch:
    head, gap_first, gap_last, more, n = struct.unpack_from("<IIIIH", payload)
    if len(payload) != TEMPLOG_HDR_LEN + n * TEMPLOG_SAMPLE_LEN:
        raise FrameError(f"TEMPLOG answer is {len(payload)} bytes for {n} samples")
    samples = tuple(
        Sample(seq, ms, value, ok != 0)
        for seq, ms, value, ok in struct.iter_unpack("<IQiB", payload[TEMPLOG_HDR_LEN:])
    )
    return TempBatch(head, gap_first, gap_last, more, samples)


def decode_stat(payload: bytes) -> Stat:
    if len(payload) != STAT_LEN:
        raise FrameError(f"STAT answer is {len(payload)} bytes, not {STAT_LEN}")
    return Stat(*struct.unpack("<IIII", payload))


def scope_request(id_: int, offset: int) -> bytes:
    return struct.pack("<IH", id_, offset)


def decode_scope(payload: bytes) -> ScopeChunk:
    if len(payload) < SCOPE_HDR_LEN:
        raise FrameError(f"SCOPE answer is {len(payload)} bytes, shorter than its header")
    id_, rate_mhz, n, offset, count = struct.unpack_from("<IIHHH", payload)
    if len(payload) != SCOPE_HDR_LEN + count * SCOPE_SAMPLE_LEN:
        raise FrameError(f"SCOPE answer is {len(payload)} bytes for {count} samples")
    samples = struct.unpack_from(f"<{count}H", payload, SCOPE_HDR_LEN)
    return ScopeChunk(id_, rate_mhz, n, offset, samples)


# --- transports -------------------------------------------------------------


class Transport(Protocol):
    def xfer(self, data: bytes, speed_hz: int) -> bytes: ...

    def close(self) -> None: ...


class SpidevTransport:
    """/dev/spidev0.0 itself, through the spidev module from the [board] extra.

    Mode 0, 8 bits, chip select held for the whole transfer: what the firmware's
    spi_link.c configures spi3 to expect.
    """

    def __init__(self, bus: int = BUS, cs: int = CHIP_SELECT, module: Any = None) -> None:
        spidev = module if module is not None else importlib.import_module("spidev")
        self._dev = spidev.SpiDev()
        self._dev.open(bus, cs)
        self._dev.mode = 0
        self._dev.bits_per_word = 8
        self._dev.max_speed_hz = max(BENCH_RATES)

    def xfer(self, data: bytes, speed_hz: int) -> bytes:
        return bytes(self._dev.xfer2(list(data), speed_hz))

    def close(self) -> None:
        self._dev.close()


# --- the link ---------------------------------------------------------------


class SpiLink:
    """Requests and their answers, over a Transport."""

    def __init__(
        self,
        transport: Transport,
        speed_hz: int = DEFAULT_SPEED_HZ,
        gap_s: float = DEFAULT_GAP_S,
        retries: int = DEFAULT_RETRIES,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self.transport = transport
        self.speed_hz = speed_hz
        self.gap_s = gap_s
        self.retries = retries
        self._sleep = sleep
        self._seq = 0
        self.polls = 0  # NOPs sent to collect an answer
        self.resends = 0  # requests sent again

    def next_seq(self) -> int:
        """1..255, then round again. 0 is skipped: it is the seq of the
        answer the MCU holds before anything has asked it anything."""
        self._seq = self._seq % 255 + 1
        return self._seq

    def xfer(self, frame: bytes) -> bytes:
        """One whole transaction: frame down, padded; whatever was waiting, up."""
        if self.gap_s > 0:
            self._sleep(self.gap_s)
        return self.transport.xfer(pad(frame), self.speed_hz)

    def request(self, type_: int, payload: bytes = b"") -> Frame:
        """Send one request and return its answer.

        A transaction can be missed (the MCU was not yet listening), damaged
        (bad CRC), or answered late. Each of those is told apart by the seq and
        type of what comes back, and costs one more poll or one resend, up to
        `retries` of them.
        """
        seq = self.next_seq()
        req = encode(type_, seq, payload)
        poll = encode(NOP, seq)
        self.xfer(req)
        for _ in range(self.retries):
            self.polls += 1
            try:
                got = decode(self.xfer(poll))
            except FrameError:
                continue  # nothing heard: the MCU missed the poll; poll again
            if got.seq != seq:
                continue  # an older answer still going up
            if got.type == type_ | RESPONSE:
                return got
            if got.type == ERROR and len(got.payload) == ERROR_LEN:
                code, req_type, detail = struct.unpack("<BBI", got.payload)
                if code not in _TRANSIENT and req_type == type_:
                    raise RemoteError(code, req_type, detail)
            # Our poll was heard, so the request was not, or was damaged.
            self.resends += 1
            self.xfer(req)
        raise LinkError(f"no answer to request 0x{type_:02x} after {self.retries} tries")

    def echo(self, payload: bytes) -> bytes:
        return self.request(ECHO, payload).payload

    def stat(self) -> Stat:
        return decode_stat(self.request(STAT).payload)

    def templog(self, since: int | None = None) -> TempBatch:
        return decode_templog(self.request(TEMPLOG, templog_request(since)).payload)

    def scope_chunk(self, id_: int = 0, offset: int = 0) -> ScopeChunk:
        return decode_scope(self.request(SCOPE, scope_request(id_, offset)).payload)

    def scope_read(self, id_: int = 0) -> Burst:
        """A whole capture, in as many SCOPE answers as it takes.

        id_ 0 reads whichever capture the MCU holds; the first answer names
        it, and every later request asks for that one. A capture taken in the
        middle of the reading is a RemoteError (ERR_STALE), never a burst
        stitched from two.
        """
        first = self.scope_chunk(id_, 0)
        samples = list(first.samples)
        while len(samples) < first.n:
            chunk = self.scope_chunk(first.id, len(samples))
            if not chunk.samples or (chunk.id, chunk.n) != (first.id, first.n):
                raise FrameError(f"SCOPE at offset {len(samples)} of {first.n}: {chunk!r}")
            samples += chunk.samples
        return Burst(first.id, first.rate_mhz / 1000, tuple(samples))

    def close(self) -> None:
        self.transport.close()


# --- the benchmark ----------------------------------------------------------


@dataclass(frozen=True)
class BenchRow:
    speed_hz: int
    transactions: int
    good: int
    bad: int
    seconds: float
    payload_len: int
    spi_errors: int | None  # the MCU's count over the run; None if STAT failed

    @property
    def bytes_per_s(self) -> float:
        """Verified payload delivered per second, each way."""
        return self.good * self.payload_len / self.seconds if self.seconds > 0 else 0.0


def _payloads(n: int, size: int) -> list[bytes]:
    """Distinct, deterministic test patterns, so an answer can only match its
    own request, and no time is spent generating them inside the timed loop."""
    return [bytes((i * 31 + j * 7 + 1) & 0xFF for j in range(size)) for i in range(n)]


def _stat_or_none(link: SpiLink) -> Stat | None:
    try:
        return link.stat()
    except LinkError:
        return None


def bench_rate(
    link: SpiLink,
    speed_hz: int,
    seconds: float = BENCH_SECONDS,
    payload_len: int = MAX_PAYLOAD,
    clock: Callable[[], float] = time.monotonic,
) -> BenchRow:
    """Pipelined ECHO at one clock rate: every transaction carries a new
    request down and checks the answer to the last one coming up."""
    link.speed_hz = speed_hz
    patterns = _payloads(4, payload_len)
    before = _stat_or_none(link)
    sent: tuple[int, bytes] | None = None
    good = bad = transactions = 0
    start = clock()
    while clock() - start < seconds:
        seq = link.next_seq()
        payload = patterns[seq % len(patterns)]
        up = link.xfer(encode(ECHO, seq, payload))
        transactions += 1
        if sent is not None:
            try:
                got = decode(up)
                ok = got == Frame(ECHO | RESPONSE, sent[0], sent[1])
            except FrameError:
                ok = False
            good += ok
            bad += not ok
        sent = (seq, payload)
    elapsed = clock() - start
    after = _stat_or_none(link)
    errors = None if before is None or after is None else after.spi_errors - before.spi_errors
    return BenchRow(speed_hz, transactions, good, bad, elapsed, payload_len, errors)


def bench(
    link: SpiLink,
    rates: Sequence[int] = BENCH_RATES,
    seconds: float = BENCH_SECONDS,
    payload_len: int = MAX_PAYLOAD,
    clock: Callable[[], float] = time.monotonic,
) -> list[BenchRow]:
    return [bench_rate(link, r, seconds, payload_len, clock) for r in rates]


def _hz(speed_hz: int) -> str:
    if speed_hz >= 1_000_000 and speed_hz % 1_000_000 == 0:
        return f"{speed_hz // 1_000_000} MHz"
    return f"{speed_hz / 1000:g} kHz"


def format_bench(rows: Sequence[BenchRow]) -> str:
    lines = [
        f"{'clock':>10} {'xfers':>7} {'good':>7} {'bad':>5} {'MCU err':>7}"
        f" {'KB/s each way':>13} {'x UART':>7}",
    ]
    for r in rows:
        err = "-" if r.spi_errors is None else str(r.spi_errors)
        lines.append(
            f"{_hz(r.speed_hz):>10} {r.transactions:>7} {r.good:>7} {r.bad:>5} {err:>7}"
            f" {r.bytes_per_s / 1000:>13.1f} {r.bytes_per_s / UART_BYTES_PER_S:>7.1f}"
        )
    lines.append(
        f"UART for comparison: 115200 baud = {UART_BYTES_PER_S / 1000:.1f} KB/s, one way at a time"
    )
    return "\n".join(lines)


# --- command line -----------------------------------------------------------


def _rates(text: str) -> list[int]:
    return [int(float(r)) for r in text.split(",") if r]


def main(
    argv: list[str] | None = None,
    transport: Callable[[], Transport] = SpidevTransport,
) -> int:
    parser = argparse.ArgumentParser(
        prog="python -m unoq.spilink",
        description="Talk to the MCU over the SPI link (/dev/spidev0.0 to spi3).",
    )
    parser.add_argument("--speed", type=int, default=DEFAULT_SPEED_HZ, help="SPI clock, Hz")
    parser.add_argument(
        "--gap-us",
        type=float,
        default=DEFAULT_GAP_S * 1e6,
        help="wait before each transaction, microseconds",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("bench", help="bytes per second at several clock rates")
    b.add_argument("--rates", type=_rates, default=list(BENCH_RATES), help="comma-separated Hz")
    b.add_argument("--seconds", type=float, default=BENCH_SECONDS, help="per rate")
    b.add_argument("--size", type=int, default=MAX_PAYLOAD, help="payload bytes per frame")
    e = sub.add_parser("echo", help="send text, print what comes back")
    e.add_argument("text")
    t = sub.add_parser("templog", help="the MCU's temperature log")
    t.add_argument("--since", type=int, default=None)
    sub.add_parser("stat", help="the MCU's counters for the link")
    sc = sub.add_parser("scope", help="the samples of the last `app scope capture`")
    sc.add_argument("--id", type=int, default=0, help="that capture, or fail (default: any)")
    args = parser.parse_args(argv)

    if args.cmd == "bench" and not 0 <= args.size <= MAX_PAYLOAD:
        parser.error(f"--size must be 0..{MAX_PAYLOAD}")

    link = SpiLink(transport(), speed_hz=args.speed, gap_s=args.gap_us / 1e6)
    try:
        if args.cmd == "bench":
            print(format_bench(bench(link, args.rates, args.seconds, args.size)))
        elif args.cmd == "echo":
            print(link.echo(args.text.encode()).decode(errors="replace"))
        elif args.cmd == "templog":
            batch = link.templog(args.since)
            if batch.gap_first:
                print(f"gap first={batch.gap_first} last={batch.gap_last}")
            for s in batch.samples:
                kind = "temp_mc" if s.ok else "temp_err"
                print(f"seq={s.seq} ms={s.ms} {kind}={s.value}")
            print(f"end head={batch.head} more={batch.more}")
        elif args.cmd == "scope":
            burst = link.scope_read(args.id)
            print(f"id={burst.id} n={len(burst.samples)} rate_hz={burst.rate_hz:.3f}")
            print(" ".join(map(str, burst.samples)))
        else:
            st = link.stat()
            print(
                f"transactions={st.transactions} requests={st.requests}"
                f" bad_frames={st.bad_frames} spi_errors={st.spi_errors}"
            )
    except (LinkError, FrameError) as exc:
        print(f"spilink: {exc}", file=sys.stderr)
        return 1
    finally:
        link.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
