<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# Security

This project sets up a development board. It is built to be convenient on a
desk, on a network you trust, and it makes trade-offs that would be wrong on a
device you deploy. This page says what those are, so that you can decide rather
than find out.

## Reporting a problem

Use **Security → Report a vulnerability** on the repository, which sends a
private report to the maintainer. If that option is not shown, open an ordinary
issue that says you have something to report and gives no detail, and you will
be contacted.

This is one person's project, maintained in spare time. Expect an answer within
a couple of weeks rather than a couple of days.

## What you are trusting when you run it

**The checkout is trusted as root.** Several of the services `bootstrap.sh`
installs run as root and execute scripts *from the repository checkout in your
home directory* — the status LEDs, the MCU link, and the USB gadget units.
Anything that can write to that checkout can therefore run code as root at the
next boot or cable plug, without a password prompt. That includes a
`git pull`: updating the checkout changes what root runs. On a single-user
development board that is a reasonable trade for being able to edit a script
and have the board run it. It is not a design to copy onto a shared or
deployed device.

**The setup downloads and runs other people's software.** The `uv` installer,
the Zephyr SDK, Zephyr itself, Python packages and, for the quality gates, a
few pinned tools. Versions are pinned where the project can pin them; the
downloads come over HTTPS from each project's own release location.

**The firmware signature is not a secret.** Images are signed with MCUboot's
published sample key, which everyone has. The signature proves an image arrived
intact. It does not prove where it came from. See
[Updating safely](docs/learn/updating-safely.md).

**The optional web server has no authentication.** `--with-learning` serves the
documentation, and the installers on the drive image, over plain HTTP on port
8080, on every network interface the board has. It serves a read-only
filesystem and runs as an unprivileged user with a restricted sandbox, but
anyone who can reach the board can read what it serves.

**The serial console is a login.** The board's own serial console offers a
login prompt to anyone with physical access to it. See
[hardware.md](docs/reference/hardware.md).

**The board talks to the internet to see whether it can.** The status LEDs and
the USB scripts ping `1.1.1.1` and `8.8.8.8` to decide whether there is a route
out, and can fall back to those as nameservers. Every address is a setting:
[What you can change](docs/reference/configuration.md).

## What is in scope

A report is welcome for anything that makes a board less safe than the above
describes: a script that can be made to run something it should not, input
from the network or the USB link that is trusted when it should not be, a
download that could be swapped, a file left writable that root later runs.

The trade-offs listed above are known. Better ways of making them are welcome
as ordinary issues.
