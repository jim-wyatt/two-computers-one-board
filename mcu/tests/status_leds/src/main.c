/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * Host-runnable tests for what LED 3 and LED 4 show.
 *
 * An LED cannot be read back, and a wrong mapping does not look broken - it
 * looks like a board in a different state. So the mapping is checked here, and
 * checked for the property that matters rather than for a list of remembered
 * values: every state of an LED must be tellable from every other WITHOUT
 * using its color. That is the whole reason the rhythms exist.
 *
 * These are the same inline functions status_leds.c calls. What is not tested
 * here is that a GPIO moved; that takes the board.
 *
 * Runs on native_sim via ~/two-computers-one-board/mcu/ztest.sh - no board, no flash cycle.
 */
#include <zephyr/ztest.h>

#include "status_leds.h"

/* Long enough to hold several whole slow blinks. */
#define BEATS (8 * 2 * STATUS_SLOW_TICKS)

/* How many times an LED with this rhythm goes from dark to lit in BEATS. */
static int flashes(enum status_rhythm rhythm)
{
	int n = 0;

	for (uint32_t t = 1; t <= BEATS; t++) {
		if (status_rhythm_lit(rhythm, t) && !status_rhythm_lit(rhythm, t - 1)) {
			n++;
		}
	}
	return n;
}

/* --- LED 3 --------------------------------------------------------------- */

ZTEST(status_leds, test_led3_states)
{
	struct status_look ok = status_led3_look(false, true);
	struct status_look trial = status_led3_look(false, false);
	struct status_look fault = status_led3_look(true, true);

	zassert_equal(ok.color, STATUS_GREEN);
	zassert_equal(ok.rhythm, STATUS_STEADY, "a confirmed image is the settled state");
	zassert_equal(trial.color, STATUS_YELLOW);
	zassert_equal(trial.rhythm, STATUS_SLOW, "probation is in progress, not a fault");
	zassert_equal(fault.color, STATUS_RED);
	zassert_equal(fault.rhythm, STATUS_FAST, "a fault needs a human");
}

ZTEST(status_leds, test_led3_fault_outranks_the_image_state)
{
	struct status_look a = status_led3_look(true, true);
	struct status_look b = status_led3_look(true, false);

	zassert_equal(a.color, b.color, "a fault looks the same on either image");
	zassert_equal(a.rhythm, b.rhythm, "a fault looks the same on either image");
	zassert_equal(b.rhythm, STATUS_FAST, "an unconfirmed image must not soften a fault");
}

ZTEST(status_leds, test_led3_states_differ_without_color)
{
	enum status_rhythm ok = status_led3_look(false, true).rhythm;
	enum status_rhythm trial = status_led3_look(false, false).rhythm;
	enum status_rhythm fault = status_led3_look(true, false).rhythm;

	zassert_not_equal(ok, trial, "green and yellow must not rely on hue");
	zassert_not_equal(ok, fault, "green and red must not rely on hue");
	zassert_not_equal(trial, fault, "yellow and red must not rely on hue");
}

/* --- LED 4 --------------------------------------------------------------- */

ZTEST(status_leds, test_led4_states)
{
	struct status_look fresh = status_led4_look(true);
	struct status_look stale = status_led4_look(false);

	zassert_equal(fresh.color, STATUS_GREEN);
	zassert_equal(fresh.rhythm, STATUS_STEADY);
	zassert_equal(stale.color, STATUS_RED);
	zassert_equal(stale.rhythm, STATUS_FAST, "silence is a fault, not a slow day");
	zassert_not_equal(fresh.rhythm, stale.rhythm, "must not rely on hue");
}

/* --- the rhythms themselves ---------------------------------------------- */

ZTEST(status_leds, test_steady_never_goes_dark)
{
	/* Dark means "nothing is driving this LED". A healthy state that
	 * flickered off, even for a beat, would be saying that. */
	for (uint32_t t = 0; t < BEATS; t++) {
		zassert_true(status_rhythm_lit(STATUS_STEADY, t), "dark on beat %u", t);
	}
}

ZTEST(status_leds, test_blinks_are_lit_half_the_time)
{
	int slow = 0;
	int fast = 0;

	for (uint32_t t = 0; t < BEATS; t++) {
		slow += status_rhythm_lit(STATUS_SLOW, t);
		fast += status_rhythm_lit(STATUS_FAST, t);
	}
	zassert_equal(slow, BEATS / 2, "slow blink lit %d of %d beats", slow, BEATS);
	zassert_equal(fast, BEATS / 2, "fast blink lit %d of %d beats", fast, BEATS);
}

ZTEST(status_leds, test_blink_rates)
{
	int per_second = 1000 / STATUS_TICK_MS;
	int seconds = BEATS / per_second;

	zassert_equal(BEATS % per_second, 0, "the window must be whole seconds");
	zassert_equal(2 * flashes(STATUS_SLOW), seconds, "slow is once every two seconds");
	zassert_equal(flashes(STATUS_FAST), 2 * seconds, "fast is twice a second");
	zassert_equal(flashes(STATUS_STEADY), 0, "steady does not flash");
}

ZTEST(status_leds, test_nothing_flashes_faster_than_three_a_second)
{
	/*
	 * The ceiling accessibility guidance sets for anything that flashes. The
	 * first version of this blinked four times a second - a change made so
	 * that more people could read these lights, and the one thing on the
	 * board some people should not look at.
	 */
	int per_second = 1000 / STATUS_TICK_MS;
	int seconds = BEATS / per_second;

	zassert_true(flashes(STATUS_FAST) <= 3 * seconds, "%d flashes in %d s",
		     flashes(STATUS_FAST), seconds);
}

ZTEST(status_leds, test_fast_is_plainly_faster_than_slow)
{
	/* Told apart at a glance, across a room, by someone not counting. */
	zassert_true(flashes(STATUS_FAST) >= 3 * flashes(STATUS_SLOW), "%d against %d",
		     flashes(STATUS_FAST), flashes(STATUS_SLOW));
}

ZTEST(status_leds, test_the_check_still_runs_once_a_second)
{
	zassert_equal(STATUS_TICKS_PER_CHECK * STATUS_TICK_MS, 1000,
		      "the link and image are looked at once a second, blink or no blink");
}

ZTEST(status_leds, test_counter_wrap_does_not_cut_a_blink_short)
{
	/* The beat counter is 32 bits and wraps after seventeen years. The
	 * rhythm either side of the wrap must be the rhythm everywhere else. */
	for (uint32_t i = 0; i < 2 * STATUS_SLOW_TICKS; i++) {
		uint32_t before = UINT32_MAX - (2 * STATUS_SLOW_TICKS - 1) + i;

		zassert_equal(status_rhythm_lit(STATUS_SLOW, before),
			      status_rhythm_lit(STATUS_SLOW, i), "slow, %u beats before the wrap",
			      2 * STATUS_SLOW_TICKS - i);
		zassert_equal(status_rhythm_lit(STATUS_FAST, before),
			      status_rhythm_lit(STATUS_FAST, i), "fast, %u beats before the wrap",
			      2 * STATUS_SLOW_TICKS - i);
	}
}

ZTEST_SUITE(status_leds, NULL, NULL, NULL, NULL, NULL);
