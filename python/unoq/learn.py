# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""
Static web server for the on-board learning content.

    unoq-learn                         # serve /srv/unoq-share on :8080
    python -m unoq.learn --root ./share --port 9000
    unoq-learn --data /var/lib/unoq/templog   # ...and that directory at /data/

The board is often the only computer in the room with the material on it - it
is plugged into a laptop that may have no internet at all. So this serves from
disk, has no dependencies outside the standard library, and never fetches
anything: a page that needs a CDN is a page that is blank exactly when you
need it.

It is deliberately read-only and unauthenticated. It is reachable over the USB
link (and whatever else the board is on), so treat it as public to anyone who
can plug in a cable - do not put anything here you would not hand out.

`--data` adds a second directory beside the root, at /data/: what the board
records as it runs (the temperature log, unoq.templog), as opposed to what it
was built with. The share image is read-only and rebuilt only at
provisioning, so a log cannot live in it. The same rules hold there: read-only,
and nothing outside the directory can be reached through it.
"""

from __future__ import annotations

import argparse
import contextlib
import ipaddress
import posixpath
import socket
import sys
import urllib.parse
from collections.abc import Callable
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

# The read-only mount of the FAT32 image, which is also what the USB drive
# exports - so the web page and the drive can never disagree. NOT
# /var/lib/unoq-share: that is the STAGING directory share/fetch-vscode.sh
# writes into and share/build-image.sh builds the image from, and it does not
# exist on a board that has only ever been provisioned. This default was that
# staging path, which nothing noticed because unoq-learn.service passes --root
# explicitly - so only someone running the server by hand ever saw it, and what
# they saw was an empty directory or an error.
DEFAULT_ROOT = "/srv/unoq-share"
DEFAULT_PORT = 8080
# Every interface: the point is to be reachable over the USB gadget link, whose
# address the board does not know until a host is plugged in.
DEFAULT_HOST = "0.0.0.0"
# Where --data appears. A directory of that name in the root is hidden by it.
DATA_PREFIX = "/data"


def data_path(path: str) -> str | None:
    """The part of a request path below /data/, or None if it is not below it.

    Decided on the path as the base class will see it - decoded, with `..`
    resolved - so that /data/../index.html is the root's index and
    /%64ata/x is /data/x. What is returned is quoted again, because the base
    class decodes it a second time: unquoted, a name that contains `%41`
    would be served as the file called `A`.
    """
    path = path.split("?", 1)[0].split("#", 1)[0]
    trailing = path.endswith("/")
    normal = posixpath.normpath(urllib.parse.unquote(path))
    if normal != DATA_PREFIX and not normal.startswith(DATA_PREFIX + "/"):
        return None
    rest = normal[len(DATA_PREFIX) :] or "/"
    if trailing and not rest.endswith("/"):
        rest += "/"
    return urllib.parse.quote(rest)


class QuietHandler(SimpleHTTPRequestHandler):
    """Serve a directory, logging one line per request to stdout.

    SimpleHTTPRequestHandler writes to stderr in a format of its own; under
    systemd that lands in the journal as an error stream, which makes a normal
    page load look like a fault. Routing it to stdout keeps `journalctl` honest
    about what is and is not a problem.

    With `data`, requests under /data/ are served from that directory instead
    of the root. Only the routing is new: the base class's translate_path,
    which drops `..` and anything with a separator in it, still builds every
    path, so nothing outside either directory can be named.
    """

    def __init__(self, *args: Any, data: str | None = None, **kwargs: Any) -> None:
        # Before super().__init__, which handles the request there and then.
        self.data = data
        super().__init__(*args, **kwargs)

    def translate_path(self, path: str) -> str:
        data = self.data
        rest = None if data is None else data_path(path)
        if data is None or rest is None:
            return super().translate_path(path)
        root = self.directory
        self.directory = data
        try:
            return super().translate_path(rest)
        finally:
            self.directory = root

    # Sent on every response. The content is static and the board's clock is
    # often wrong (no battery-backed RTC), so a validator-based cache would
    # misfire; telling the browser not to cache at all is the honest answer.
    def end_headers(self) -> None:
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    # The parameter is named `format` because that is the base class's
    # signature; renaming it would silently stop overriding the method.
    def log_message(self, format: str, *args: object) -> None:
        print(f"{self.address_string()} {format % args}", flush=True)


def make_server(
    root: str | Path = DEFAULT_ROOT,
    host: str = DEFAULT_HOST,
    port: int = DEFAULT_PORT,
    data: str | Path | None = None,
) -> ThreadingHTTPServer:
    """Build a server rooted at `root`, bound but not yet serving.

    Binding here rather than inside serve() is what lets a test ask for port 0
    and then find out which port it actually got.

    `data` need not exist yet. The unit always names the temperature log's
    directory, and on a board without the logger, or before its first start,
    /data/ is a 404 rather than a server that will not start.
    """
    path = Path(root).expanduser()
    if not path.is_dir():
        raise FileNotFoundError(f"{path} is not a directory - nothing to serve")
    extra = None if data is None else str(Path(data).expanduser())
    handler: Callable[..., SimpleHTTPRequestHandler] = partial(
        QuietHandler, directory=str(path), data=extra
    )
    # Threading, so one slow client fetching a 120 MB installer does not block
    # the page load behind it. allow_reuse_address so a restart does not have
    # to wait out TIME_WAIT on a board you are iterating on.
    ThreadingHTTPServer.allow_reuse_address = True
    return ThreadingHTTPServer((host, port), handler)


def addresses(port: int) -> list[str]:
    """Best-effort list of URLs this board is reachable on.

    Purely informational - it is printed at startup so you can read the address
    off the console instead of guessing what the USB link came up as.

    LOOPBACK IS FILTERED, because the resolver has a documented way of handing
    back 127.0.0.2 that looks exactly like a real answer. nss-myhostname
    resolves the local hostname by asking the kernel over a netlink socket; if
    it cannot - no addresses configured, or the caller is sandboxed away from
    AF_NETLINK, which is what bit unoq-learn.service - it answers 127.0.0.2.

    A loopback URL is worse than no URL: it is the line someone reads to find
    out where to point a browser, and it looks like it worked. Filtering here
    is the belt to the unit's braces; neither alone is enough, because the unit
    fixes only this caller and the filter cannot invent an address.

    Resolving the hostname is kept deliberately. It is tempting to enumerate
    interfaces instead, but SIOCGIFADDR returns only an interface's PRIMARY
    address: br-usb can hold a link-local address as well as the one the host
    leases over ICS, and that ioctl silently drops the leased one - which is
    the address a Windows user actually needs. getaddrinfo returns both.
    """
    urls = []
    with contextlib.suppress(OSError):  # no network at all is not an error here
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            addr = info[4][0]
            # Link-local goes too: 169.254.x is what you get when DHCP failed,
            # so it is a symptom rather than somewhere to point a browser.
            parsed = ipaddress.ip_address(addr)
            if parsed.is_loopback or parsed.is_link_local:
                continue
            url = f"http://{addr}:{port}/"
            if url not in urls:
                urls.append(url)
    return urls


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="unoq-learn",
        description="Serve the on-board learning content and installers over HTTP.",
    )
    parser.add_argument("--root", default=DEFAULT_ROOT, help="directory to serve")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="TCP port")
    parser.add_argument("--host", default=DEFAULT_HOST, help="address to bind")
    parser.add_argument(
        "--data", default=None, help=f"a second directory to serve, at {DATA_PREFIX}/"
    )
    args = parser.parse_args(argv)

    try:
        server = make_server(args.root, args.host, args.port, data=args.data)
    except FileNotFoundError as exc:
        print(f"unoq-learn: {exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        # Almost always "address already in use" - worth saying plainly rather
        # than as a traceback in the journal.
        print(f"unoq-learn: cannot bind {args.host}:{args.port}: {exc}", file=sys.stderr)
        return 1

    bound = server.server_address[1]
    print(f"serving {args.root} on port {bound}", flush=True)
    if args.data is not None:
        print(f"serving {args.data} at {DATA_PREFIX}/", flush=True)
    found = addresses(bound)
    for url in found:
        print(f"  {url}", flush=True)
    if not found:
        # Say why, rather than nothing. An empty list is normal on a board with
        # nothing plugged in, and silence reads as "it did not bother to look".
        print("  no external address found - serving anyway", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass  # Ctrl-C and SIGINT are how you stop this, not failures.
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
