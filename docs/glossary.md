<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# Glossary

Every term the course introduces, defined once, with a link to where it is
actually taught. Definitions here are deliberately short — the chapter is where
the idea gets explained, this is where you come to be reminded.

> [!TIP]
> Acronyms have hover definitions everywhere on this site. If you meet an
> unfamiliar one mid-sentence, point at it rather than coming here.

---

## A

**A/B slots**
:   Keeping two copies of a piece of software — one running, one being replaced —
    so that a failed update can be undone by switching a pointer back. Used by
    this board's bootloader partitions *and*, at a much smaller scale, by
    MCUboot for the firmware. See [From power to prompt](learn/from-power-to-prompt.md)
    and [Updating safely](learn/updating-safely.md).

**Admonition**
:   A callout box, like the tip above. Nothing to do with the board; mentioned
    because the documentation uses them for asides you can safely skip.

## B

**Baud rate**
:   How many signal changes per second a serial line carries. This board's
    MPU↔MCU link runs at 115200, which works out at roughly 9 ms for a
    104-byte message. See [How they talk](learn/how-they-talk.md).

**Binding (devicetree)**
:   A file that says which properties a kind of hardware may have and what they
    mean — the schema for a devicetree node. See
    [How the build knows your hardware](learn/how-the-build-knows-your-hardware.md).

**Binding (USB)**
:   Writing a USB controller's name into a gadget's `UDC` file, which is the
    moment the board actually appears on the host computer. See
    [One cable, many devices](learn/one-cable-many-devices.md).

**BOOT0**
:   A single wire, sampled by the microcontroller at reset, that selects between
    running your firmware and sitting in the chip's own ROM bootloader. Driven
    by Linux. Get it wrong and a perfectly good board looks dead — this is the
    single most expensive mistake available on this hardware.

**Bootloader**
:   A small program that runs before the real one, decides what to start, and
    starts it. This board has a chain of them on the Linux side and one
    (MCUboot) on the microcontroller.

## C

**Charlieplexing**
:   A wiring trick that drives *n* × (*n*−1) LEDs from *n* pins, by exploiting
    the fact that a microcontroller pin can be an input as well as high or low.
    Eleven pins, 104 LEDs. See [The LED matrix](learn/the-led-matrix.md).

**configfs**
:   A Linux filesystem where **creating a directory creates a kernel object**.
    Making a folder called `functions/ncm.usb0` does not make a folder; it makes
    a USB network function. See [One cable, many devices](learn/one-cable-many-devices.md).

**Confirmed image**
:   A firmware image that has told the bootloader it is working, so it survives
    the next reset. Until then it is on probation. LED 3 shows this: green
    confirmed, yellow not. See [Updating safely](learn/updating-safely.md).

**Coverage**
:   The fraction of lines and branches a test suite executes. It measures what
    ran, not whether the assertions were any good — see
    [Knowing it works](learn/knowing-it-works.md) for why it is enforced at 100%
    anyway.

**Cross-compiling**
:   Building on one kind of computer a program that will run on a different
    kind. Everything for the microcontroller is cross-compiled, on the Linux
    side of the same board. See [From source to a running chip](learn/from-source-to-chip.md).

## D

**DDR**
:   The kind of RAM on the Linux side of the board. It cannot be used until an
    early boot stage has measured its timing and tuned the memory controller to
    match, which is called *training* it. See
    [From power to prompt](learn/from-power-to-prompt.md).

**Debug probe**
:   A small adapter that sits between a computer and a chip and speaks a debug
    protocol such as SWD for it. This board has none: Linux drives the SWD wires
    itself. See [From source to a running chip](learn/from-source-to-chip.md).

**Devicetree**
:   A description of what hardware exists and how it is wired, as data rather
    than code. Compiled into C macros at build time — there is no devicetree
    parser on the chip. See
    [How the build knows your hardware](learn/how-the-build-knows-your-hardware.md).

## E

**ELF**
:   The file format a compiler produces for a finished program: the machine
    code, plus a header saying what kind of machine it is for. `zephyr.elf` is
    the firmware in that form. See
    [From source to a running chip](learn/from-source-to-chip.md).

**eMMC**
:   The storage chip soldered to the board, which holds Linux and everything in
    its filesystem. See [From power to prompt](learn/from-power-to-prompt.md).

## F

**Firmware**
:   The program running on the microcontroller. The word is doing real work: it
    is the *only* program there, with no operating system beneath it in the
    sense Linux means.

**FOTA** (firmware over the air)
:   Updating a device's firmware over a link it already has, without debug
    wires. Here the "air" is the serial line between the two chips. See
    [Updating safely](learn/updating-safely.md).

**Framing**
:   Turning a stream of bytes into a sequence of messages. A wire delivers
    bytes when it feels like it, in any grouping; framing is the agreement that
    says where one message ends. See [How they talk](learn/how-they-talk.md).

## G

**Gadget (USB)**
:   A Linux-side definition of a USB device the board will pretend to be. Built
    from *functions* (a network adapter, a disk) grouped into *configurations*.
    See [One cable, many devices](learn/one-cable-many-devices.md).

**GPIO**
:   A pin software can read, or drive high or low. Five of them connect the two
    chips on this board.

## H

**Hypervisor**
:   A thin layer of software that sits beneath an operating system and controls
    what it may touch. One stage of this board's Linux-side boot chain. See
    [From power to prompt](learn/from-power-to-prompt.md).

## I

**Idempotent**
:   Doing it twice has the same effect as doing it once. The property that makes
    `bootstrap.sh` a recovery path rather than a one-shot. See
    [From factory to this](learn/from-factory-to-this.md).

**initrd**
:   A small temporary filesystem loaded into RAM alongside the Linux kernel,
    holding just enough to find and mount the real one. See
    [From power to prompt](learn/from-power-to-prompt.md).

**Interrupt**
:   Hardware stopping whatever the processor was doing to run a specific
    function immediately. The LED matrix refresh is one, firing every 10
    microseconds.

## J

**Jiffies**
:   The unit `/proc/stat` counts CPU time in. Not seconds — a tick whose length
    depends on the kernel's configuration, which is why the CPU percentages are
    computed from *differences* between two readings rather than from one. See
    [The Linux side](learn/the-linux-side.md).

## K

**Kconfig**
:   The system that decides which software features get compiled in. Distinct
    from devicetree, which describes what hardware exists — the two must agree,
    and most "device not ready" errors are them disagreeing. See
    [How the build knows your hardware](learn/how-the-build-knows-your-hardware.md).

## L

**Linker**
:   The last step of a build, which joins the separately compiled pieces into
    one program. A *linker error* means one piece refers to something no other
    piece provides. See
    [How the build knows your hardware](learn/how-the-build-knows-your-hardware.md).

## M

**MCU** (microcontroller unit)
:   The small chip. One core, 786 KB of memory, no operating system underneath
    you, and timing you can rely on. Here, an STM32U585.

**MCUboot**
:   The bootloader on the microcontroller. Keeps two firmware slots, boots the
    right one, and reverts an update that never confirms itself. See
    [Updating safely](learn/updating-safely.md).

**MPU** (microprocessor unit)
:   The big chip. Four 64-bit cores, gigabytes of memory, Debian Linux, and no
    timing guarantees whatsoever. Here, a Qualcomm QRB2210.

    (Confusingly, the same three letters also mean *memory protection unit* in
    Arm documentation. This course always means the processor.)

## N

**native_sim**
:   A Zephyr target that compiles firmware as an ordinary program for the
    board's Linux side, so logic can be tested in seconds without the chip. See
    [Knowing it works](learn/knowing-it-works.md).

**NCM / RNDIS**
:   Two USB standards for pretending to be a network adapter. NCM is the modern
    one and what the gadget is built with; RNDIS is Microsoft's older one, kept
    as a build-time alternative for a host with no NCM driver. Only one of them
    is ever offered — see [IP over USB](reference/usb.md).

## O

**Overlay**
:   A small devicetree file layered on top of the board's, so you can change
    what the board description says without forking it. This project's is 38
    lines.

## P

**Persistence of vision**
:   The reason a panel that lights one LED at a time looks like a steady
    picture. The matrix sweeps all 104 LEDs about a thousand times a second;
    your eye integrates. See [The LED matrix](learn/the-led-matrix.md).

**Prescaler**
:   A divider in front of a timer, which makes it count more slowly than the
    clock feeding it. This project sets one on the timer that paces the LED
    matrix. See
    [How the build knows your hardware](learn/how-the-build-knows-your-hardware.md).

**`/proc/stat`**
:   A file that is not a file. Reading it asks the kernel for CPU counters,
    formatted as text, generated at the moment you read. The source of every
    number this project's demo displays. See [The Linux side](learn/the-linux-side.md).

## R

**Rasterizer**
:   The code that turns "core 2 is at 47%" into which pixels are lit at what
    brightness. Pure arithmetic with no hardware in it, which is exactly why it
    can be tested without the chip.

**Real-time**
:   Not "fast". Guaranteeing that something happens **by a deadline**. Linux is
    much faster than the microcontroller and cannot make that guarantee; the
    microcontroller is slow and can. This distinction is most of the argument
    for a board with both.

## S

**Sysfs**
:   Another filesystem that is not files — `/sys` exposes kernel objects as
    directories, which is how this project reads and writes the LEDs.

**systemd**
:   What starts and supervises everything on the Linux side. A *unit* is one
    thing it manages. See [The Linux side](learn/the-linux-side.md).

**SWD** (Serial Wire Debug)
:   Two wires that let one chip write flash on another, halt it, and read its
    registers. How firmware gets onto the microcontroller the first time.

## T

**tio**
:   A serial terminal: it shows whatever arrives on a serial line and sends
    whatever you type. How you talk to the microcontroller's shell by hand. See
    [The microcontroller side](learn/the-microcontroller-side.md).

**Trigger (LED)**
:   A kernel feature that wires an LED to an event source — disk activity, wifi
    traffic — so it blinks without any program driving it. Three of them are
    registered on this board and none of them fire. See
    [Four lights that tell the truth](learn/four-lights.md).

## U

**UART**
:   The hardware behind a plain serial line: bytes, one bit at a time, on a pair
    of wires. On the Linux side it appears as the file `/dev/ttyHS1`.

**Unit (systemd)**
:   One thing systemd manages — a service, a mount, a timer. This project adds
    about half a dozen.

## W

**west**
:   Zephyr's meta-tool: manages the workspace, the several repositories in it,
    and wraps the build. See [From source to a running chip](learn/from-source-to-chip.md).

## Z

**Zephyr**
:   The real-time operating system running on the microcontroller. Small enough
    to fit in tens of kilobytes, and honest about being an operating system for
    one program rather than many. See
    [The microcontroller side](learn/the-microcontroller-side.md).

**ztest**
:   Zephyr's unit-testing framework. Runs on the chip, or on the Linux side via
    `native_sim`.
