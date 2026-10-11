/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * LED 3 and LED 4 - the two RGB LEDs on the MCU side. See status_leds.h.
 */

#include "status_leds.h"

#include <zephyr/dfu/mcuboot.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/kernel.h>

/* Node labels rather than the led0/led1 aliases: the aliases cover only two of
 * the six channels (led3_green and led3_red), and color is the whole point.
 */
#define LED_SPEC(node) GPIO_DT_SPEC_GET_OR(DT_NODELABEL(node), gpios, {0})

static const struct gpio_dt_spec led3[] = {
	LED_SPEC(led3_red),
	LED_SPEC(led3_green),
	LED_SPEC(led3_blue),
};
static const struct gpio_dt_spec led4[] = {
	LED_SPEC(led4_red),
	LED_SPEC(led4_green),
	LED_SPEC(led4_blue),
};

enum {
	CH_RED = 0,
	CH_GREEN = 1,
	CH_BLUE = 2
};

static bool ready;
static bool faulted;
static bool confirmed_seen;
static int64_t last_seen_ms;

/* What each LED is showing, and the beat it is shown on. Dark until told
 * otherwise - STATUS_OFF is zero.
 */
static struct status_look look3;
static struct status_look look4;
static uint32_t tick;

static void on_tick(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(tick_work, on_tick);

static void set_chan(const struct gpio_dt_spec *spec, int on)
{
	if (spec->port == NULL) {
		return;
	}
	(void)gpio_pin_set_dt(spec, on);
}

static void set_rgb(const struct gpio_dt_spec *led, int r, int g, int b)
{
	set_chan(&led[CH_RED], r);
	set_chan(&led[CH_GREEN], g);
	set_chan(&led[CH_BLUE], b);
}

/* The one place a look becomes pins. `lit` is worked out once and gates every
 * channel, so a two-channel color cannot blink out of step with itself.
 */
static void show(const struct gpio_dt_spec *led, struct status_look look)
{
	bool lit = status_rhythm_lit(look.rhythm, tick);
	bool red = look.color == STATUS_RED || look.color == STATUS_YELLOW;
	bool green = look.color == STATUS_GREEN || look.color == STATUS_YELLOW;

	set_rgb(led, lit && red, lit && green, 0);
}

static bool claim(const struct gpio_dt_spec *led, size_t n)
{
	bool any = false;

	for (size_t i = 0; i < n; i++) {
		if (led[i].port == NULL || !gpio_is_ready_dt(&led[i])) {
			continue;
		}
		if (gpio_pin_configure_dt(&led[i], GPIO_OUTPUT_INACTIVE) != 0) {
			continue;
		}
		any = true;
	}
	return any;
}

/* Runs four times a second forever, and does two jobs on one work item.
 *
 * Every beat it redraws both LEDs, which is all a blink is. No second timer
 * and no thread: the rhythm is a counter, and the counter was already here.
 *
 * Every fourth beat - once a second, as before there was any blinking - it
 * looks at the link. Deliberately a poll rather than a timeout armed on each
 * message: the interesting event here is the ABSENCE of traffic, and you
 * cannot receive an interrupt for something not happening.
 */
static void on_tick(struct k_work *work)
{
	ARG_UNUSED(work);

	tick++;
	if (ready && (tick % STATUS_TICKS_PER_CHECK) == 0) {
		bool fresh = (k_uptime_get() - last_seen_ms) < STATUS_LINK_STALE_MS;

		look4 = status_led4_look(fresh);

		/* Re-read the image state rather than trusting the value taken
		 * at boot.
		 *
		 * Confirming happens over SMP, minutes or hours after main()
		 * ran, and the first version of this called
		 * boot_is_img_confirmed() exactly once at startup. LED 3 then
		 * sat on yellow through a successful confirm - showing a state
		 * that had been true and was not any more, which is the same
		 * "confidently wrong" failure the Linux side of this project is
		 * built to avoid, reintroduced in C.
		 *
		 * Only while unconfirmed: this reads the image trailer out of
		 * flash, and once confirmed it cannot become unconfirmed again
		 * without another upload, which means another boot. So the poll
		 * costs nothing on a settled board.
		 */
		if (!confirmed_seen && !faulted && boot_is_img_confirmed()) {
			confirmed_seen = true;
			look3 = status_led3_look(false, true);
		}
	}
	if (ready) {
		show(led3, look3);
		show(led4, look4);
	}
	(void)k_work_reschedule(&tick_work, K_MSEC(STATUS_TICK_MS));
}

void status_leds_init(void)
{
	bool a = claim(led3, ARRAY_SIZE(led3));
	bool b = claim(led4, ARRAY_SIZE(led4));

	ready = a || b;
	if (!ready) {
		return;
	}
	show(led3, look3);
	/* The fault look until the MPU says something. A board nobody has talked
	 * to yet is genuinely in the "link not proven" state, and starting green
	 * would be an optimistic lie for the first four seconds. */
	look4 = status_led4_look(false);
	show(led4, look4);
	last_seen_ms = 0;
	(void)k_work_reschedule(&tick_work, K_MSEC(STATUS_TICK_MS));
}

bool status_leds_present(void)
{
	return ready;
}

void status_leds_link_seen(void)
{
	last_seen_ms = k_uptime_get();
}

void status_leds_set_image_confirmed(bool confirmed)
{
	if (!ready || faulted) {
		return;
	}
	confirmed_seen = confirmed;
	/* Yellow is red+green together. The only place in this project where two
	 * channels are lit at once, and it earns it: "on probation" is neither
	 * healthy nor broken, and it gets a color and a rhythm of its own to
	 * say so. Shown now rather than on the next beat, as the fault below is.
	 */
	look3 = status_led3_look(false, confirmed);
	show(led3, look3);
}

void status_leds_set_fault(void)
{
	if (!ready) {
		return;
	}
	faulted = true;
	look3 = status_led3_look(true, confirmed_seen);
	show(led3, look3);
}
