/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * Host-runnable tests for the jitter record the firmware ships.
 *
 * The record is only worth what its bins are: a deviation that lands one bin
 * over, or an interval measured across a counter wrap as 71 minutes, would
 * put a number in the course that the board never produced. So these check
 * every bin edge from both sides, the clamp, min/max/mean, the string the
 * shell prints, and the tick bookkeeping with made-up timestamps: the first
 * tick after arming, the wrap, stop and re-arm.
 *
 * Runs on native_sim via ~/two-computers-one-board/mcu/ztest.sh - no board,
 * no flash cycle, no timers.
 */
#include <zephyr/ztest.h>
#include <errno.h>
#include <limits.h>
#include <string.h>

#include "jitter.h"

static const int32_t edges_us[APP_JITTER_EDGES] = APP_JITTER_EDGES_US;
static struct jitter_hist h;
static struct jitter_ticker t;

static void reset(void *fixture)
{
	ARG_UNUSED(fixture);
	jitter_hist_clear(&h);
	jitter_ticker_arm(&t, 0);
	jitter_ticker_stop(&t);
}

/* --- the bins ---------------------------------------------------------- */

ZTEST(jitter, test_the_bins_are_the_ones_app_proto_h_counts)
{
	zassert_equal(APP_JITTER_BINS, 15);
	zassert_equal(ARRAY_SIZE(edges_us), APP_JITTER_EDGES);
	for (int i = 1; i < APP_JITTER_EDGES; i++) {
		zassert_true(edges_us[i] > edges_us[i - 1], "edges must rise");
	}
}

ZTEST(jitter, test_on_time_and_either_side_of_it_is_the_middle_bin)
{
	zassert_equal(jitter_bin(0), APP_JITTER_EDGES);
	zassert_equal(jitter_bin(50000), APP_JITTER_EDGES, "+50 us is in the middle");
	zassert_equal(jitter_bin(-50000), APP_JITTER_EDGES, "-50 us is in the middle");
	zassert_equal(jitter_bin(50001), APP_JITTER_EDGES + 1, "just past +50 us is late");
	zassert_equal(jitter_bin(-50001), APP_JITTER_EDGES - 1, "just past -50 us is early");
}

ZTEST(jitter, test_every_edge_belongs_to_the_bin_inside_it)
{
	/* An edge is the outer end of its bin, on each side; a nanosecond past
	 * it is the next bin out. */
	for (int i = 0; i < APP_JITTER_EDGES; i++) {
		int32_t e = edges_us[i] * 1000;

		zassert_equal(jitter_bin(e), APP_JITTER_EDGES + i, "+%d us", edges_us[i]);
		zassert_equal(jitter_bin(-e), APP_JITTER_EDGES - i, "-%d us", edges_us[i]);
		zassert_equal(jitter_bin(e + 1), APP_JITTER_EDGES + i + 1, "past +%d us",
			      edges_us[i]);
		zassert_equal(jitter_bin(-e - 1), APP_JITTER_EDGES - i - 1, "past -%d us",
			      edges_us[i]);
	}
}

ZTEST(jitter, test_the_ends_are_the_first_and_last_bins)
{
	zassert_equal(jitter_bin(INT32_MAX), APP_JITTER_BINS - 1);
	zassert_equal(jitter_bin(INT32_MIN), 0, "INT32_MIN has no positive twin; no overflow");
	zassert_equal(jitter_bin(5000001), APP_JITTER_BINS - 1);
	zassert_equal(jitter_bin(-5000001), 0);
}

ZTEST(jitter, test_the_bins_are_the_table_in_app_proto_h)
{
	/* One deviation from the inside of each row of the table, earliest
	 * first, so a reordered table or a swapped sign fails here. */
	static const int32_t us[APP_JITTER_BINS] = {
		-9000, -3000, -1500, -700, -300, -150, -75, 0, 75, 150, 300, 700, 1500, 3000, 9000,
	};

	for (int i = 0; i < APP_JITTER_BINS; i++) {
		zassert_equal(jitter_bin(us[i] * 1000), i, "%d us", us[i]);
	}
}

/* --- the clamp ----------------------------------------------------------- */

ZTEST(jitter, test_a_deviation_beyond_an_int32_is_clamped)
{
	zassert_equal(jitter_clamp_ns(0), 0);
	zassert_equal(jitter_clamp_ns(-123), -123);
	zassert_equal(jitter_clamp_ns((int64_t)INT32_MAX + 1), INT32_MAX);
	zassert_equal(jitter_clamp_ns((int64_t)INT32_MIN - 1), INT32_MIN);
	zassert_equal(jitter_clamp_ns(INT64_MAX), INT32_MAX);
	zassert_equal(jitter_clamp_ns(INT64_MIN), INT32_MIN);
}

/* --- one histogram ------------------------------------------------------- */

ZTEST(jitter, test_an_empty_histogram_reads_as_zeros)
{
	struct jitter_summary s = jitter_hist_read(&h);

	zassert_equal(s.n, 0);
	zassert_equal(s.min_ns, 0);
	zassert_equal(s.max_ns, 0);
	zassert_equal(s.mean_ns, 0);
	for (int i = 0; i < APP_JITTER_BINS; i++) {
		zassert_equal(s.bins[i], 0);
	}
}

ZTEST(jitter, test_min_max_mean_and_bins_add_up)
{
	struct jitter_summary s;

	jitter_hist_add(&h, -3000);   /* middle */
	jitter_hist_add(&h, 120000);  /* late, 100..200 us */
	jitter_hist_add(&h, -700000); /* early, 500..1000 us */
	s = jitter_hist_read(&h);

	zassert_equal(s.n, 3);
	zassert_equal(s.min_ns, -700000);
	zassert_equal(s.max_ns, 120000);
	/* (-3000 + 120000 - 700000) / 3 = -194333.33, toward zero. */
	zassert_equal(s.mean_ns, -194333);
	zassert_equal(s.bins[APP_JITTER_EDGES], 1);
	zassert_equal(s.bins[APP_JITTER_EDGES + 2], 1);
	zassert_equal(s.bins[APP_JITTER_EDGES - 4], 1);
}

ZTEST(jitter, test_one_sample_is_its_own_min_and_max)
{
	/* min starts from the first sample, not from 0: a histogram of late
	 * arrivals only must not report a minimum of 0. */
	struct jitter_summary s;

	jitter_hist_add(&h, 75000);
	s = jitter_hist_read(&h);
	zassert_equal(s.min_ns, 75000);
	zassert_equal(s.max_ns, 75000);
	zassert_equal(s.mean_ns, 75000);
}

ZTEST(jitter, test_a_clamped_sample_is_counted_at_the_clamp)
{
	struct jitter_summary s;

	jitter_hist_add(&h, (int64_t)3600 * 1000000000);
	s = jitter_hist_read(&h);
	zassert_equal(s.max_ns, INT32_MAX);
	zassert_equal(s.bins[APP_JITTER_BINS - 1], 1);
}

ZTEST(jitter, test_the_mean_of_extremes_does_not_overflow)
{
	struct jitter_summary s;

	for (int i = 0; i < 4; i++) {
		jitter_hist_add(&h, INT32_MAX);
	}
	s = jitter_hist_read(&h);
	zassert_equal(s.mean_ns, INT32_MAX, "the sum is 64-bit");
}

ZTEST(jitter, test_clear_empties_it)
{
	jitter_hist_add(&h, 1);
	jitter_hist_clear(&h);
	zassert_equal(jitter_hist_read(&h).n, 0);
	zassert_equal(jitter_hist_read(&h).bins[APP_JITTER_EDGES], 0);
}

/* --- the bins= string ---------------------------------------------------- */

ZTEST(jitter, test_the_bins_print_comma_separated_in_order)
{
	uint32_t bins[APP_JITTER_BINS];
	char buf[JITTER_BINS_STR_MAX];

	for (int i = 0; i < APP_JITTER_BINS; i++) {
		bins[i] = (uint32_t)i;
	}
	zassert_equal(jitter_format_bins(bins, buf, sizeof(buf)), 34);
	zassert_str_equal(buf, "0,1,2,3,4,5,6,7,8,9,10,11,12,13,14");
}

ZTEST(jitter, test_the_widest_bins_fit_the_buffer_the_header_promises)
{
	uint32_t bins[APP_JITTER_BINS];
	char buf[JITTER_BINS_STR_MAX];
	int n;

	for (int i = 0; i < APP_JITTER_BINS; i++) {
		bins[i] = UINT32_MAX;
	}
	n = jitter_format_bins(bins, buf, sizeof(buf));
	zassert_equal(n, APP_JITTER_BINS * 11 - 1, "15 x 10 digits and 14 commas");
	zassert_equal(strlen(buf), (size_t)n);
}

ZTEST(jitter, test_a_short_buffer_is_refused_and_left_empty)
{
	uint32_t bins[APP_JITTER_BINS] = {0};
	char buf[8];

	memset(buf, 'x', sizeof(buf));
	zassert_equal(jitter_format_bins(bins, buf, sizeof(buf)), -ENOSPC);
	zassert_str_equal(buf, "");
	zassert_equal(jitter_format_bins(bins, buf, 0), -ENOSPC);
}

/* --- the ticks ----------------------------------------------------------- */

ZTEST(jitter, test_a_tick_before_arming_is_refused)
{
	zassert_equal(jitter_ticker_tick(&t, 1000), -EAGAIN);
	zassert_equal(jitter_hist_read(&t.hist).n, 0);
}

ZTEST(jitter, test_the_first_tick_starts_the_run_and_counts_nothing)
{
	jitter_ticker_arm(&t, 10000);
	zassert_ok(jitter_ticker_tick(&t, 5000000));
	zassert_equal(jitter_hist_read(&t.hist).n, 0, "one tick is not an interval");
}

ZTEST(jitter, test_each_tick_after_is_one_deviation)
{
	struct jitter_summary s;

	jitter_ticker_arm(&t, 10000);
	zassert_ok(jitter_ticker_tick(&t, 1000000));
	zassert_ok(jitter_ticker_tick(&t, 1010000)); /* on time */
	zassert_ok(jitter_ticker_tick(&t, 1020300)); /* 300 us late */
	zassert_ok(jitter_ticker_tick(&t, 1029900)); /* 400 us early */
	s = jitter_hist_read(&t.hist);

	zassert_equal(s.n, 3);
	zassert_equal(s.min_ns, -400000);
	zassert_equal(s.max_ns, 300000);
	zassert_equal(s.mean_ns, -33333);
	zassert_equal(s.bins[APP_JITTER_EDGES], 1);
	zassert_equal(s.bins[APP_JITTER_EDGES + 3], 1, "300 us late: 200..500");
	zassert_equal(s.bins[APP_JITTER_EDGES - 3], 1, "400 us early: 200..500");
}

ZTEST(jitter, test_an_interval_across_the_counter_wrap_is_measured)
{
	/* TIM5 wraps at 2^32 us, every 71.6 minutes. A run that crosses it
	 * must not see one interval of minus 71 minutes. */
	jitter_ticker_arm(&t, 10000);
	zassert_ok(jitter_ticker_tick(&t, UINT32_MAX - 4999));
	zassert_ok(jitter_ticker_tick(&t, 5000));
	zassert_equal(jitter_hist_read(&t.hist).n, 1);
	zassert_equal(jitter_hist_read(&t.hist).max_ns, 0, "exactly one period");
}

ZTEST(jitter, test_a_missed_tick_is_one_long_late_interval)
{
	struct jitter_summary s;

	jitter_ticker_arm(&t, 10000);
	zassert_ok(jitter_ticker_tick(&t, 0));
	zassert_ok(jitter_ticker_tick(&t, 20000));
	s = jitter_hist_read(&t.hist);
	zassert_equal(s.max_ns, 10000000);
	zassert_equal(s.bins[APP_JITTER_BINS - 1], 1, "10 ms late is past 5000 us");
}

ZTEST(jitter, test_stop_keeps_the_record_and_refuses_ticks)
{
	jitter_ticker_arm(&t, 10000);
	zassert_ok(jitter_ticker_tick(&t, 0));
	zassert_ok(jitter_ticker_tick(&t, 10000));
	jitter_ticker_stop(&t);

	zassert_equal(jitter_ticker_tick(&t, 20000), -EAGAIN);
	zassert_equal(jitter_hist_read(&t.hist).n, 1, "stop is not clear");
	zassert_equal(t.period_us, 10000, "stat still says what it was held to");
}

ZTEST(jitter, test_arming_again_clears_and_forgets_the_last_tick)
{
	jitter_ticker_arm(&t, 10000);
	zassert_ok(jitter_ticker_tick(&t, 0));
	zassert_ok(jitter_ticker_tick(&t, 10000));

	/* The next tick after re-arming must not close an interval that began
	 * under the old period. */
	jitter_ticker_arm(&t, 20000);
	zassert_ok(jitter_ticker_tick(&t, 999999));
	zassert_equal(jitter_hist_read(&t.hist).n, 0);
	zassert_ok(jitter_ticker_tick(&t, 1019999));
	zassert_equal(jitter_hist_read(&t.hist).n, 1);
	zassert_equal(jitter_hist_read(&t.hist).max_ns, 0);
}

ZTEST_SUITE(jitter, NULL, NULL, reset, NULL, NULL);
