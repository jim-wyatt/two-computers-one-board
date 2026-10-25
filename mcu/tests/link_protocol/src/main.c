/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * Host-runnable tests for the MPU <-> MCU contract in app_proto.h.
 *
 * These test the definitions the firmware actually ships: the header included
 * here is the same one main.c includes. An earlier version of this file kept
 * its own copy of the range check, which meant the test could not fail when
 * the firmware changed.
 *
 * Runs on native_sim (i.e. natively on the UNO Q's own Linux side), so this
 * costs no flash cycle and no hardware. Run with:
 *   ~/two-computers-one-board/mcu/ztest.sh
 */
#include <zephyr/ztest.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "app_proto.h"

/* --- the status line ----------------------------------------------------- */

/* Render APP_STATUS_FMT exactly as cmd_app_status() does. */
static void render_status(char *buf, size_t len)
{
	snprintf(buf, len, APP_STATUS_FMT, (long long)1234, 0, (unsigned int)9620);
}

ZTEST(link_protocol, test_status_line_is_parseable)
{
	char buf[128];
	int seen = 0;

	render_status(buf, sizeof(buf));

	for (char *tok = strtok(buf, " "); tok; tok = strtok(NULL, " ")) {
		char *eq = strchr(tok, '=');

		zassert_not_null(eq, "every token must be key=value");
		zassert_true(eq != tok, "a token must have a key before '='");
		zassert_true(*(eq + 1) != '\0', "a token must have a value after '='");
		seen++;
	}
	zassert_equal(seen, APP_STATUS_FIELDS, "expected %d status fields, got %d",
		      APP_STATUS_FIELDS, seen);
}

ZTEST(link_protocol, test_status_line_carries_the_expected_keys)
{
	/* unoq.MCU.status() looks these up by name; renaming one breaks the MPU
	 * side silently, because a missing key just does not appear in the dict.
	 */
	static const char *const keys[] = {"uptime_ms=", "flip=", "sweeps="};
	char buf[128];

	render_status(buf, sizeof(buf));

	for (size_t i = 0; i < ARRAY_SIZE(keys); i++) {
		zassert_not_null(strstr(buf, keys[i]), "status line is missing %s", keys[i]);
	}
}

ZTEST(link_protocol, test_status_values_contain_no_separators)
{
	/* The parser splits on whitespace then on the first '='. A value holding
	 * either character would be silently mis-parsed.
	 */
	char buf[128];

	render_status(buf, sizeof(buf));

	for (char *tok = strtok(buf, " "); tok; tok = strtok(NULL, " ")) {
		zassert_is_null(strchr(strchr(tok, '=') + 1, '='), "a value must not contain '='");
	}
}

/* --- the temp line -------------------------------------------------------- */

ZTEST(link_protocol, test_temp_line_round_trips)
{
	/* Render APP_TEMP_FMT as cmd_app_temp() does and read it back with the
	 * same format. Below freezing is in the list on purpose: the part is
	 * rated to -40 C, and a format that lost the sign would report a cold
	 * board as a warm one.
	 */
	static const int samples[] = {31250, 0, -1, -40000, 125000};
	char buf[64];

	for (size_t i = 0; i < ARRAY_SIZE(samples); i++) {
		int back = 0;

		snprintf(buf, sizeof(buf), APP_TEMP_FMT, samples[i]);
		zassert_equal(sscanf(buf, APP_TEMP_FMT, &back), 1, "'%s' did not parse", buf);
		zassert_equal(back, samples[i], "sent %d, read back %d", samples[i], back);
	}
}

ZTEST(link_protocol, test_temp_line_is_one_key_value_token)
{
	/* unoq.MCU.die_temp() looks for exactly "temp_mc=<integer>". The key is
	 * spelled out here so that renaming it in the header fails a test on
	 * this side too, not only in python/tests/test_contract.py.
	 */
	char buf[64];

	snprintf(buf, sizeof(buf), APP_TEMP_FMT, -40000);
	zassert_equal(strncmp(buf, "temp_mc=", 8), 0, "temp line must start with temp_mc=");
	zassert_is_null(strchr(buf, ' '), "the temp line is a single token");
	zassert_is_null(strchr(strchr(buf, '=') + 1, '='), "a value must not contain '='");
}

ZTEST(link_protocol, test_temp_failure_cannot_be_read_as_a_temperature)
{
	/* The error line carries a negative errno. If it shared the reading's
	 * key - or merely contained it - a parser would hand back -19 millidegrees
	 * for a sensor that never came up, which is a plausible number.
	 */
	char buf[64];
	int back = 12345;

	snprintf(buf, sizeof(buf), APP_TEMP_ERR_FMT, -19);
	zassert_is_null(strstr(buf, "temp_mc="), "error line must not carry the reading's key");
	zassert_equal(sscanf(buf, APP_TEMP_FMT, &back), 0, "'%s' parsed as a temperature", buf);
	zassert_equal(back, 12345, "a failed parse must leave the value alone");

	zassert_equal(sscanf(buf, APP_TEMP_ERR_FMT, &back), 1, "'%s' did not parse", buf);
	zassert_equal(back, -19, "errno did not survive the round trip");
}

/* --- other shared constants ---------------------------------------------- */

ZTEST(link_protocol, test_settings_key_is_namespaced)
{
	/* SETTINGS_STATIC_HANDLER_DEFINE registers the "app" subtree, so the key
	 * must sit under it or settings_load() will never call the handler.
	 */
	zassert_equal(strncmp(APP_SETTINGS_FLIP, "app/", 4), 0,
		      "panel orientation key must live under the app/ subtree");
}

/* --- the bars contract ---------------------------------------------------- */

ZTEST(link_protocol, test_bar_percentages_span_exactly_zero_to_full)
{
	/* unoq.MCU.bars() clamps to this range before sending. If the two ends
	 * disagree the MPU would send values the firmware rejects, and the
	 * panel would freeze on its last good frame with no error visible.
	 */
	zassert_true(app_bars_pct_valid(0), "an idle core is a legal reading");
	zassert_true(app_bars_pct_valid(APP_BARS_PCT_MAX), "a pegged core is a legal reading");
	zassert_false(app_bars_pct_valid(-1), "negative load is not a thing");
	zassert_false(app_bars_pct_valid(APP_BARS_PCT_MAX + 1), "over 100%% must be rejected");
}

ZTEST(link_protocol, test_bar_count_matches_what_the_panel_can_show)
{
	zassert_true(app_bars_count_valid(1), "one bar must be allowed");
	zassert_true(app_bars_count_valid(APP_BARS_MAX), "the advertised maximum must be allowed");
	zassert_false(app_bars_count_valid(0), "nothing to draw is a usage error");
	zassert_false(app_bars_count_valid(APP_BARS_MAX + 1), "above the maximum must be rejected");

	/* Each bar needs a column and each pair of bars a blank column between
	 * them. If APP_BARS_MAX ever exceeds that, the layout silently loses
	 * the gaps and separate cores read as one bar. */
	zassert_true(2 * APP_BARS_MAX - 1 <= APP_MATRIX_COLS,
		     "%d bars cannot be drawn with gaps in %d columns", APP_BARS_MAX,
		     APP_MATRIX_COLS);

	/* The UNO Q's own MPU has four cores; a cap below that would make this
	 * firmware unable to display the board it is soldered to. */
	zassert_true(APP_BARS_MAX >= 4, "must be able to show four CPU cores");
}

ZTEST(link_protocol, test_matrix_geometry_is_self_consistent)
{
	zassert_equal(APP_MATRIX_LEDS, APP_MATRIX_ROWS * APP_MATRIX_COLS,
		      "LED count must equal the grid it indexes");

	/* matrix.c walks pixel indices 0..APP_MATRIX_LEDS-1 against a phase
	 * counter of 0..APP_MATRIX_MAX_LEVEL-1; a max level of zero would make
	 * that modulo a division by zero in the refresh ISR. */
	zassert_true(APP_MATRIX_MAX_LEVEL > 0, "grayscale needs at least one step");

	zassert_true(app_matrix_level_valid(0), "off is a valid level");
	zassert_true(app_matrix_level_valid(APP_MATRIX_MAX_LEVEL), "full brightness is valid");
	zassert_false(app_matrix_level_valid(APP_MATRIX_MAX_LEVEL + 1), "above full is not");
	zassert_false(app_matrix_level_valid(-1), "negative brightness is not");
}

ZTEST(link_protocol, test_matrix_pixel_bounds_cover_the_panel_and_no_more)
{
	zassert_true(app_matrix_pixel_valid(0, 0), "the first pixel must be addressable");
	zassert_true(app_matrix_pixel_valid(APP_MATRIX_ROWS - 1, APP_MATRIX_COLS - 1),
		     "the last pixel must be addressable");
	zassert_false(app_matrix_pixel_valid(APP_MATRIX_ROWS, 0), "one row past the end");
	zassert_false(app_matrix_pixel_valid(0, APP_MATRIX_COLS), "one column past the end");
	zassert_false(app_matrix_pixel_valid(-1, 0), "negative row");
	zassert_false(app_matrix_pixel_valid(0, -1), "negative column");
}

ZTEST(link_protocol, test_documented_sweep_rate_matches_the_geometry)
{
	/* APP_MATRIX_SWEEPS_PER_S is what docs and `app status` are checked
	 * against, so it has to follow from the panel size and the 10us slot
	 * matrix.c programs - not from whatever a board happened to measure.
	 */
	int expected = 1000000 / (APP_MATRIX_LEDS * 10);

	zassert_within(APP_MATRIX_SWEEPS_PER_S, expected, 5,
		       "documented %d sweeps/s but the geometry implies %d",
		       APP_MATRIX_SWEEPS_PER_S, expected);
}

/* --- the numbers a command takes ----------------------------------------- */

ZTEST(link_protocol, test_a_number_is_read_as_that_number)
{
	static const struct {
		const char *in;
		int want;
	} ok[] = {{"0", 0}, {"7", 7}, {"100", 100}, {"-1", -1}, {"012", 12}};

	for (size_t i = 0; i < ARRAY_SIZE(ok); i++) {
		int got = -999;

		zassert_true(app_parse_int(ok[i].in, &got), "'%s' was refused", ok[i].in);
		zassert_equal(got, ok[i].want, "'%s' read as %d", ok[i].in, got);
	}
}

ZTEST(link_protocol, test_anything_else_is_refused_and_changes_nothing)
{
	/* atoi() read every one of these as a number - most of them as 0, which
	 * is a legal bar and a legal pixel, so the command said "ok". The last
	 * two do not fit an int, which strtol reports and atoi does not. */
	static const char *const bad[] = {
		"", "abc", "x", "5x", "5 ", "1.5", "0x10", "-", "+", "99999999999", "-99999999999",
	};

	for (size_t i = 0; i < ARRAY_SIZE(bad); i++) {
		int got = 12345;

		zassert_false(app_parse_int(bad[i], &got), "'%s' was read as a number", bad[i]);
		zassert_equal(got, 12345, "a refused '%s' still wrote %d", bad[i], got);
	}
	zassert_false(app_parse_int(NULL, &(int){0}), "a missing argument is not a number");
}

ZTEST_SUITE(link_protocol, NULL, NULL, NULL, NULL, NULL);
