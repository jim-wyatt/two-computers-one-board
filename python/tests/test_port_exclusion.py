# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""The port-exclusion path: who gets /dev/ttyHS1, and what you are told if not.

Nothing here opens a real tty. `open_port` is a thin wrapper over
`serial.Serial` plus one ioctl, so the interesting behavior is entirely in
which exception comes out and what it says - and that is exactly the part that
has never been covered.

WHY THIS SUITE EXISTS
---------------------
The port had a comment promising kernel-enforced exclusion (TIOCEXCL) sitting
above a call that only took an advisory flock. The promise was wrong for as
long as it had been written, and no test could have noticed, because no test
ever exercised a failed open. These do.
"""

from __future__ import annotations

import builtins
import errno
from typing import Any

import pytest
import serial

from unoq import mcu


def _serial_exc(err: int) -> serial.SerialException:
    """A SerialException shaped like the ones pyserial actually raises."""
    return serial.SerialException(err, f"could not open port: [Errno {err}]")


@pytest.fixture
def no_ioctl(monkeypatch: pytest.MonkeyPatch) -> list[tuple[int, int]]:
    """Record TIOCEXCL attempts instead of making them."""
    calls: list[tuple[int, int]] = []

    def fake_ioctl(fd: int, request: int, *a: Any) -> int:
        calls.append((fd, request))
        return 0

    monkeypatch.setattr("unoq.mcu.fcntl.ioctl", fake_ioctl)
    return calls


class _FakePort:
    def __init__(self) -> None:
        self.closed = False

    def fileno(self) -> int:
        return 42

    def close(self) -> None:
        self.closed = True


# --- the happy path --------------------------------------------------------


def test_open_port_sets_tiocexcl(
    monkeypatch: pytest.MonkeyPatch, no_ioctl: list[tuple[int, int]]
) -> None:
    """The whole point: a successful open is followed by the kernel lock.

    This is the regression test for the bug that started this - exclusive=True
    alone is advisory, and every non-pyserial reader walked through it.
    """
    monkeypatch.setattr(serial, "Serial", lambda *a, **k: _FakePort())
    mcu.open_port("/dev/ttyfake", 115200, 0.3)
    assert no_ioctl == [(42, mcu.TIOCEXCL)]


def test_open_port_still_asks_for_the_flock(
    monkeypatch: pytest.MonkeyPatch, no_ioctl: list[tuple[int, int]]
) -> None:
    """Both locks, not one. The flock catches another pyserial caller before
    the open even completes; TIOCEXCL catches everyone else afterwards."""
    seen: dict[str, Any] = {}

    def fake_serial(*a: Any, **k: Any) -> _FakePort:
        seen.update(k)
        return _FakePort()

    monkeypatch.setattr(serial, "Serial", fake_serial)
    mcu.open_port("/dev/ttyfake", 115200, 0.3)
    assert seen["exclusive"] is True


def test_a_tty_that_refuses_tiocexcl_still_opens(monkeypatch: pytest.MonkeyPatch) -> None:
    """Degrade, do not refuse. Losing the ability to exclude `tio` is worse
    than nothing; losing the link entirely is worse than that."""
    monkeypatch.setattr(serial, "Serial", lambda *a, **k: _FakePort())

    def boom(*a: Any) -> int:
        raise OSError(errno.ENOTTY, "not a tty")

    monkeypatch.setattr("unoq.mcu.fcntl.ioctl", boom)
    assert mcu.open_port("/dev/ttyfake", 115200, 0.3) is not None


# --- the failure paths -----------------------------------------------------


@pytest.mark.parametrize("err", [errno.EBUSY, errno.EAGAIN, errno.EWOULDBLOCK])
def test_contended_open_raises_portbusy(monkeypatch: pytest.MonkeyPatch, err: int) -> None:
    """EBUSY comes from TIOCEXCL, EAGAIN from the flock. Both mean the same
    thing to a user and must not surface as a raw errno."""

    def refuse(*a: Any, **k: Any) -> None:
        raise _serial_exc(err)

    monkeypatch.setattr(serial, "Serial", refuse)
    monkeypatch.setattr(mcu, "port_holders", lambda p=None: [])
    with pytest.raises(mcu.PortBusy):
        mcu.open_port("/dev/ttyfake", 115200, 0.3)


def test_unrelated_serial_errors_are_not_swallowed(monkeypatch: pytest.MonkeyPatch) -> None:
    """A missing device is not a busy device, and calling it one would send
    someone hunting for a process that does not exist."""

    def refuse(*a: Any, **k: Any) -> None:
        raise _serial_exc(errno.ENOENT)

    monkeypatch.setattr(serial, "Serial", refuse)
    with pytest.raises(serial.SerialException) as caught:
        mcu.open_port("/dev/ttyfake", 115200, 0.3)
    assert not isinstance(caught.value, mcu.PortBusy)


# --- what the message says -------------------------------------------------


def test_message_names_the_holder_and_the_remedy() -> None:
    msg = mcu._busy_message("/dev/ttyHS1", [(1234, "unoq-cpu-bars")])
    assert "unoq-cpu-bars" in msg
    assert "1234" in msg
    assert "systemctl stop unoq-cpu-bars" in msg


def test_message_does_not_blame_the_holder_for_setting_the_flag() -> None:
    """The holder is often an innocent bystander that merely keeps the tty
    open while something else's TIOCEXCL outlives it. Saying otherwise sends
    people to fix the wrong thing."""
    msg = mcu._busy_message("/dev/ttyHS1", [(1234, "unoq-cpu-bars")])
    # Both halves of the disclaimer, because a mutation that deleted only the
    # first one slipped past an earlier version of this test that checked only
    # the second.
    assert "not claiming" in msg
    assert "innocent bystander" in msg


def test_message_explains_the_sticky_flag_when_nothing_is_visible() -> None:
    """The trap: run `tio`, kill it, and the flag outlives it because a
    long-lived reader still holds the tty. `lsof` then shows nothing that
    explains the EBUSY, which is the single most confusing state this port
    gets into."""
    msg = mcu._busy_message("/dev/ttyHS1", [])
    assert "LAST close" in msg
    assert "systemctl restart unoq-cpu-bars" in msg
    assert "lsof" in msg


# --- holder discovery ------------------------------------------------------


def test_port_holders_finds_our_own_open_file(tmp_path: Any) -> None:
    """Exercised against a real fd on a real path, because the /proc walk is
    the kind of code that looks right and reads nothing."""
    target = tmp_path / "pretend-tty"
    target.write_text("")
    with open(target) as fh:  # noqa: F841 - held open for the duration
        holders = mcu.port_holders(str(target))
    assert holders, "the /proc walk did not find a file this process has open"


def test_port_holders_returns_empty_for_an_unheld_path(tmp_path: Any) -> None:
    target = tmp_path / "nobody-has-this"
    target.write_text("")
    assert mcu.port_holders(str(target)) == []


def test_port_holders_survives_a_process_exiting_mid_scan(
    tmp_path: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The /proc walk races every process on the machine by construction: a pid
    can vanish between listing its fds and reading its name. The holder is
    still reported, just without a name - losing the whole diagnosis because
    one unrelated process exited would be much worse."""
    target = tmp_path / "pretend-tty"
    target.write_text("")
    # builtins.open, not mcu.open: the module has no `open` attribute of its
    # own until this test creates one, so reading it first is an AttributeError.
    real_open = builtins.open

    def flaky_open(path: Any, *a: Any, **k: Any) -> Any:
        if str(path).startswith("/proc/") and str(path).endswith("/comm"):
            raise OSError(errno.ESRCH, "no such process")
        return real_open(path, *a, **k)

    monkeypatch.setattr(mcu, "open", flaky_open, raising=False)
    with open(target):
        holders = mcu.port_holders(str(target))
    assert holders
    assert holders[0][1] == "?"


def test_an_unexpected_ioctl_error_is_not_swallowed(monkeypatch: pytest.MonkeyPatch) -> None:
    """EBADF from the TIOCEXCL ioctl means a bug, not an unusual tty. Ignoring
    it would leave us holding an advisory-only lock believing it was enforced -
    which is precisely the failure this whole module was changed to end."""
    port = _FakePort()
    monkeypatch.setattr(serial, "Serial", lambda *a, **k: port)

    def boom(*a: Any) -> int:
        raise OSError(errno.EBADF, "bad file descriptor")

    monkeypatch.setattr("unoq.mcu.fcntl.ioctl", boom)
    with pytest.raises(OSError, match="bad file descriptor"):
        mcu.open_port("/dev/ttyfake", 115200, 0.3)
    assert port.closed, "the port was left open after a failed exclusive claim"


def test_port_holders_survives_an_unreadable_proc(monkeypatch: pytest.MonkeyPatch) -> None:
    """This only ever runs while explaining an ALREADY failed open. Raising
    here would replace "the port is busy, here is who has it" with an
    unrelated errno about /proc - the diagnosis lost to the code meant to
    produce it."""

    def no_proc(path: str) -> list[str]:
        raise PermissionError(errno.EACCES, "nope")

    monkeypatch.setattr("unoq.mcu.os.listdir", no_proc)
    assert mcu.port_holders("/dev/ttyHS1") == []


def test_a_busy_message_is_still_produced_without_proc(monkeypatch: pytest.MonkeyPatch) -> None:
    """The end-to-end version of the above: a contended open must still raise
    PortBusy with a usable message when /proc cannot be read at all."""

    def refuse(*a: Any, **k: Any) -> None:
        raise _serial_exc(errno.EBUSY)

    def no_proc(path: str) -> list[str]:
        raise PermissionError(errno.EACCES, "nope")

    monkeypatch.setattr(serial, "Serial", refuse)
    monkeypatch.setattr("unoq.mcu.os.listdir", no_proc)
    with pytest.raises(mcu.PortBusy, match="flagged exclusive"):
        mcu.open_port("/dev/ttyfake", 115200, 0.3)
