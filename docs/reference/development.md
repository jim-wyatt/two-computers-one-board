<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# Working on this project

How to change this repository without breaking a board: where things are, the
checks every change has to pass, and the maintenance jobs that are nobody's
favourite.

The reasoning behind the checks is the chapter
[Knowing it works](../learn/knowing-it-works.md). This page is the detail.

## Where things are

```
├── bootstrap.sh            stock board -> working board, one command
├── env.sh                  shell shortcuts + Zephyr environment (sourced by ~/.bashrc)
├── mkdocs.yml              the documentation site: theme, navigation, offline rules
├── docs/
│   ├── learn/              the course, in reading order
│   └── reference/          the detail, for someone who already knows
├── mcu/                    everything for the STM32U585
│   ├── app/                the firmware: shell + SMP + NVS + LED matrix
│   │   ├── include/        app_proto.h - the MPU<->MCU contract, shared
│   │   └── src/            main.c, matrix.c (charlieplex driver), bars.c (rasteriser)
│   ├── tests/              ztest suites, run on the host with native_sim
│   ├── board-support/      the OpenOCD configuration that names this board's SWD pins
│   ├── zbuild.sh           west build + sign + compile_commands
│   ├── flash.sh            flash over SWD
│   ├── flash-all.sh        bootloader + application, for first flash and recovery
│   ├── ztest.sh            the firmware tests
│   ├── link-up.sh          BOOT0 + serial-link enable (unoq-link.service runs root's copy)
│   └── restore-arduino-firmware.sh
├── python/                 the Linux-side package (an editable install)
│   ├── unoq/               link.py (GPIOs), mcu.py (shell), fota.py,
│   │                       cpu.py (/proc/stat), cpubars.py + learn.py (daemons)
│   └── tests/              pytest, all against fakes - no hardware
├── provision/              what bootstrap.sh runs; see provisioning.md
│   ├── lib.sh              the primitives that make every step idempotent
│   └── user/               the half that must not run as root
├── usb/                    the composite USB gadget: network + fileshare (the services run root's copies)
├── status/                 the status LEDs Linux can drive, and their unit (likewise)
├── share/                  the drive image the board hands out
├── tests/                  bats suites for the shell scripts
└── tools/                  check.sh (every gate), and the maintenance scripts
```

Two paths are load-bearing inside a checkout and must not move: `python/` (the
editable install target) and `provision/lib.sh` (every script sources it by
relative path). `env.sh` and the scripts named in unit files may move *with*
the checkout — `provision/user/50-shell-env.sh` repoints `~/.bashrc`, and
`install_unit` rewrites the unit paths — but not independently of it.

## Trying a script change on the board

The services that run as root do not run the scripts in the checkout. They run
root-owned copies in `/usr/local/lib/unoq/`, which a provisioning step makes.
The reason is in [What root runs](provisioning.md#what-root-runs). The
consequence is one extra command.

After editing anything under `usb/`, `status/leds.sh` or `mcu/link-up.sh`:

```bash
sudo bash ~/two-computers-one-board/provision/35-status-leds.sh
```

Any of steps `30`, `35` and `60` refreshes every copy, and `35` is the one
that touches nothing else. It prints `changed  updated …` for each script it
replaced, and restarts the LED service if anything changed. When the change
takes effect depends on the script:

| You edited | It takes effect |
|---|---|
| `status/leds.sh` | at once: step `35` restarts `unoq-leds` |
| `usb/usb-dhcp.sh`, `usb-route.sh`, `usb-profile.sh` | at the next lease event |
| `usb/gadget-up.sh`, `usb-net-up.sh`, `bind-guard.sh` | at the next cable plug or boot |
| `usb/gadget-down.sh`, `uplink-fallback.sh` | at the next stop or boot |
| `mcu/link-up.sh` | at the next boot |

To put a USB change into effect at once, run `60-usb-gadget.sh` instead. It
restarts the gadget, which drops the USB network for a few seconds.

If the board is not doing what the script you are looking at says, compare the
two copies:

```bash
~/two-computers-one-board/usb/status.sh      # the section "what root runs"
```

The bats suites and `tools/check-units.sh` test the scripts in the checkout
and need none of this.

Two things did not change. A unit that runs as you (`unoq-cpu-bars`,
`unoq-learn`) runs the editable Python install, so a Python edit needs only
`sudo systemctl restart <unit>`. And a script you run by hand runs the copy
you name.

## The quality gates

One command runs everything, and it is the same command CI runs:

```bash
tools/check.sh              # every gate
tools/check.sh --fast       # skip the slow ones: the firmware tests and the browser check
tools/check.sh --fix        # reformat in place, then check
tools/check.sh python       # one area: python | shell | c | docs | workflows | diagrams | mcu
```

Gates keep running after a failure, so one pass shows you all the work rather
than the first thing to break. A missing tool is a failure, not a skip: a gate
that silently does nothing is worse than no gate.

| Area | Gate | Tool | Covers |
|---|---|---|---|
| `python` | lint, format | `ruff` | `python/` |
| | types | `mypy --strict` | `python/`, tests included |
| | tests | `pytest` + coverage | `python/unoq`, held at **100%** of branches |
| `shell` | lint | `shellcheck -x` | every tracked `*.sh` |
| | format | `shfmt -i 2 -ci` | every tracked `*.sh` |
| | behaviour | `bats` | `tests/*.bats` — see [the suite's own guide](../../tests/README.md) |
| | units | `tools/check-units.sh` | systemd accepts every unit file and udev rule as provisioning would install them, and everything they start exists — for a root unit, in the set of scripts that is copied for root |
| `c` | version pin | `tools/check-zephyr-pin.sh` | the board and CI build the same Zephyr |
| | format | `clang-format` | `mcu/**/*.[ch]`, in Zephyr's own style |
| `docs` | build | `mkdocs --strict` | every internal link and anchor resolves |
| | offline | `tools/check-diagram-assets.sh` | the diagram library is on disk, not at a CDN |
| | settings | `tools/check-config-docs.sh` | [What you can change](configuration.md) names every setting the code reads |
| | site inputs | `tools/check-site-inputs.sh` | no page embeds a file the site's path filters do not watch |
| `workflows` | lint | `actionlint` | `.github/workflows/`, including the shell inside every `run:` block |
| `diagrams` | render | `tools/check-diagrams.sh` | every diagram actually draws, and can be read: lettering displayed at 12px or more and no diagram wider than the text column, in a 1440px window. One headless browser, driven over every page that has one, a few seconds |
| `mcu` | tests | `ztest` on `native_sim` | the protocol in `app_proto.h` and the rasteriser in `bars.c` |

Install the tools, and the pre-commit hook that runs `--fast`:

```bash
tools/install-dev-tools.sh       # no sudo, no apt
tools/install-hooks.sh           # pre-commit -> check.sh --fast
```

`install-dev-tools.sh` puts ruff, mypy, pytest, mkdocs and clang-format in the
project venv, and fetches pinned `shellcheck`, `shfmt`, `bats` and `actionlint` into
`~/.local/bin`. It detects the architecture, so the same script works on the
board (aarch64) and on an ordinary x86_64 machine. You do not need a board for
any of them: `mcu` wants a Zephyr workspace and `diagrams` wants a browser,
and the rest want nothing.

> [!NOTE]
> The `pre-commit` framework is deliberately not used. It fetches its own pinned
> copies of ruff and shellcheck: a second toolchain to keep in step with the one
> `check.sh` uses, on a board with 3.6 GiB of RAM.

## The tests

```bash
(cd python && ../.venv/bin/pytest)                         # the Linux-side package
(cd python && ../.venv/bin/pytest -m hardware --no-cov)    # opt-in: needs a live MCU
bats tests/                                                # the shell scripts
mcu/ztest.sh                                               # the firmware, on native_sim
```

**Nothing in the default suites touches hardware.** Every serial port, GPIO
chip and system command is faked, because the suites have to be runnable on a
board that is mid-flash — and on a laptop with no board at all — and a test
that quietly drove the real BOOT0 line would be worse than no test.

Three Python suites are not about behaviour at all. They pin facts that have no
other source of truth:

- **The GPIO line numbers** (`test_link.py`). Nothing upstream records them. A
  "tidy up" has nothing to check against except that test.
- **The unsigned-image guard** (`test_fota.py`). Getting it wrong stops the
  board booting.
- **The panel constants** (`test_contract.py`). C macros cannot be imported
  into Python, so `unoq/mcu.py` holds a second copy of the LED matrix geometry.
  That test parses `app_proto.h` and fails if the two drift, which is what
  makes the duplication safe to have.

Coverage of `python/unoq` gates at 100%. That is a ratchet, not a boast — new
code needs a test — and it is one line in `pyproject.toml` if you want it
lower.

The shell suites run the *real* scripts with fake commands at the front of
`PATH`. [tests/README.md](../../tests/README.md) explains how, what that does
and does not prove, and how to add one.

## CI

[`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) runs on every push
to `main` and every pull request.

| Job | What it does |
|---|---|
| `checks` | `tools/check.sh python shell c docs workflows`. Fast, so a missing comma fails in seconds rather than behind a toolchain download. |
| `changes` | Decides what a change touched, on a pull request and on the push that merges it, so the two jobs below run only when something they test has moved. When it cannot tell, it says everything. |
| `diagrams` | `tools/check.sh diagrams`, in a `chrome-headless-shell` pinned by version and hash rather than whatever browser the runner image ships. Skipped when nothing the site is built from changed. |
| `firmware` | Runs `mcu/zbuild.sh` — the script the board runs, not a copy — to cross-compile and sign the firmware for the real board, then `mcu/ztest.sh` for the firmware tests. |

Three more workflows:

- [`provision.yml`](../../.github/workflows/provision.yml) runs the user-level
  provisioning steps themselves in an empty home directory, on x86_64 and on
  arm64, runs them a second time to prove nothing changes, then builds and
  tests the firmware with what they installed. Weekly, and whenever a
  provisioning script changes. It exists because the first stranger's board
  stopped at a step that had passed on every board it was developed on.
- [`pages.yml`](../../.github/workflows/pages.yml) builds and publishes this
  site.
- [`links.yml`](../../.github/workflows/links.yml) checks the external links
  once a month and opens an issue if any have died, rather than failing a build
  over somebody else's website.

The Zephyr version is pinned in two places: `west.yml`, which CI builds from,
and `provision/user/30-zephyr-workspace.sh`, which sets up the board. A gate
fails if they disagree, because CI compiling a different Zephyr from the board
is worse than no CI.

What CI cannot do is touch a board. Flashing, the serial link, the USB gadget
and the LEDs are verified by hand on real hardware, and
[the findings log](clean-board-findings.md) is the record of what that turned
up.

### What it costs, and what keeps that down

The repository is public, so the minutes are free. They are still somebody's
machines, and a slow CI is one people stop waiting for.

- **A newer commit cancels the run it replaces**, on the same branch or pull
  request, in `ci.yml` and `provision.yml`. A superseded build of the site is
  cancelled too; a deployment that has started is left to finish.
- **The expensive jobs are filtered by what changed**: the firmware build and
  the browser check in `ci.yml`, by the `changes` job; `provision.yml` by its
  `paths:`; and `pages.yml` only rebuilds the site when the site's inputs
  moved.
- **The firmware job waits for `checks`**, so a missing comma does not buy a
  toolchain download.
- **Everything has a timeout.**

Two things run on every pull request that are not in this repository and
cannot be tuned from it: GitHub's code scanning, and Copilot's review if it is
switched on for the account. Both are settings.

## Conventions worth knowing

- **Scripts explain themselves.** The header comment of each script says what
  it does and why it is the way it is, including what went wrong before. Keep
  that up when you change one.
- **Shell behaviour gets a test.** Pick by blast radius: what happens when this
  is wrong? Then check the new test fails when you break the script on purpose.
- **`unoq/*` ignores ruff's `PT` rules.** They are pytest-style checks and
  misfire on `fota.test()`, which is MCUboot's "mark this image pending".
- **`__all__` is not sorted** (`RUF022` off). It is grouped by meaning.
- **A blind `except Exception` is `contextlib.suppress`**, with the reason in a
  comment, on hardware paths where raising would make the API unusable.
- **C follows Zephyr's own `.clang-format`**, copied from the Zephyr tree.
  Re-copy it after a Zephyr version bump.

## The documentation

```bash
tools/build-docs.sh              # render docs/ -> share/learn/
tools/build-docs.sh --serve      # live preview on :8000 while you write
sudo bash share/build-image.sh   # on the board: put the result on the drive and the web server
```

`build-image.sh` renders the docs itself and re-inserts the drive's medium
without unbinding the gadget. Do not run `usb/gadget-down.sh` first: that drops
the USB network, and restarting `unoq-usb-gadget` does not bring it back.

Every page has to work in three places: on GitHub as plain markdown, on the
built site, and opened as a file from the USB drive with no network. In
practice that means:

- **Links are relative paths to `.md` files.** The strict build fails on one
  that does not resolve.
- **Callouts use GitHub's syntax** (`> [!NOTE]`), which a build hook converts
  for the site. The site's own `!!!` syntax shows up as stray text on GitHub.
- **Nothing is loaded from a CDN.** What the site needs is fetched at build
  time and shipped with it.

`share/learn/` is generated and is not in the repository.

## Maintenance

```bash
tools/check-versions.sh          # audit every dependency; reports only
tools/check-versions.sh pins     # just the versions this project pins itself
tools/check-links.sh             # do the external links in the docs still resolve?
```

Nothing on the board updates itself, on purpose, so run the first of these now
and then. The script's header lists the things that look out of date and are
not — `cbor2` held at 5.x, mkdocs held below 2.0, OpenOCD built from master —
and why.

Upgrading Zephyr has its own checklist: [mcu.md](mcu.md#upgrading-zephyr).

### The documentation toolchain is held back on purpose

`mkdocs` is pinned below 2.0 and `mkdocs-material` below 10 in
`python/pyproject.toml`. MkDocs 2.0 removes the plugin system, and this site
depends on three plugins: `search`, `privacy` and `offline`. The last two are
what make it work opened as a file from the USB drive with no network, which is
the one requirement that cannot be traded away.

The successor is [Zensical](https://zensical.org/), from the same author. It
builds this site faster and cannot yet build it *offline*: it leaves the
diagram library at a CDN. That is the whole blocker, and
[issue #52](https://github.com/jim-wyatt/two-computers-one-board/issues/52)
holds the ten-minute test that says when it has gone.

So the rule is: **do not move on a version number.** Move when one of these is
true.

- Zensical ships its `privacy` equivalent and the test in #52 passes.
- The pinned range stops receiving security fixes.
- A build with the pinned range stops working on a supported Python.

`tools/check-versions.sh pins` prints the range and the newest release inside
it, so a range that has gone quiet is visible. If it ever has to be replaced in
a hurry, what would not survive is small: `tools/mkdocs_hooks.py`, the theme
configuration in `mkdocs.yml`, and the two index pages. The chapters are plain
Markdown and would.

### Rebuilding OpenOCD

`/opt/openocd` is owned by no Debian package, so apt can never reinstall it.
This script removes that as a single point of failure.

```bash
sudo bash tools/build-openocd.sh              # build + self-test only
sudo bash tools/build-openocd.sh --promote    # then replace /opt/openocd
```

It builds upstream OpenOCD from a pinned commit on master (override with
`OPENOCD_COMMIT`). Master is required: the newest release, 0.12.0, predates the
libgpiod v2 API this board's SWD connection uses. The only configuration this
repository supplies is `mcu/board-support/openocd_gpiod.cfg`, which names the
SWD pins.

The build goes to `/opt/openocd-rebuilt` and **tests itself against the real
MCU**: it must see `Cortex-M33`, or it exits non-zero and leaves `/opt/openocd`
alone. `--promote` keeps the old install as `/opt/openocd.<timestamp>`. Every
tool here honours `OCD_ROOT`, so you can try the new one first:

```bash
OCD_ROOT=/opt/openocd-rebuilt zflash
```

### Keep your own copies

Two things on a provisioned board cannot be downloaded again, and neither is
this project's to redistribute (see [third-party.md](../third-party.md)).
`bootstrap.sh` copies the first aside for you; check both are there before
running `provision/40-purge-arduino.sh`:

```bash
ls ~/uno-q-backup/                                       # the stock MCU firmware (.hex)
mkdir -p ~/uno-q-backup && cp -a /opt/openocd ~/uno-q-backup/   # rebuildable, but slowly
```

## Recovery

```bash
mcu/flash-all.sh                      # rebuild the bootloader + application chain over SWD
mcu/restore-arduino-firmware.sh       # back to the stock Arduino firmware
```

The second needs the stock image from `~/uno-q-backup`, passed as `STOCK_FW`.
For a board you cannot reach at all, see
[Troubleshooting](troubleshooting.md#recovery).
