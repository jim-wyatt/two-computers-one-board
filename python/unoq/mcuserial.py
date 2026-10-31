# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""
The MCU's Zephyr shell on the host's COM port: a relay between the USB
gadget's serial port and the MCU's UART.

    sudo systemctl start unoq-mcu-serial     # how it is meant to run
    python -m unoq.mcuserial                 # the same thing, by hand

The host opens its COM port (or /dev/ttyACM0) and is talking to the STM32's
shell, with no SSH, no IP and nothing installed on the host. Every byte from
/dev/ttyGS0 goes to /dev/ttyHS1 and every byte back goes the other way,
untouched: no line editing, no echo, no translation of line endings. The
shell does its own echo and its own editing, so anything done here would be
done twice.

/dev/ttyHS1 has one owner at a time. It is opened exactly as unoq.mcu opens
it, through open_port(), so the relay holds the same two locks and fails the
same legible way when something else holds the port. The unit makes the
usual owner, unoq-cpu-bars, step aside first (Conflicts=), so systemd keeps
the rule rather than a race.

It stops on SIGTERM (systemctl stop) or SIGINT (Ctrl-C) with both ports
closed, and exits 1 if either port goes away under it: the cable pulled, the
gadget rebuilt, the MCU's UART failing. The unit restarts it after a pulled
cable, which leaves /dev/ttyGS0 in place but hung up.
"""

from __future__ import annotations

import argparse
import contextlib
import errno
import os
import selectors
import signal
import sys
from collections.abc import Callable
from typing import Protocol

import serial

from .link import link_up
from .mcu import BAUD, PORT, PortBusy, open_port, set_exclusive

# The gadget's CDC-ACM function, as the board sees it (usb/gadget-up.sh).
HOST_PORT = "/dev/ttyGS0"
# One read's worth. The shell is a person typing at one end and a few lines of
# output at the other, so this is generous; it only bounds a burst.
CHUNK = 4096
# How much may wait for a side that is not taking it - the host with the COM
# port closed, or no host at all - before the oldest bytes are dropped. A
# console that loses scrollback is fine; a relay that stops reading the other
# side because one side stopped is not.
BACKLOG = 64 * 1024
# How often the loop looks up from select() to see whether it was told to
# stop. A signal handler cannot end a select() by itself (PEP 475 retries it),
# so the loop has to come round to notice.
TICK = 0.5


class Port(Protocol):
    """One end of the relay: a file descriptor that reads and writes bytes.

    read() returns b"" when the far end has gone (a hung-up tty) and raises
    BlockingIOError when there is nothing yet; write() returns how much it
    took and raises BlockingIOError when it can take nothing.
    """

    def fileno(self) -> int: ...
    def read(self, size: int) -> bytes: ...
    def write(self, data: bytes) -> int: ...
    def close(self) -> None: ...


class _Serial(Protocol):
    def fileno(self) -> int: ...
    def close(self) -> None: ...


class Tty:
    """An open pyserial port, read and written through its descriptor.

    pyserial is what opens and configures the port - raw mode, the speed, the
    locks - and then gets out of the way. Its own read() and write() block,
    loop and raise on a hang-up, which is the opposite of what a byte pump
    wants; os.read() and os.write() on a non-blocking descriptor say exactly
    what happened.
    """

    def __init__(self, s: _Serial) -> None:
        self._s = s
        os.set_blocking(s.fileno(), False)

    def fileno(self) -> int:
        return self._s.fileno()

    def read(self, size: int) -> bytes:
        return os.read(self.fileno(), size)

    def write(self, data: bytes) -> int:
        return os.write(self.fileno(), data)

    def close(self) -> None:
        self._s.close()


class PortGone(Exception):
    """One end of the relay stopped working."""


class Relay:
    """Pump bytes both ways between the MCU's UART and the host's port.

    What each side has not yet taken is held, up to BACKLOG, and the side is
    watched for writability only while something is waiting for it - so a
    host that is not reading never stops the MCU being read.
    """

    def __init__(self, mcu: Port, host: Port, selector: selectors.BaseSelector) -> None:
        self._sel = selector
        self._names = {mcu: PORT, host: HOST_PORT}
        self._peer = {mcu: host, host: mcu}
        self._pending: dict[Port, bytearray] = {mcu: bytearray(), host: bytearray()}
        self._stopping = False
        self.dropped = 0
        for port in (mcu, host):
            selector.register(port, selectors.EVENT_READ, port)

    def stop(self, *_: object) -> None:
        """Ask the loop to finish. Safe to use as a signal handler."""
        self._stopping = True

    def run(self) -> int:
        """Relay until stop(), then return 0; or until a port fails, then 1."""
        try:
            while not self._stopping:
                for key, events in self._sel.select(TICK):
                    port: Port = key.data
                    if events & selectors.EVENT_READ:
                        self._read(port)
                    if events & selectors.EVENT_WRITE:
                        self._flush(port)
        except PortGone as exc:
            print(exc, file=sys.stderr)
            return 1
        return 0

    def _read(self, port: Port) -> None:
        try:
            data = port.read(CHUNK)
        except BlockingIOError:
            return  # readable, then not: another reader, or a spurious wake
        except OSError as exc:
            raise PortGone(self._gone(port, exc)) from exc
        if not data:
            raise PortGone(self._gone(port, None))
        out = self._peer[port]
        buf = self._pending[out]
        buf += data
        if len(buf) > BACKLOG:
            excess = len(buf) - BACKLOG
            del buf[:excess]
            self.dropped += excess
        self._flush(out)

    def _flush(self, port: Port) -> None:
        buf = self._pending[port]
        if buf:
            try:
                del buf[: port.write(bytes(buf))]
            except BlockingIOError:
                pass  # full: it is watched for writability below
            except OSError as exc:
                raise PortGone(self._gone(port, exc)) from exc
        events = selectors.EVENT_READ | (selectors.EVENT_WRITE if buf else 0)
        self._sel.modify(port, events, port)

    def _gone(self, port: Port, exc: OSError | None) -> str:
        name = self._names[port]
        why = f": {exc.strerror}" if exc is not None else ""
        if name == HOST_PORT:
            return (
                f"{name} went away{why} - the cable was unplugged, or the gadget "
                f"was rebuilt. The unit starts the relay again."
            )
        return f"{name} failed{why} - is the MCU link up? (systemctl status unoq-link)"


def open_host(port: str = HOST_PORT) -> serial.Serial:
    """Open the gadget's serial port raw, and as exclusively as the MCU's.

    The speed is ignored by a USB serial port; it is set only because pyserial
    needs one. The lock is the same TIOCEXCL unoq.mcu sets: it keeps out a
    `tio` opened by mistake on the board's side.
    """
    s = serial.Serial(port, BAUD, timeout=0, exclusive=True)
    set_exclusive(s)
    return s


def _open_error(port: str, exc: OSError) -> str:
    if exc.errno == errno.ENOENT:
        return (
            f"no {port}: the gadget has no serial port. Set UNOQ_GADGET_ACM=1 and\n"
            f"  rebuild it - see 'A serial login over the cable' in docs/reference/usb.md."
        )
    return f"cannot open {port}: {exc}"


def main(
    argv: list[str] | None = None,
    *,
    mcu_opener: Callable[[str], _Serial] = open_port,
    host_opener: Callable[[str], _Serial] = open_host,
    make_selector: Callable[[], selectors.BaseSelector] = selectors.DefaultSelector,
    ensure_link: Callable[[], None] = link_up,
) -> int:
    parser = argparse.ArgumentParser(
        prog="python -m unoq.mcuserial",
        description="Relay the MCU's shell to the host's COM port over the USB gadget.",
    )
    parser.add_argument("--mcu-port", default=PORT, help="the MCU's UART")
    parser.add_argument("--host-port", default=HOST_PORT, help="the gadget's serial port")
    args = parser.parse_args(argv)

    # As unoq.mcu does: cheap and idempotent, and without it the UART reads
    # nothing. The unit already Requires= unoq-link; this is for a run by hand.
    with contextlib.suppress(Exception):
        ensure_link()

    try:
        mcu = Tty(mcu_opener(args.mcu_port))
    except PortBusy as exc:  # it says who holds the port, and what to do
        print(exc, file=sys.stderr)
        return 1
    except OSError as exc:  # serial.SerialException is one
        print(_open_error(args.mcu_port, exc), file=sys.stderr)
        return 1
    try:
        host = Tty(host_opener(args.host_port))
    except OSError as exc:
        mcu.close()
        print(_open_error(args.host_port, exc), file=sys.stderr)
        return 1

    sel = make_selector()
    relay = Relay(mcu, host, sel)
    previous = {sig: signal.signal(sig, relay.stop) for sig in (signal.SIGTERM, signal.SIGINT)}
    print(f"relaying {args.host_port} <-> {args.mcu_port}", file=sys.stderr)
    try:
        rc = relay.run()
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)
        sel.close()
        host.close()
        mcu.close()
    if relay.dropped:
        print(f"dropped {relay.dropped} bytes nobody was reading", file=sys.stderr)
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
