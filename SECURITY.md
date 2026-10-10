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

**Provisioning is trusted as root; the checkout, by itself, is not.** Six of
the services `bootstrap.sh` installs run as root: the status LEDs, the MCU
link, and the four USB gadget units. They do not execute the repository
checkout in your home directory. Each provisioning step that installs one
first copies the scripts root runs into `/usr/local/lib/unoq/`, owned by root
and writable by nobody else, and the units name those copies. Editing a file
in the checkout, a `git pull` or a branch switch therefore changes nothing
that root runs.

What does change it is running a provisioning step or `bootstrap.sh` again,
which you do with `sudo`. That is the gate: at that moment whatever is in the
checkout is copied and becomes what root runs at the next boot or cable plug,
and the step prints a `changed  updated …` line for each script it replaced.
So the checkout is still trusted *when you provision from it*. Look at what
you pulled before you re-run a step, as you would before running any script
with `sudo`.

Three things this does not cover, so that you know:

- The two services that run from the Python environment (`unoq-cpu-bars` and
  `unoq-learn`) still run from the checkout. They run as you, not as root.
- Commands you run yourself with `sudo` from the checkout
  (`sudo usb/wifi.sh off`, `sudo bash share/build-image.sh`) run that copy as
  root. That is your decision each time, with your password.
- A board set up before this arrangement keeps its old units until each step
  that installed them is run again. Every step ends by naming any that are
  left. See [Provisioning](docs/reference/provisioning.md#what-root-runs).

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
