/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * Host-runnable tests for the MCU's watchdog: when it is fed, and what
 * `app reset` calls each reset cause.
 *
 * A watchdog that is fed when it should not be looks exactly like one that
 * works, until the day it is needed. So the feed decision is checked for each
 * case it exists to tell apart: a panel refreshing, a panel off on purpose,
 * and a panel that should be refreshing and is not.
 *
 * The names are checked for the properties Linux relies on - one token, the
 * cause before "pin", nothing dropped and nothing cut - against the same
 * inline functions guard.c calls. That a real watchdog reset sets the
 * watchdog bit takes the board: `app hang yes`, then `app reset`.
 *
 * Runs on native_sim via mcu/ztest.sh - no board, no flash cycle.
 */
#include <zephyr/ztest.h>

#include <string.h>

#include "app_proto.h"
#include "guard.h"

#define N_NAMES (sizeof(guard_reset_table) / sizeof(guard_reset_table[0]))

static const char *names(uint32_t cause)
{
	static char buf[GUARD_RESET_NAMES_MAX];

	(void)guard_reset_names(cause, buf, sizeof(buf));
	return buf;
}

/* --- the feed decision ---------------------------------------------------- */

ZTEST(guard, test_a_refreshing_panel_feeds)
{
	zassert_true(guard_should_feed(true, 1240, 1000));
	zassert_true(guard_should_feed(true, 1, 0), "one sweep is enough");
}

ZTEST(guard, test_a_stalled_panel_starves_the_dog)
{
	/* The panel is meant to be on and its count has not moved: the timer
	 * interrupt has stopped. This is the case the watchdog exists for. */
	zassert_false(guard_should_feed(true, 1000, 1000));
	zassert_false(guard_should_feed(true, 0, 0), "on but never swept");
}

ZTEST(guard, test_a_panel_off_on_purpose_still_feeds)
{
	/* Before the first frame and after `app matrix off`, the count stands
	 * still on purpose. Not feeding then would reset a healthy board every
	 * eight seconds whenever nothing was drawing. */
	zassert_true(guard_should_feed(false, 1000, 1000));
	zassert_true(guard_should_feed(false, 0, 0));
	zassert_true(guard_should_feed(false, 5, 1000));
}

ZTEST(guard, test_the_count_wrapping_is_still_progress)
{
	zassert_true(guard_should_feed(true, 3, UINT32_MAX - 5));
}

ZTEST(guard, test_the_timeout_leaves_room_for_many_beats)
{
	/* The beat that feeds is STATUS_TICK_MS (250 ms). A timeout a beat or
	 * two long would reset on one late work item. */
	zassert_true(GUARD_TIMEOUT_MS >= 8 * 1000);
	zassert_true(GUARD_TIMEOUT_MS / 250 >= 16);
}

/* --- the reset-cause names ----------------------------------------------- */

ZTEST(guard, test_a_watchdog_reset_reads_watchdog_then_pin)
{
	/* What RCC records for an IWDG reset on this part: the chip pulls its
	 * own NRST, so the pin flag comes with it. The cause leads. */
	zassert_str_equal(names(RESET_WATCHDOG | RESET_PIN), "watchdog,pin");
}

ZTEST(guard, test_common_resets)
{
	zassert_str_equal(names(RESET_SOFTWARE | RESET_PIN), "software,pin");
	zassert_str_equal(names(RESET_BROWNOUT | RESET_PIN), "brownout,pin");
	zassert_str_equal(names(RESET_PIN), "pin");
	zassert_str_equal(names(RESET_POR), "power_on");
}

ZTEST(guard, test_no_bits_is_none)
{
	zassert_str_equal(names(0), GUARD_RESET_NONE);
}

ZTEST(guard, test_every_bit_has_its_own_name)
{
	for (size_t i = 0; i < N_NAMES; i++) {
		zassert_str_equal(names(guard_reset_table[i].bit), guard_reset_table[i].name);
		zassert_true(guard_reset_table[i].bit != 0);
		for (size_t j = 0; j < i; j++) {
			zassert_true(guard_reset_table[i].bit != guard_reset_table[j].bit,
				     "%s and %s share a bit", guard_reset_table[i].name,
				     guard_reset_table[j].name);
			zassert_true(strcmp(guard_reset_table[i].name, guard_reset_table[j].name) !=
					     0,
				     "two bits are called %s", guard_reset_table[i].name);
		}
	}
}

ZTEST(guard, test_every_hwinfo_cause_is_named)
{
	/* RESET_FLASH is the highest bit hwinfo.h defines today. A new one
	 * would print as "unknown" until it is added to the table. */
	uint32_t named = 0;

	for (size_t i = 0; i < N_NAMES; i++) {
		named |= guard_reset_table[i].bit;
	}
	zassert_equal(named, (RESET_FLASH << 1) - 1);
}

ZTEST(guard, test_names_are_single_tokens)
{
	/* The line is "reset=<names>", split by Python on '=' and ','. */
	for (size_t i = 0; i < N_NAMES; i++) {
		const char *n = guard_reset_table[i].name;

		zassert_true(strlen(n) > 0);
		for (const char *c = n; *c != '\0'; c++) {
			zassert_true((*c >= 'a' && *c <= 'z') || *c == '_', "'%s' has '%c'", n, *c);
		}
	}
}

ZTEST(guard, test_pin_is_last_whatever_else_is_set)
{
	const char *all = names(UINT32_MAX);
	const char *pin = strstr(all, ",pin");

	zassert_not_null(pin);
	/* Only "unknown" may follow it, for bits no name covers. */
	zassert_str_equal(pin, ",pin," GUARD_RESET_UNKNOWN);
}

ZTEST(guard, test_bits_without_a_name_are_unknown_not_dropped)
{
	zassert_str_equal(names(BIT(31)), GUARD_RESET_UNKNOWN);
	zassert_str_equal(names(RESET_WATCHDOG | BIT(30) | BIT(31)), "watchdog,unknown");
}

ZTEST(guard, test_every_bit_at_once_fits)
{
	char buf[GUARD_RESET_NAMES_MAX];
	size_t want = 0;

	for (size_t i = 0; i < N_NAMES; i++) {
		want += strlen(guard_reset_table[i].name) + 1;
	}
	want += strlen(GUARD_RESET_UNKNOWN);

	zassert_equal(guard_reset_names(UINT32_MAX, buf, sizeof(buf)), want);
	zassert_equal(strlen(buf), want);
	zassert_true(want < sizeof(buf));
}

ZTEST(guard, test_a_short_buffer_drops_names_whole)
{
	char buf[12];

	/* "watchdog" fits, ",software" would not: it is left out, not cut. */
	zassert_equal(guard_reset_names(RESET_WATCHDOG | RESET_SOFTWARE, buf, sizeof(buf)), 8);
	zassert_str_equal(buf, "watchdog");

	zassert_equal(guard_reset_names(RESET_WATCHDOG, buf, 1), 0);
	zassert_str_equal(buf, "");
	zassert_equal(guard_reset_names(RESET_WATCHDOG, buf, 0), 0);
}

ZTEST(guard, test_the_line_app_reset_prints)
{
	char line[64];

	snprintf(line, sizeof(line), APP_RESET_FMT, names(RESET_WATCHDOG | RESET_PIN));
	zassert_str_equal(line, "reset=watchdog,pin");
}

ZTEST_SUITE(guard, NULL, NULL, NULL, NULL, NULL);
