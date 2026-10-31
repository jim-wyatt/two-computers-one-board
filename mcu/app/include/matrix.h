/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * The 8x13 LED panel.
 *
 * Everything hardware about the matrix is behind these five calls, so the
 * interesting half of the feature (bars.h) stays testable on the host.
 */
#ifndef MATRIX_H
#define MATRIX_H

#include <stdbool.h>
#include <stdint.h>

/* Claim the GPIO port and the refresh timer. Does not light anything and does
 * not start the ISR - the first matrix_draw() does that. Returns 0, or a
 * negative errno if the devicetree does not give us what we need. */
int matrix_init(void);

/* Show a frame: APP_MATRIX_LEDS bytes, one brightness level (0..
 * APP_MATRIX_MAX_LEVEL) per LED, row-major. The buffer is copied. */
void matrix_draw(const uint8_t *levels);

/* Stop refreshing and release the pins. matrix_draw() restarts it. */
void matrix_off(void);

/*
 * Completed refresh sweeps since boot - one per pass over all 104 LEDs.
 *
 * This is the only way to tell from the far end of a serial cable that the
 * panel is really being refreshed: nothing else about a charlieplexed display
 * is observable without looking at it. A stalled count means the timer never
 * started; a count climbing at ~962/s means the ISR is running to schedule.
 */
uint32_t matrix_sweeps(void);

/*
 * Is the refresh timer meant to be running? True from the first matrix_draw()
 * that starts it until matrix_off(). While it is, matrix_sweeps() should be
 * climbing, and the watchdog (guard.h) is fed only if it is.
 */
bool matrix_running(void);

#endif /* MATRIX_H */
