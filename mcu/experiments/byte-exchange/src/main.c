/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * One byte each way, between the two computers on an UNO Q, with no RPC.
 *
 *   Linux  ---- 0x23 ---->  this
 *   Linux  <--- 0x45 -----  this          Linux asked, the MCU answered
 *
 *   this   ---- 0x23 ---->  Linux
 *   this   <--- 0x45 -----  Linux         the MCU asked, Linux answered
 *
 * WHAT THIS IS UNDERNEATH
 * -----------------------
 * Arduino's "Router Bridge" is a program on the Linux side holding a serial
 * port, with the microcontroller on the other end of the wire. It speaks RPC
 * and nothing else: write a plain byte down that wire while it is running and
 * it logs `invalid packet, expected array, got: int8` and throws the byte away.
 * So a conversation "without the RPC functions" cannot go through the bridge.
 * It goes underneath it, on the wire itself, which is all this file uses:
 *
 *   MCU    lpuart1 (PG7/PG8), 115200 8N1
 *   Linux  /dev/ttyHS1, the same wire, with the router not running
 *
 * WHY THERE IS NO printk IN HERE
 * ------------------------------
 * The wire carries the experiment, so nothing else may write to it. The LEDs
 * are the only other way this program has of saying anything:
 *
 *   LED 4 green   toggles each time 0x23 arrives and 0x45 is sent back
 *   LED 3 green   toggles each time this side's own 0x23 was answered by 0x45
 *   LED 3 red     on while this side is waiting for an answer that has not come
 *
 * BOTH SIDES MAY ASK AT ONCE
 * --------------------------
 * Each end sends 0x23 when it feels like it, so the two can cross: this side
 * is waiting for 0x45 and a 0x23 arrives instead. That is not an error. It is
 * the other side's question, it gets its 0x45, and the wait for our own answer
 * carries on. A protocol where both ends may speak first has to say what
 * happens when they do; this is the smallest one that does.
 */
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/kernel.h>

#define ASK    0x23
#define ANSWER 0x45

/* How often this side starts the conversation, and how long it waits. */
#define ASK_EVERY_MS     2000
#define ANSWER_WITHIN_MS 500

static const struct device *const link = DEVICE_DT_GET(DT_NODELABEL(lpuart1));

#define LED(node) GPIO_DT_SPEC_GET_OR(DT_NODELABEL(node), gpios, {0})
static const struct gpio_dt_spec heard = LED(led4_green);
static const struct gpio_dt_spec answered = LED(led3_green);
static const struct gpio_dt_spec waiting = LED(led3_red);

static void led_init(const struct gpio_dt_spec *led)
{
	if (led->port != NULL && gpio_is_ready_dt(led)) {
		gpio_pin_configure_dt(led, GPIO_OUTPUT_INACTIVE);
	}
}

static void led_toggle(const struct gpio_dt_spec *led)
{
	if (led->port != NULL) {
		gpio_pin_toggle_dt(led);
	}
}

static void led_set(const struct gpio_dt_spec *led, int on)
{
	if (led->port != NULL) {
		gpio_pin_set_dt(led, on);
	}
}

int main(void)
{
	int64_t next_ask = k_uptime_get() + ASK_EVERY_MS;
	int64_t answer_due = 0; /* 0: not waiting for one */
	uint8_t byte;

	if (!device_is_ready(link)) {
		return 0;
	}
	led_init(&heard);
	led_init(&answered);
	led_init(&waiting);

	while (true) {
		/* Everything that has arrived, one byte at a time. */
		while (uart_poll_in(link, &byte) == 0) {
			if (byte == ASK) {
				uart_poll_out(link, ANSWER);
				led_toggle(&heard);
			} else if (byte == ANSWER && answer_due != 0) {
				answer_due = 0;
				led_set(&waiting, 0);
				led_toggle(&answered);
			}
			/* Anything else is not part of this conversation. */
		}

		int64_t now = k_uptime_get();

		if (answer_due != 0 && now >= answer_due) {
			/* Nobody answered. Leave the red LED on and ask again later. */
			answer_due = 0;
		}
		if (answer_due == 0 && now >= next_ask) {
			uart_poll_out(link, ASK);
			answer_due = now + ANSWER_WITHIN_MS;
			next_ask = now + ASK_EVERY_MS;
			led_set(&waiting, 1);
		}

		k_msleep(1);
	}
	return 0;
}
