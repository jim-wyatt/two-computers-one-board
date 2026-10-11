<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# The shell test suite

```bash
tools/check.sh shell        # what CI runs
bats tests/                 # just these
bats tests/bind-guard.bats  # one file
```

Shell is the largest thing in this project — several thousand lines across forty-odd
scripts, several times the Python and the C put together — and until this suite
existed it was checked only by `shellcheck` and `shfmt`. Those are linters. They
will tell you a variable is unquoted; they will never tell you the bind guard
counts wrong.

Meanwhile the Python is held at 100% branch coverage by a gate that fails the
build. That gap was the wrong way round: **nearly every finding in
[the findings log](../docs/reference/clean-board-findings.md) was in shell or in
a systemd unit.** Hardly any were in Python or C.

## How it works: no refactor, no board

The obvious way to make shell testable is to split every script into a "decide"
half and a "do" half and test the first. That is a large change to scripts that
currently work, made *before* there are any tests to catch it going wrong —
which is the wrong order.

These scripts already have a seam, because everything they actually do is
another program: `ip`, `nmcli`, `systemctl`, `logger`, `sync`. Putting a
directory of fakes at the front of `PATH` lets the **real script run,
unmodified**, while nothing reaches the board. What you assert on is the `argv`
it would have used.

```bash
stub_body ip <<'SH'
case "$1 $2" in "link show") exit 1 ;; esac   # pretend the bridge is gone
exit 0
SH

run "$PROJECT/usb/usb-route.sh" add 192.168.137.1
[ "$status" -eq 0 ]
refute ran_like 'ip route'
```

Everything else is environment variables the scripts already accept —
`UNOQ_STATE_DIR`, `UNOQ_USB_BIND_MAX_ATTEMPTS`, `UNOQ_USB_DEFAULT_ROUTE` — so a
test can point the state directory at a temporary one and set a limit of 3
without touching `/var/lib`.

> **The limit, stated plainly.** This proves what a script *decides to run*, not
> that running it has the intended effect on a kernel. `ip route replace` being
> called with the right arguments is not the same as the route existing. That
> second half is what the board is for, and no amount of this replaces it.

## What is covered, and why those first

| suite | what is at stake |
|---|---|
| [`bind-guard.bats`](bind-guard.bats) | The worst failure mode in the project. The guard exists to stop a browning-out USB bind becoming a permanent reboot loop — and if its own counting is wrong it *causes* that outage, on a board that then cannot be reached over USB to fix it. It has been wrong once already. |
| [`usb-route.bats`](usb-route.bats) | Runs as root, with an address off the wire, and moves the board's **default route** — the setting most able to break a machine remotely while leaving it looking fine. It has been wrong once already. |
| [`usb-dhcp.bats`](usb-dhcp.bats) | The address the board remembers between boots, and what it does when the computer on the other end will not give it back. |
| [`usb-profile.bats`](usb-profile.bats) | The only thing here that takes an address on somebody else's subnet without being asked. Most of what is tested is refusal. |
| [`wifi.bats`](wifi.bats) | Whether it is safe to turn off the radio you are probably connected over. It got that wrong once, by asking only IPv4. |
| [`leds.bats`](leds.bats) | The board's only output when everything else is down. A wrong color is worse than a dark board. |
| [`install-unit.bats`](install-unit.bats) | Every unit is rewritten on its way into `/etc/systemd/system`. Get it wrong and a unit installs happily, then fails at boot with a status that does not name the path. It also decides *where* a unit runs from: a unit that runs as root must name root's copies, never the checkout. |
| [`install-runtime.bats`](install-runtime.bats) | The root-owned copies of the scripts that the root services run. A stale or writable file there is something root executes at the next boot; a missing one is a service that does not start. |
| [`gadget-up.bats`](gadget-up.bats) | Which file the host is handed as the drive. Run as root's copy, a script that asks who owns it gets the answer `root`, and the drive comes up empty. |
| [`usb-net-up.bats`](usb-net-up.bats) | The script that makes a bound gadget a network link, run at every boot and plug-in. A second DHCP client on the same bridge, the board's own wifi interface dragged onto it, or whatever is in the last-address file reaching a command line. |
| [`gadget-down.bats`](gadget-down.bats) | The way back from the USB gadget, which kills what its pid files name, as root. A stale file getting an unrelated process killed. |
| [`usb-status.bats`](usb-status.bats) | The comparison between the checkout and root's copies. If it says "same" when they are not, an edit that never reached the board looks like a fix that does nothing. |
| [`cleanup.bats`](cleanup.bats) | A step that deletes things as root at the end of every run. Clearing root's `uv` cache and calling it yours, ignoring `UNOQ_KEEP_CACHES`, or reporting a change on a board with nothing to clear. |
| [`host-tools.bats`](host-tools.bats) | The first download of a fresh board failing with nothing but the name of the command, so that a full disk and a dead network look the same. |
| [`usb-handover.bats`](usb-handover.bats) | The order a stock board's doors are closed and opened in. `adbd` stopped before `sshd` is running, or by a script that is `adbd`'s own child, is a board nobody can log into; and "stopped and disabled" printed over a unit that is still running is how the MCU's serial port stayed held. |
| [`zephyr-sdk.bats`](zephyr-sdk.bats) | The first step of `bootstrap.sh` a stranger's board ever stopped at. It passed on every board it was developed on, and failed on a fresh one. |
| [`build-flash.bats`](build-flash.bats) | `zbuild` and `zflash` with nothing after them: the right app, and never the unsigned image. Also that CI can run the same script the board does. |
| [`uplink-fallback.bats`](uplink-fallback.bats) | The last automatic way back onto a network when wifi is off. Wrong one way it strands the board; wrong the other way the radio comes back on every boot. |
| [`check-links.bats`](check-links.bats) | The monthly link check files an issue with whatever it prints. If it cannot tell "no network" from "every link is dead", one bad night on a runner becomes an issue listing every link in the docs. |
| [`check-constraints.bats`](check-constraints.bats) | The gate that notices a lock file going stale. A dependency added and never pinned installs without complaint, so the gate is the only thing that would say. |
| [`lock.bats`](lock.bats) | An environment that remembers which lock file it was built to. Without it a pin moves, the board is provisioned again, every line says `ok`, and it is still running the old versions. |
| [`bootstrap.bats`](bootstrap.bats) | What `bootstrap.sh` says about the microcontroller when the firmware did not go on. Telling someone their chip is as it was, after a flash that stopped half-way, sends them looking in the wrong place. |
| [`build-image.bats`](build-image.bats) | The web server is stopped for a remount and always started again, on every exit path, and a busy mount is never forced. |

The first two were written first, because both scripts had already failed:

- udev triggered the bind unit **three times** on a healthy plug-in (once for
  the controller, once for each of the two network interfaces the gadget had
  then), so an earlier version that counted invocations hit its limit of 3
  during the first *successful* plug-in and refused to bind ever again. The
  gadget has one network interface now; the guard counts boots, not
  invocations, so the number of triggers no longer matters.
- the route metric was 500, which **beat** NetworkManager's 600 for wifi, so
  plugging the board into a computer silently handed that computer the default
  route. SSH survived, so nothing looked wrong, while `apt` and `git` stopped.

## Adding a suite

Pick by blast radius, not by line count. The question is *what happens when this
is wrong*, and the scripts worth doing next are the ones where the answer is "a
board nobody can reach".

1. `load helpers/stub` and `stub_setup` in `setup()`.
2. `stub <name>` for anything the script shells out to. Use `stub_body` when it
   needs to answer differently for different arguments.
3. Point the script's own environment variables at `$BATS_TEST_TMPDIR`.
4. **Check the test fails.** A suite that passes the first time it is run may be
   asserting nothing. Break the script on purpose, confirm the right test goes
   red, then put it back.

That last step is not optional. The suites here were each checked that way
before being committed: break the script, watch the right test go red.

5. **Write "this must not happen" as `refute`, never as `!`.**

    ```bash
    refute ran "systemctl stop adbd"      # fails the test if it ran
    ! ran "systemctl stop adbd"           # does nothing, unless it is the last line
    ```

    A test fails when one of its lines fails, and bash does not count a line
    negated with `!` as failing. So `! something` in the middle of a test
    passes whatever happened. Thirty-seven assertions here were written that
    way, and step 4 did not catch them, because a test with several
    assertions still goes red when a *different* one of them trips.
    `refute`, in `helpers/stub.bash`, is an ordinary command that returns 1.
