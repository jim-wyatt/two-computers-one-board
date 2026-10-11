# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""Tests for the learning-content web server.

Unlike the rest of the suite these talk to a real socket - but only to
127.0.0.1 on an ephemeral port, so they need no hardware and no network. The
server is the one component here whose whole job is I/O; testing it against a
fake socket would be testing the fake.
"""

from __future__ import annotations

import threading
import urllib.error
import urllib.request
from collections.abc import Iterator
from http.server import ThreadingHTTPServer
from pathlib import Path
from typing import Any

import pytest

from unoq import learn


@pytest.fixture
def served(tmp_path: Path) -> Iterator[tuple[ThreadingHTTPServer, str]]:
    """A server on a real ephemeral port, serving tmp_path, torn down after."""
    (tmp_path / "index.html").write_text("<h1>hello board</h1>")
    (tmp_path / "vscode").mkdir()
    (tmp_path / "vscode" / "code.deb").write_bytes(b"not really a deb")

    server = learn.make_server(tmp_path, "127.0.0.1", 0)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    try:
        yield server, base
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


# -- make_server ------------------------------------------------------------


def test_serves_the_index(served: tuple[ThreadingHTTPServer, str]) -> None:
    _, base = served
    with urllib.request.urlopen(f"{base}/", timeout=5) as r:
        assert r.status == 200
        assert b"hello board" in r.read()


def test_serves_a_binary_from_a_subdirectory(served: tuple[ThreadingHTTPServer, str]) -> None:
    _, base = served
    with urllib.request.urlopen(f"{base}/vscode/code.deb", timeout=5) as r:
        assert r.read() == b"not really a deb"


def test_responses_are_not_cached(served: tuple[ThreadingHTTPServer, str]) -> None:
    # The board's clock is usually wrong, so a validator-based cache misfires.
    _, base = served
    with urllib.request.urlopen(f"{base}/", timeout=5) as r:
        assert r.headers["Cache-Control"] == "no-store"


def test_missing_paths_are_404_not_a_crash(served: tuple[ThreadingHTTPServer, str]) -> None:
    _, base = served
    with pytest.raises(urllib.error.HTTPError) as exc:
        urllib.request.urlopen(f"{base}/nope.html", timeout=5)
    assert exc.value.code == 404


def test_make_server_rejects_a_root_that_is_not_a_directory(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError, match="not a directory"):
        learn.make_server(tmp_path / "does-not-exist", "127.0.0.1", 0)


def test_request_logging_goes_to_stdout(
    served: tuple[ThreadingHTTPServer, str], capfd: pytest.CaptureFixture[str]
) -> None:
    # Under systemd, stderr reads as a fault; a page load is not one.
    _, base = served
    with urllib.request.urlopen(f"{base}/", timeout=5):
        pass
    out, err = capfd.readouterr()
    assert "GET /" in out
    assert "GET /" not in err


# -- addresses --------------------------------------------------------------


def test_addresses_are_urls_on_the_given_port() -> None:
    for url in learn.addresses(1234):
        assert url.startswith("http://")
        assert url.endswith(":1234/")


def test_addresses_survives_a_host_with_no_resolvable_name(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # A board with no network at all must still start and say so, not raise.
    def boom(*_a: object, **_k: object) -> None:
        raise OSError("no address associated with hostname")

    # Patched by dotted path: unoq.learn does not re-export socket, so reaching
    # through the module attribute is not something mypy will accept.
    monkeypatch.setattr("unoq.learn.socket.getaddrinfo", boom)
    assert learn.addresses(8080) == []


def _resolving_to(*addrs: str) -> Any:
    """A getaddrinfo stub returning `addrs`, in getaddrinfo's 5-tuple shape."""

    def fake(*_a: object, **_k: object) -> list[tuple[Any, ...]]:
        return [(2, 1, 6, "", (a, 0)) for a in addrs]

    return fake


def test_addresses_drops_the_loopback_answer(monkeypatch: pytest.MonkeyPatch) -> None:
    # THE bug this filter exists for. With no external address configured,
    # nss-myhostname answers the local hostname with 127.0.0.2 - documented
    # behavior - and it used to be printed as the address to browse to.
    monkeypatch.setattr("unoq.learn.socket.getaddrinfo", _resolving_to("127.0.0.2"))
    assert learn.addresses(8080) == []


def test_addresses_drops_link_local(monkeypatch: pytest.MonkeyPatch) -> None:
    # 169.254.x means DHCP failed. That is a symptom, not somewhere to browse.
    monkeypatch.setattr("unoq.learn.socket.getaddrinfo", _resolving_to("169.254.3.4"))
    assert learn.addresses(8080) == []


def test_addresses_keeps_every_real_address(monkeypatch: pytest.MonkeyPatch) -> None:
    # Both of the board's, as seen in USB gadget mode: the static one and the
    # address the host leases over ICS. Enumerating interfaces with SIOCGIFADDR
    # would have returned only the first - it reports an interface's PRIMARY
    # address - which is why resolving the hostname is kept.
    monkeypatch.setattr(
        "unoq.learn.socket.getaddrinfo",
        _resolving_to("127.0.0.2", "10.55.0.1", "192.168.137.210"),
    )
    assert learn.addresses(8080) == [
        "http://10.55.0.1:8080/",
        "http://192.168.137.210:8080/",
    ]


def test_addresses_does_not_repeat_itself(monkeypatch: pytest.MonkeyPatch) -> None:
    # getaddrinfo returns one row per socket type, so the same address arrives
    # three times. The real board's resolution does exactly this.
    monkeypatch.setattr("unoq.learn.socket.getaddrinfo", _resolving_to("10.55.0.1", "10.55.0.1"))
    assert learn.addresses(8080) == ["http://10.55.0.1:8080/"]


# -- main -------------------------------------------------------------------


def test_main_reports_a_missing_root(capsys: pytest.CaptureFixture[str]) -> None:
    assert learn.main(["--root", "/definitely/not/here"]) == 1
    assert "nothing to serve" in capsys.readouterr().err


def test_main_reports_a_port_it_cannot_bind(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    def boom(*_a: object, **_k: object) -> None:
        raise OSError("Address already in use")

    monkeypatch.setattr(learn, "make_server", boom)
    assert learn.main(["--root", str(tmp_path)]) == 1
    assert "cannot bind" in capsys.readouterr().err


def test_main_serves_then_exits_cleanly_on_interrupt(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """Ctrl-C is how you stop it, so it must exit 0 and still close the socket."""
    closed: list[bool] = []

    class FakeServer:
        server_address = ("0.0.0.0", 8080)

        def serve_forever(self) -> None:
            raise KeyboardInterrupt

        def server_close(self) -> None:
            closed.append(True)

    def fake_make_server(*_a: object, **_k: object) -> Any:
        return FakeServer()

    monkeypatch.setattr(learn, "make_server", fake_make_server)
    monkeypatch.setattr(learn, "addresses", lambda _p: ["http://10.55.0.1:8080/"])
    assert learn.main(["--root", str(tmp_path)]) == 0
    assert closed == [True]
    assert "serving" in capsys.readouterr().out


def test_main_says_so_when_it_has_no_address_to_offer(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """An empty list is normal, and silence would read as "it did not look".

    The USB link gets its address when a host is plugged in, which can be long
    after this starts. Saying nothing is better than a loopback URL, but worse
    than saying why there is nothing.
    """

    class FakeServer:
        server_address = ("0.0.0.0", 8080)

        def serve_forever(self) -> None:
            raise KeyboardInterrupt

        def server_close(self) -> None:
            pass

    monkeypatch.setattr(learn, "make_server", lambda *_a, **_k: FakeServer())
    monkeypatch.setattr(learn, "addresses", lambda _p: [])
    assert learn.main(["--root", str(tmp_path)]) == 0
    out = capsys.readouterr().out
    assert "no external address found" in out
    assert "http://127." not in out


def test_default_root_is_the_mount_not_the_staging_directory() -> None:
    """These are two different things and the names are one character apart.

    /srv/unoq-share is the read-only mount of the FAT32 image - what the drive
    exports and what the web server must serve. /var/lib/unoq-share is the
    staging directory share/fetch-vscode.sh writes into, which does not exist
    on a board that has only been provisioned.

    The default used to be the staging path. Nothing caught it because
    unoq-learn.service passes --root explicitly, so the wrong default was only
    ever reachable by running the server by hand.
    """
    assert learn.DEFAULT_ROOT == "/srv/unoq-share"


def test_the_unit_file_agrees_with_the_default() -> None:
    """The unit passing --root is what hid the bug. Now the two are held equal,
    so changing either alone fails here rather than diverging silently."""
    unit = Path(__file__).resolve().parents[1] / "unoq-learn.service"
    execstart = next(
        line for line in unit.read_text().splitlines() if line.startswith("ExecStart=")
    )
    assert f"--root {learn.DEFAULT_ROOT}" in execstart
