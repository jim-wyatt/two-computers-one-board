/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * Host-runnable tests for the bar rasterizer the firmware ships.
 *
 * A charlieplexed panel is invisible to software: nothing the MCU can read
 * back tells you what is lit. That makes these tests the only place the
 * drawing rules are actually checked, so they check properties (bars stay in
 * their columns, height rises with load, rotation is a true rotation) rather
 * than a handful of remembered frames.
 *
 * Runs on native_sim via ~/two-computers-one-board/mcu/ztest.sh - no board, no flash cycle.
 */
#include <zephyr/ztest.h>
#include <string.h>

#include "bars.h"

#define AT(frame, row, col) ((frame)[(row) * APP_MATRIX_COLS + (col)])

/* --- layout -------------------------------------------------------------- */

ZTEST(bars, test_layout_rejects_impossible_counts)
{
	struct app_bars_layout l = {.width = 999, .left = 999};

	zassert_false(app_bars_layout(0, &l), "zero bars is not a display");
	zassert_false(app_bars_layout(-1, &l), "negative must be rejected");
	zassert_false(app_bars_layout(APP_BARS_MAX + 1, &l), "above the panel's capacity");

	zassert_equal(l.width, 999, "a rejected layout must not be written to");
	zassert_equal(l.left, 999, "a rejected layout must not be written to");
}

ZTEST(bars, test_layout_fits_the_panel)
{
	for (int n = 1; n <= APP_BARS_MAX; n++) {
		struct app_bars_layout l;
		int last;

		zassert_true(app_bars_layout(n, &l), "%d bars must be layable out", n);
		zassert_true(l.width >= 1, "%d bars: width %d is not drawable", n, l.width);
		zassert_true(l.left >= 0, "%d bars: negative margin", n);

		last = app_bars_column(&l, n - 1) + l.width;
		zassert_true(last <= APP_MATRIX_COLS, "%d bars: overruns the panel by %d", n,
			     last - APP_MATRIX_COLS);
	}
}

ZTEST(bars, test_layout_keeps_a_gap_between_bars)
{
	/* Without a blank column between them, two busy cores read as one wide
	 * bar - the whole point of separate bars is lost. */
	for (int n = 2; n <= APP_BARS_MAX; n++) {
		struct app_bars_layout l;

		zassert_true(app_bars_layout(n, &l), "%d bars", n);
		for (int i = 1; i < n; i++) {
			int gap = app_bars_column(&l, i) - (app_bars_column(&l, i - 1) + l.width);

			zassert_equal(gap, 1, "%d bars: gap %d between bar %d and %d", n, gap,
				      i - 1, i);
		}
	}
}

ZTEST(bars, test_layout_is_centered)
{
	/* Leftover columns are margin, split as evenly as an integer allows -
	 * never handed to one bar, which would make it look busier. */
	for (int n = 1; n <= APP_BARS_MAX; n++) {
		struct app_bars_layout l;
		int right;

		zassert_true(app_bars_layout(n, &l), "%d bars", n);
		right = APP_MATRIX_COLS - (app_bars_column(&l, n - 1) + l.width);

		zassert_true(right - l.left >= 0 && right - l.left <= 1,
			     "%d bars: margins %d and %d are not balanced", n, l.left, right);
	}
}

/* --- rendering ----------------------------------------------------------- */

static int lit_pixels(const uint8_t *frame)
{
	int n = 0;

	for (int i = 0; i < APP_MATRIX_LEDS; i++) {
		if (frame[i] > 0) {
			n++;
		}
	}
	return n;
}

ZTEST(bars, test_idle_draws_nothing)
{
	const uint8_t pct[] = {0, 0, 0, 0};
	uint8_t frame[APP_MATRIX_LEDS];

	app_bars_render(pct, 4, false, frame);
	zassert_equal(lit_pixels(frame), 0, "an idle host must leave the panel dark");
}

ZTEST(bars, test_full_load_fills_the_bar_at_full_brightness)
{
	const uint8_t pct[] = {APP_BARS_PCT_MAX};
	uint8_t frame[APP_MATRIX_LEDS];
	struct app_bars_layout l;

	app_bars_render(pct, 1, false, frame);
	zassert_true(app_bars_layout(1, &l), "layout");

	for (int row = 0; row < APP_MATRIX_ROWS; row++) {
		for (int c = 0; c < l.width; c++) {
			zassert_equal(AT(frame, row, app_bars_column(&l, 0) + c),
				      APP_MATRIX_MAX_LEVEL, "100%% must light row %d fully", row);
		}
	}
}

ZTEST(bars, test_bars_grow_from_the_bottom)
{
	const uint8_t pct[] = {50};
	uint8_t frame[APP_MATRIX_LEDS];
	struct app_bars_layout l;
	int col;

	app_bars_render(pct, 1, false, frame);
	zassert_true(app_bars_layout(1, &l), "layout");
	col = app_bars_column(&l, 0);

	/* Half load is the bottom half lit and the top half dark. A bar that
	 * grew downwards would pass every other test in this file. */
	for (int row = 0; row < APP_MATRIX_ROWS / 2; row++) {
		zassert_equal(AT(frame, row, col), 0, "row %d should be above the bar", row);
	}
	for (int row = APP_MATRIX_ROWS / 2; row < APP_MATRIX_ROWS; row++) {
		zassert_equal(AT(frame, row, col), APP_MATRIX_MAX_LEVEL,
			      "row %d should be inside the bar", row);
	}
}

ZTEST(bars, test_bars_stay_in_their_own_columns)
{
	uint8_t pct[APP_BARS_MAX];
	uint8_t frame[APP_MATRIX_LEDS];

	for (int n = 1; n <= APP_BARS_MAX; n++) {
		struct app_bars_layout l;

		for (int i = 0; i < n; i++) {
			pct[i] = APP_BARS_PCT_MAX;
		}
		app_bars_render(pct, n, false, frame);
		zassert_true(app_bars_layout(n, &l), "layout");

		/* Every lit column must belong to some bar. */
		for (int col = 0; col < APP_MATRIX_COLS; col++) {
			bool in_bar = false;
			bool lit = false;

			for (int i = 0; i < n; i++) {
				int start = app_bars_column(&l, i);

				if (col >= start && col < start + l.width) {
					in_bar = true;
				}
			}
			for (int row = 0; row < APP_MATRIX_ROWS; row++) {
				lit = lit || AT(frame, row, col) > 0;
			}
			zassert_equal(lit, in_bar, "%d bars: column %d lit=%d but in_bar=%d", n,
				      col, lit, in_bar);
		}
	}
}

ZTEST(bars, test_one_busy_core_does_not_light_the_others)
{
	const uint8_t pct[] = {100, 0, 0, 0};
	uint8_t frame[APP_MATRIX_LEDS];
	struct app_bars_layout l;

	app_bars_render(pct, 4, false, frame);
	zassert_true(app_bars_layout(4, &l), "layout");

	zassert_equal(lit_pixels(frame), APP_MATRIX_ROWS * l.width,
		      "only the first bar should be lit");
}

ZTEST(bars, test_height_never_falls_as_load_rises)
{
	/* The reading has to be monotonic or the display lies. Rounding in the
	 * partial-row arithmetic is the easy way to break this. */
	int prev_total = -1;

	for (int p = 0; p <= APP_BARS_PCT_MAX; p++) {
		uint8_t pct[] = {(uint8_t)p};
		uint8_t frame[APP_MATRIX_LEDS];
		int total = 0;

		app_bars_render(pct, 1, false, frame);
		for (int i = 0; i < APP_MATRIX_LEDS; i++) {
			total += frame[i];
		}
		zassert_true(total >= prev_total, "%d%% is dimmer than %d%%", p, p - 1);
		prev_total = total;
	}
}

ZTEST(bars, test_partial_rows_use_grayscale)
{
	/* Eight rows alone would quantize to 12.5% steps. Somewhere below one
	 * whole row there has to be a dimmed pixel, or the vernier is not
	 * working and small differences in load are invisible. */
	const uint8_t pct[] = {6};
	uint8_t frame[APP_MATRIX_LEDS];
	struct app_bars_layout l;
	uint8_t level;

	app_bars_render(pct, 1, false, frame);
	zassert_true(app_bars_layout(1, &l), "layout");

	level = AT(frame, APP_MATRIX_ROWS - 1, app_bars_column(&l, 0));
	zassert_true(level > 0, "6%% should light the bottom row");
	zassert_true(level < APP_MATRIX_MAX_LEVEL, "6%% should light it dimly, not fully");
}

ZTEST(bars, test_levels_never_exceed_the_panel)
{
	/* The ISR compares level against a phase counter of 0..MAX-1; a level
	 * above MAX would simply be on permanently, silently saturating. */
	uint8_t pct[APP_BARS_MAX];
	uint8_t frame[APP_MATRIX_LEDS];

	for (int i = 0; i < APP_BARS_MAX; i++) {
		pct[i] = (uint8_t)(i * 17);
	}
	for (int n = 1; n <= APP_BARS_MAX; n++) {
		app_bars_render(pct, n, false, frame);
		for (int i = 0; i < APP_MATRIX_LEDS; i++) {
			zassert_true(frame[i] <= APP_MATRIX_MAX_LEVEL,
				     "level %d at %d exceeds the panel's %d", frame[i], i,
				     APP_MATRIX_MAX_LEVEL);
		}
	}
}

ZTEST(bars, test_out_of_range_percentages_are_clamped)
{
	const uint8_t over[] = {200};
	const uint8_t full[] = {APP_BARS_PCT_MAX};
	uint8_t a[APP_MATRIX_LEDS], b[APP_MATRIX_LEDS];

	app_bars_render(over, 1, false, a);
	app_bars_render(full, 1, false, b);
	zassert_mem_equal(a, b, sizeof(a), "above 100%% must render as 100%%, not wrap");
}

ZTEST(bars, test_impossible_bar_count_renders_an_empty_frame)
{
	const uint8_t pct[] = {100, 100};
	uint8_t frame[APP_MATRIX_LEDS];

	memset(frame, APP_MATRIX_MAX_LEVEL, sizeof(frame));
	app_bars_render(pct, APP_BARS_MAX + 1, false, frame);
	zassert_equal(lit_pixels(frame), 0, "a frame it cannot draw must be blank, not stale");
}

/* --- orientation --------------------------------------------------------- */

ZTEST(bars, test_rotation_is_a_true_180_degrees)
{
	const uint8_t pct[] = {100, 40, 0, 75};
	uint8_t plain[APP_MATRIX_LEDS], rotated[APP_MATRIX_LEDS];

	app_bars_render(pct, 4, false, plain);
	app_bars_render(pct, 4, true, rotated);

	for (int i = 0; i < APP_MATRIX_LEDS; i++) {
		zassert_equal(rotated[i], plain[APP_MATRIX_LEDS - 1 - i],
			      "pixel %d is not its own opposite", i);
	}
}

ZTEST(bars, test_rotation_preserves_what_is_lit)
{
	const uint8_t pct[] = {100, 40, 0, 75};
	uint8_t plain[APP_MATRIX_LEDS], rotated[APP_MATRIX_LEDS];

	app_bars_render(pct, 4, false, plain);
	app_bars_render(pct, 4, true, rotated);

	zassert_equal(lit_pixels(plain), lit_pixels(rotated),
		      "turning the board around must not change the reading");
}

ZTEST(bars, test_rotated_bars_grow_from_the_other_edge)
{
	const uint8_t pct[] = {50};
	uint8_t frame[APP_MATRIX_LEDS];
	struct app_bars_layout l;
	int col;

	app_bars_render(pct, 1, true, frame);
	zassert_true(app_bars_layout(1, &l), "layout");
	/* One bar spans the panel, so the column mirrors onto itself. */
	col = app_bars_column(&l, 0);

	for (int row = 0; row < APP_MATRIX_ROWS / 2; row++) {
		zassert_equal(AT(frame, row, col), APP_MATRIX_MAX_LEVEL,
			      "rotated, row %d should be inside the bar", row);
	}
	for (int row = APP_MATRIX_ROWS / 2; row < APP_MATRIX_ROWS; row++) {
		zassert_equal(AT(frame, row, col), 0, "rotated, row %d should be outside", row);
	}
}

ZTEST_SUITE(bars, NULL, NULL, NULL, NULL, NULL);
