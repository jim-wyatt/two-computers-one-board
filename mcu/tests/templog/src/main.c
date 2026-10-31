/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * Host-runnable tests for the temperature log the firmware ships.
 *
 * The log's whole job is that a reader who comes back later can tell exactly
 * what it missed. So these check the bookkeeping that makes that true -
 * sequence numbers, wraparound, what `since` means at each edge, the gap a
 * reader is told about, the cap on one reply, the drop count - and the clock
 * that fills it, with a fake in place of the sensor.
 *
 * Runs on native_sim via ~/two-computers-one-board/mcu/ztest.sh - no board, no flash cycle.
 */
#include <zephyr/ztest.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>

#include "templog.h"

/* 9.6 KB: static, not on a test thread's stack. */
static struct templog tl;
static struct templog_sample out[APP_TEMPLOG_SIZE + 1];

/* Sample n is taken at n * 1000 ms and reads 20000 + n millidegrees, so any
 * sample checks itself against its own sequence number. */
static void fill(uint32_t n)
{
	for (uint32_t i = 0; i < n; i++) {
		uint32_t seq = tl.head + 1U;

		templog_record(&tl, (int64_t)seq * 1000, 0, 20000 + (int32_t)seq);
	}
}

static void assert_sample(const struct templog_sample *s, uint32_t seq)
{
	zassert_equal(s->seq, seq, "expected seq %u, got %u", seq, s->seq);
	zassert_true(s->ok, "seq %u should be a reading", seq);
	zassert_equal(s->ms, (int64_t)seq * 1000, "seq %u: wrong timestamp", seq);
	zassert_equal(s->value, 20000 + (int32_t)seq, "seq %u: another sample's value", seq);
}

static void reset(void *fixture)
{
	ARG_UNUSED(fixture);
	templog_stop();
	templog_init(&tl);
}

/* --- before anything is recorded --------------------------------------- */

ZTEST(templog, test_an_empty_log_has_nothing_and_says_so)
{
	struct templog_batch b;
	struct templog_stat st = templog_stat(&tl);

	zassert_equal(st.head, 0);
	zassert_equal(st.count, 0);
	zassert_equal(st.dropped, 0);

	zassert_ok(templog_read(&tl, false, 0, out, APP_TEMPLOG_BATCH, &b));
	zassert_equal(b.n, 0);
	zassert_equal(b.more, 0);
	zassert_equal(b.gap_first, 0, "nothing was lost from a log never written");

	zassert_ok(templog_read(&tl, true, 0, out, APP_TEMPLOG_BATCH, &b),
		   "since 0 is the start of time, and valid before the first sample");
	zassert_equal(b.n, 0);
	zassert_equal(b.gap_first, 0);
}

/* --- sequence numbers --------------------------------------------------- */

ZTEST(templog, test_sequence_starts_at_one_and_reads_oldest_first)
{
	struct templog_batch b;

	fill(5);
	zassert_ok(templog_read(&tl, false, 0, out, APP_TEMPLOG_BATCH, &b));
	zassert_equal(b.n, 5);
	zassert_equal(b.head, 5);
	for (uint32_t i = 0; i < b.n; i++) {
		assert_sample(&out[i], i + 1U);
	}
}

ZTEST(templog, test_a_failed_read_keeps_its_sequence_number)
{
	/* A failure is a sample that says what went wrong, not a missing one:
	 * otherwise a sensor fault would look exactly like a lost record. */
	struct templog_batch b;

	fill(1);
	templog_record(&tl, 2000, -EIO, 99999);
	fill(1);

	zassert_ok(templog_read(&tl, false, 0, out, APP_TEMPLOG_BATCH, &b));
	zassert_equal(b.n, 3);
	assert_sample(&out[0], 1);
	zassert_equal(out[1].seq, 2);
	zassert_false(out[1].ok);
	zassert_equal(out[1].value, -EIO, "the errno, not the number the read left");
	assert_sample(&out[2], 3);
}

/* --- since ---------------------------------------------------------------- */

ZTEST(templog, test_since_returns_only_newer_samples)
{
	struct templog_batch b;

	fill(10);
	zassert_ok(templog_read(&tl, true, 7, out, APP_TEMPLOG_BATCH, &b));
	zassert_equal(b.n, 3);
	assert_sample(&out[0], 8);
	assert_sample(&out[2], 10);
	zassert_equal(b.gap_first, 0, "8 follows 7: nothing lost");
}

ZTEST(templog, test_since_the_newest_is_an_empty_batch_not_an_error)
{
	/* The common case for a reader that is keeping up. */
	struct templog_batch b;

	fill(10);
	zassert_ok(templog_read(&tl, true, 10, out, APP_TEMPLOG_BATCH, &b));
	zassert_equal(b.n, 0);
	zassert_equal(b.more, 0);
	zassert_equal(b.head, 10);
}

ZTEST(templog, test_since_beyond_the_newest_is_refused)
{
	/* The reader's number is from before a restart. Answering with nothing
	 * would leave it waiting for sample 50 while the MCU counts up from 1. */
	struct templog_batch b;

	fill(10);
	zassert_equal(templog_read(&tl, true, 50, out, APP_TEMPLOG_BATCH, &b), -ERANGE);
	zassert_equal(b.head, 10, "the refusal still says where the log is");
	zassert_equal(b.n, 0);
}

/* --- wraparound and gaps ---------------------------------------------------- */

ZTEST(templog, test_a_full_ring_overwrites_the_oldest)
{
	struct templog_batch b;
	struct templog_stat st;

	fill(APP_TEMPLOG_SIZE + 10);
	st = templog_stat(&tl);
	zassert_equal(st.head, APP_TEMPLOG_SIZE + 10);
	zassert_equal(st.count, APP_TEMPLOG_SIZE);

	/* The whole ring in one read, to check every slot after the wrap. */
	zassert_ok(templog_read(&tl, false, 0, out, APP_TEMPLOG_SIZE + 1, &b));
	zassert_equal(b.n, APP_TEMPLOG_SIZE);
	zassert_equal(b.gap_first, 0, "no since, no gap: the caller asked for what is held");
	for (uint32_t i = 0; i < b.n; i++) {
		assert_sample(&out[i], 11U + i);
	}
}

ZTEST(templog, test_since_older_than_the_oldest_reports_the_gap)
{
	struct templog_batch b;

	fill(APP_TEMPLOG_SIZE + 10); /* 1..10 are gone; 11 is the oldest */
	zassert_ok(templog_read(&tl, true, 4, out, APP_TEMPLOG_BATCH, &b));
	zassert_equal(b.gap_first, 5, "the first number the reader will never get");
	zassert_equal(b.gap_last, 10, "the last, inclusive");
	assert_sample(&out[0], 11);
}

ZTEST(templog, test_since_zero_reports_everything_lost_since_boot)
{
	struct templog_batch b;

	fill(APP_TEMPLOG_SIZE + 3);
	zassert_ok(templog_read(&tl, true, 0, out, APP_TEMPLOG_BATCH, &b));
	zassert_equal(b.gap_first, 1);
	zassert_equal(b.gap_last, 3);
	assert_sample(&out[0], 4);
}

ZTEST(templog, test_since_just_before_the_oldest_is_not_a_gap)
{
	/* The edge: the reader saw 10, and 11 is the oldest held. */
	struct templog_batch b;

	fill(APP_TEMPLOG_SIZE + 10);
	zassert_ok(templog_read(&tl, true, 10, out, APP_TEMPLOG_BATCH, &b));
	zassert_equal(b.gap_first, 0);
	assert_sample(&out[0], 11);
}

/* --- the cap on one reply --------------------------------------------------- */

ZTEST(templog, test_a_batch_is_capped_and_says_how_many_remain)
{
	struct templog_batch b;

	fill(100);
	zassert_ok(templog_read(&tl, false, 0, out, APP_TEMPLOG_BATCH, &b));
	zassert_equal(b.n, APP_TEMPLOG_BATCH);
	zassert_equal(b.more, 100 - APP_TEMPLOG_BATCH);
	assert_sample(&out[0], 1);
	assert_sample(&out[APP_TEMPLOG_BATCH - 1], APP_TEMPLOG_BATCH);
}

ZTEST(templog, test_paging_with_since_reads_every_sample_once)
{
	/* What MCU.temp_log() does: ask again from the last number seen until
	 * nothing is left. Across a wrapped ring, so the paging crosses the
	 * slot where the ring starts over. */
	struct templog_batch b;
	uint32_t since = 250; /* just before the oldest held */
	uint32_t next = 251;
	uint32_t replies = 0;

	fill(APP_TEMPLOG_SIZE + 250);
	do {
		zassert_ok(templog_read(&tl, true, since, out, APP_TEMPLOG_BATCH, &b));
		zassert_equal(b.gap_first, 0);
		for (uint32_t i = 0; i < b.n; i++) {
			assert_sample(&out[i], next++);
		}
		if (b.n > 0) {
			since = out[b.n - 1].seq;
		}
		replies++;
	} while (b.more > 0);

	zassert_equal(next, APP_TEMPLOG_SIZE + 251, "stopped at %u", next);
	zassert_equal(replies, DIV_ROUND_UP(APP_TEMPLOG_SIZE, APP_TEMPLOG_BATCH));
}

/* --- dropped ----------------------------------------------------------------- */

ZTEST(templog, test_dropped_counts_each_overwrite)
{
	fill(APP_TEMPLOG_SIZE);
	zassert_equal(templog_stat(&tl).dropped, 0, "full is not dropped");

	fill(1);
	zassert_equal(templog_stat(&tl).dropped, 1);

	fill(APP_TEMPLOG_SIZE * 2);
	zassert_equal(templog_stat(&tl).dropped, APP_TEMPLOG_SIZE * 2 + 1);
	zassert_equal(templog_stat(&tl).count, APP_TEMPLOG_SIZE);
}

/* --- the clock, with a fake sensor -------------------------------------- */

static int reads;

static int fake_read(int32_t *temp_mc)
{
	reads++;
	*temp_mc = 30000 + reads;
	return 0;
}

static int broken_read(int32_t *temp_mc)
{
	ARG_UNUSED(temp_mc);
	return -ENODEV;
}

ZTEST(templog, test_sample_records_what_the_read_returns)
{
	struct templog_batch b;

	reads = 0;
	templog_sample(&tl, fake_read, 1234);
	templog_sample(&tl, broken_read, 2234);

	zassert_ok(templog_read(&tl, false, 0, out, APP_TEMPLOG_BATCH, &b));
	zassert_equal(b.n, 2);
	zassert_true(out[0].ok);
	zassert_equal(out[0].value, 30001);
	zassert_equal(out[0].ms, 1234);
	zassert_false(out[1].ok);
	zassert_equal(out[1].value, -ENODEV);
}

ZTEST(templog, test_the_timer_samples_on_its_own)
{
	/* Nobody calls templog_sample() here: the samples come from the timer.
	 * On native_sim k_sleep() advances simulated time, so this is quick. */
	struct templog_batch b;

	reads = 0;
	templog_start(&tl, fake_read, APP_TEMPLOG_PERIOD_MS);
	k_sleep(K_MSEC(3 * APP_TEMPLOG_PERIOD_MS + APP_TEMPLOG_PERIOD_MS / 2));
	templog_stop();

	zassert_equal(templog_stat(&tl).head, 3, "3.5 periods is three samples");
	zassert_ok(templog_read(&tl, false, 0, out, APP_TEMPLOG_BATCH, &b));
	for (uint32_t i = 1; i < b.n; i++) {
		int64_t step = out[i].ms - out[i - 1].ms;

		zassert_within(step, APP_TEMPLOG_PERIOD_MS, 1, "samples %u ms apart",
			       (unsigned int)step);
	}

	k_sleep(K_MSEC(2 * APP_TEMPLOG_PERIOD_MS));
	zassert_equal(templog_stat(&tl).head, 3, "stopped means stopped");
}

/* --- the lines the shell prints ------------------------------------------- */

ZTEST(templog, test_the_sample_lines_render_as_documented)
{
	/* The same values python/tests/test_contract.py renders through the same
	 * formats, so both ends agree on what is on the wire. */
	char buf[96];

	snprintf(buf, sizeof(buf), APP_TEMPLOG_FMT, 4294967295U, (long long)-1, -40000);
	zassert_str_equal(buf, "seq=4294967295 ms=-1 temp_mc=-40000");
	snprintf(buf, sizeof(buf), APP_TEMPLOG_ERR_FMT, 7U, (long long)123456789012, -19);
	zassert_str_equal(buf, "seq=7 ms=123456789012 temp_err=-19");
	snprintf(buf, sizeof(buf), APP_TEMPLOG_GAP_FMT, 5U, 10U);
	zassert_str_equal(buf, "gap first=5 last=10");
	snprintf(buf, sizeof(buf), APP_TEMPLOG_END_FMT, 610U, 0U);
	zassert_str_equal(buf, "end head=610 more=0");
	snprintf(buf, sizeof(buf), APP_TEMPLOG_STAT_FMT, 610U, 600U, 600U, 10U, 1000U);
	zassert_str_equal(buf, "head=610 count=600 size=600 dropped=10 period_ms=1000");
}

ZTEST(templog, test_a_reading_and_a_failure_never_share_a_key)
{
	/* MCU.temp_log() tells them apart by key, as die_temp() does. */
	zassert_not_null(strstr(APP_TEMPLOG_FMT, "temp_mc="));
	zassert_is_null(strstr(APP_TEMPLOG_FMT, "temp_err="));
	zassert_not_null(strstr(APP_TEMPLOG_ERR_FMT, "temp_err="));
	zassert_is_null(strstr(APP_TEMPLOG_ERR_FMT, "temp_mc="));
}

ZTEST(templog, test_a_full_reply_fits_the_batch_the_header_promises)
{
	/* A batch the size of the ring would be one 20 KB reply; the cap is what
	 * keeps a reader's timeout honest. */
	zassert_true(APP_TEMPLOG_BATCH < APP_TEMPLOG_SIZE);
	zassert_true(APP_TEMPLOG_BATCH >= 1);
}

ZTEST_SUITE(templog, NULL, NULL, reset, NULL, NULL);
