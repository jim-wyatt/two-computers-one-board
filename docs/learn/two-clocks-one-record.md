<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# Two clocks, one record

The CPU-bars demo has Linux do the measuring and the microcontroller do the
drawing. This chapter turns that around. The microcontroller measures, on a
clock of its own, and Linux keeps the record: a file on the eMMC and a graph
on the board's web page. Nothing needs to be plugged in. The thing measured
is the microcontroller's own die temperature.

It is a small program. What makes it worth a chapter is the questions it
raises, which any two machines sharing data have to answer: whose clock says
when something happened, who remembers it until the other side asks, and how
anyone notices a reading that never arrived.

> [!NOTE]
> **In this chapter**
>
> - why the chip that takes a sample should also be the one that stamps the
>   time
> - push versus pull, and why pulling loses nothing when Linux goes away
> - how a sequence number turns a silent gap into a line in the file
> - how one record can use two clocks, each for what it is good at
>
> **You need:** [The LED matrix](the-led-matrix.md), which is the same split
> in the other direction, and [The microcontroller side](the-microcontroller-side.md)
> for interrupts and threads. The Try it installs the temperature logger
> **in place of** the CPU-bars demo; the last step puts the demo back.

## Why the microcontroller keeps the time

Ask Linux to read a sensor once a second and it will, roughly. `sleep(1)`
wakes up *at least* a second later, and later still when the four cores are
busy compiling something or the system is swapping. Over a day that drift
adds up, and nothing in the readings shows it.

The STM32 has no such problem. In
[`mcu/app/src/templog.c`](https://github.com/jim-wyatt/two-computers-one-board/blob/main/mcu/app/src/templog.c)
a hardware timer (`k_timer`) fires every 1000 ms. Its callback runs as an
interrupt, and it cannot read the sensor itself: the read waits for an
analog-to-digital conversion to turn a voltage into a number, and an
interrupt must not wait, because while it runs nothing else on the chip
does. So it hands the work to a thread, as a **work item** — a job queued
for later — and the thread does the read. Each sample is stamped with two
numbers:

- `seq`, counting up by one from 1 at boot, and
- `ms`, the microcontroller's uptime when the sample was taken.

Whatever Linux is doing, those stamps are a second apart. That is the
[real-time half of the board](the-microcontroller-side.md) earning its place.

## Who remembers, until the other side asks

There are two ways to get the samples up the wire. The microcontroller could
**push** each one as it is taken, or keep them and let Linux **pull**.

Pushing looks simpler, and it is how the issue that started this first
described it. But a push needs someone listening at every moment. Stop the
Linux side for a minute, to update it or because it crashed, and that
minute's samples go out into a serial port nobody has open. They are gone, and
nothing on either side knows.

So the microcontroller keeps them. The samples go into a **ring buffer** of
600 — a fixed-size array used as a circle, where the newest entry overwrites
the oldest: ten minutes at one a second.
Linux asks, every ten seconds, for everything newer than the last sample it
stored:

```text
uart:~$ app temp log 41
seq=42 ms=43017 temp_mc=38250
seq=43 ms=44017 temp_mc=38375
...
end head=51 more=0
```

A Linux side that was stopped for five minutes asks the same question when it
comes back, and gets five minutes of answers. Pulling also keeps the link as
it has always been, one question and one reply, so the shell, the bars demo and
this can share the same parser. At most 32 samples come back per reply, and
`more=` says how many are still waiting; the Python side asks again until it is
zero (`MCU.temp_log()` in
[`python/unoq/mcu.py`](https://github.com/jim-wyatt/two-computers-one-board/blob/main/python/unoq/mcu.py)).

## Noticing what did not arrive

A missing reading is easy to miss. A graph draws a straight line across it,
and an average quietly leaves it out. This is what the sequence number is for:
it is the one thing about a sample that is *predictable*. After 41 comes 42.
(TCP numbers its bytes for the same reason: a receiver cannot notice what
never arrived unless it knows what should have.)

The daemon
([`python/unoq/templog.py`](https://github.com/jim-wyatt/two-computers-one-board/blob/main/python/unoq/templog.py))
holds every sample to that. If it last stored 41 and the next it is given is
48, then 42 to 47 were overwritten before anyone read them (the daemon was
away for more than the ten minutes the ring holds), and it writes a row
saying so before it writes 48:

```text
time,seq,mcu_ms,mcu_temp_c,mcu_err,note,linux_cpuss0-thermal,...
1793801234.017,41,43017,38.250,,,
1793801241.017,,,,,gap 42-47,
1793801241.017,48,50017,39.125,,,
```

A sensor read that fails is kept too, with its error number in `mcu_err` and
no temperature. It still has its sequence number, so a sensor fault never
looks like a lost record.

The other surprise is the microcontroller restarting. Flash new firmware and
the count starts again at 1. If the daemon last stored 3000 and the
microcontroller now says its newest is 12, it has restarted, and the daemon
writes `mcu-restart` and starts from the beginning of the new count.

That check alone has a hole. Stop the daemon at 3000, reflash, and start it
again an hour later: the new count has reached 3600, which is past 3000, so
nothing looks wrong. So every pull asks for one sample more than it needs, the
last one it stored, and checks that the microcontroller still has *the same
sample* under that number: same uptime, same reading. A restarted
microcontroller has a different sample 3000, and that gives it away.

## Whose time goes in the file

The record needs a time a person can read, and only Linux knows the date. But
Linux's idea of *when* a sample was taken is only as good as when it got round
to asking. So the file uses both clocks, each for what it is good at.

At each pull the daemon reads Linux's clock once. The newest sample in the
reply is taken to be "now", and every other sample is placed before it by
exactly the difference in the microcontroller's own `ms`:

```text
time = linux_now - (newest.ms - sample.ms) / 1000
```

A pull that ran four seconds late because Linux was busy still puts every
sample a second apart, because the spacing comes from the microcontroller.
The date comes from Linux, and the intervals come from the microcontroller.

The Linux side's own temperatures, from
[`unoq.thermal`](../reference/mpu.md#temperatures), are read once per pull
and written on the newest row only. Copying them onto the ten rows before it
would make up readings that were never taken.

## Writing it down

The file is plain CSV, so any tool can read it. After each pull it is flushed
and `fsync`ed, which makes the kernel actually put it on the eMMC rather than
hold it in memory. The board has no battery, and a pulled cable should cost
at most one pull. Even that one is not lost: the file still ends at the
sample before it, so on the next start the daemon asks the microcontroller for
everything after that sample, and the ten minutes in the ring cover it.

The graph is a single HTML file the daemon writes next to the CSV. It fetches
the CSV and draws it, with nothing from the internet, because the board is
often on a cable to a laptop that has none. `unoq-learn`, the course's web
server, serves that directory read-only at `/data/`.

## Try it

The logger and the CPU-bars demo both need the one serial line, so they are
alternatives. Installing the logger switches the demo off:

```bash
sudo bash ~/two-computers-one-board/provision/66-temp-log.sh
journalctl -u unoq-temp-log -f
```

Open `http://<board name>.local:8080/data/` and wait a minute for a line.
Then make something happen, and watch for it:

1. **Warm it up.** Hold a finger on the STM32, the microcontroller's chip,
   for twenty seconds. The MCU line should rise a little; the Linux zones
   should not.
2. **Load Linux.** `yes > /dev/null & yes > /dev/null & yes > /dev/null & yes > /dev/null &`,
   then `kill %1 %2 %3 %4` after a few minutes. The Linux zones climb. Look at
   `mcu_ms` in the file during the load: still a thousand apart.
3. **Stop the reader.** `sudo systemctl stop unoq-temp-log`, wait two minutes,
   start it. No gap: the ring held them. Now do it for fifteen minutes.
4. **Restart the microcontroller.** Flash it again (`zflash`, which works
   while the logger runs: it uses the debug lines, not the serial port; the
   logger fails and retries while the chip is held in reset). Look for
   `mcu-restart` in the file.

To get the demo back:

```bash
sudo systemctl disable --now unoq-temp-log
sudo bash ~/two-computers-one-board/provision/65-cpu-bars.sh
```

The [reference](../reference/mpu.md#temperature-log) has every column and
what it costs.

## Check yourself

1. The daemon pulls every ten seconds and the ring holds ten minutes. What is
   the longest the daemon can be stopped without losing a sample, and what
   appears in the file if it is stopped for longer?
2. Why is each sample's `time` worked out from `mcu_ms`, rather than taken
   from Linux's clock when the sample arrived?
3. The microcontroller was restarted while the daemon was stopped, and has
   since counted past the last `seq` in the file. How does the daemon notice?
4. Why is the microcontroller's timer callback not allowed to read the sensor
   itself?

<details markdown="1">
<summary>Answers — try each one first</summary>

1. **About ten minutes.** The ring holds 600 samples at one a second, so a
   daemon that comes back within that finds every sample it missed. Longer,
   and the oldest have been overwritten: the file gets a `gap <first>-<last>`
   row naming exactly which ones, before the first sample after them.
2. **Because Linux's clock says when Linux got round to asking, not when the
   sample was taken.** The samples in one reply arrive together, up to ten
   seconds after the oldest was taken, and later if Linux was busy. The
   microcontroller's uptime was stamped at the moment of each reading, by a
   timer Linux's load cannot delay. Linux's clock is used once per pull, for
   the date.
3. **Every pull asks again for the last sample it stored, and compares.** A
   restarted microcontroller has a different sample under that number:
   different uptime, different reading. When they do not match, the daemon
   writes `mcu-restart` and starts from the new boot's oldest sample.
4. **Reading the sensor waits for an analog conversion, and an interrupt
   handler must never wait.** A timer callback runs in interrupt context; a
   wait there would hold up everything else the chip does at a higher
   priority than any thread. So the callback only submits a work item, and a
   thread does the read.

</details>

## What to remember

- **The chip that samples should stamp the time.** The MCU's timer fires
  every second whatever Linux is doing; `sleep(1)` on Linux only promises
  *at least* a second.
- **Pull, do not push,** when the receiver might be away. The MCU keeps ten
  minutes in a ring buffer and Linux asks for everything newer than it has.
- **A sequence number makes absence visible.** A gap in the count becomes a
  `gap` row; a count that starts again becomes `mcu-restart`; and every pull
  re-reads the last stored sample to catch a restart the count alone would
  hide.
- **Two clocks, two jobs.** Linux supplies the date, once per pull; the
  MCU's `ms` supplies the spacing between samples. Readings that were never
  taken are never written.
- Flush and **`fsync`** after every pull: a pulled cable then costs at most
  one pull, and the ring covers even that.

Next: [Jitter, measured](jitter-measured.md) — how late Linux really is,
timed by the microcontroller.
