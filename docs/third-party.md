# Third-party material

Everything in this repository is MIT-licensed (see [LICENSE](../LICENSE)) **except**
the files listed here, which belong to other projects and keep their own terms.
Each one carries its original licence header — do not replace those with this
project's.

## Trademarks and affiliation

**This is an independent project. It is not affiliated with, authorised by,
sponsored by, or endorsed by any of the companies or projects named in it.**

Arduino® and UNO®, Qualcomm® and Snapdragon®, STMicroelectronics® and STM32®,
Arm® and Cortex®, Zephyr®, Linux®, Debian®, Python®, Microsoft®, Windows®,
Visual Studio Code, GitHub®, macOS® and Qwiic® are the property of their
respective owners, and may be registered trademarks in some jurisdictions.

The same goes for every other product and project name on this site — USB-C®,
Bluetooth®, Raspberry Pi®, Docker®, SparkFun®, MCUboot, OpenOCD, U-Boot and the
rest: each belongs to its owner.

They are used here **descriptively** — to say accurately what this software
runs on, builds with and talks to. You cannot explain a Zephyr application that
flashes an STM32 over SWD without naming Zephyr and STM32. That is descriptive
use, not a claim on the names, and nothing here should be read as suggesting
that any of these organisations produced, reviewed or endorsed this project.

- The only third-party mark shown is GitHub's, as the link to this project's
  repository. No other vendor logo, icon or brand artwork is used or
  redistributed. The mark on this site is [`docs/assets/logo.svg`](assets/logo.svg) — four LED bars,
  drawn for this project and MIT-licensed like the rest of it.
- No vendor binaries or firmware images are redistributed. See
  [Not included](#not-included) for what was deliberately removed and why.
- Where third-party *files* are included, they keep their own licence headers
  and are listed below.

If you own one of these marks and object to how it is used here, open an issue
and it will be changed.

## Licences, not trademarks

The rest of this page is about **copyright and licensing** — which files belong
to whom, and under what terms. That is a separate question from the trademark
notice above, and the two are easy to conflate: a permissive licence on a
project's *code* grants nothing at all in respect of its *name*.

| File | Owner | Licence |
|---|---|---|
| `.vscode/STM32U585.svd` | STMicroelectronics | Apache-2.0 |
| `.clang-format` | The Zephyr Project | Apache-2.0 |

Both are copied unmodified, and both keep the notice they came with. The text of
the Apache licence is in [`LICENSES/Apache-2.0.txt`](../LICENSES/Apache-2.0.txt).

## Derived work

`mcu/app/src/matrix.c` implements the 8×13 LED panel from scratch, but two
facts in it were read out of Arduino's own implementation
([ArduinoCore-zephyr](https://github.com/arduino/ArduinoCore-zephyr),
`loader/matrix.inc`, Apache-2.0): which ordered pin pair lights which LED, and
the 10 µs slot. That wiring is not described anywhere else — not in the UNO Q
datasheet and not in Zephyr's `arduino_uno_q` board definition, which does not
mention the panel at all. The grayscale scheme, the refresh ISR and the
register-level `MODER`/`BSRR` handling are this project's.

`mcu/board-support/openocd_gpiod.cfg` is adapted from the adapter configuration
Arduino ships on the board's stock image (`/opt/openocd/openocd_gpiod.cfg`). It
is six lines naming which GPIO lines carry SWD; the numbers are Arduino's.

## Build-time dependencies

Not redistributed here — you install them yourself, and they are listed for
completeness because the firmware links against them:

| | Licence |
|---|---|
| [Zephyr RTOS](https://github.com/zephyrproject-rtos/zephyr) (+ MCUboot) | Apache-2.0 |
| [OpenOCD](https://openocd.org/) — built by `tools/build-openocd.sh` | GPL-2.0-or-later |
| `pyserial`, `gpiod`, `smpclient` | BSD-3-Clause / LGPL-2.1 / Apache-2.0 |
| [MkDocs](https://www.mkdocs.org/) + [Material for MkDocs](https://squidfunk.github.io/mkdocs-material/) | BSD-2-Clause / MIT |

OpenOCD is GPL. `tools/build-openocd.sh` builds it from upstream source into
`/opt/openocd`; no OpenOCD code is vendored into this repository. If you pass a
built `/opt/openocd` on to someone else, the GPL applies to you: give them the
source, or say where it is. The script prints the commit it built.

The firmware you build also links the modules Zephyr pulls in for this board,
among them ST's STM32Cube HAL (BSD-3-Clause) and Arm's CMSIS (Apache-2.0). This
project publishes no firmware binary; if you publish one, their notices go with
it.

## Inside the site you are reading

This page is part of a site built by Material for MkDocs, and the build copies
some of that project's work into the output. That output ships on the USB drive
and is served over the network, so it is redistribution and belongs here.

| In `share/learn/` | Owner | Licence |
|---|---|---|
| `assets/stylesheets/`, `assets/javascripts/bundle.*.js` | Martin Donath (squidfunk) and contributors — Material for MkDocs | MIT |
| inside that bundle | RxJS; tslib; clipboard.js; escape-html; focus-visible | Apache-2.0; 0BSD; MIT; MIT; W3C |
| `assets/javascripts/workers/search.*.js` | Oliver Nightingale — lunr.js | MIT |
| `assets/javascripts/lunr/min/` | Mihai Valentin and others — lunr-languages, with the Snowball stemmers | MPL-1.1 |
| `assets/javascripts/lunr/tinyseg.js`, `wordcut.js` | Taku Kudo — TinySegmenter; Vee Satayamas — wordcut | see each project |
| `assets/external/unpkg.com/mermaid@11/` | The Mermaid authors. It bundles DOMPurify, d3, dagre, cytoscape, KaTeX, lodash and others, each under its own permissive licence | MIT |
| `assets/external/unpkg.com/iframe-worker/` | Martin Donath | MIT |
| Icons, inlined as SVG | Pictogrammers — Material Design Icons; GitHub — Octicons; Fonticons — Font Awesome Free | Apache-2.0; MIT; CC BY 4.0 |

The site is in English only, so the language files under `lunr/` are never
loaded. They are there because the theme ships them.

`assets/javascripts/mermaid-init.js` sits beside those and is ours, not
third-party - it is the few lines that actually call `mermaid.run()`, which the
theme does not.

The `privacy` plugin is what puts the mermaid and lunr copies there: it downloads at build
time anything the theme would otherwise fetch from a CDN while the page is
loading, so that a reader with no network still gets a complete site. The
consequence is that the copies travel with the drive, which is the point, and
which is why they are listed.

None of it is in this repository — `share/learn/` is generated output and is in
`.gitignore`. Rebuild it with `tools/build-docs.sh`.

## Downloaded onto your board, never redistributed

`share/fetch-vscode.sh` downloads Microsoft's official Visual Studio Code
installers onto the board so it can hand them to a laptop that has no internet
of its own — over the USB fileshare and over `unoq-learn`.

| | Owner | Terms |
|---|---|---|
| VS Code installers (`.exe`, `.zip`, `.deb`, `.tar.gz`) | Microsoft | [Microsoft Software Licence Terms](https://code.visualstudio.com/license) |

They are **not** in this repository and are not published by this project. They
are fetched from `update.code.visualstudio.com` at the moment you run that
script, onto your own hardware, and land inside `unoq-share.img` which is
likewise not tracked here. Handing them on to other people is redistribution
and is governed by Microsoft's terms, not by this project's MIT licence.

Note that the official builds are not the MIT-licensed `vscode` source — they
add Microsoft-proprietary components. If you would rather ship something freely
redistributable, point the script at [VSCodium](https://vscodium.com/) builds
instead.

## Not included

Earlier revisions of this project kept a `backup/` directory holding Arduino's
stock MCU firmware image, Arduino's `remoteocd` helper binary, and OpenOCD
target configuration files. Those are other people's build artefacts and are
not this project's to redistribute, so they are not published here and have
been removed from the git history.

If you want the stock firmware back on your own board you need your own copy,
taken **before** you purge the Arduino tree — see
[Keep your own copies](reference/development.md#keep-your-own-copies) for the
commands. `mcu/restore-arduino-firmware.sh` uses it via `STOCK_FW`.
