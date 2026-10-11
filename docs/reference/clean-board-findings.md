<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# What a clean board revealed

A running log, kept while taking a factory-restored UNO Q back to a working
board with `bootstrap.sh`. It exists because **none of these are visible on a
board that is already provisioned** — which is every board the scripts had been
tested on until then.

The common shape is worth stating up front, because it is what to look for
next: of the seventeen findings below, **five reported success** and five more
printed a warning that read as noise. Only two announced themselves as errors.
A check that cannot pass is indistinguishable from a check that always passes,
unless you run it somewhere it matters.

Status as of the runs on 2026-08-08/09. Fixed items link to the commit.

| # | What | How it presented | Status |
|---|---|---|---|
| 1 | Stock firmware backup globbed `variants/`, image is in `firmwares/` | `warn`, then carried on into the purge having saved nothing — see #12 for what that does and does not cost | fixed |
| 2 | SDK 1.0.1 nests toolchains under `gnu/` | verify failed on a good install; **and** the idempotency check never matched, so every re-run re-downloaded ~1 GB | fixed |
| 3 | `tr -d '\0'` on the devicetree `compatible` | `unrecognised board` on every UNO Q and VENTUNO Q ever | fixed |
| 4 | avahi advertises *both* bridge addresses | `<host>.local` resolved to the unreachable `10.55.0.1` half the time | fixed |
| 5 | `flash-all.sh` ran `west build` outside the workspace | `unknown command "build"` at the last step of a 45-minute run | fixed |
| 6 | `env.sh` hardcoded `$HOME/hybrid` | `zbuild`/`zflash`/`hpy`/`mcucon` broken on any other clone path | fixed |
| 7 | Alias check ran in a non-interactive shell | `command -v zbuild` can never see an alias there; had never passed | fixed |
| 8 | No host C compiler on the image at all | `check.sh mcu` and `ztest.sh` could never have run | fixed |
| 9 | Venv check tested 3 of the 5 packages it installs | `smbus2` and `spidev` absent, reported `0 changed, 5 already correct` | fixed |
| 10 | VS Code machine settings lived only in `~/.vscode-server` | restore wiped them; nothing said so, the board just swapped sooner | fixed |
| 11 | `75-learning-web.sh` printed only the first address per interface, and ignored link state | advertised `10.55.0.1` and a **down** `docker0`, hid the one address the host can reach | fixed |
| 12 | `55-purge-arduino.sh` claimed the purge deletes `~/.arduino15` | it does not — apt removes packages, not `$HOME`. 621 MB still there after a real run | fixed |
| 13 | Attaching the fileshare after the gadget was built left the drive exported **read-write** | the read-only protection `usb.md` insists on was absent on every board following the documented order | fixed |
| 14 | Nothing locked `/dev/ttyHS1`, so two openers interleaved | 6 of 8 reads correct, 2 failing with an error that blames a disconnected cable | fixed |
| 15 | `fwupd.service` masked but `fwupd-refresh.timer` left enabled | a permanently failed unit on a board with nothing wrong — found by the new alarm LED, seconds after it was first enabled | fixed |
| 16 | `mmc0`, `disk-activity`, `disk-write` LED triggers never fire | offered, selectable, and inert: 0 of 400 samples under sustained writes | worked around |
| 17 | Firmware read the MCUboot image state once at boot | LED 3 sat on yellow through a successful confirm — stale, in the exact way the Linux LEDs were designed not to be | fixed |

---

## The ones worth understanding, not just fixing

### 2 and 9 — checks that make their own gap unreachable

Both are worse than a missed check, and in the same way.

`25-zephyr-sdk.sh` used the wrong path in **two** places: the verify at the end,
and the "already installed?" test before the download. The first is a loud
failure. The second means the install branch runs every time, re-downloading
~1 GB, and *a run that re-downloads looks exactly like one that skipped, only
slower*. Nobody would ever have reported it.

`35-python-venv.sh` is the mirror image. It installs five packages and tests
three. Satisfy the three and the install branch never runs again — so the two
missing ones are not merely undetected, they are **unreachable**. The board
reported `0 changed, 5 already correct` while two libraries were absent.

The rule both break: *a check must cover everything the thing it guards does.*
Where a list drives an action, derive the check from the same list.

### 8 — the dependency nothing declares

The stock image has no `cc` at all. `gcc` is `un` in dpkg, not merely absent.

Everything cross-compiled kept working, because the Zephyr SDK carries its own
`arm-zephyr-eabi`. Only two things wanted the *host* compiler — `native_sim`
ztest builds, and the `spidev` C extension — and both are the kind of thing you
run once and rarely.

The tell was sitting in the tree the whole time: `10-optimize-board.sh` installs
`python3-dev` *for spidev*, i.e. the headers, without the compiler that consumes
them. Half a dependency is a stronger signal than none.

### 10 — configuration that only existed on the machine

`.vscode/settings.json` says the board-wide tuning lives in
`~/.vscode-server/data/Machine/settings.json`. After the restore that file did
not exist, and nothing anywhere said so.

Every setting in it is one whose default merely *costs* something rather than
breaking anything: `extensions.autoUpdate` came back on (which the README
explicitly calls out as deliberately off), the file watcher went back to
watching ~4 GB of Zephyr checkout and toolchain, and project-wide search walked
all of it. The board simply ran hotter and swapped sooner.

It now lives in `provision/user/vscode-machine-settings.json` and is installed
by `40-shell-env.sh` if absent. The general rule: **configuration that is not in
the repo does not survive a restore, and configuration whose absence is silent
will not be noticed when it does not.**

For scale, on this board VS Code Server plus its Claude Code instances was
1875 MB of 3.6 GB, of which ~620 MB was a second extension host left behind by a
window whose connection had gone away.

### 1 — a guard that saved nothing, and how bad that actually was

The stock MCU firmware is Arduino's build: not in this repo, not in apt. The
backup step globbed a path that has not existed since core 0.55.2, warned, and
continued into `apt_remove arduino-*` having saved nothing.

Now: `bootstrap.sh` takes the copy during **preflight**, while the tree is
certainly still there, and the purge **refuses** without one. The find logic
lives in `lib.sh` because two callers need the same answer and the path has
already moved once.

Two corrections to how this was first written up, both in the direction of it
being *less* dramatic — recorded because #12 is about exactly this failure mode:

- The purge does **not** delete `~/.arduino15`, so the image survives it. What
  the broken glob cost was the *deliberate* copy, not the last one.
- The image is **recoverable** regardless: it ships in the `arduino-*` debs, so
  a factory restore brings it back. Losing it costs a restore, not the board.

The guard still earns its place, for a narrower reason than "otherwise it is
gone forever": the purge is the point after which nobody thinks to look for the
image again, and a restore months later will not feel connected to it.

---

### 15, 16, 17 — what an indicator is worth, and what it costs to get wrong

Adding four status LEDs took an afternoon and turned up three separate problems,
none of which were about LEDs.

**15.** The "a unit has failed" LED came on within *seconds* of first being
enabled. `10-optimize-board.sh` masks `fwupd.service` but left
`fwupd-refresh.timer` enabled; it fires daily, cannot reach the masked daemon,
and leaves a failed unit forever. That would have made the new alarm useless
from birth — **an indicator that is always on is not an indicator**, which is
the same disease as a warning nobody reads.

**16.** The kernel offers `mmc0`, `disk-activity` and `disk-write` in every
LED's trigger list. All three can be selected without complaint. None of them
fire — measured at 0 of 400 samples with 400 MB of `O_DIRECT` writes in flight.
**Being listed is not being implemented**, and a trigger you can select is not a
trigger that fires. `/sys/block/mmcblk0/stat` does move, and is checkable.

**17.** The firmware called `boot_is_img_confirmed()` once, in `main()`.
Confirming happens over SMP long afterwards, so LED 3 stayed yellow through a
successful confirm — showing something that *had* been true. This is exactly the
failure `status/leds.sh` was written to avoid ("a stale LED is worse than a dark
one, because it is confidently wrong"), reintroduced in C two files away. Having
the principle written down did not stop it; **watching the board did.**

The through-line: every one of these was found by looking at hardware, not by
reading code or running tests. The suite was green throughout.

### 14 — mostly working, which is worse than broken

Found while checking that a sentence in the course was true. It said that
opening the serial port while `unoq-cpu-bars.service` holds it fails. It did
not: Linux happily lets two processes open the same tty, and their conversations
interleave.

Measured, eight status reads alongside the running demo: **six correct, two
failed**, with

```
device reports readiness to read but returned no data
(device disconnected or multiple access on port?)
```

which reads like the cable fell out.

A clean failure is found in the first five minutes. Something that works 75% of
the time survives testing, ships, and then fails in front of somebody else while
pointing at the wrong cause. The documentation had always said to stop the
service first — `exclusive=True` on the port is what turned that from advice
into something the kernel enforces.

The general form, worth keeping: **when a README says "remember to X first", ask
whether the code can make X unnecessary or impossible to forget.**

### 12 — a warning that was worse than wrong

`55-purge-arduino.sh` said the purge takes `~/.arduino15` with it, so the stock
image is gone forever. Measured after a real run: `~/.arduino15` is still there,
**621 MB of it**, stock `.hex` included. apt removes packages, not files in
`$HOME`.

Overstating a danger is its own failure mode. The reader who checks and finds it
untrue learns to discount everything else the file says — and this file is one
where the other warnings are real.

What actually eats the image is a **factory restore**, which is also what puts
it back. The guard still belongs here, for a different reason than stated: not
because this script deletes the image, but because it is the point after which
nobody thinks to look for it again.

---

## Validated on this board

Everything below was run end to end after the fixes above, on 2026-08-09.

| Feature | Result |
|---|---|
| CPU-bars demo | Drives the panel: MCU sweep counter `0 → 29,627`, and `+10,554` across a controlled 20-frame run. Boot service stable, 0 restarts, holds `/dev/ttyHS1` as documented. |
| Fileshare image | Builds with MBR + FAT32 at `+1048576`, mounts read-only, and attaches to the live gadget by **re-inserting the medium** — no unbind, so an SSH session over the same cable survives it. |
| Learning web | `HTTP 200`, reachable on the leased USB address. |
| **FOTA** | Full cycle *and* the safety property: upload → staged; `test`+`reset` → swapped with `confirmed: False`; **reset without confirming reverted automatically**; `test`+`reset`+`confirm` survived a further reset. |
| `--with-purge` | Removed four packages, reclaimed ~400 MB, OpenOCD verified working afterwards, all services still up. |
| MCU suites | 26/26 cases, 2/2 suites (needs the `gcc` from finding #8). |
| Host suites | 106 tests, 100% coverage, all 7 gates. |

Nothing in this table had been run on this board before today.

## Found later, while writing the course

### 18. U-Boot names all five MCU control lines, and disagrees about one

Reconstructing the boot chain for
[From power to prompt](../learn/from-power-to-prompt.md) meant reading the
bootloader partitions. `boot_a` holds U-Boot, and its embedded devicetree names
`mcu-swdio-state`, `mcu-swclk-state`, `mcu-boot0-state`, `mcu-nrst-state` and
`mcu-spi-rdy-state`, mapped to GPIO 25, 26, 37, 38 and 70.

Four match what this project worked out empirically. The fifth does not: GPIO 70
is what makes `/dev/ttyHS1` produce bytes, and this project calls it a *UART link
enable*; U-Boot calls it an **SPI ready** line. Recorded in
[hardware.md](hardware.md), unresolved, and worth chasing — a hardware SPI
channel between the two chips would be far faster than the 115200 line
everything currently goes through.

Reproduce with:

```bash
sudo dd if=/dev/disk/by-partlabel/boot_a bs=1M count=16 2>/dev/null \
  | strings -n 4 | grep -A2 -E '^mcu-.*-state$'
```

### 19. Nineteen documentation links were dead on GitHub

The previous documentation generator rendered every page into one flat
directory, so a link written as `hardware.md` from `docs/learn/` resolved
correctly on the site and 404'd in the repository. Nineteen of them. Nothing
noticed, because the site was the only surface anyone checked.

Building with `mkdocs --strict` against the real directory tree found all of
them at once. `tools/check.sh docs` now fails on the next one.

The general shape is worth keeping: **a generator that is forgiving about its
input hides bugs in the input.**

### 20. The offline site nearly shipped needing the network

Material for MkDocs' `privacy` plugin vendors the assets the theme would
otherwise fetch at page load — which is what makes the USB drive work with no
internet. With `site_url` set, it rewrites those references to *absolute* URLs
on the public site, so the mermaid renderer would have been fetched from GitHub
Pages every time a page with a diagram was opened.

Removing `site_url` makes the same reference relative. Caught by grepping the
built bundle, not by anything failing:

```bash
grep -o '.\{30\}unpkg.com/mermaid' share/learn/assets/javascripts/bundle.*.js
```

It must not start with `https://`. The comment in `mkdocs.yml` says so.

### 21. The drive accumulated a second, stale copy of the whole site

`share/build-image.sh` synced the rendered site onto the drive with a plain
`rsync -a` — no `--delete`. That was harmless while the generator wrote one flat
directory of pages, because the file set never shrank.

The first build after the site grew subdirectories put **both layouts on the
drive at once**: twenty pages from the old build sitting beside the new tree,
every one of them still reachable over HTTP and every one of them out of date.
Precisely the disagreement between the three copies that rebuilding the image is
supposed to prevent.

Fixed with `--delete` plus `--exclude '/vscode/'`, since the installers live on
the drive and are not in `share/learn` — rsync does not delete excluded paths,
so stale documentation goes and the ~2 GB of downloads stay.

Verified afterwards: 27 HTML files on the drive, matching the build exactly, and
an old flat URL now returns 404.

### 22. Zephyr 4.4.2 is a security release, and the upgrade was uneventful

4.4.1 was superseded on 2026-08-07 by a bugfix release carrying more than ten
CVEs. Most are in subsystems this firmware does not build - ext2, the HTTP
server, Bluetooth, Xtensa, network sockets - so the practical exposure was low.
"We do not think we are affected" is not a reason to stay on a superseded
release when the upgrade is patch-level, so it was taken.

One is worth noting for its shape rather than its impact: **CVE-2026-10642**, an
unbounded TX busy-loop DoS in the **PL011** UART driver under CTS hardware flow
control. This board uses STM32 LPUART, not PL011, so it does not apply - but the
MPU link does run RTS/CTS, so it is the same class of bug one driver over.

Validated end to end on the board rather than assumed:

| | |
|---|---|
| Build | clean, 3m04 |
| MCU suites | 26 of 26 cases, 2 of 2 configurations |
| FOTA upload | 86,088 bytes staged |
| Probation | booted with `confirmed: False`, old image intact in slot 1 |
| Confirm | slot 0 active and confirmed, slot 1 released |
| Demo | sweep counter advancing, `unoq-cpu-bars` back up, 0 failed units |

The pin gate did its job in passing: `tools/check-zephyr-pin.sh` had to be
satisfied in both `provision/user/30-zephyr-workspace.sh` and `west.yml` before
anything would build.

## Decisions taken, for the refactor

- ~~**Keep the `10.55.0.0/24` server mode.**~~ **Reversed.** The reasoning was
  that server mode is what makes the board work with a host that is not sharing
  its internet, and that `UNOQ_USB_MODE` made the unused half inert anyway. The
  first half was right about the *requirement* and wrong about the *only way to
  meet it*: IPv4 link-local covers a host that serves no DHCP, and covers it
  better, because both ends reach `169.254/16` on their own and no static route
  has to be typed at the far end. The second half undervalued the cost — inert
  at runtime still meant two DHCP daemons, two route paths, two answers to
  "what do I ssh to", and a mode setting that could be wrong.
- ~~**Keep `10.55.0.1` on the bridge in client mode.**~~ **Reversed**, and this
  is the one that mattered. Finding 4 in this document — avahi advertising both
  addresses, so `<host>.local` resolved to the unreachable one half the time —
  was recorded as "fixed" by having `wifi.sh` print the numeric address instead.
  That treated the symptom. The second address *was* the bug, and removing it is
  what makes the mDNS name a reliable answer, which is now the whole addressing
  story.
- ~~**`docs/usb.md` should lead with client mode.**~~ **Done, by deletion.**
  There is only one mode to lead with.
