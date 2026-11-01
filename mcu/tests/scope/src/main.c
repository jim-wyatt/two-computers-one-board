/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * Host-runnable tests for the scope's arithmetic (scope.c).
 *
 * The hardware cannot be watched from here, so what is checked is what it is
 * given: tables that are the shape and size they claim and stay inside the
 * DAC, timer divisions that land on the rate asked for or as near as whole
 * numbers allow, and a burst that is never readable while it is being
 * written, after it failed, or as a mix of two captures. And the shell's
 * limits from app_proto.h, which say how long a capture may hold adc1.
 *
 * Runs on native_sim via ~/two-computers-one-board/mcu/ztest.sh.
 */
#include <zephyr/ztest.h>
#include <errno.h>
#include <string.h>

#include "app_proto.h"
#include "scope.h"

#define CLK_HZ 160000000U

static uint32_t table[APP_SCOPE_POINTS];
static uint16_t buf[APP_SCOPE_N_MAX];
static struct scope_burst b;

static void reset(void *fixture)
{
	ARG_UNUSED(fixture);
	memset(table, 0, sizeof(table));
	memset(buf, 0, sizeof(buf));
	scope_burst_init(&b, buf, ARRAY_SIZE(buf));
}

/* --- waveforms ------------------------------------------------------------ */

ZTEST(scope, test_the_wave_names_are_the_ones_app_proto_gives)
{
	enum scope_wave w;

	zassert_str_equal(scope_wave_name(SCOPE_WAVE_SINE), APP_SCOPE_WAVE_SINE);
	zassert_str_equal(scope_wave_name(SCOPE_WAVE_TRIANGLE), APP_SCOPE_WAVE_TRIANGLE);
	zassert_str_equal(scope_wave_name(SCOPE_WAVE_OFF), APP_SCOPE_WAVE_OFF);

	zassert_ok(scope_wave_parse("sine", &w));
	zassert_equal(w, SCOPE_WAVE_SINE);
	zassert_ok(scope_wave_parse("triangle", &w));
	zassert_equal(w, SCOPE_WAVE_TRIANGLE);
	zassert_equal(scope_wave_parse("off", &w), -EINVAL, "off is not a wave to play");
	zassert_equal(scope_wave_parse("Sine", &w), -EINVAL);
	zassert_equal(scope_wave_parse("", &w), -EINVAL);
	zassert_equal(scope_wave_parse(NULL, &w), -EINVAL);
}

static void assert_wave_shape(enum scope_wave w)
{
	const int q = APP_SCOPE_POINTS / 4;
	int64_t sum = 0;

	zassert_ok(scope_wave_fill(w, table));
	for (int i = 0; i < APP_SCOPE_POINTS; i++) {
		zassert_true(table[i] <= APP_SCOPE_DAC_MAX, "point %d is past the DAC", i);
		sum += (int64_t)table[i] - APP_SCOPE_DAC_MID;
		/* Odd about the middle, as a sine is: the second half is the
		 * first upside down. */
		if (i < APP_SCOPE_POINTS / 2) {
			zassert_equal((int)table[i] - APP_SCOPE_DAC_MID,
				      APP_SCOPE_DAC_MID - (int)table[i + APP_SCOPE_POINTS / 2],
				      "point %d", i);
		}
	}
	zassert_equal(sum, 0, "the mean is the middle");
	zassert_equal(table[0], APP_SCOPE_DAC_MID, "it starts at the middle");
	zassert_equal(table[q], APP_SCOPE_DAC_MID + APP_SCOPE_DAC_AMPLITUDE, "the top");
	zassert_equal(table[3 * q], APP_SCOPE_DAC_MID - APP_SCOPE_DAC_AMPLITUDE, "the bottom");
	/* Rising for the first quarter, and symmetric about its peak. */
	for (int i = 1; i <= q; i++) {
		zassert_true(table[i] > table[i - 1], "rises at %d", i);
		zassert_equal(table[q - i], table[q + i], "symmetric at %d", i);
	}
}

ZTEST(scope, test_the_sine_is_a_sine)
{
	assert_wave_shape(SCOPE_WAVE_SINE);
	/* 45 degrees is point 8, at 0.7071 of the amplitude. */
	zassert_within((int)table[8] - APP_SCOPE_DAC_MID, 1158, 1, "45 degrees: %u", table[8]);
}

ZTEST(scope, test_the_triangle_is_straight_lines)
{
	assert_wave_shape(SCOPE_WAVE_TRIANGLE);
	/* Every step up the first quarter is the same size, give or take the
	 * rounding to a whole code. */
	for (int i = 1; i <= APP_SCOPE_POINTS / 4; i++) {
		zassert_within((int)(table[i] - table[i - 1]),
			       APP_SCOPE_DAC_AMPLITUDE / (APP_SCOPE_POINTS / 4), 1, "step %d", i);
	}
}

ZTEST(scope, test_off_is_not_a_table)
{
	zassert_equal(scope_wave_fill(SCOPE_WAVE_OFF, table), -EINVAL);
	zassert_equal(table[0], 0, "and nothing was written");
}

/* --- timers ---------------------------------------------------------------- */

ZTEST(scope, test_a_rate_that_divides_the_clock_is_exact)
{
	struct scope_div d;

	/* The DAC at the top: 10 kHz * 64 points. */
	zassert_ok(scope_timer_div(CLK_HZ, 640000, &d));
	zassert_equal(d.psc, 0);
	zassert_equal(d.arr, 249);
	zassert_equal(d.rate_mhz, 640000000ULL);

	/* The ADC at the top and at the bottom. */
	zassert_ok(scope_timer_div(CLK_HZ, APP_SCOPE_RATE_HZ_MAX, &d));
	zassert_equal((d.psc + 1) * (d.arr + 1), 640);
	zassert_equal(d.rate_mhz, 250000000ULL);
	zassert_ok(scope_timer_div(CLK_HZ, APP_SCOPE_RATE_HZ_MIN, &d));
	zassert_equal((uint64_t)(d.psc + 1) * (d.arr + 1), 1600000);
	zassert_equal(d.rate_mhz, 100000ULL);
}

ZTEST(scope, test_a_slow_rate_needs_a_prescaler_and_the_reload_stays_16_bit)
{
	struct scope_div d;

	/* 1 Hz of wave is 64 updates a second: 2.5 million cycles each. */
	zassert_ok(scope_timer_div(CLK_HZ, APP_SCOPE_WAVE_HZ_MIN * APP_SCOPE_POINTS, &d));
	zassert_true(d.psc > 0 && d.psc <= 0xFFFF);
	zassert_true(d.arr <= 0xFFFF);
	zassert_equal(d.psc, 38, "the smallest prescaler that fits");
	/* As near as whole numbers allow: within a hundredth of a percent. */
	zassert_within(d.rate_mhz, 64000ULL, 6ULL, "rate %llu mHz", d.rate_mhz);
}

ZTEST(scope, test_an_awkward_rate_is_rounded_to_the_nearest_count)
{
	struct scope_div d;

	/* 7 Hz * 64 points is 357142.86 cycles: over 2^16, so divided by 6
	 * (prescaler 5) into 59523.8 counts, rounded to 59524. */
	zassert_ok(scope_timer_div(CLK_HZ, 7 * APP_SCOPE_POINTS, &d));
	zassert_equal(d.psc, 5);
	zassert_equal(d.arr, 59523);
	zassert_equal(d.rate_mhz, (uint64_t)CLK_HZ * 1000 / ((d.psc + 1ULL) * (d.arr + 1ULL)));
	zassert_within(d.rate_mhz, 448000ULL, 5ULL, "rate %llu mHz", d.rate_mhz);
}

ZTEST(scope, test_every_wave_and_capture_rate_divides_within_a_fifth_of_a_percent)
{
	struct scope_div d;

	/* The coarsest is at the top, where an update is only 250 counts and
	 * half a count is 0.2%. */
	for (uint32_t hz = APP_SCOPE_WAVE_HZ_MIN; hz <= APP_SCOPE_WAVE_HZ_MAX; hz += 37) {
		uint64_t want = (uint64_t)hz * APP_SCOPE_POINTS * 1000;

		zassert_ok(scope_timer_div(CLK_HZ, hz * APP_SCOPE_POINTS, &d));
		zassert_true(d.psc <= 0xFFFF && d.arr <= 0xFFFF && d.arr >= 1);
		zassert_within(d.rate_mhz, want, want / 500 + 1, "wave %u Hz", hz);
	}
	for (uint32_t hz = APP_SCOPE_RATE_HZ_MIN; hz <= APP_SCOPE_RATE_HZ_MAX; hz += 997) {
		uint64_t want = (uint64_t)hz * 1000;

		zassert_ok(scope_timer_div(CLK_HZ, hz, &d));
		zassert_within(d.rate_mhz, want, want / 500 + 1, "capture %u Hz", hz);
	}
}

ZTEST(scope, test_a_rate_of_zero_or_past_half_the_clock_is_refused)
{
	struct scope_div d;

	zassert_equal(scope_timer_div(CLK_HZ, 0, &d), -EINVAL);
	zassert_equal(scope_timer_div(CLK_HZ, CLK_HZ / 2 + 1, &d), -EINVAL);
	zassert_ok(scope_timer_div(CLK_HZ, CLK_HZ / 2, &d));
	zassert_equal(d.arr, 1, "the fastest a timer goes: two counts");
}

/* --- the shell's limits ---------------------------------------------------- */

ZTEST(scope, test_a_capture_is_held_to_its_ranges_and_its_length)
{
	zassert_true(app_scope_capture_valid(APP_SCOPE_N_MAX, APP_SCOPE_RATE_HZ_MAX));
	zassert_true(app_scope_capture_valid(APP_SCOPE_N_MIN, APP_SCOPE_RATE_HZ_MIN));
	zassert_false(app_scope_capture_valid(APP_SCOPE_N_MIN - 1, 10000));
	zassert_false(app_scope_capture_valid(APP_SCOPE_N_MAX + 1, 10000));
	zassert_false(app_scope_capture_valid(100, APP_SCOPE_RATE_HZ_MIN - 1));
	zassert_false(app_scope_capture_valid(100, APP_SCOPE_RATE_HZ_MAX + 1));

	/* 4096 samples take 500 ms at 8192 Hz: the longest allowed. */
	zassert_true(app_scope_capture_valid(4096, 8192));
	zassert_false(app_scope_capture_valid(4096, 8191));
	/* 50 samples at 100 Hz is exactly 500 ms; 51 is not. */
	zassert_true(app_scope_capture_valid(50, 100));
	zassert_false(app_scope_capture_valid(51, 100));
}

ZTEST(scope, test_the_wave_range)
{
	zassert_true(app_scope_wave_hz_valid(APP_SCOPE_WAVE_HZ_MIN));
	zassert_true(app_scope_wave_hz_valid(APP_SCOPE_WAVE_HZ_MAX));
	zassert_false(app_scope_wave_hz_valid(APP_SCOPE_WAVE_HZ_MIN - 1));
	zassert_false(app_scope_wave_hz_valid(APP_SCOPE_WAVE_HZ_MAX + 1));
	/* The DAC's update rate at the top is under its 1 MHz. */
	zassert_true(APP_SCOPE_WAVE_HZ_MAX * APP_SCOPE_POINTS <= 1000000);
}

/* --- bursts ---------------------------------------------------------------- */

static uint32_t take(uint16_t n)
{
	zassert_ok(scope_burst_begin(&b, n, 50000000));
	for (uint16_t i = 0; i < n; i++) {
		buf[i] = (uint16_t)(i + 100U);
	}
	return scope_burst_end(&b, true);
}

ZTEST(scope, test_an_empty_burst_is_no_data)
{
	uint16_t out[4];
	struct scope_chunk c;
	struct scope_burst_info i = scope_burst_info(&b);

	zassert_equal(scope_burst_read(&b, 0, 0, out, 4, &c), -ENODATA);
	zassert_equal(c.count, 0);
	zassert_equal(i.id, 0);
	zassert_equal(i.n, 0);
	zassert_false(i.busy);
	zassert_false(i.valid);
}

ZTEST(scope, test_a_capture_reads_back_in_pieces_under_its_id)
{
	uint16_t out[100];
	struct scope_chunk c;
	uint32_t id = take(250);

	zassert_equal(id, 1);
	zassert_ok(scope_burst_read(&b, 0, 0, out, 100, &c));
	zassert_equal(c.id, 1);
	zassert_equal(c.rate_mhz, 50000000);
	zassert_equal(c.n, 250);
	zassert_equal(c.count, 100);
	zassert_equal(out[0], 100);
	zassert_equal(out[99], 199);

	zassert_ok(scope_burst_read(&b, id, 200, out, 100, &c));
	zassert_equal(c.offset, 200);
	zassert_equal(c.count, 50, "only what is left");
	zassert_equal(out[49], 349);

	zassert_ok(scope_burst_read(&b, id, 250, out, 100, &c));
	zassert_equal(c.count, 0, "at the end: nothing, and no error");
}

ZTEST(scope, test_nothing_is_readable_while_the_dma_writes)
{
	uint16_t out[4];
	struct scope_chunk c;

	take(10);
	zassert_ok(scope_burst_begin(&b, 20, 1000000));
	zassert_equal(scope_burst_read(&b, 0, 0, out, 4, &c), -EBUSY);
	zassert_true(scope_burst_info(&b).busy);
	zassert_equal(scope_burst_begin(&b, 20, 1000000), -EBUSY, "one capture at a time");
	zassert_equal(scope_burst_end(&b, true), 2);
	zassert_ok(scope_burst_read(&b, 2, 0, out, 4, &c));
	zassert_equal(c.n, 20);
}

ZTEST(scope, test_a_failed_capture_leaves_nothing_to_read_and_is_counted)
{
	uint16_t out[4];
	struct scope_chunk c;
	struct scope_burst_info i;

	take(10);
	zassert_ok(scope_burst_begin(&b, 10, 1000000));
	zassert_equal(scope_burst_end(&b, false), 0);
	zassert_equal(scope_burst_read(&b, 0, 0, out, 4, &c), -ENODATA,
		      "the buffer is half overwritten: not the old capture, not a new one");
	i = scope_burst_info(&b);
	zassert_equal(i.errors, 1);
	zassert_equal(i.id, 0);
	zassert_false(i.valid);
	/* And the next good one still gets a new id. */
	zassert_equal(take(10), 2);
}

ZTEST(scope, test_a_reader_of_one_capture_is_told_when_another_replaced_it)
{
	uint16_t out[4];
	struct scope_chunk c;

	take(10);
	take(10);
	zassert_equal(scope_burst_read(&b, 1, 0, out, 4, &c), -ESTALE);
	zassert_equal(c.id, 2, "and which one is held now");
	zassert_equal(c.count, 0);
}

ZTEST(scope, test_an_offset_past_the_end_is_out_of_range)
{
	uint16_t out[4];
	struct scope_chunk c;

	take(10);
	zassert_equal(scope_burst_read(&b, 0, 11, out, 4, &c), -ERANGE);
	zassert_equal(c.n, 10);
}

ZTEST(scope, test_a_burst_is_refused_bigger_than_its_buffer_or_empty)
{
	zassert_equal(scope_burst_begin(&b, 0, 1000), -EINVAL);
	zassert_equal(scope_burst_begin(&b, APP_SCOPE_N_MAX + 1, 1000), -EINVAL);
	zassert_false(scope_burst_info(&b).busy, "a refused begin claims nothing");
}

ZTEST(scope, test_the_id_skips_zero_when_it_wraps)
{
	b.id = UINT32_MAX - 1;
	zassert_equal(take(16), UINT32_MAX);
	zassert_equal(take(16), 1, "0 means none, so it is never a capture's");
}

ZTEST(scope, test_the_summary_is_min_max_and_mean)
{
	const uint16_t s[] = {5, 1, 9, 4};
	uint16_t lo = 99, hi = 99, mean = 99;

	scope_summary(s, ARRAY_SIZE(s), &lo, &hi, &mean);
	zassert_equal(lo, 1);
	zassert_equal(hi, 9);
	zassert_equal(mean, 4, "19 / 4, rounded down");

	scope_summary(s, 0, &lo, &hi, &mean);
	zassert_equal(lo + hi + mean, 0);

	/* The largest burst at full scale does not overflow the sum. */
	for (size_t i = 0; i < ARRAY_SIZE(buf); i++) {
		buf[i] = APP_SCOPE_ADC_MAX;
	}
	scope_summary(buf, ARRAY_SIZE(buf), &lo, &hi, &mean);
	zassert_equal(mean, APP_SCOPE_ADC_MAX);
}

ZTEST_SUITE(scope, NULL, NULL, reset, NULL, NULL);
