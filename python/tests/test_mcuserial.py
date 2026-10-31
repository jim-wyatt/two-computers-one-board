# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""Tests for the relay between the host's COM port and the MCU's UART.

Nothing here opens a tty. The relay is driven two ways: with fake ports and a
scripted selector, which is how every branch of the pump is reached on
purpose, and through main() with socket pairs standing in for the two ttys and
real signals sent to this process, which is how stopping is shown to close
everything.
"""

from __future__ import annotations

import errno
import os
import selectors
import signal
import socket
from collections.abc import Callable, Iterator
from typing import Any

import pytest
import serial

from unoq import mcuserial
from unoq.mcu import PORT, PortBusy
from unoq.mcuserial import HOST_PORT, Relay

R = selectors.EVENT_READ
W = selectors.EVENT_WRITE


class FakePort:
    """A port whose reads are scripted and whose writes are recorded.

    Each read takes the next item: bytes are returned, an exception raised.
    `accept` limits how much one write takes; an exception there is raised.
    """

    def __init__(self, fd: int, reads: list[bytes | Exception] | None = None) -> None:
        self._fd = fd
        self.reads = list(reads or [])
        self.written = bytearray()
        self.accept: list[int | Exception] = []
        self.closed = False

    def fileno(self) -> int:
        return self._fd

    def read(self, size: int) -> bytes:
        item = self.reads.pop(0)
        if isinstance(item, Exception):
            raise item
        return item[:size]

    def write(self, data: bytes) -> int:
        n: int | Exception = self.accept.pop(0) if self.accept else len(data)
        if isinstance(n, Exception):
            raise n
        self.written += data[:n]
        return n

    def close(self) -> None:
        self.closed = True


Ready = list[tuple[Any, int]]
Step = Ready | Callable[["FakeSelector"], Ready]


class FakeSelector(selectors.BaseSelector):
    """Hands back scripted events, one step per select(), and records how
    each port is being watched. When the script runs out it stops the relay,
    as a signal would."""

    def __init__(self, steps: list[Step] | None = None) -> None:
        self.steps = list(steps or [])
        self.watch: dict[Any, int] = {}
        self.history: list[tuple[Any, int]] = []
        self.timeouts: list[float | None] = []
        self.relay: Relay | None = None
        self.closed = False

    def register(self, fileobj: Any, events: int, data: Any = None) -> selectors.SelectorKey:
        assert data is fileobj
        self.watch[fileobj] = events
        return selectors.SelectorKey(fileobj, 0, events, data)

    def unregister(self, fileobj: Any) -> selectors.SelectorKey:  # pragma: no cover
        raise AssertionError("the relay never unregisters")

    def modify(self, fileobj: Any, events: int, data: Any = None) -> selectors.SelectorKey:
        assert fileobj in self.watch
        assert data is fileobj
        self.watch[fileobj] = events
        self.history.append((fileobj, events))
        return selectors.SelectorKey(fileobj, 0, events, data)

    def select(self, timeout: float | None = None) -> list[tuple[selectors.SelectorKey, int]]:
        self.timeouts.append(timeout)
        if not self.steps:
            assert self.relay is not None
            self.relay.stop()
            return []
        step = self.steps.pop(0)
        ready = step(self) if callable(step) else step
        return [(selectors.SelectorKey(p, 0, self.watch[p], p), ev) for p, ev in ready]

    def get_map(self) -> Any:  # pragma: no cover
        raise AssertionError("not used")

    def close(self) -> None:
        self.closed = True


def make(
    steps: list[Step], mcu_reads: list[bytes | Exception], host_reads: list[bytes | Exception]
) -> tuple[Relay, FakePort, FakePort, FakeSelector]:
    mcu, host = FakePort(10, mcu_reads), FakePort(11, host_reads)
    sel = FakeSelector(steps)
    relay = Relay(mcu, host, sel)
    sel.relay = relay
    return relay, mcu, host, sel


# --- the pump ---------------------------------------------------------------


def test_both_ports_are_watched_for_reading_from_the_start() -> None:
    _, mcu, host, sel = make([], [], [])
    assert sel.watch == {mcu: R, host: R}


def test_bytes_go_both_ways_untouched() -> None:
    # Raw: a CR, a backspace and an escape sequence arrive exactly as sent.
    steps: list[Step] = []
    relay, mcu, host, sel = make(steps, [], [])
    steps += [[(host, R)], [(mcu, R)]]
    sel.steps = steps
    host.reads = [b"app status\r\x08\x1b[A"]
    mcu.reads = [b"\r\nuptime_ms=1\r\nunoq:~$ "]
    assert relay.run() == 0
    assert bytes(mcu.written) == b"app status\r\x08\x1b[A"
    assert bytes(host.written) == b"\r\nuptime_ms=1\r\nunoq:~$ "
    # Everything was taken, so neither side is watched for writing.
    assert sel.watch == {mcu: R, host: R}
    assert relay.dropped == 0


def test_the_loop_looks_up_every_tick_to_see_whether_to_stop() -> None:
    relay, _, _, sel = make([[], []], [], [])
    assert relay.run() == 0
    assert sel.timeouts == [mcuserial.TICK] * 3


def test_a_stopped_relay_does_not_select_at_all() -> None:
    relay, _, _, sel = make([], [], [])
    relay.stop(signal.SIGTERM, None)
    assert relay.run() == 0
    assert sel.timeouts == []


def test_a_side_that_takes_part_is_watched_until_it_takes_the_rest() -> None:
    relay, mcu, host, sel = make([], [b"hello"], [])
    host.accept = [2, BlockingIOError(), 3]
    sel.steps = [[(mcu, R)], [(host, W)], [(host, W)]]
    assert relay.run() == 0
    assert bytes(host.written) == b"hello"
    assert sel.history == [(host, R | W), (host, R | W), (host, R)]


def test_a_full_side_does_not_stop_the_other_being_read() -> None:
    # The host is not reading: every write is refused. The MCU is still read.
    relay, mcu, host, sel = make([], [b"one ", b"two"], [])
    host.accept = [BlockingIOError(), BlockingIOError()]
    sel.steps = [[(mcu, R)], [(mcu, R)]]
    assert relay.run() == 0
    assert mcu.reads == []
    assert sel.watch[host] == R | W
    assert relay._pending[host] == bytearray(b"one two")


def test_a_backlog_past_its_limit_drops_the_oldest_bytes(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(mcuserial, "BACKLOG", 4)
    relay, mcu, host, sel = make([], [b"0123456789"], [])
    host.accept = [BlockingIOError()]
    sel.steps = [[(mcu, R)]]
    assert relay.run() == 0
    assert relay._pending[host] == bytearray(b"6789")
    assert relay.dropped == 6


def test_writable_with_nothing_waiting_just_stops_watching_for_it() -> None:
    relay, _, host, sel = make([], [], [])
    sel.steps = [[(host, W)]]
    assert relay.run() == 0
    assert host.written == bytearray()
    assert sel.history == [(host, R)]


def test_a_spurious_wake_reads_nothing_and_carries_on() -> None:
    relay, mcu, host, sel = make([], [BlockingIOError()], [])
    sel.steps = [[(mcu, R)]]
    assert relay.run() == 0
    assert host.written == bytearray()


def test_readable_and_writable_together_does_both() -> None:
    relay, mcu, host, sel = make([], [b"x"], [b"y"])
    mcu.accept = [BlockingIOError(), 1]
    sel.steps = [[(host, R)], [(mcu, R | W)]]
    assert relay.run() == 0
    assert bytes(mcu.written) == b"y"
    assert bytes(host.written) == b"x"


# --- a port going away ------------------------------------------------------


def test_the_cable_pulled_is_a_hang_up_and_ends_the_relay(
    capsys: pytest.CaptureFixture[str],
) -> None:
    # A hung-up tty reads as end of file.
    relay, _, host, sel = make([], [], [b""])
    sel.steps = [[(host, R)]]
    assert relay.run() == 1
    err = capsys.readouterr().err
    assert f"{HOST_PORT} went away -" in err
    assert "unplugged" in err


def test_the_gadget_rebuilt_under_it_ends_the_relay(capsys: pytest.CaptureFixture[str]) -> None:
    # /dev/ttyGS0 gone: the descriptor fails rather than reading end of file.
    relay, mcu, host, sel = make([], [b"unoq:~$ "], [])
    host.accept = [OSError(errno.EIO, "Input/output error")]
    sel.steps = [[(mcu, R)]]
    assert relay.run() == 1
    assert f"{HOST_PORT} went away: Input/output error -" in capsys.readouterr().err


def test_a_failing_read_on_the_host_side_ends_the_relay(
    capsys: pytest.CaptureFixture[str],
) -> None:
    relay, _, host, sel = make([], [], [OSError(errno.ENODEV, "No such device")])
    sel.steps = [[(host, R)]]
    assert relay.run() == 1
    assert f"{HOST_PORT} went away: No such device" in capsys.readouterr().err


def test_a_failing_mcu_side_ends_the_relay_and_points_at_the_link(
    capsys: pytest.CaptureFixture[str],
) -> None:
    relay, mcu, _, sel = make([], [OSError(errno.EIO, "Input/output error")], [])
    sel.steps = [[(mcu, R)]]
    assert relay.run() == 1
    err = capsys.readouterr().err
    assert f"{PORT} failed: Input/output error" in err
    assert "unoq-link" in err


def test_the_mcu_side_reading_end_of_file_ends_the_relay(
    capsys: pytest.CaptureFixture[str],
) -> None:
    relay, mcu, _, sel = make([], [b""], [])
    sel.steps = [[(mcu, R)]]
    assert relay.run() == 1
    assert f"{PORT} failed - is the MCU link up?" in capsys.readouterr().err


# --- the ports themselves ---------------------------------------------------


class SockSerial:
    """Stands in for an open serial.Serial: one end of a socket pair."""

    def __init__(self, sock: socket.socket) -> None:
        self.sock = sock
        self.closed = False

    def fileno(self) -> int:
        return self.sock.fileno()

    def close(self) -> None:
        self.closed = True
        self.sock.close()


@pytest.fixture
def pair() -> Iterator[tuple[SockSerial, socket.socket]]:
    a, b = socket.socketpair()
    s = SockSerial(a)
    yield s, b
    b.close()
    if not s.closed:
        a.close()


def test_a_tty_reads_and_writes_its_descriptor_without_blocking(
    pair: tuple[SockSerial, socket.socket],
) -> None:
    s, far = pair
    t = mcuserial.Tty(s)
    assert t.fileno() == s.fileno()
    assert not os.get_blocking(s.fileno())
    with pytest.raises(BlockingIOError):
        t.read(10)
    far.sendall(b"abc")
    assert t.read(10) == b"abc"
    assert t.write(b"xyz") == 3
    assert far.recv(10) == b"xyz"
    t.close()
    assert s.closed


def test_the_host_port_is_opened_raw_and_locked_like_the_mcus(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    opened: list[tuple[Any, ...]] = []
    locked: list[object] = []
    sentinel = object()

    def fake_serial(*a: Any, **kw: Any) -> object:
        opened.append((a, kw))
        return sentinel

    monkeypatch.setattr("unoq.mcuserial.serial.Serial", fake_serial)
    monkeypatch.setattr(mcuserial, "set_exclusive", locked.append)
    assert mcuserial.open_host("/dev/ttyGS9") is sentinel
    assert opened == [(("/dev/ttyGS9", 115200), {"timeout": 0, "exclusive": True})]
    assert locked == [sentinel]


# --- main -------------------------------------------------------------------


class Board:
    """Two socket pairs standing in for /dev/ttyHS1 and /dev/ttyGS0, and the
    far ends of each: the MCU and the host."""

    def __init__(self) -> None:
        a, self.mcu_far = socket.socketpair()
        b, self.host_far = socket.socketpair()
        self.mcu = SockSerial(a)
        self.host = SockSerial(b)
        self.opened: list[str] = []
        self.links = 0

    def open_mcu(self, port: str) -> SockSerial:
        self.opened.append(port)
        return self.mcu

    def open_host(self, port: str) -> SockSerial:
        self.opened.append(port)
        return self.host

    def link(self) -> None:
        self.links += 1
        raise PermissionError("no gpio here")  # not fatal: the unit brought it up

    def close(self) -> None:
        for s in (self.mcu_far, self.host_far, self.mcu.sock, self.host.sock):
            s.close()


@pytest.fixture
def board() -> Iterator[Board]:
    b = Board()
    yield b
    b.close()


def run_main(
    board: Board, steps: list[Step], argv: list[str] | None = None, **kw: Any
) -> tuple[int, FakeSelector]:
    sel = FakeSelector(steps)
    real_relay = mcuserial.Relay

    def relay(*a: Any) -> Relay:
        r = real_relay(*a)
        sel.relay = r
        return r

    mp = pytest.MonkeyPatch()
    mp.setattr(mcuserial, "Relay", relay)
    try:
        rc = mcuserial.main(
            argv or [],
            mcu_opener=kw.get("mcu_opener", board.open_mcu),
            host_opener=kw.get("host_opener", board.open_host),
            make_selector=lambda: sel,
            ensure_link=board.link,
        )
    finally:
        mp.undo()
    return rc, sel


def readable(s: SockSerial) -> Callable[[FakeSelector], Ready]:
    """A step: the port standing on `s` is readable."""
    return lambda sel: [(p, R) for p in sel.watch if p.fileno() == s.fileno()]


@pytest.mark.parametrize("sig", [signal.SIGTERM, signal.SIGINT])
def test_a_signal_stops_it_and_both_ports_are_closed(
    board: Board, sig: signal.Signals, capsys: pytest.CaptureFixture[str]
) -> None:
    before = {s: signal.getsignal(s) for s in (signal.SIGTERM, signal.SIGINT)}
    board.host_far.sendall(b"\r")

    def kill(sel: FakeSelector) -> Ready:
        os.kill(os.getpid(), sig)
        return []

    rc, sel = run_main(board, [readable(board.host), kill, kill])
    assert rc == 0
    # The Enter reached the MCU, and the second kill was never needed.
    assert board.mcu_far.recv(10) == b"\r"
    assert len(sel.steps) == 1
    assert board.mcu.closed
    assert board.host.closed
    assert sel.closed
    assert {s: signal.getsignal(s) for s in before} == before
    assert board.opened == [PORT, HOST_PORT]
    assert board.links == 1
    assert f"relaying {HOST_PORT} <-> {PORT}" in capsys.readouterr().err


def test_the_ports_can_be_named(board: Board) -> None:
    rc, _ = run_main(board, [], ["--mcu-port", "/dev/ttyX", "--host-port", "/dev/ttyY"])
    assert rc == 0
    assert board.opened == ["/dev/ttyX", "/dev/ttyY"]


def test_a_port_that_goes_away_closes_both_and_fails(board: Board) -> None:
    board.host_far.close()  # the host hangs up: the socket reads end of file
    rc, sel = run_main(board, [readable(board.host)])
    assert rc == 1
    assert board.mcu.closed
    assert board.host.closed
    assert sel.closed


def test_bytes_dropped_for_want_of_a_reader_are_counted_on_the_way_out(
    board: Board, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(mcuserial, "BACKLOG", 2)
    board.mcu_far.sendall(b"12345")
    rc, _ = run_main(board, [readable(board.mcu)])
    assert rc == 0
    assert board.host_far.recv(10) == b"45"
    assert "dropped 3 bytes nobody was reading" in capsys.readouterr().err


def test_the_mcu_port_held_by_someone_else_says_who(
    board: Board, capsys: pytest.CaptureFixture[str]
) -> None:
    def busy(port: str) -> SockSerial:
        raise PortBusy(f"{port} is in use by unoq-cpu-bars")

    rc, sel = run_main(board, [], mcu_opener=busy)
    assert rc == 1
    assert f"{PORT} is in use by unoq-cpu-bars" in capsys.readouterr().err
    assert sel.timeouts == []


def test_the_mcu_port_failing_to_open_is_reported(
    board: Board, capsys: pytest.CaptureFixture[str]
) -> None:
    def denied(port: str) -> SockSerial:
        raise serial.SerialException(errno.EACCES, "Permission denied")

    rc, _ = run_main(board, [], mcu_opener=denied)
    assert rc == 1
    assert f"cannot open {PORT}:" in capsys.readouterr().err


def test_no_gadget_serial_port_says_how_to_get_one(
    board: Board, capsys: pytest.CaptureFixture[str]
) -> None:
    def missing(port: str) -> SockSerial:
        raise serial.SerialException(errno.ENOENT, f"could not open port {port}")

    rc, sel = run_main(board, [], host_opener=missing)
    assert rc == 1
    err = capsys.readouterr().err
    assert f"no {HOST_PORT}: the gadget has no serial port" in err
    assert "UNOQ_GADGET_ACM=1" in err
    # The MCU's port was opened first, and is let go again.
    assert board.mcu.closed
    assert sel.timeouts == []
