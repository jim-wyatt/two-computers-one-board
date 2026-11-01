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

**ADC** (analog-to-digital converter)
:   Hardware that turns a voltage into a number. The microcontroller's
    temperature sensor is read through one, and the read has to wait for the
    conversion to finish — which is why an interrupt handler cannot do it. See
    [Two clocks, one record](learn/two-clocks-one-record.md).

**Admonition**
:   A callout box, like the tip above. Nothing to do with the board; mentioned
    because the documentation uses them for asides you can safely skip.

**Advisory lock**
:   A lock that stops only the programs that ask for it. pyserial's
    `exclusive=True` takes one, so `tio` and `cat` walk straight through it;
    the kernel-enforced lock is a separate `ioctl`. See
    [Debugging without a screen](learn/debugging-without-a-screen.md).

## B

**Baud rate**
:   How many signal changes per second a serial line carries. This board's
    MPU↔MCU link runs at 115200, which works out at roughly 9 ms for a
    104-byte message. See [How they talk](learn/how-they-talk.md).

**Bind guard**
:   The USB gadget's trial. It counts boots on which the gadget was bound and
    the board did not stay up for two minutes; after three in a row it stops
    binding and keeps the network, so the board can still be reached. See
    [One cable, many devices](learn/one-cable-many-devices.md) and
    [Trial, confirm, roll back](learn/trial-confirm-roll-back.md).

**Binding (devicetree)**
:   A file that says which properties a kind of hardware may have and what they
    mean — the schema for a devicetree node. See
    [How the build knows your hardware](learn/how-the-build-knows-your-hardware.md).

**Binding (USB)**
:   Writing a USB controller's name into a gadget's `UDC` file, which is the
    moment the board actually appears on the host computer. See
    [One cable, many devices](learn/one-cable-many-devices.md).

**Bit-banging**
:   Driving a protocol's wires from software, one voltage change at a time,
    instead of with hardware built for it. Linux bit-bangs SWD on two GPIO
    pins, which is why this board needs no debug probe. See
    [From source to a running chip](learn/from-source-to-chip.md).

**BOOT0**
:   A single wire, sampled by the microcontroller at reset, that selects between
    running your firmware and sitting in the chip's own ROM bootloader. Driven
    by Linux. Get it wrong and a perfectly good board looks dead — this is the
    single most expensive mistake available on this hardware.

**Boot counting**
:   systemd-boot's trial for a new kernel. The kernel's entry starts with three
    tries, one is spent at each boot, and the boot is marked good only once it
    has finished and `sshd` is up. An entry with no tries left sorts last, so
    the previous kernel boots instead. See
    [Trial, confirm, roll back](learn/trial-confirm-roll-back.md).

**Bootloader**
:   A small program that runs before the real one, decides what to start, and
    starts it. This board has a chain of them on the Linux side and one
    (MCUboot) on the microcontroller.

**Bricking**
:   Leaving a device unable to boot far enough to be told anything, so that the
    only fix is a physical visit. The failure that two firmware slots and a
    probation period exist to prevent. See
    [Updating safely](learn/updating-safely.md).

**Brown-out**
:   The supply voltage dropping far enough that a chip resets. Binding the USB
    gadget on a weak port can cause one, and the board then boots, binds and
    browns out again, which is what the bind guard breaks. See
    [One cable, many devices](learn/one-cable-many-devices.md).

## C

**Charlieplexing**
:   A wiring trick that drives *n* × (*n*−1) LEDs from *n* pins, by exploiting
    the fact that a microcontroller pin can be an input as well as high or low.
    Eleven pins, 104 LEDs. See [The LED matrix](learn/the-led-matrix.md).

**`CLOCK_MONOTONIC`**
:   A Linux clock that only ever moves forward and never jumps when the wall
    clock is corrected. Deadlines are set against it so that an NTP adjustment
    cannot move them. See [Jitter, measured](learn/jitter-measured.md).

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

**Daemon**
:   A program that runs in the background, with no terminal attached, usually
    for as long as the machine is up. On this board a daemon is started and
    supervised by systemd: the CPU-bars demo and the temperature logger are
    both daemons. See [The Linux side](learn/the-linux-side.md).

**DDR**
:   The kind of RAM on the Linux side of the board. It cannot be used until an
    early boot stage has measured its timing and tuned the memory controller to
    match, which is called *training* it. See
    [From power to prompt](learn/from-power-to-prompt.md).

**Deadline (absolute)**
:   Scheduling the *k*-th event at `start + k × period`, worked out from *k*
    each time, instead of sleeping for one period after the last event. A late
    wake-up then delays one event rather than every event after it. See
    [Jitter, measured](learn/jitter-measured.md).

**Debug probe**
:   A small adapter that sits between a computer and a chip and speaks a debug
    protocol such as SWD for it. This board has none: Linux drives the SWD wires
    itself. See [From source to a running chip](learn/from-source-to-chip.md).

**Deterministic**
:   The same input produces not just the same output but the same *timing*.
    The microcontroller can promise it, because nothing else is running; Linux
    cannot. See [Two computers on one board](learn/two-computers.md).

**`/dev`**
:   Where Linux presents devices as files. `/dev/ttyHS1` is the serial line to
    the microcontroller: read it for the bytes the MCU sent, write to it to send
    bytes back. See [The Linux side](learn/the-linux-side.md).

**Devicetree**
:   A description of what hardware exists and how it is wired, as data rather
    than code. Compiled into C macros at build time — there is no devicetree
    parser on the chip. See
    [How the build knows your hardware](learn/how-the-build-knows-your-hardware.md).

## E

**EFI system partition**
:   The small partition on the eMMC that the UEFI firmware reads boot entries
    from. systemd-boot's one-file-per-kernel entries, their try counters and
    the rescue entry all live there. See
    [Trial, confirm, roll back](learn/trial-confirm-roll-back.md).

**ELF**
:   The file format a compiler produces for a finished program: the machine
    code, plus a header saying what kind of machine it is for. `zephyr.elf` is
    the firmware in that form. See
    [From source to a running chip](learn/from-source-to-chip.md).

**eMMC**
:   The storage chip soldered to the board, which holds Linux and everything in
    its filesystem. See [From power to prompt](learn/from-power-to-prompt.md).

**Enumeration (USB)**
:   The host noticing a newly attached device, asking it what it is, and giving
    it an address. Binding the gadget makes the host enumerate the board, and
    the current that draws is what can brown it out. See
    [One cable, many devices](learn/one-cable-many-devices.md).

## F

**Firmware**
:   The program running on the microcontroller. The word is doing real work: it
    is the *only* program there, with no operating system beneath it in the
    sense Linux means.

**Flash (memory)**
:   The microcontroller's permanent storage: 2 MB, survives power off, written
    rarely and in blocks. The firmware executes directly out of it, which is why
    *flashing* — writing it — is how a program gets onto the chip. See
    [The microcontroller side](learn/the-microcontroller-side.md) and
    [From source to a running chip](learn/from-source-to-chip.md).

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

**Governor**
:   The kernel's rule for choosing the CPU cores' clock speed, set by writing
    its name to a file under `/sys`. `schedutil` is the kernel's default;
    provisioning sets `ondemand`. See [The Linux side](learn/the-linux-side.md).

**GPIO**
:   A pin software can read, or drive high or low. Five of them connect the two
    chips on this board.

## H

**Histogram**
:   A count of how many measurements fell into each of a set of ranges, called
    *bins*. `unoq-jitter` prints three of them side by side. See
    [Jitter, measured](learn/jitter-measured.md).

**Host and device (USB)**
:   The two ends of every USB connection. The host supplies power, asks what is
    attached and starts every transfer; the device only answers. The board's
    port can be either, but never both at once. See
    [One cable, many devices](learn/one-cable-many-devices.md).

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

**Interrupt context**
:   The state of running *because* an interrupt fired, rather than as a thread.
    Code there must never wait — a wait would hold up everything on the chip —
    so it does the minimum and hands the rest to a thread as a work item. See
    [Two clocks, one record](learn/two-clocks-one-record.md).

**`ioctl`**
:   A catch-all system call for device-specific settings that `read` and
    `write` cannot express. `TIOCEXCL` is the one that marks a serial port
    exclusive, so a second `open()` fails. See
    [Debugging without a screen](learn/debugging-without-a-screen.md).

## J

**Jiffies**
:   The unit `/proc/stat` counts CPU time in. Not seconds — a tick whose length
    depends on the kernel's configuration, which is why the CPU percentages are
    computed from *differences* between two readings rather than from one. See
    [The Linux side](learn/the-linux-side.md).

**Jitter**
:   How far each event lands from where it was meant to be in time. Linux's
    jitter has a short middle and a long tail; the microcontroller's hardware
    timers have almost none. See [Jitter, measured](learn/jitter-measured.md).

**Journal**
:   systemd's log. `journalctl -u <unit>` shows one unit's lines, and
    `journalctl -b -1` the previous boot's, which is where the evidence is when
    something reset the board. See
    [Debugging without a screen](learn/debugging-without-a-screen.md).

## K

**Kconfig**
:   The system that decides which software features get compiled in. Distinct
    from devicetree, which describes what hardware exists — the two must agree,
    and most "device not ready" errors are them disagreeing. See
    [How the build knows your hardware](learn/how-the-build-knows-your-hardware.md).

## L

**Link-local address**
:   An address in `169.254.0.0/16` that a machine gives itself when no DHCP
    server answers. Both ends of the USB cable fall back to one, so they still
    find each other with nothing configured. See
    [One cable, many devices](learn/one-cable-many-devices.md).

**Linker**
:   The last step of a build, which joins the separately compiled pieces into
    one program. A *linker error* means one piece refers to something no other
    piece provides. See
    [How the build knows your hardware](learn/how-the-build-knows-your-hardware.md).

## M

**Mask ROM**
:   The first code the Qualcomm chip runs, burned into the silicon at
    manufacture and unchangeable. Its one job is to find and verify the next
    boot stage. See [From power to prompt](learn/from-power-to-prompt.md).

**MCU** (microcontroller unit)
:   The small chip. One core, 786 KB of memory, no operating system underneath
    you, and timing you can rely on. Here, an STM32U585.

**MCUboot**
:   The bootloader on the microcontroller. Keeps two firmware slots, boots the
    right one, and reverts an update that never confirms itself. See
    [Updating safely](learn/updating-safely.md).

**mDNS**
:   Resolving a `.local` name by asking the local network rather than a server,
    which is how `ssh arduino@uno-q.local` finds the board whatever address it
    was given. See [One cable, many devices](learn/one-cable-many-devices.md).

**MPU** (microprocessor unit)
:   The big chip. Four 64-bit cores, gigabytes of memory, Debian Linux, and no
    timing guarantees whatsoever. Here, a Qualcomm QRB2210.

    (Confusingly, the same three letters also mean *memory protection unit* in
    Arm documentation. This course always means the processor.)

**Multiplexing (display)**
:   Lighting LEDs one at a time, in turn, fast enough that persistence of
    vision shows them all lit at once. The reason 104 LEDs need only 11 pins,
    and the reason the refresh is a timing job. See
    [The LED matrix](learn/the-led-matrix.md).

**Mutation testing**
:   Breaking the code on purpose to check that the *right* test goes red. A
    suite that passes the first time may be asserting nothing. See
    [Knowing it works](learn/knowing-it-works.md).

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
    what the board description says without forking it. This project's is under
    sixty lines.

## P

**Persistence of vision**
:   The reason a panel that lights one LED at a time looks like a steady
    picture. The matrix sweeps all 104 LEDs about a thousand times a second;
    your eye integrates. See [The LED matrix](learn/the-led-matrix.md).

**Preemption**
:   The kernel taking the processor away from a running program because
    something else needs it. Linux does it constantly and your program cannot
    refuse; on the microcontroller nothing else exists to preempt you. See
    [Two computers on one board](learn/two-computers.md).

**Prescaler**
:   A divider in front of a timer, which makes it count more slowly than the
    clock feeding it. This project sets one on the timer that paces the LED
    matrix. See
    [How the build knows your hardware](learn/how-the-build-knows-your-hardware.md).

**Probation**
:   The time between a new firmware image's first boot and its confirmation.
    An image still on probation is undone by the next reset. See
    [Updating safely](learn/updating-safely.md).

**`/proc/stat`**
:   A file that is not a file. Reading it asks the kernel for CPU counters,
    formatted as text, generated at the moment you read. The source of every
    number this project's demo displays. See [The Linux side](learn/the-linux-side.md).

**Provisioning**
:   Taking a board from the state it shipped in to the state the course is
    taught on, by script. The numbered scripts under `provision/` are this
    project's, and `bootstrap.sh` runs them in order. See
    [From factory to this](learn/from-factory-to-this.md).

**Pull and push**
:   Who moves the data. *Push*: the side that has it sends it, whether or not
    anyone is listening. *Pull*: the side that has it keeps it until asked. The
    temperature log pulls, so a minute with Linux away loses nothing. See
    [Two clocks, one record](learn/two-clocks-one-record.md).

**PWM** (pulse-width modulation)
:   A level expressed as a fraction of time switched on, too fast to see. How
    a panel whose LEDs are only on or off shows eight brightnesses, and the
    name of the hardware square wave the jitter tool measures. See
    [The LED matrix](learn/the-led-matrix.md) and
    [Jitter, measured](learn/jitter-measured.md).

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

**Register**
:   A fixed address built into the chip that controls or reports a piece of
    hardware. On the microcontroller, a pin is a bit in one: write the bit and
    the voltage changes, with no driver or kernel in between. See
    [The microcontroller side](learn/the-microcontroller-side.md).

**Rescue entry**
:   A boot entry that mounts no root filesystem at all: it brings the USB cable
    up as a network link at `169.254.77.1` and starts an SSH server, so there is
    a way in when every kernel has failed. Added by `--with-rescue-entry`. See
    [Trial, confirm, roll back](learn/trial-confirm-roll-back.md).

**`REVERT:` line**
:   The comment near the top of every provisioning script giving the commands
    that undo it. A change that cannot be undone in a couple of commands is
    probably too broad. See [From factory to this](learn/from-factory-to-this.md).

**Ring buffer**
:   A store of fixed size where the newest entry overwrites the oldest. The
    microcontroller keeps its last 600 temperature samples in one: ten minutes,
    which is how long Linux can be away without losing any. See
    [Two clocks, one record](learn/two-clocks-one-record.md).

## S

**Scheduler**
:   The part of an operating system that decides which runnable thread gets a
    core, and when. Linux's is built to be fair and to get a lot done overall;
    Zephyr's honors priorities strictly. The difference is the whole of
    [Jitter, measured](learn/jitter-measured.md).

**Sequence number**
:   A count stamped on each sample, going up by one every time. It is the one
    predictable thing about a sample, which is what makes a missing one
    noticeable. See [Two clocks, one record](learn/two-clocks-one-record.md).

**Serialization**
:   Turning a value into bytes so it can cross a wire, and turning the bytes
    back into a value on the other side. The only way anything gets from one
    chip to the other, because they share no memory. See
    [Two computers on one board](learn/two-computers.md).

**Shell (MCU)**
:   The command line the firmware runs over the serial wire. Type at it with
    `tio`; the project's "protocol" is its commands and their one-line replies.
    See [The microcontroller side](learn/the-microcontroller-side.md) and
    [How they talk](learn/how-they-talk.md).

**Shortcuts** (`zbuild`, `zflash`, `mcucon`, `hpy`)
:   Defined by `env.sh`, which `~/.bashrc` sources after setup. Build and sign
    the firmware, flash it over SWD, watch the MCU's console, and run the
    project's own Python. See
    [From source to a running chip](learn/from-source-to-chip.md).

**Signed image**
:   A firmware image carrying a signature MCUboot checks before running it.
    `zbuild` signs with MCUboot's published sample key, so on this board the
    check proves the image is intact, not whose it is. See
    [Updating safely](learn/updating-safely.md).

**Slot**
:   One of the two regions of flash MCUboot keeps a firmware image in. Slot 0
    is what runs; slot 1 is where an update is written, so the running image is
    never overwritten by a download. See
    [Updating safely](learn/updating-safely.md).

**Stub (test)**
:   A fake version of a program — `ip`, `systemctl`, `nmcli` — put ahead of the
    real one on `PATH`, so a shell script runs unmodified while nothing reaches
    the board. The test then asserts on what the script *would* have run. See
    [Knowing it works](learn/knowing-it-works.md).

**Swap**
:   Parking memory that is not being used right now on storage, to make room.
    Less alarming on this board than the word suggests. See
    [The Linux side](learn/the-linux-side.md).

**Sysfs**
:   Another filesystem that is not files — `/sys` exposes kernel objects as
    directories, which is how this project reads and writes the LEDs.

**systemd**
:   What starts and supervises everything on the Linux side. A *unit* is one
    thing it manages. See [The Linux side](learn/the-linux-side.md).

**systemd-boot**
:   The boot loader that picks the kernel on this board. It reads one small
    text file per kernel from the EFI partition, spends a try by renaming the
    file, and boots the entry that sorts first. See
    [Trial, confirm, roll back](learn/trial-confirm-roll-back.md).

**SWD** (Serial Wire Debug)
:   Two wires that let one chip write flash on another, halt it, and read its
    registers. How firmware gets onto the microcontroller the first time.

## T

**Tail (of a distribution)**
:   The rare, worst measurements, far from the typical one. Load barely moves
    the middle of Linux's timing and stretches the tail about threefold, and
    the tail is what breaks a real-time job. See
    [Jitter, measured](learn/jitter-measured.md).

**Thermal zone**
:   A temperature sensor the kernel exposes as a file under
    `/sys/class/thermal/`. The board has several; the microcontroller's own
    die temperature is not one of them, because it is on the other chip. See
    [The Linux side](learn/the-linux-side.md).

**Time-sharing**
:   Many processes taking turns on the same cores, with the kernel deciding who
    runs and for how long. The reason Linux cannot promise *when* your code
    runs. See [Two computers on one board](learn/two-computers.md).

**tio**
:   A serial terminal: it shows whatever arrives on a serial line and sends
    whatever you type. How you talk to the microcontroller's shell by hand. See
    [The microcontroller side](learn/the-microcontroller-side.md).

**Toolchain**
:   The compiler, assembler, linker, debugger and the tools around them, as a
    matched set for one target. The cross-toolchain's tools are all named
    `arm-zephyr-eabi-*`, after the code they produce. See
    [From source to a running chip](learn/from-source-to-chip.md).

**Trigger (LED)**
:   A kernel feature that wires an LED to an event source — disk activity, wifi
    traffic, a timer — so it blinks without any program driving it. Every blink
    this project shows uses the `timer` one; the three disk triggers registered
    on this board never fire. See
    [Four lights that tell the truth](learn/four-lights.md).

**TrustZone**
:   Arm's name for a walled-off "secure world" on the same processor, which the
    main operating system cannot see into. One stage of the Linux-side boot
    chain sets it up. See [From power to prompt](learn/from-power-to-prompt.md).

## U

**U-Boot**
:   The open-source bootloader stage on the Linux side. It presents a standard
    UEFI interface, finds the kernel and starts it, and its own devicetree names
    the control lines to the microcontroller. See
    [From power to prompt](learn/from-power-to-prompt.md).

**UART**
:   The hardware behind a plain serial line: bytes, one bit at a time, on a pair
    of wires. On the Linux side it appears as the file `/dev/ttyHS1`.

**Unit (systemd)**
:   One thing systemd manages — a service, a mount, a timer. This project adds
    about half a dozen.

## V

**venv**
:   A private Python installation for one project, so its packages cannot
    collide with the system's. This project's is `.venv` in the checkout, and
    `hpy` runs the Python inside it. See
    [From factory to this](learn/from-factory-to-this.md).

## W

**Watchdog**
:   A hardware timer that resets the chip unless software keeps proving it is
    alive by *feeding* it. The microcontroller's is armed by the firmware,
    with an eight-second timeout, and fed only while the LED panel's refresh is
    making progress; the Linux side's is optional (`--with-watchdog`). See
    [Debugging without a screen](learn/debugging-without-a-screen.md).

**west**
:   Zephyr's meta-tool: manages the workspace, the several repositories in it,
    and wraps the build. See [From source to a running chip](learn/from-source-to-chip.md).

**Work item**
:   A job handed to a thread to run later, so that whoever queued it — usually
    an interrupt handler or a timer callback — can return at once. Zephyr's
    *workqueue* is the thread that runs them. See
    [Two clocks, one record](learn/two-clocks-one-record.md).

**Workspace (west)**
:   The directory holding Zephyr and the projects it depends on, here
    `~/zephyrproject`. `west build` finds it by walking upwards from the current
    directory, and reports "unknown command" from anywhere else. See
    [From source to a running chip](learn/from-source-to-chip.md).

## X

**XBL**
:   Qualcomm's boot stage that configures the memory controller, so that the
    board's RAM exists at all. Signed, closed, and the bottom of what can be
    read. See [From power to prompt](learn/from-power-to-prompt.md).

## Z

**Zephyr**
:   The real-time operating system running on the microcontroller. Small enough
    to fit in tens of kilobytes, and honest about being an operating system for
    one program rather than many. See
    [The microcontroller side](learn/the-microcontroller-side.md).

**ztest**
:   Zephyr's unit-testing framework. Runs on the chip, or on the Linux side via
    `native_sim`.
