# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""Tests for MCUboot image staging over SMP.

The dangerous mistakes here are silent ones: staging an unsigned image, or
confirming the wrong slot. Both are guarded below without touching a board.
"""

from __future__ import annotations

import asyncio
import errno
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any, ClassVar

import pytest
import serial

from unoq import fota
from unoq.mcu import PortBusy


class FakeImage:
    def __init__(
        self,
        slot: int,
        version: str = "0.0.0",
        *,
        active: bool = False,
        confirmed: bool = False,
        pending: bool = False,
        digest: bytes = b"\xab\xcd",
    ) -> None:
        self.slot = slot
        self.version = version
        self.active = active
        self.confirmed = confirmed
        self.pending = pending
        self.hash = digest


class FakeReply:
    def __init__(self, images: list[FakeImage] | None) -> None:
        if images is not None:
            self.images = images


class FakeTransport:
    def __init__(self) -> None:
        self.disconnected = False

    async def disconnect(self) -> None:
        self.disconnected = True


class FakeClient:
    def __init__(
        self,
        images: list[FakeImage] | None = None,
        *,
        offsets: list[int] | None = None,
        fail: Exception | None = None,
    ) -> None:
        self.images = images if images is not None else []
        self.offsets = offsets or [0]
        self.fail = fail
        self.requests: list[Any] = []

    async def request(self, req: Any, timeout_s: float | None = None) -> FakeReply:
        self.requests.append(req)
        if self.fail is not None:
            raise self.fail
        return FakeReply(self.images)

    async def upload(self, blob: bytes) -> AsyncIterator[int]:
        for off in self.offsets:
            yield off


@pytest.fixture
def smp(monkeypatch: pytest.MonkeyPatch) -> dict[str, Any]:
    """Patch the SMP connection helper and the request types fota builds."""
    state: dict[str, Any] = {"client": FakeClient(), "transport": FakeTransport()}

    async def _client(port: str, timeout: float) -> tuple[Any, Any]:
        state["port"] = port
        return state["client"], state["transport"]

    class RecordingWrite:
        def __init__(self, **kwargs: Any) -> None:
            self.kwargs = kwargs

    monkeypatch.setattr(fota, "_client", _client)
    monkeypatch.setattr(fota, "ImageStatesWrite", RecordingWrite)
    monkeypatch.setattr(fota, "ImageStatesRead", RecordingWrite)
    monkeypatch.setattr(fota, "ResetWrite", RecordingWrite)
    return state


# -- images ------------------------------------------------------------------


def test_images_maps_the_slot_table(smp: dict[str, Any]) -> None:
    smp["client"] = FakeClient(
        [FakeImage(0, "1.2.3", active=True, confirmed=True, digest=b"\x01\x02")]
    )
    assert fota.images() == [
        {
            "slot": 0,
            "version": "1.2.3",
            "active": True,
            "confirmed": True,
            "pending": False,
            "hash": "0102",
        }
    ]


def test_images_is_empty_when_the_reply_has_none(smp: dict[str, Any]) -> None:
    smp["client"] = FakeClient(None)
    assert fota.images() == []


def test_images_always_disconnects(smp: dict[str, Any]) -> None:
    fota.images()
    assert smp["transport"].disconnected is True


def test_images_disconnects_even_when_the_request_fails(smp: dict[str, Any]) -> None:
    smp["client"] = FakeClient(fail=RuntimeError("link dropped"))
    with pytest.raises(RuntimeError, match="link dropped"):
        fota.images()
    assert smp["transport"].disconnected is True


# -- upload ------------------------------------------------------------------


def test_upload_rejects_a_missing_file(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError):
        fota.upload(tmp_path / "nope.signed.bin")


def test_upload_refuses_an_unsigned_image(tmp_path: Path) -> None:
    """The guard that stops you bricking the MCUboot chain.

    An unsigned image links into slot0 with no header, so the bootloader
    refuses it and the board stops booting.
    """
    raw = tmp_path / "zephyr.bin"
    raw.write_bytes(b"\x00" * 16)
    with pytest.raises(ValueError, match="does not look signed"):
        fota.upload(raw)


def test_upload_returns_the_staged_slot_hash(smp: dict[str, Any], tmp_path: Path) -> None:
    image = tmp_path / "zephyr.signed.bin"
    image.write_bytes(b"\x01" * 32)
    smp["client"] = FakeClient(
        [
            FakeImage(0, active=True, digest=b"\xaa"),
            FakeImage(1, active=False, digest=b"\xbe\xef"),
        ]
    )
    assert fota.upload(image, progress=False) == "beef"


def test_upload_returns_empty_when_no_inactive_slot_exists(
    smp: dict[str, Any], tmp_path: Path
) -> None:
    image = tmp_path / "zephyr.signed.bin"
    image.write_bytes(b"\x01" * 8)
    smp["client"] = FakeClient([FakeImage(0, active=True)])
    assert fota.upload(image, progress=False) == ""


def test_upload_reports_progress(
    smp: dict[str, Any], tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    image = tmp_path / "zephyr.signed.bin"
    image.write_bytes(b"\x01" * 100)
    smp["client"] = FakeClient([FakeImage(1)], offsets=[0, 50, 100])
    fota.upload(image, progress=True)
    out = capsys.readouterr().out
    assert "upload" in out
    assert "100%" in out


def test_upload_is_silent_when_progress_is_off(
    smp: dict[str, Any], tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    image = tmp_path / "zephyr.signed.bin"
    image.write_bytes(b"\x01" * 100)
    smp["client"] = FakeClient([FakeImage(1)], offsets=[0, 100])
    fota.upload(image, progress=False)
    assert capsys.readouterr().out == ""


# -- test / confirm / reset --------------------------------------------------


def test_test_marks_the_given_hash_pending(smp: dict[str, Any]) -> None:
    fota.test("beef")
    write = smp["client"].requests[-1]
    assert write.kwargs["hash"] == bytes.fromhex("beef")
    # confirm=False is what makes this a *test* boot that reverts on failure.
    assert write.kwargs["confirm"] is False


def test_test_finds_the_inactive_slot_when_no_hash_is_given(smp: dict[str, Any]) -> None:
    smp["client"] = FakeClient(
        [
            FakeImage(0, "0.0.0.100", active=True, digest=b"\xaa"),
            FakeImage(1, "0.0.0.200", active=False, digest=b"\xbe\xef"),
        ]
    )
    fota.test()
    assert smp["client"].requests[-1].kwargs["hash"] == bytes.fromhex("beef")


@pytest.mark.parametrize(
    ("running", "staged"),
    [
        # After a swap and a confirm: the previous image, in the inactive slot.
        ("0.0.0.200", "0.0.0.100"),
        ("0.0.0.100", "0.0.0.100"),
        # 1.2 is 1.2.0.0, not something smaller than it.
        ("1.2", "1.2.0.0"),
        ("0.0.0.100", "not-a-version"),
        ("0.0.0.100", "1.2.3.4.5"),
    ],
)
def test_test_with_no_hash_never_marks_an_image_that_is_not_newer(
    smp: dict[str, Any], running: str, staged: str
) -> None:
    smp["client"] = FakeClient(
        [
            FakeImage(0, running, active=True, digest=b"\xaa"),
            FakeImage(1, staged, active=False, digest=b"\xbe\xef"),
        ]
    )
    with pytest.raises(RuntimeError, match="not newer") as exc:
        fota.test()
    # It says how to do it on purpose, with the hash to do it with.
    assert "fota.test('beef')" in str(exc.value)
    assert not any("hash" in getattr(r, "kwargs", {}) for r in smp["client"].requests)


def test_test_with_no_hash_refuses_when_nothing_is_running(smp: dict[str, Any]) -> None:
    smp["client"] = FakeClient([FakeImage(1, "0.0.0.200", active=False)])
    with pytest.raises(RuntimeError, match="than the running unknown"):
        fota.test()


def test_an_older_image_is_marked_when_asked_for_by_hash(smp: dict[str, Any]) -> None:
    # Rolling back on purpose is a thing you do, so the hash is taken as meant.
    smp["client"] = FakeClient(
        [
            FakeImage(0, "0.0.0.200", active=True, digest=b"\xaa"),
            FakeImage(1, "0.0.0.100", active=False, digest=b"\xbe\xef"),
        ]
    )
    fota.test("beef")
    assert smp["client"].requests[-1].kwargs["hash"] == bytes.fromhex("beef")


def test_an_empty_hash_is_not_an_image(smp: dict[str, Any]) -> None:
    with pytest.raises(RuntimeError, match="no staged image"):
        fota.test("")


def test_test_raises_when_nothing_is_staged(smp: dict[str, Any]) -> None:
    smp["client"] = FakeClient([FakeImage(0, active=True)])
    with pytest.raises(RuntimeError, match="no staged image"):
        fota.test()


def test_confirm_keeps_the_running_image(smp: dict[str, Any]) -> None:
    fota.confirm()
    assert smp["client"].requests[-1].kwargs == {"confirm": True}


def test_reset_treats_a_missing_reply_as_success(smp: dict[str, Any]) -> None:
    # The device reboots instead of answering, so the request never completes.
    smp["client"] = FakeClient(fail=TimeoutError("no reply"))
    fota.reset()
    assert smp["transport"].disconnected is True


def test_reset_still_disconnects(smp: dict[str, Any]) -> None:
    fota.reset()
    assert smp["transport"].disconnected is True


# -- the port: both locks, and a busy port named ------------------------------


class FakeSMPTransport:
    def __init__(self, **kwargs: Any) -> None:
        self.kwargs = kwargs
        self._conn = serial.Serial()  # never opened
        self.disconnected = False

    async def disconnect(self) -> None:
        self.disconnected = True


class FakeSMPClient:
    connect_fails: ClassVar[BaseException | None] = None
    connected: ClassVar[list[float]] = []

    def __init__(self, transport: Any, port: str, timeout_s: float) -> None:
        self.port = port

    async def connect(self, connect_timeout_s: float) -> None:
        FakeSMPClient.connected.append(connect_timeout_s)
        if FakeSMPClient.connect_fails is not None:
            raise FakeSMPClient.connect_fails


@pytest.fixture
def port(monkeypatch: pytest.MonkeyPatch) -> dict[str, Any]:
    """fota._client with the transport, the probe and TIOCEXCL all faked."""
    state: dict[str, Any] = {"probes": 0, "busy_on": set(), "exclusive": []}

    class Probe:
        def close(self) -> None:
            pass

    def fake_open_port(p: str) -> Probe:
        state["probes"] += 1
        if state["probes"] in state["busy_on"]:
            raise PortBusy(f"{p} is flagged exclusive. Open right now: unoq-cpu-bars (pid 7).")
        return Probe()

    def fake_set_exclusive(s: Any) -> None:
        state["exclusive"].append(s)
        if "exclusive_fails" in state:
            raise state["exclusive_fails"]

    def fake_transport(**kwargs: Any) -> FakeSMPTransport:
        t = FakeSMPTransport(**kwargs)
        state["transport"] = t
        return t

    FakeSMPClient.connect_fails = None
    FakeSMPClient.connected = []
    monkeypatch.setattr(fota, "open_port", fake_open_port)
    monkeypatch.setattr(fota, "set_exclusive", fake_set_exclusive)
    monkeypatch.setattr(fota, "SMPSerialTransport", fake_transport)
    monkeypatch.setattr(fota, "SMPClient", FakeSMPClient)
    return state


def test_the_smp_connection_takes_both_locks(port: dict[str, Any]) -> None:
    pair: tuple[Any, Any] = asyncio.run(fota._client("/dev/ttyHS1", 5.0))
    client, transport = pair
    assert transport.kwargs["baudrate"] == 115200
    assert FakeSMPClient.connected == [5.0]
    # flock, through pyserial ...
    assert transport.kwargs["exclusive"] is True
    # ... and TIOCEXCL, on the transport's own fd.
    assert port["exclusive"] == [transport._conn]
    assert client.port == "/dev/ttyHS1"


def test_a_busy_port_is_named_before_anything_is_sent(port: dict[str, Any]) -> None:
    port["busy_on"] = {1}
    with pytest.raises(PortBusy, match="unoq-cpu-bars"):
        asyncio.run(fota._client("/dev/ttyHS1", 1.0))
    assert "transport" not in port


def test_a_port_taken_after_the_probe_is_still_named(port: dict[str, Any]) -> None:
    # smpclient retries a failed open until its timeout and then says only
    # TimeoutError. The second probe is what says who.
    port["busy_on"] = {2}
    FakeSMPClient.connect_fails = TimeoutError("Failed to connect")
    with pytest.raises(PortBusy, match="unoq-cpu-bars"):
        asyncio.run(fota._client("/dev/ttyHS1", 1.0))


def test_a_connect_timeout_with_nobody_holding_the_port_stays_a_timeout(
    port: dict[str, Any],
) -> None:
    FakeSMPClient.connect_fails = TimeoutError("Failed to connect")
    with pytest.raises(TimeoutError):
        asyncio.run(fota._client("/dev/ttyHS1", 1.0))
    assert port["probes"] == 2


def test_a_port_that_will_not_lock_is_let_go_and_reported(port: dict[str, Any]) -> None:
    port["exclusive_fails"] = OSError(errno.EPERM, "Operation not permitted")
    with pytest.raises(OSError, match="not permitted"):
        asyncio.run(fota._client("/dev/ttyHS1", 1.0))
    assert port["transport"].disconnected is True


def test_a_transport_with_no_port_inside_is_not_used_unlocked() -> None:
    # smpclient's _conn is private; if a new version moves it, say so rather
    # than carry on with only half the locking.
    with pytest.raises(RuntimeError, match="cannot lock the port"):
        fota._serial_of(object())  # type: ignore[arg-type]
