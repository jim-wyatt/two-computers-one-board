/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * Turning percentages into pixels.
 *
 * Deliberately free of Zephyr and of hardware: this is arithmetic, so it is
 * compiled straight into mcu/tests/bars/ and runs on the host. The half of the
 * feature that cannot be tested that way - charlieplexing PF0..PF10 from a
 * timer ISR - lives in matrix.h and stays as thin as possible.
 */
#ifndef BARS_H
#define BARS_H

#include <stdbool.h>
#include <stdint.h>

#include "app_proto.h"

/* Where n bars sit on the 13-column panel.
 *
 * Bars are uniform width with a one-column gap, and the whole group is
 * centered: leftovers show up as margin, never as one fatter bar.
 */
struct app_bars_layout {
	int width; /* columns per bar, >= 1 */
	int left;  /* blank columns before the first bar */
};

/* Compute the layout for n bars. Returns false (and leaves *out alone) if n is
 * outside 1..APP_BARS_MAX. */
bool app_bars_layout(int n, struct app_bars_layout *out);

/* Which column the i-th bar starts at, given a layout. */
static inline int app_bars_column(const struct app_bars_layout *l, int i)
{
	return l->left + i * (l->width + 1);
}

/*
 * Render n percentages as vertical bars into a APP_MATRIX_LEDS grayscale
 * framebuffer (one byte per LED, 0..APP_MATRIX_MAX_LEVEL), clearing it first.
 *
 * Height uses the grayscale as a vernier: a bar is whole rows at full
 * brightness plus one partial row dimmed in proportion to the remainder. Eight
 * rows would otherwise quantize the reading to 12.5% steps, which for a CPU
 * meter is the difference between "idle" and "a core is busy".
 *
 * rotate180 mirrors the panel for a board viewed from the other side. It is a
 * true 180-degree rotation, so bars grow the other way *and* run right-to-left,
 * which is what you want if you turned the board around rather than the image.
 *
 * pct values outside 0..APP_BARS_PCT_MAX are clamped, and n outside
 * 1..APP_BARS_MAX renders an empty frame - a display that shows nothing is a
 * better failure than one that shows a wrong number confidently.
 */
void app_bars_render(const uint8_t *pct, int n, bool rotate180, uint8_t *frame);

#endif /* BARS_H */
