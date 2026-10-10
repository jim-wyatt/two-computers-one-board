<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# Further reading

This course is short on purpose. It teaches one board well enough that the real
documentation stops being intimidating, and then hands you over.

Everything on this page is **free to read**, and every link was checked when
this page was written. They are annotated, because a bare list of good resources
is only marginally more useful than no list: what you need to know is *which one
to open, for what, and when*.

> [!TIP]
> A rough order of usefulness, if you read nothing else: **Operating Systems:
> Three Easy Pieces** for why Linux cannot meet a deadline, **the Zephyr
> documentation** for everything on the microcontroller, **Bootlin's training
> materials** for how embedded Linux is actually built, and **Beej** for
> anything involving a wire.

---

## If a prerequisite is missing

The course assumes you can program and can open a terminal. If either of those
is shakier than you would like, start here rather than pushing through.

| Resource | What it is | Reach for it when |
|---|---|---|
| [The Missing Semester of Your CS Education](https://missing.csail.mit.edu/) | An MIT short course on the shell, editors, `git`, and debugging — the tools every other course assumes you already have | The commands in the **Try it** blocks feel like incantations |
| [Pro Git](https://git-scm.com/book/en/v2) | The canonical `git` book, free in full | You are about to change something in this repository and want to be able to undo it |
| [Dive Into Systems](https://diveintosystems.org/) | A free systems textbook: C, assembly, memory, and how a program actually runs | "The compiler produces machine code" is a sentence you can say but not explain |
| [Modern C](https://inria.hal.science/hal-02383654) (Jens Gustedt) | A full C book, free PDF, written for people who already program | You know Python, and the sketch side is your first real C |
| [The Bash guide in the TLDP archive](https://tldp.org/LDP/abs/html/) | Exhaustive shell scripting reference | You are editing anything in `provision/` |
| [explainshell](https://explainshell.com/) | Paste a command, get every flag explained | Any line in this course you do not fully understand |

---

## The Linux side

> [!NOTE]
> These map onto [The Linux side](learn/the-linux-side.md) and
> [Debugging without a screen](learn/debugging-without-a-screen.md).

**[Operating Systems: Three Easy Pieces](https://ostep.org/)** — the single best
free operating systems book, from Wisconsin ([direct
copy](https://pages.cs.wisc.edu/~remzi/OSTEP/)). The scheduling chapters are the
rigorous version of this course's claim that Linux cannot be trusted with a
microsecond. Read the "Virtualization" part; skim the rest until you need it.

**[proc(5)](https://man7.org/linux/man-pages/man5/proc.5.html)** — the manual
page for `/proc`, which is where this project's CPU numbers come from. It is
long and you should not read it end to end. Search it for `stat` and read that
paragraph; it explains the jiffies arithmetic in
[`unoq/cpu.py`](https://github.com/jim-wyatt/two-computers-one-board/blob/main/python/unoq/cpu.py)
better than any tutorial. The [kernel's own filesystem
documentation](https://docs.kernel.org/filesystems/proc.html) covers the same
ground with more detail on why each field exists.

**[The LED class documentation](https://docs.kernel.org/leds/leds-class.html)**
— why `/sys/class/leds/*/brightness` behaves the way it does, and what a
*trigger* is. This project measured three kernel triggers doing nothing at all
on this board; the document explains what they were supposed to do.

**[systemd for Administrators](https://0pointer.de/blog/projects/systemd-for-admins-1.html)**
— Lennart Poettering's own series, and still the clearest explanation of why
`systemd` is shaped the way it is. Then the [`systemd.service`
manual](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html)
for the exact meaning of `Type=`, `RemainAfterExit=` and `Restart=` — three
settings this project got wrong before it got them right.

**[Bootlin's training materials](https://bootlin.com/docs/)** — several hundred
slides of genuinely excellent embedded Linux teaching, given away. The
"Embedded Linux system development" deck is the closest thing to a map of
everything under the Debian install on this board.

**[Linux Device Drivers, 3rd edition](https://lwn.net/Kernel/LDD3/)** — dated
against a modern kernel, but the *concepts* have not moved, and it is the
standard free introduction to what a driver is.

**[Julia Evans' blog](https://jvns.ca/)** — short, illustrated, unusually
honest explanations of exactly the things that confuse people about Linux:
`strace`, DNS, networking, permissions. Excellent when you are stuck and cross.

---

## The microcontroller side

> [!NOTE]
> These map onto [The microcontroller side](learn/the-microcontroller-side.md)
> and [The LED matrix](learn/the-led-matrix.md).

**[The Zephyr documentation](https://docs.zephyrproject.org/latest/)** — the
primary source for everything on the STM32 side of this board. It is very good
and very large. The pages worth bookmarking:

- [Threads and kernel services](https://docs.zephyrproject.org/latest/kernel/services/threads/index.html)
  — what a "thread" means when there is no process and no MMU
- [GPIO](https://docs.zephyrproject.org/latest/hardware/peripherals/gpio.html) —
  the API behind every pin this project toggles
- [Devicetree](https://docs.zephyrproject.org/latest/build/dts/index.html) — how
  the build learns which pins exist. Start with the "Introduction", not the
  bindings reference
- [Kconfig](https://docs.zephyrproject.org/latest/build/kconfig/index.html) —
  how the build learns which *features* exist
- [west](https://docs.zephyrproject.org/latest/develop/west/index.html) — the
  meta-tool that manages the workspace

**[Interrupt](https://interrupt.memfault.com/blog/)** (Memfault) — the best
free embedded-systems blog being written. Deep, specific, and unromantic about
firmware. The posts on fault handling, firmware update and debugging are
directly relevant to this board.

**[Cortex-M33 Devices Generic User
Guide](https://developer.arm.com/documentation/100235/latest/)** — Arm's own
description of the core inside the STM32U585: the register set, the exception
model, the memory map. Reference material, not reading material, but this is
where you go when a fault handler fires and you want to know what `PSR` means.

**[Charlieplexing](https://en.wikipedia.org/wiki/Charlieplexing)** — the wiring
trick that lets 11 pins drive 104 LEDs, which is the whole reason
[The LED matrix](learn/the-led-matrix.md) is a chapter and not a footnote.

**[SparkFun's serial communication
tutorial](https://learn.sparkfun.com/tutorials/serial-communication)** and
**[their I²C tutorial](https://learn.sparkfun.com/tutorials/i2c)** — beginner
level, well illustrated, and correct. If "baud rate" or "open drain" is a phrase
you nod at rather than understand, half an hour here is well spent.

**[Nand2Tetris](https://www.nand2tetris.org/)** — build a computer from logic
gates up to an operating system. Not about this board at all, and the single
best cure for treating a processor as a magic box.

---

## The wire between them

> [!NOTE]
> These map onto [How they talk](learn/how-they-talk.md).

**[Beej's Guide to Network
Programming](https://beej.us/guide/bgnet/)** — nominally about sockets, actually
the friendliest explanation anywhere of byte order, framing, and why "I sent 100
bytes so I will receive 100 bytes" is false. Every one of those lessons applies
to a serial line. Beej also wrote a [C
guide](https://beej.us/guide/bgc/) worth the same recommendation.

**[Consistent Overhead Byte
Stuffing](https://en.wikipedia.org/wiki/Consistent_Overhead_Byte_Stuffing)** —
one honest way to turn a stream of bytes into a stream of messages, with a
bounded worst case. Read it alongside this project's framing and judge which
trade-off you prefer.

**[A Painless Guide to CRC Error Detection
Algorithms](https://www.zlib.net/crc_v3.txt)** (Ross Williams) — plain text from
1993, still the clearest explanation of what a CRC actually computes and why a
checksum you invented yourself is probably weaker than you think.

**[High Performance Browser Networking](https://hpbn.co/)** — free in full.
Chapters 1–2 on latency and bandwidth are the general form of "the link is
115200 baud, so a 104-byte frame costs about 9 ms".

---

## Building software for a chip that is not the one you are on

> [!NOTE]
> These map onto [From source to a running chip](learn/from-source-to-chip.md).

**[CMake's documentation](https://cmake.org/cmake/help/latest/)** — Zephyr's
build is CMake underneath, and the day you need to add a source file to the
sketch you will need to know that. Use it as a reference; the tutorial is
heavy going.

**[Computer Systems: A Programmer's Perspective — lab
assignments](https://csapp.cs.cmu.edu/3e/labs.html)** — the CMU labs are free
even though the book is not. `bomblab` and `buflab` teach you to read compiler
output, which is a skill you will want the first time a cross-compiled binary
does something the source clearly does not say.

**[cppreference](https://en.cppreference.com/)** — accurate C and C++ reference.
Prefer it to the first search result, always.

---

## Updating firmware without bricking the board

> [!NOTE]
> These map onto [Updating safely](learn/updating-safely.md).

**[MCUboot's documentation](https://docs.mcuboot.com/)** — the bootloader this
board actually uses. The "Design" page explains slots, swap and the confirm flag;
the course chapter is a simplification of it.

**[Zephyr's SMP protocol
documentation](https://docs.zephyrproject.org/latest/services/device_mgmt/smp_protocol.html)**
— the wire format `mcumgr` speaks, which is what this project's
[`unoq/fota.py`](https://github.com/jim-wyatt/two-computers-one-board/blob/main/python/unoq/fota.py)
drives.

---

## One cable pretending to be several devices

> [!NOTE]
> These map onto [One cable, many devices](learn/one-cable-many-devices.md).

**[USB in a NutShell](https://www.beyondlogic.org/usbnutshell/usb1.shtml)** —
the standard free introduction to how USB enumeration, descriptors and endpoints
work. Everything in [the USB reference](reference/usb.md) assumes this.

**[The kernel's USB gadget
documentation](https://docs.kernel.org/driver-api/usb/gadget.html)** and
**[gadget ConfigFS](https://docs.kernel.org/usb/gadget_configfs.html)** — the
exact mechanism this board uses to *become* a network adapter and a disk. The
ConfigFS page is short and is essentially the specification for
[`usb/gadget-up.sh`](https://github.com/jim-wyatt/two-computers-one-board/blob/main/usb/gadget-up.sh).

**[RFC 2131](https://www.rfc-editor.org/rfc/rfc2131)** — DHCP. Worth skimming
once, so that "the board asks the laptop for an address" stops being magic and
becomes four named messages.

---

## Knowing whether it works

> [!NOTE]
> These map onto [Debugging without a screen](learn/debugging-without-a-screen.md).

**[pytest](https://docs.pytest.org/)**, **[Ruff](https://docs.astral.sh/ruff/)**
and **[mypy](https://mypy.readthedocs.io/)** — the three gates the Python side
of this project has to pass. Ruff's rule index in particular is a readable
catalogue of mistakes worth not making.

**[Zephyr's ztest](https://docs.zephyrproject.org/latest/develop/test/ztest.html)**
and **[twister](https://docs.zephyrproject.org/latest/develop/test/twister.html)**
— unit testing for firmware, including running it on your laptop instead of the
chip. This is how the MCU logic in this repository is tested without a board
attached.

**[ShellCheck](https://www.shellcheck.net/)** — a linter for shell, and an
education in the ways shell quoting betrays you. Every script here passes it.

**[GitHub Actions documentation](https://docs.github.com/en/actions)** — what
runs on every push to this repository.

**[Google's code review
guide](https://google.github.io/eng-practices/review/)** — short, opinionated,
and the clearest published description of what reviewing a change is actually
for.

---

## The specific hardware

**[Arduino's UNO Q documentation](https://docs.arduino.cc/hardware/uno-q/)** —
the vendor's own pages: datasheet, pinout, and the App Lab workflow this project
deliberately works underneath rather than through.

**[ArduinoCore-zephyr](https://github.com/arduino/ArduinoCore-zephyr)** — the
source of the Arduino layer that runs on the STM32. When the documentation and
the behaviour disagree, this repository is the tiebreaker.

**[Arduino_RouterBridge](https://github.com/arduino-libraries/Arduino_RouterBridge)**
— the RPC library Arduino's own examples use across the two chips. This project
does not use it, and [How they talk](learn/how-they-talk.md) explains why; read
both and decide which you would have built.

---

## Writing it down

Making the documentation good is part of this project, not decoration on top of
it.

**[Diátaxis](https://diataxis.fr/)** — the framework that says tutorials,
how-to guides, reference and explanation are four different things that fail
when mixed. This site is split along exactly that line: the course is
explanation, [the reference](reference/hardware.md) is reference, and
[troubleshooting](reference/troubleshooting.md) is how-to.

**[Material for MkDocs](https://squidfunk.github.io/mkdocs-material/)** and
**[MkDocs](https://www.mkdocs.org/)** — what builds this site, and what to read
if you want to change how it looks.

**[SPDX](https://spdx.dev/)** and **[Choose a
License](https://choosealicense.com/)** — why every file here starts with a
one-line licence identifier, and how to pick one for whatever you build next.

---

## A note on books that are not free

Three are worth the money, and no free equivalent is quite as good. Listed
because leaving them out would be dishonest, not because you need them:

- **The Linux Programming Interface**, Michael Kerrisk — the reference for
  everything Linux exposes to a program. The author also maintains
  [man7.org](https://man7.org/linux/man-pages/man5/proc.5.html), which is free
  and covers much of the same ground in a less connected form.
- **Making Embedded Systems**, Elecia White — the book about how to think about
  firmware, rather than which register to write.
- **The Definitive Guide to Arm Cortex-M33 and Cortex-M23 Processors**, Joseph
  Yiu — the readable version of the Arm reference manuals.
