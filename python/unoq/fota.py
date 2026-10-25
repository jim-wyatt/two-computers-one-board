# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""
Firmware update over the serial link, via MCUboot + SMP. No SWD needed.

    from unoq import fota
    fota.upload("~/zephyrproject/build/zephyr/zephyr.signed.bin")
    fota.test()      # mark pending, then reset - MCUboot swaps slot1 -> slot0
    fota.confirm()   # keep it; without this the next reset reverts

The revert-on-failure behavior is the point: an image that boots but cannot
be confirmed (because it crashed, or you never called confirm) is rolled back
automatically. That is what makes remote updates safe.

Requires the app to be built with CONFIG_BOOTLOADER_MCUBOOT=y and signed - mcu/zbuild.sh does both,
and docs/reference/mcu.md has the detail.
"""

from __future__ import annotations

import asyncio
import contextlib
import os
from pathlib import Path
from typing import Any, TypedDict

import serial
from smpclient import SMPClient
from smpclient.requests.image_management import ImageStatesRead, ImageStatesWrite
from smpclient.requests.os_management import ResetWrite
from smpclient.transport.serial import SMPSerialTransport

from .mcu import BAUD, PORT, open_port, set_exclusive


class ImageState(TypedDict):
    """One row of the MCUboot slot table, as reported over SMP.

    `active` is the slot running now; `confirmed` is the one MCUboot will keep.
    An image that is active but not confirmed reverts on the next reset - that
    is the safety net, not a fault.
    """

    slot: int
    version: str
    active: bool
    confirmed: bool
    pending: bool
    hash: str


def _serial_of(transport: SMPSerialTransport) -> serial.Serial:
    """The pyserial port inside smpclient's transport.

    It is a private attribute, and smpclient is pinned in the lock file. If a
    new version moves it, this raises rather than carrying on unlocked.
    """
    conn = getattr(transport, "_conn", None)
    if not isinstance(conn, serial.Serial):
        raise RuntimeError(
            "smpclient's serial transport no longer keeps its port in _conn; "
            "fota cannot lock the port. Update fota._serial_of."
        )
    return conn


async def _client(port: str, timeout: float) -> tuple[SMPClient, SMPSerialTransport]:
    """Connect over SMP holding both of the port's locks, as MCU() does.

    This used to open the port with neither. An upload runs for minutes, and
    during it MCU() or tio could open the port and put shell lines between the
    SMP frames. And while unoq-cpu-bars held the port, the open here failed
    with a bare EBUSY - or, because smpclient retries every failed open until
    its timeout, as a TimeoutError - instead of PortBusy naming who has it.

    The open_port() probe is what turns a busy port into that PortBusy, before
    anything is sent. It is closed again at once, which also clears the
    TIOCEXCL it set, and the transport opens the port for itself.
    """
    open_port(port).close()
    transport = SMPSerialTransport(baudrate=BAUD, exclusive=True)
    client = SMPClient(transport, port, timeout_s=timeout)
    try:
        await client.connect(connect_timeout_s=timeout)
    except TimeoutError:
        # Taken in the moment between the probe and here. Ask again, so that
        # the error names the holder if there is one.
        open_port(port).close()
        raise
    try:
        set_exclusive(_serial_of(transport))
    except BaseException:
        await transport.disconnect()
        raise
    return client, transport


def _send(
    request: Any,
    port: str,
    timeout: float,
    *,
    expect_reply: bool = True,
    overall: float | None = None,
) -> Any:
    """Connect, send one SMP request, disconnect. Returns the reply.

    Every command here is one round trip on a UART that only one process can
    hold, so the disconnect matters more than the reply does - it is in a
    `finally` for that reason. `overall` bounds the whole exchange, including
    the connect, separately from the per-request `timeout`.

    smpclient is untyped, so the reply is Any and callers pin what they need.
    """

    async def _run() -> Any:
        c, t = await _client(port, timeout)
        try:
            if not expect_reply:
                # reset() gets no answer: the device resets instead of
                # replying, so the request never completes. That is success.
                with contextlib.suppress(Exception):
                    await c.request(request, timeout_s=timeout)
                return None
            return await c.request(request, timeout_s=timeout)
        finally:
            await t.disconnect()

    return asyncio.run(asyncio.wait_for(_run(), timeout * 3 if overall is None else overall))


def images(port: str = PORT, timeout: float = 10.0) -> list[ImageState]:
    """Return the MCUboot slot table."""
    r = _send(ImageStatesRead(), port, timeout, overall=timeout * 6)
    return [
        {
            "slot": im.slot,
            "version": im.version,
            "active": im.active,
            "confirmed": im.confirmed,
            "pending": im.pending,
            "hash": im.hash.hex(),
        }
        for im in getattr(r, "images", [])
    ]


def upload(
    image: str | os.PathLike[str], port: str = PORT, timeout: float = 600.0, progress: bool = True
) -> str:
    """Upload a *signed* image (.signed.bin) into the inactive slot.

    Returns the new image's hash. This only stages it - call test() to boot it.
    """
    path = Path(image).expanduser()
    if not path.exists():
        raise FileNotFoundError(path)
    if "signed" not in path.name:
        raise ValueError(
            f"{path.name} does not look signed; MCUboot will reject an unsigned "
            "image. Use zephyr.signed.bin, which zbuild writes and signs."
        )
    blob = path.read_bytes()

    async def _run() -> str:
        c, t = await _client(port, 20.0)
        try:
            last = -1
            async for offset in c.upload(blob):
                if progress:
                    pct = offset * 100 // len(blob)
                    if pct >= last + 10:
                        last = pct
                        print(f"  upload {pct:3d}%  ({offset}/{len(blob)})", flush=True)
            r = await c.request(ImageStatesRead(), timeout_s=20.0)
            for im in getattr(r, "images", []):
                if not im.active:
                    # smpclient is untyped, so pin the type at the boundary.
                    staged: str = im.hash.hex()
                    return staged
            return ""
        finally:
            await t.disconnect()

    return asyncio.run(asyncio.wait_for(_run(), timeout))


def _version(v: str) -> tuple[int, ...] | None:
    """An MCUboot version, major.minor.revision[.build], as four integers to
    compare. None if it is not one. zbuild stamps the build number from the
    clock, so a newer build is a larger version."""
    try:
        parts = tuple(int(p) for p in v.split("."))
    except ValueError:
        return None
    return parts + (0,) * (4 - len(parts)) if len(parts) <= 4 else None


def test(image_hash: str | None = None, port: str = PORT, timeout: float = 20.0) -> None:
    """Mark the staged image pending, so the next boot swaps to it.

    If it does not get confirm()ed, MCUboot reverts on the following reset.

    With no hash, only an inactive image NEWER than the running one is
    marked. After a swap and a confirm the inactive slot holds the PREVIOUS
    image, and marking whatever was there quietly scheduled a downgrade on a
    second call with no fresh upload. A hash, such as the one upload()
    returns, is taken as meaning exactly that image, older or not: that is
    how you roll back on purpose.
    """
    if image_hash is None:
        table = images(port)
        running = next((im for im in table if im["active"]), None)
        staged = next((im for im in table if not im["active"]), None)
        if staged is None:
            raise RuntimeError("no staged image found in the inactive slot")
        new = _version(staged["version"])
        now = _version(running["version"]) if running else None
        if new is None or now is None or new <= now:
            was = running["version"] if running else "unknown"
            raise RuntimeError(
                f"the inactive slot holds {staged['version']}, which is not newer "
                f"than the running {was}. After a confirm that slot holds the "
                f"previous image, and marking it would downgrade the MCU.\n"
                f"  To update: fota.test(fota.upload(path))\n"
                f"  To go back to it on purpose: fota.test('{staged['hash']}')"
            )
        image_hash = staged["hash"]
    if not image_hash:
        raise RuntimeError("no staged image found in the inactive slot")

    _send(ImageStatesWrite(hash=bytes.fromhex(image_hash), confirm=False), port, timeout)


def confirm(port: str = PORT, timeout: float = 20.0) -> None:
    """Confirm the running image so MCUboot stops reverting it."""
    _send(ImageStatesWrite(confirm=True), port, timeout)


def reset(port: str = PORT, timeout: float = 20.0) -> None:
    """Reset the MCU over SMP (applies a pending swap)."""
    _send(ResetWrite(), port, timeout, expect_reply=False)
