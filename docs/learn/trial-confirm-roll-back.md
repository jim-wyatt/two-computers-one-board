<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# Trial, confirm, roll back

[Updating safely](updating-safely.md) ended on a hint: once you have seen the
pattern, it turns up everywhere something can strand you. This chapter follows
it down the board. The firmware on the microcontroller, the Linux kernel, the
USB gadget and the boot entries each have their own way of being wrong, and
this project answers all four with the same three words.

**Trial.** A new thing runs, but it is not trusted yet.
**Confirm.** Only once it has proved it can do the job is it kept.
**Roll back by default.** If nothing confirms it, the next boot puts the old
state back, and nobody has to notice anything went wrong for that to happen.

The last part is the one that matters. Nothing has to *detect* a failure. A
board that hangs, crashes or loses power before confirming simply does not
confirm, and that is enough.

## Four layers, one idea

| Layer | On trial | Confirmed when | If it never confirms | Shown on |
|---|---|---|---|---|
| MCU firmware (MCUboot) | a new image, marked pending | the firmware calls `confirm` | the next reset swaps the old image back | LED 3, slow yellow |
| Linux kernel (boot counting) | a new kernel's entry, `…+3.conf` | the boot finished and `sshd` is up | after three tries its entry sorts last, and the previous kernel boots | LED 2, slow yellow, then slow blue |
| USB gadget (the bind guard) | each boot that binds the gadget | the board stayed up two minutes | after three such boots it stops binding and keeps the network | LED 2, fast red |
| Boot entries (the rescue entry) | every kernel entry | any kernel is marked good | once every kernel entry has run out of tries, they all sort below the rescue entry, and it boots | LED 2, slow blue |

The first row is [Updating safely](updating-safely.md). The last is the odd one
out: nothing about the rescue entry is updated, it is where the board lands
when every row above it has rolled back as far as it can. The rest of this page
is the other three, and then the honest part: what each one cannot catch.

## The kernel: three tries, then the previous one

Linux on this board starts from systemd-boot, which reads small text files on
the EFI partition, one per kernel. With boot counting on, a new kernel's file
is named with a counter: `…-7.0.1+3.conf` has three tries. Before it starts
the kernel, systemd-boot renames the file to spend one (`+2-1`: two left, one
used). If the boot is later marked good, the counter is dropped from the name
and the entry is ordinary again. An entry at `+0` has no tries left, and
systemd-boot sorts it below every other, so the next boot is the previous
kernel.

None of that needed new software. It is systemd's own boot counting, and the
first question was only whether this board's U-Boot lets systemd-boot rename a
file before Linux runs. A counted boot answered it: the entry was renamed, and
the boot logged

```
Marked boot as 'good'. (Boot attempt counter is at 1.)
```

The same test showed the trap. **As shipped, the boot was marked good in its
first second**, because nothing on the stock image waits before the step that
marks it. That is the MCU's "confirm in the first line of `main`" mistake, one
layer up: a counter that calls every boot good protects nothing. So the project
adds `unoq-boot-health.service`, which `systemd-bless-boot` waits for. It
passes once the boot has finished and `sshd` is listening, a minute in. That is
the thing you would have to visit the board to restore.

The fallback was tried too, with an entry built never to confirm: a copy of
the running kernel's entry, three tries, and an option that reboots it as soon
as it starts. Three boots, each straight back to a reboot, and then the stock
entry, with nobody touching the board. It took one minute and forty-five
seconds.

`./bootstrap.sh --with-boot-counting` turns this on.
[Troubleshooting](../reference/troubleshooting.md#a-new-kernel-that-did-not-come-up)
has the details.

## The gadget: the bind guard

The USB gadget has a failure the other layers do not: on a weak port, binding
it can drop the supply far enough to reset the board, which then boots, binds
and resets again. [One cable, many devices](one-cable-many-devices.md) told
that story. The guard is the same pattern. Each boot that binds is on trial;
staying up for two minutes confirms it and clears the count; three boots in a
row that never confirm, and the next one does not bind. It rolls back to a
board without the gadget and with wifi on, which is a board you can still
reach. [usb.md](../reference/usb.md#the-bind-guard) has how to live with it.

Unlike kernel fallback, this one turns LED 2 red. Its roll-back leaves
something switched off that a human has to switch on again.

## The rescue entry: a way in with nothing mounted

The kernel's safety net assumes there is a previous kernel to go back to, and
that the problem is the kernel. If the root filesystem is the problem, every
kernel fails the same way. So the EFI partition has one more entry, added by
`--with-rescue-entry`: a tiny system that brings the USB cable up as a network
link at `169.254.77.1`, starts an SSH server, and mounts no root filesystem.
Its `sort-key` puts it below every kernel entry. The board reaches it only when
every kernel entry has run out of tries, or when someone points it there.

Until it had been booted, nobody knew if it worked. Two things were open: would
the USB controller come up as a device without the running system's help, and
would the Type-C controller be ready in time? On 2026-11-01 it was booted once,
from a test entry with a single try, and both answers were yes. SSH from a
Windows host to `root@169.254.77.1` answered 5.5 s after power-on, and its
`dmesg` told the story in order:

```
[    5.393072] unoq-rescue: rescue system: no root filesystem will be mounted
[    5.454276] unoq-rescue: gadget built (c.1 = ncm.usb0)
[    5.468553] unoq-rescue: dropbear started
[    5.497478] unoq-rescue: bound to 4e00000.usb
[    5.514508] unoq-rescue: usb0 has 169.254.77.1
```

`reboot -f` from the rescue shell, and the board came back on its ordinary
kernel by itself. The test entry's one try had been spent before the rescue
system started, so the kernel was first in line again.

### The test that passed without running

That was the second attempt. The first one rebooted the board, the board came
back on its ordinary kernel, and nothing anywhere said anything was wrong.

The instructions had pointed `loader.conf`'s `default` line at the test entry
by its file name, `…-rescue-test+1.conf`, counter and all. This systemd-boot
leaves the counter out of an entry's id, so that line matched no entry, and
systemd-boot did what it does when `default` matches nothing: it booted the
first entry in order, which was the kernel. To anyone watching, a test that
never ran looked exactly like a board coming back after one that did.

The obvious fix, naming the entry without its counter, would have been worse.
A `default` match does not skip an entry with no tries left, so the board would
have booted the rescue system every time. What worked used order instead. The
test entry gets a sort key ahead of the kernel's and one try; while the try
lasts it is first, and spent, it is last. Nothing names it, so nothing can keep
choosing it.

The lesson is broader than boot loaders. **A safety test whose failure looks
like its success has not told you anything yet.** Check that the thing on trial
actually ran: here, that `bootctl list` called the test entry `(default)`
before the reboot, and that you got the rescue shell, not just a board that
came back.

## Making it visible

A board that rolled back by itself looks, from outside, exactly like one that
took its update. That is the whole point of rolling back by default, and it
is also why it needs a light. LED 2 has two slow blinks for it, in the rhythm
the four LEDs use for "in progress, or degraded":

- **slow yellow:** a counted boot not marked good yet. A new kernel is on
  trial. It is the same color as LED 3's unconfirmed firmware, because it is
  the same idea on the other chip.
- **slow blue:** an entry has used up its tries and is not the one booted. A
  kernel was set aside. The board is fine; the new kernel is not.

Blue outranks yellow: a trial ends by itself within minutes, a set-aside kernel
waits for someone. Red outranks both.

The rescue test showed the blue light working on a real board. After the
test, the spent entry sat on the EFI partition with no tries left, and LED 2
blinked slow blue until it was removed, then went back to normal. The
light cannot tell a spent test entry from a failed kernel, and it should not
try: both are an entry that used up its tries, and both clear the same way.
[Four lights that tell the truth](four-lights.md) has the rest of LED 2.

## One command

```bash
./bootstrap.sh --with-recovery
```

That is `--with-boot-counting` and `--with-rescue-entry` together: new kernels
on trial, and the rescue entry below them. It needs your SSH key in
`~/.ssh/authorized_keys` first, because the rescue system takes no passwords,
and it refuses up front without one. It costs about 40 MB on the EFI partition.
It never writes `loader.conf` or the entry you boot now. Boot counting alone is
also part of `--everything`; the rescue entry is not.

## What each layer cannot catch

Every one of these has an edge, and the edges are worth knowing better than
the middle.

- **MCUboot** cannot save you from a bad bootloader, or from firmware that
  confirms itself and then fails. SWD is the way back from those.
- **Boot counting** only judges what the health check looks at: a finished
  boot and `sshd`. A kernel that gets that far and breaks the network or the
  MCU is marked good; those two are deliberately not checked. The fallback also
  needs the previous kernel still installed.
- **The running kernel's own entry has no counter yet.** Only kernels installed
  from now on are counted. That was decided on purpose: counting the only
  kernel could take it out of rotation, so it waits until the rescue entry had
  been booted once. Until it changes, the fall-through to the rescue entry
  cannot happen, and the rescue entry is reached only on purpose.
- **The bind guard** cannot tell a brownout from three quick reboots by an
  impatient person. Both look like boots that never confirmed.
- **The rescue entry** is a way in, not a fix. It gives you a shell with
  nothing mounted, and what you do there is up to you. If it hangs before its
  timeout, nothing restarts it: someone has to unplug the board.
- **Below all of this is Qualcomm's boot chain**, a pair of `_a`/`_b`
  partitions for every stage up to U-Boot. It has a "this boot was good"
  mark of its own, set by `qbootctl`, and this project's rule for it is look, do not
  touch. Nothing here writes it, and `tests/no-slot-writes.bats` checks that on
  every CI run. A bad write there is a board that never reaches U-Boot, and the
  only way back is Arduino's factory flasher.
  [hardware.md](../reference/hardware.md#the-qualcomm-boot-chain-look-do-not-touch)
  has what was seen there.
- **The root filesystem has no trial at all yet.** An update to it is written
  in place. Two roots, so that an update boots on trial and falls back to the
  other, is
  [issue #169](https://github.com/jim-wyatt/two-computers-one-board/issues/169),
  and it is not built.

## Try it

Start with the parts that only read:

```bash
~/two-computers-one-board/status/leds.sh explain     # LED 2's states, from the board
sudo bootctl list                                    # entries, counters, sort order
~/two-computers-one-board/usb/bind-guard.sh status   # the guard's count
```

In `bootctl list`, find the kernel's entry and, if you have run
`--with-recovery`, the rescue entry under it. Check that the kernel is
`(default)`, and that no entry says `tries: 0 left`. If one does, LED 2 should
be blinking slow blue.

Then, if a hand is free to unplug the board in the one case that needs it, boot
the rescue entry once. The safe way is a counted test entry, ordered so it runs
exactly once: follow
[Booting the rescue entry once](../reference/troubleshooting.md#booting-the-rescue-entry-once)
in Troubleshooting, which has the risks, the commands and how to read the
result. While you do, notice the three things this chapter is about: LED 2
blinking slow blue for the spent entry afterwards, going green when you
remove it, and `bootctl status` naming the kernel as *Current Entry* once the
board is back.

> [!TIP]
> **Go deeper** — systemd's
> [Automatic Boot Assessment](https://systemd.io/AUTOMATIC_BOOT_ASSESSMENT/)
> is the design behind boot counting, and the
> [Boot Loader Specification](https://uapi-group.org/specifications/specs/boot_loader_specification/)
> defines the entry files and how they sort.
> [Issue #93](https://github.com/jim-wyatt/two-computers-one-board/issues/93)
> is the plan these layers came from, with every test as it was run.

## Check yourself

1. As shipped, a counted boot on this board was marked good in its first
   second. Why does that make boot counting useless, and what is the MCU-side
   mistake it repeats?
2. The first rescue test rebooted the board, and the board came back on its
   kernel with no error. Why was that not a pass?
3. LED 2 is blinking slow blue, and no kernel has been installed lately. What
   should you look for?
4. Why can the rescue entry not be reached by fallback today, and what has to
   change for it to be?
5. Why does the bind guard turn LED 2 red, when kernel fallback only gets a
   slow blink?

<details markdown="1">
<summary>Answers — try each one first</summary>

1. **Because a boot that is always good can never fall back.** The counter
   only helps if something checks the boot before confirming it; marked in the
   first second, a kernel that fails a minute later has already passed. It is
   confirming in the first line of `main`. The fix is the same as on the MCU:
   confirm only after the board can do the job you would have to visit it to
   restore, here a finished boot with `sshd` up.
2. **Because that is also exactly what a test that never ran looks like.** The
   `default` line named the entry with its counter, which this systemd-boot
   leaves out of entry ids, so nothing matched and the kernel booted as usual.
   A pass needs evidence that the thing on trial ran: the rescue shell itself,
   and the entry shown as `(default)` before the reboot.
3. **An entry with no tries left that is not the one booted.** `sudo bootctl
   list` shows it, as `tries: 0 left`. If it is a spent test entry, such as the
   rescue test's, removing it ends the blue. If it is a kernel, find out from
   its boot why it failed.
4. **Because the kernel's own entry has no counter.** Fallback to the rescue
   entry happens only when every kernel entry has run out of tries, and the
   running kernel's entry cannot run out. It waits on a deliberate decision to
   count that entry, which was put off until the rescue entry had been booted
   once.
5. **Because its roll-back needs a human to undo.** A set-aside kernel leaves
   a board that is fully working on the previous kernel. A tripped guard
   leaves the gadget unbound until someone clears the count, so it is a failed
   unit, and a failed unit is what red is for.

</details>

Next: [when none of the lights help, and you have to find out what a program
with no screen is actually doing](debugging-without-a-screen.md).
