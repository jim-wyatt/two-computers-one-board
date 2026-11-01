<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# Jitter, measured

This course keeps saying that Linux cannot promise *when* your code runs and
the microcontroller can. The [last chapter](two-clocks-one-record.md) built a
whole design on that claim: the microcontroller stamps the samples, because
its clock is the one that holds still. This chapter stops asserting it and
measures it, on this board, with the microcontroller as the stopwatch.

The tool is `unoq-jitter`. Linux tries to send the microcontroller a line
every 20 ms, exactly on schedule, for 30 seconds. Both sides write down how
far from the schedule each one was. Then it does the same again with every
core of the Linux side kept busy.

## Why Linux cannot promise, and the microcontroller can

When a Linux program asks to be woken in 20 ms, the kernel puts it on a list.
When the time comes, the timer fires and the program becomes *ready to run*.
Whether it *runs* depends on what else wants those four cores: other
programs, the kernel's own work, interrupts from the disk and the network.
The scheduler is built to be fair and to get a lot of work done overall, not
to run any one program at an exact moment. So the wake-up is never early,
usually a little late, and now and then a lot late. Nothing in the program
can tell in advance which.

The microcontroller has one core and no other programs. Its timers are
counters in hardware, and a timer interrupt starts running within
microseconds of firing, every time. Zephyr's
scheduler honors priorities strictly. That is what
[real-time](the-microcontroller-side.md) means: not fast, but bounded.

*Jitter* is the name for that variation: how far each event lands from where
it was meant to.

## Three views of one schedule

`unoq-jitter` prints three histograms side by side, in the same bins (±50 µs
out to ±5000 µs and beyond). Each column answers a different question.

- **Linux, late.** Linux's own view of itself. For each tick, the tool reads
  `CLOCK_MONOTONIC` just before writing the line and records how long after
  the deadline that was. It can never be early, so only the late half fills.
  It sees nothing after the write: not the serial driver, the wire, or the
  microcontroller.
- **MCU tick, interval.** The microcontroller's view of Linux. Each
  `app jitter tick` is stamped on arrival by TIM5, a hardware counter at
  1 MHz. The column is each interval between two arrivals, minus 20 ms. It
  holds everything from Linux deciding to write to the microcontroller's
  shell reading the line. Only a *change* in lateness moves an interval, so
  one late tick shows up twice: once late, and once early on the interval
  after it.
- **MCU pwm, period.** The microcontroller's view of itself. One timer makes
  a square wave on pin D3, and another measures its period on D2, both from
  the same 160 MHz clock. No software is in the path at all. This is the
  column for what hardware timing looks like beside the other two.

The first two columns are two different clocks, on two different chips,
looking at the same events. If they agree, neither is fooling itself.

## Deadlines, not delays

The obvious way to do something every 20 ms is a loop:

```python
while True:
    send_tick()
    time.sleep(0.020)
```

That loop drifts. `sleep` waits *at least* 20 ms, and the send takes time too,
so each round is a little longer than 20 ms. Worse, every late wake-up pushes
every tick after it later. The error is added up, never paid back, and after
a while the schedule is somewhere else entirely.

`unoq-jitter` instead works out where each tick *belongs*:

```python
deadline = start + k * period          # tick k, from k, never by adding up
time.sleep(deadline - time.monotonic())
```

On Linux, Python's `time.sleep()` is `clock_nanosleep()` on `CLOCK_MONOTONIC`
with an absolute end time, so this waits until a moment, not for a length of
time. A wake-up that comes 3 ms late makes one tick 3 ms late. The next
deadline is still where it always was, so the next tick is on time again. The
monotonic clock matters too: it never jumps when the wall clock is set by NTP,
so a deadline cannot move under the program.

If a tick is a whole period late, its deadline is skipped and counted as
*missed*, rather than sent late in a burst with the next one. The
[reference](../reference/mpu.md#jitter) has the details.

## What the board said

These are the first measurements, taken on this board on **2026-11-01**:
`unoq-jitter --seconds 30`, a 20 ms period, kernel 7.0.0, CPU governor
`schedutil`. "Spin" is `--load spin`, one busy process on each of the four
cores. There was no jumper on D3 to D2, so the PWM column was off.

| | idle | spin on 4 cores |
|---|---|---|
| ticks, deadlines missed | 1501, 0 | 1501, 0 |
| Linux late: within 100 µs | 59% | 76% |
| Linux late: within 500 µs | 99.8% | 89.9% |
| Linux late: over 1 ms | 2 (0.1%) | 141 (9.4%) |
| Linux late: over 5 ms | 0 | 12 |
| Linux late: max | 4.4 ms | 14.8 ms |
| MCU tick interval within ±50 µs | 61% | 56% |
| MCU tick interval: min / max | −4.2 / +4.2 ms | −12.0 / +14.8 ms |

Read it in three passes.

**The middle stays put.** More than half the ticks were within 100 µs of
their deadline, idle or loaded, so the median is under 100 µs either way. The
typical tick barely notices four busy cores. (It was within 100 µs *more*
often under load. One likely reason, not measured here: with the cores busy,
`schedutil` keeps the clock speed up, so a waking program starts faster. Treat
that as a guess.)

**The tail grows.** What load changes is the worst case. Ticks more than 1 ms
late went from 2 to 141, and the latest went from 4.4 ms to 14.8 ms, about
three times as far. Twelve ticks under load were more than 5 ms late; idle,
none were. This is the shape to remember about a general-purpose operating
system: the average is fine, and the average is not what breaks things. A
motor step or an audio sample that is 14.8 ms late is a fault, however many
others were on time.

**Nothing was missed.** A miss means a whole 20 ms period late, and even the
worst tick, at 14.8 ms, did not get that far. Absolute deadlines also meant
none of those 141 late ticks delayed the ones after them. Had each been added
to every later tick, as the plain `sleep` loop does, the schedule would have
slipped by more than 141 ms in 30 seconds from those alone.

## Why the second clock matters

Look at the max rows together. Idle, Linux says its latest tick was
4.4 ms late, and the microcontroller saw one interval 4.2 ms too long and one
4.2 ms too short. Under load, Linux says 14.8 ms, and the microcontroller saw
an interval +14.8 ms too long, and one 12.0 ms too short. Each is a late tick
seen from the other end: a long interval as it arrives, then a short one when
the next tick is back on schedule, just as the column's definition says. (The
short side need not match exactly: if the tick after a late one is itself a
little late, the short interval is that much less short.)

That agreement is the point of the whole exercise. A program measuring its
own lateness on its own clock could be wrong in ways it cannot see. The
kernel could be misreporting, or the delay could be somewhere after the
timestamp, in the driver or on the wire. The microcontroller's TIM5 knows
nothing about Linux. It counts on its own chip, from its own clock, and it
only sees when the bytes actually arrived. When an independent clock sees the
same outliers Linux reports, the outliers are real, and they happen where
Linux says they do: before the write, in the scheduler.

The MCU column holds more than the scheduler: the serial driver, the
115200-baud wire and the shell are in it too, and every late tick counts in
it twice. Even so, 61% of intervals idle and 56% under load were within
±50 µs of 20 ms.

## The third column

The PWM column needs one jumper wire from **D3 to D2**: the MCU's own PWM out
on one pin, its own timer capturing it on the other. Measured on 2026-11-01,
same board, kernel and governor, with `unoq-jitter --seconds 30 --pwm 1000`:

| | idle | spin on 4 cores |
|---|---|---|
| PWM periods captured | 31284 | 31390 |
| within ±50 µs of 1000 µs | **all of them** | **all of them** |
| worst deviation | under 0.05 µs | under 0.05 µs |
| Linux late, max (same run) | 7.5 ms | 19.8 ms |
| Linux ticks over 5 ms late | 3 | 104 |
| deadlines missed | 0 | 1 |

This is the whole argument of the course in one table. Nothing in the PWM's
path is scheduled: it is two timers on one clock, and four busy Linux cores
cannot reach it. The prediction this section used to carry said "nearly all
in the middle bin"; the board did better than that, with not one period
outside it and the worst a twentieth of a microsecond off.

The Linux columns are worth a second look too. This load run was much worse
than the one in [What the board said](#what-the-board-said): 104 ticks more
than 5 ms late, not 12, a worst case of 19.8 ms, not 14.8, and for the first
time a deadline missed outright. Same board, same command, a day apart. That
is not the measurement failing; it is what "no promise" means. A scheduler
under load has a distribution, and one run is one sample of its tail.

## Try it

The jitter tool and the CPU-bars demo both need the one serial line, so stop
the demo first. You need the firmware with `app jitter` on the
microcontroller (any build since it was added); if `unoq-jitter` is not on
your `PATH`, `hpy -m unoq.jitter` is the same program.

```bash
sudo systemctl stop unoq-cpu-bars
unoq-jitter --seconds 30
unoq-jitter --seconds 30 --load spin
```

Each run takes about half a minute and prints its table. Compare yours with
the one above:

1. **Find the median.** Add up the Linux column from the middle until you
   pass half the ticks. Which bin is that in, idle and loaded?
2. **Find the tail.** Read the `max` row for both tick columns. Does the
   microcontroller's max match Linux's, the way it did here?
3. **Make your own load.** Run the idle command again while something real
   is busy: a build, or `yes > /dev/null &` on two cores (`kill %1 %2`
   after). Is the tail more like idle or like spin?
4. **Add the jumper,** if you have a wire, and run
   `unoq-jitter --seconds 30 --pwm 1000`. Compare your PWM column with
   [the third column](#the-third-column).

To get the demo back:

```bash
sudo systemctl start unoq-cpu-bars
```

Every option, the bins and the exit codes are in the
[MPU reference](../reference/mpu.md#jitter). The firmware's side, the pins
and the timers are in the [MCU reference](../reference/mcu.md#jitter).

## Check yourself

1. Under load, more ticks were within 100 µs of their deadline than at idle,
   yet the maximum went from 4.4 ms to 14.8 ms. Why is the maximum the number
   that matters for something like a motor?
2. A tick is 3 ms late. With `sleep(period)` in a loop, what happens to every
   tick after it? With absolute deadlines?
3. Linux reported a tick 14.8 ms late. Why does the MCU column show both a
   +14.8 ms interval and a large negative one?
4. Why measure on the microcontroller at all, when Linux already knows how
   late it was?
5. Without the jumper, the PWM column was empty. What do you expect it to
   show with the jumper on, and why should load make no difference to it?

<details markdown="1">
<summary>Answers — try each one first</summary>

1. **Because one late step is a fault, however many were on time.** A motor,
   a sample clock or a safety cutoff fails on its worst moment, not its
   typical one. Load left the middle of the distribution alone and stretched
   the tail about three times, which is the part a real-time job cannot
   tolerate.
2. **With `sleep(period)`, every later tick is 3 ms later too, and the error
   keeps adding up.** With absolute deadlines, tick *k* is still due at
   *start + k × period*, so only that one tick is late and the next is back
   on schedule.
3. **Because the MCU measures intervals, and one late tick changes two of
   them.** The interval ending at the late tick is 14.8 ms too long. The next
   tick's deadline has not moved, so it comes back on schedule and the
   interval after the late one is short: here, by 12.0 ms.
4. **Because a clock checking itself cannot see its own mistakes.** Linux's
   number stops at the moment before the write. The MCU's TIM5 is an
   independent clock that only sees when the line really arrived. When the
   two agree, the lateness is real and it happened in Linux's scheduler.
5. **About 30000 periods, every one in the middle bin, idle or loaded**: on
   this board 31284 and 31390, the worst under 0.05 µs off. The wave is
   made and measured by two timers on one 160 MHz clock, with no software and
   nothing scheduled in between, so nothing on the Linux side can delay it.

</details>

Next: [Updating safely](updating-safely.md) — replacing the firmware on a
running board without being able to visit it.
