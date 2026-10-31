/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * Jitter, measured: the MCU times what Linux schedules.
 *
 * The course says the MCU is there because Linux cannot keep time. This is
 * where that stops being asserted. Linux sends `app jitter tick` on a fixed
 * schedule, and the MCU writes down how far each arrival was from where the
 * schedule said it would be. Beside it, the same record for a square wave
 * the MCU's own timers make and measure, with no software in the path: what
 * "keeping time" looks like when it is done in hardware.
 *
 * TWO HALVES
 * ----------
 * This file is the record: a histogram of deviations (struct jitter_hist)
 * and the bookkeeping that turns arrival timestamps into deviations (struct
 * jitter_ticker). It touches no hardware and no kernel object but a
 * spinlock, so mcu/tests/jitter/ runs it on native_sim with made-up
 * timestamps, wraparound included.
 *
 * The clocks are main.c's: TIM5 as a 1 MHz free-running counter for the
 * tick timestamps, TIM3 for the PWM out on D3 and TIM2's capture on D2. See
 * boards/arduino_uno_q.overlay, and app_proto.h for the shell formats and
 * the bins.
 */

#ifndef JITTER_H
#define JITTER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <zephyr/spinlock.h>

#include "app_proto.h"

/* Deviations of measured intervals from an expected period. Added to from an
 * interrupt (the capture callback) as well as from the shell's thread, hence
 * the lock. About 80 bytes. */
struct jitter_hist {
	uint32_t bins[APP_JITTER_BINS];
	uint32_t n;
	int32_t min_ns;
	int32_t max_ns;
	int64_t sum_ns;
	struct k_spinlock lock;
};

/* What jitter_hist_read() copies out: one consistent look at a histogram. */
struct jitter_summary {
	uint32_t bins[APP_JITTER_BINS];
	uint32_t n;
	int32_t min_ns;
	int32_t max_ns;
	int32_t mean_ns; /* sum / n, rounded toward zero; 0 when n is 0 */
};

/* The tick half: arrivals on a microsecond counter, against an armed period. */
struct jitter_ticker {
	struct jitter_hist hist;
	uint32_t period_us; /* what each interval is held to; kept after a stop */
	uint32_t last_us;   /* the previous arrival, if have_last */
	bool armed;
	bool have_last;
};

/** The bin a deviation of `dev_ns` goes in, 0..APP_JITTER_BINS - 1, by the
 *  rule in app_proto.h. */
int jitter_bin(int32_t dev_ns);

/** `ns` clamped to the range of an int32. */
int32_t jitter_clamp_ns(int64_t ns);

/** Empty a histogram, under its lock, so it is safe while the capture
 *  interrupt is adding to it. One that has never been used - static, so
 *  zeroed - is already empty and needs no call. */
void jitter_hist_clear(struct jitter_hist *h);

/** Count one deviation, clamped as jitter_clamp_ns() does. */
void jitter_hist_add(struct jitter_hist *h, int64_t dev_ns);

/** Copy a histogram out, all of it under the lock. */
struct jitter_summary jitter_hist_read(struct jitter_hist *h);

/** Write the bins as `a,b,...` - the bins= value of APP_JITTER_FMT - into
 *  buf. Returns the length written, or -ENOSPC if buf is too small, in which
 *  case buf holds an empty string. JITTER_BINS_STR_MAX is always enough. */
#define JITTER_BINS_STR_MAX (APP_JITTER_BINS * 11)
int jitter_format_bins(const uint32_t *bins, char *buf, size_t cap);

/** Set the expected period, empty the histogram, forget the last arrival and
 *  take ticks: the next one starts a new run rather than closing an interval
 *  that began before the arm. */
void jitter_ticker_arm(struct jitter_ticker *t, uint32_t period_us);

/** Take no more ticks. The histogram and the period stay, to be read; the
 *  next arm clears them. */
void jitter_ticker_stop(struct jitter_ticker *t);

/** One arrival at `now_us` on the free-running counter. The first after
 *  arming only sets the start; each after it adds one deviation. The counter
 *  is 32 bits and wraps every 71.6 minutes; the interval is taken modulo
 *  2^32, so one wrap between two ticks is harmless.
 *  Returns 0, or -EAGAIN if not armed (nothing recorded). */
int jitter_ticker_tick(struct jitter_ticker *t, uint32_t now_us);

#endif /* JITTER_H */
