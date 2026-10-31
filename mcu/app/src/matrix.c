/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * Charlieplex driver for the UNO Q's 8x13 LED panel.
 *
 * The 104 LEDs hang off eleven pins, PF0..PF10, as ordered pairs: LED n is lit
 * by driving one pin high, one low, and leaving the other nine floating. Only
 * one LED is ever on; the illusion of a picture is entirely persistence of
 * vision, which is why the refresh runs from a timer ISR and not a thread.
 *
 * WHY REGISTER ACCESS, NOT THE GPIO API
 * -------------------------------------
 * Charlieplexing needs pins to change *direction*, not just level, once every
 * 10us. gpio_pin_configure_dt() is the API for that and it is far too heavy to
 * call 100k times a second - it re-resolves the port, takes a lock and walks
 * the pinctrl tables. Writing MODER and BSRR directly is a two-instruction
 * version of the same thing. The port is still claimed through the devicetree
 * (see matrix_init) so that Zephyr enables its clock and nothing else in the
 * build believes PF0..PF10 are free.
 *
 * The pin pairing and the 10us slot come from Arduino's own implementation for
 * this panel (ArduinoCore-zephyr, loader/matrix.inc) - it is the only
 * description of how this hardware is wired that exists. The grayscale is not
 * theirs: see the phase comment below.
 */
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/counter.h>
#include <soc.h>
#include <string.h>

#include "app_proto.h"
#include "matrix.h"

/* PF0..PF10. Eleven pins give 11*10 = 110 ordered pairs, of which the panel
 * uses the first 104. */
#define MATRIX_PINS 11

/* MODER holds two bits per pin, so our eleven pins occupy the low 22. Masking
 * exactly those leaves PF11..PF15 - which reach the Arduino header - untouched.
 */
#define MATRIX_MODER_MASK ((uint32_t)((1ULL << (2 * MATRIX_PINS)) - 1))

/* One LED per slot: 104 slots is a 1.04ms sweep, and a grayscale cycle is
 * APP_MATRIX_MAX_LEVEL sweeps, so the panel refreshes at ~137Hz. */
#define MATRIX_SLOT_US 10

#define MATRIX_TIMER DT_NODELABEL(counter_matrix)
#define MATRIX_PORT  DT_NODELABEL(gpiof)

static const struct device *const timer = DEVICE_DT_GET(MATRIX_TIMER);
static const struct device *const port = DEVICE_DT_GET(MATRIX_PORT);

static uint8_t anode[APP_MATRIX_LEDS];   /* pin driven high for LED n */
static uint8_t cathode[APP_MATRIX_LEDS]; /* pin driven low for LED n */

static uint8_t framebuffer[APP_MATRIX_LEDS];
static bool ready;   /* matrix_init() succeeded; the devices are usable */
static bool running; /* the refresh timer is going */
static uint32_t sweeps;

/* Enumerate the charlieplex pairs in panel order: for each new pin, pair it
 * with every lower-numbered one, both ways round. Generating the table beats
 * transcribing 104 literals - there is no typo to make. */
static void build_pin_table(void)
{
	int idx = 0;

	for (int hi = 1; hi < MATRIX_PINS; hi++) {
		for (int lo = 0; lo < hi; lo++) {
			if (idx < APP_MATRIX_LEDS) {
				anode[idx] = (uint8_t)lo;
				cathode[idx] = (uint8_t)hi;
				idx++;
			}
			if (idx < APP_MATRIX_LEDS) {
				anode[idx] = (uint8_t)hi;
				cathode[idx] = (uint8_t)lo;
				idx++;
			}
		}
	}
}

static inline void all_pins_floating(void)
{
	GPIOF->MODER &= ~MATRIX_MODER_MASK;
}

/*
 * One slot. Every LED gets a slot in every sweep; a level-L LED is actually
 * driven in L of the APP_MATRIX_MAX_LEVEL sweeps that make up a grayscale
 * cycle, so brightness is L/7 duty at a flicker-free rate. Comparing against a
 * per-sweep phase rather than a free-running counter keeps the LEDs of one
 * level in step, which is what stops a dim frame from shimmering.
 */
static void matrix_tick(const struct device *dev, void *user_data)
{
	static uint16_t idx;
	static uint8_t phase;
	uint8_t level;

	ARG_UNUSED(dev);
	ARG_UNUSED(user_data);

	/* Unconditionally first: the previous LED has to stop conducting
	 * before the next pair is driven, or its neighbors ghost. */
	all_pins_floating();

	level = framebuffer[idx];
	if (level > phase) {
		uint32_t a = anode[idx];
		uint32_t c = cathode[idx];

		/* Levels before directions - BSRR on a floating pin is
		 * harmless, but driving before the level is set would emit a
		 * glimpse of whatever ODR held. */
		GPIOF->BSRR = BIT(a) | BIT(c + 16);
		GPIOF->MODER |= BIT(a * 2) | BIT(c * 2);
	}

	if (++idx == APP_MATRIX_LEDS) {
		idx = 0;
		sweeps++;
		phase = (phase + 1) % APP_MATRIX_MAX_LEVEL;
	}
}

static int matrix_start(void)
{
	struct counter_top_cfg top_cfg = {
		.ticks = counter_us_to_ticks(timer, MATRIX_SLOT_US),
		.callback = matrix_tick,
		.user_data = NULL,
		.flags = 0,
	};
	int err;

	if (top_cfg.ticks == 0 || top_cfg.ticks > counter_get_max_top_value(timer)) {
		return -ERANGE;
	}

	err = counter_start(timer);
	if (err != 0) {
		return err;
	}

	err = counter_set_top_value(timer, &top_cfg);
	if (err != 0) {
		counter_stop(timer);
		return err;
	}

	running = true;
	return 0;
}

int matrix_init(void)
{
	if (!device_is_ready(port) || !device_is_ready(timer)) {
		return -ENODEV;
	}

	build_pin_table();
	all_pins_floating();
	ready = true;
	return 0;
}

void matrix_draw(const uint8_t *levels)
{
	unsigned int key;

	/* Without the devicetree nodes there is no port to write and no timer
	 * to pace it; going further would call counter_*() on a device that
	 * never initialized. */
	if (!ready) {
		return;
	}

	key = irq_lock();
	memcpy(framebuffer, levels, sizeof(framebuffer));
	irq_unlock(key);

	if (!running) {
		/* Nothing to report to: a panel that will not start shows
		 * nothing, which is already the visible symptom. */
		(void)matrix_start();
	}
}

void matrix_off(void)
{
	if (!ready) {
		return;
	}
	if (running) {
		counter_stop(timer);
		running = false;
	}
	all_pins_floating();
	memset(framebuffer, 0, sizeof(framebuffer));
}

uint32_t matrix_sweeps(void)
{
	return sweeps;
}

bool matrix_running(void)
{
	return running;
}
