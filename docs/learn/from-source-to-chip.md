<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# From source to a running chip

You have written C for the microcontroller. It is a text file on the Linux side.
Getting it running on the other chip involves two steps that do not exist in
ordinary programming: **cross-compiling** it, and **flashing** it.

## Cross-compiling

When you run `gcc hello.c` on this board, you get a program for *this* chip:
64-bit ARM, running Linux, using the system's C library.

The microcontroller is none of those things. It is a 32-bit Cortex-M33, running
no Linux, with a different instruction encoding and a different idea of what a
function call even looks like. A program compiled for the Linux side is not
merely slow on it — it is meaningless.

So you need a second compiler: one that *runs* on this machine but *produces
code for* the other. That is a **cross-compiler**, and by convention it is named
after its target:

```bash
~/zephyr-sdk-1.0.1/gnu/arm-zephyr-eabi/bin/arm-zephyr-eabi-gcc --version
```

Every part of the name describes the code it *produces*, not the machine it
runs on: `arm` is the processor that code is for, `zephyr` the system it will
run under, `eabi` the calling convention (how functions pass arguments to each
other), and `gcc` is the tool itself. Alongside it are `arm-zephyr-eabi-objdump`, `-gdb`, `-size`
and the rest — the whole toolchain, doubled.

**Try it.** The difference is visible:

```bash
cd ~/zephyrproject/build/zephyr
file zephyr.elf
```

```
ELF 32-bit LSB executable, ARM, EABI5 version 1 (SYSV), statically linked, with debug_info, not stripped
```

ELF is the file format compilers produce for a finished program: the machine
code, plus a header saying what kind of machine it is for. `file` is reading
that header.

Compare that with any Linux program:

```bash
file /bin/ls        # ELF 64-bit LSB pie executable, ARM aarch64
```

Two different machines, one directory.

## Why `west` and not `make`

Zephyr is not one repository. It is Zephyr itself plus dozens of separate
projects — the hardware abstraction layer for STM32, the C library, the
bootloader, cryptography — each versioned independently.

**`west`** is the tool that manages that. It reads a *manifest* listing which
projects at which versions, fetches them, and then drives the actual build.

```bash
cd ~/zephyrproject
./.venv/bin/west list | head
```

The thing worth knowing: `west build` only works **from inside the workspace**.
It finds the workspace by looking at your current directory and walking upwards.
Run it from somewhere else and you get

```
west: unknown command "build"; do you need to run this inside a workspace?
```

which reads like west is broken but means "I cannot see a workspace from here".

This project wraps all of it:

```bash
zbuild
```

With nothing after it, `zbuild` builds this project's own firmware, the code in
`mcu/app`. It sets the board, points at the right workspace, builds, and signs the result
(more on signing in [Updating safely](updating-safely.md)). What comes out:

| File | What it is |
|---|---|
| `zephyr.elf` | Full binary with debug information — what the debugger reads |
| `zephyr.hex` | Addresses and bytes, in text — what the flasher usually wants |
| `zephyr.bin` | Raw bytes only, no addresses |
| `zephyr.signed.hex` | The same program with a signature the bootloader checks |

## Getting it onto the chip

The program is on the Linux filesystem. It needs to be in the microcontroller's
flash memory. There are two ways, and this project uses both.

### SWD — the wires

**SWD** (Serial Wire Debug) is a two-wire protocol built into ARM chips that
gives you near-total control from outside: halt the processor, read and write
any memory address, single-step, and write flash. It works even if the chip's
own program is broken, which is exactly when you need it.

Normally you would need a **debug probe** for this: a small USB adapter that
sits between your computer and the chip and speaks SWD for you. This board has
none. Instead, Linux **bit-bangs** SWD directly on GPIO pins — driving the two
wires in software, one edge at a time, via `libgpiod`, the standard Linux
library for setting and reading pins. The software doing it is **OpenOCD**:

```bash
zflash
```

With nothing after it, `zflash` writes the image `zbuild` just made:
`~/zephyrproject/build/zephyr/zephyr.signed.hex`.

```
** Programming Started **
Info : device idcode = 0x30076482 (STM32U57/U58xx)
Info : flash size = 2048 KiB
** Programming Finished **
** Verify Started **
** Verified OK **
```

> Two errors always appear in that output — `Translation from khz to adapter
> speed not implemented` and `Execution of event reset-init failed`. They are
> harmless: the bit-bang adapter has no configurable clock speed, so the
> speed-setting step fails and the flash proceeds anyway. Noisy, not broken.
> [troubleshooting.md](../reference/troubleshooting.md) says so too, because everyone asks.

### Over the serial wire

Once a bootloader is installed, you can also send new firmware down the same
UART used for the shell — no debug wires, no halting the processor. That is a
firmware update over the wire, usually called **FOTA** — firmware over the air,
even when the air is a cable — and it is the whole of a later chapter,
[Updating safely](updating-safely.md).

The difference matters: SWD is how you recover a board with broken firmware,
because it does not depend on that firmware working. Serial updates are how you
update a *working* board conveniently.

## The first flash is different

An important wrinkle. This project's firmware is built to run **underneath a
bootloader**, which expects to live at the start of flash with the application
after it. So the very first time, both must be written:

```bash
~/two-computers-one-board/mcu/flash-all.sh        # bootloader + application, in order
```

You do not need to run that now. `bootstrap.sh` already did, when it set the
board up, which is why plain `zflash` works for you. You need it again only
after erasing the chip or changing the bootloader.

Flash only the signed application onto a blank chip and nothing runs. The
application is sitting at an address nothing jumps to, with no bootloader in
front of it to do the jumping. The chip is fine; it just has no starting point.

## Try it: change something and watch it happen

The firmware prints one line on the serial wire every time it starts. Change a
word of it, and see your word come back from the other chip.

Open `~/two-computers-one-board/mcu/app/src/main.c` in an editor and find this
line near the bottom, in `main()`:

```c
printk("\n=== UNO Q MCU up: %s ===\n", CONFIG_BOARD_TARGET);
```

Change `up` to a word of your own — `awake`, say — and save.

That line is printed once, at the moment the chip starts, so you have to be
listening before it restarts. You can be: flashing goes over the SWD wires and
does not touch the serial line, which leaves the serial line free for a
listener. Open a **second terminal** on the board and start one there:

```bash
sudo systemctl stop unoq-cpu-bars      # the demo is holding the serial line
mcucon                                 # read-only: prints whatever the MCU sends
```

Back in the first terminal, build and flash:

```bash
zbuild                                 # ~1 minute
zflash
```

`zflash` ends by resetting the chip. Watch the second terminal: the firmware
starts, and among its first lines is yours, beginning `=== UNO Q MCU awake:`.
You changed a text file on one computer and a different computer said the word.

Stop `mcucon` with `Ctrl-C`, and ask the chip how long it has been running:

```bash
cd ~/two-computers-one-board
./.venv/bin/python -c "
from unoq import MCU
with MCU() as mcu: print(mcu.status())
"
sudo systemctl start unoq-cpu-bars
```

Look at `uptime_ms` in the output: it will be a few seconds. You just restarted
a computer.

Put the word back if you like, then `zbuild` and `zflash` once more. This
undoes the edit:

```bash
git -C ~/two-computers-one-board checkout mcu/app/src/main.c
```

> [!TIP]
> **Go deeper** — Zephyr's
> [west documentation](https://docs.zephyrproject.org/latest/develop/west/index.html)
> explains the workspace model, and
> [CMake's reference](https://cmake.org/cmake/help/latest/) is what you will
> need the first time you add a source file. If you want to be able to read what
> a cross-compiler produced, the free
> [CS:APP lab assignments](https://csapp.cs.cmu.edu/3e/labs.html) teach exactly
> that skill.

## Check yourself

1. Why can't you run `gcc` on your MCU source and flash the result?
2. `west build` says "unknown command". The binary exists and works. Why?
3. You flash a signed application onto a completely blank chip. Verification
   passes and nothing runs. What is missing?

<details markdown="1">
<summary>Answers — try each one first</summary>

1. **Because `gcc` on this board produces a program for this board's chip.**
   That is 64-bit ARM running Linux; the microcontroller is a 32-bit
   Cortex-M33 with no Linux and a different instruction encoding. You need the
   cross-compiler, `arm-zephyr-eabi-gcc`, which runs here but produces code
   for the other chip.
2. **You are not inside the workspace.** `west` finds the workspace by walking
   upwards from your current directory, and `build` only exists once it has
   found one. Nothing is broken; run it from `~/zephyrproject`, or use
   `zbuild`.
3. **The bootloader.** The application is built to sit after a bootloader at
   the start of flash, so on a blank chip it is at an address nothing jumps
   to. The first flash must write both, which is what `flash-all.sh` does.

</details>

Next: [How the build knows your hardware](how-the-build-knows-your-hardware.md)
— how that build knew this board has an LED panel, a TIM17 and a console on
lpuart1, because it did not detect any of it.
