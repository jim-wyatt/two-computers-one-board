/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * The two RGB LEDs wired to the STM32 rather than to Linux.
 *
 * The board has four. Linux drives LED 1 and LED 2 through /sys/class/leds and
 * shows connectivity and unit health there; LED 3 and LED 4 are on this side,
 * named led3_red/green/blue and led4_* in Zephyr's board definition.
 *
 * WHAT THEY SHOW, AND WHY NOT THE OBVIOUS THINGS
 * ----------------------------------------------
 * The first attempt used them for link traffic and eMMC activity. Both were
 * wrong, and the board made it obvious:
 *
 *   Blinking on every command received made LED 3 a CLOCK. cpubars sends a
 *   frame every 0.5s, so the LED blinked every 0.5s, forever, saying only
 *   "the demo is running" - which the matrix already says, in more detail.
 *   An indicator whose period is set by someone else's timer carries no
 *   information.
 *
 *   eMMC activity cannot be shown from here at any useful resolution. Linux
 *   samples the counter twice a second and pushes the answer down a 115200
 *   link; a real activity light flickers on individual transfers. What you got
 *   was a lamp that sat on through a copy and off otherwise - which the CPU
 *   bars beside it already imply.
 *
 * So both now show things ONLY THIS CHIP KNOWS, and that change slowly enough
 * that every transition means something:
 *
 *   LED 3   the firmware's own identity.
 *           steady green        running a CONFIRMED image - this is what stays
 *                               after a reset
 *           slow blink, yellow  running an UNCONFIRMED image, on MCUboot
 *                               probation. The next reset reverts it.
 *                               Invisible otherwise unless you go and read the
 *                               slot table, and precisely what you want to see
 *                               on the hardware after an update.
 *           fast blink, red     a subsystem failed to start (see main.c)
 *
 *   LED 4   whether the MPU is still talking.
 *           steady green        heard from Linux within the last few seconds
 *           fast blink, red     silent for longer than that
 *
 * LED 4 is the inverse of the blink it replaces. A tick tells you nothing; the
 * tick STOPPING is the news, and it is news Linux cannot deliver - a host that
 * has stopped talking cannot report that it stopped talking. This is the only
 * indicator on the board that says something about the other chip's health.
 *
 * RHYTHM AS WELL AS COLOUR
 * ------------------------
 * Colour alone was the first design, and it was mostly red against green - the
 * one pair that about one man in twelve cannot tell apart. To them LED 4 had a
 * single state. So every state has a rhythm too, the same three that
 * status/leds.sh uses for LED 1 and LED 2, and the rhythm alone identifies it:
 *
 *   steady       fine
 *   slow blink   in progress or on probation - once every two seconds
 *   fast blink   a fault - twice a second
 *
 * Which state gets which is decided by the three small functions at the bottom
 * of this file. They touch no hardware, so mcu/tests/status_leds/ runs them on
 * the host - the part of an indicator that can be wrong without anything
 * looking broken is the mapping, not the GPIO.
 */

#ifndef STATUS_LEDS_H
#define STATUS_LEDS_H

#include <stdbool.h>
#include <stdint.h>

/* How long the MPU may be quiet before LED 4 calls the link stale.
 *
 * cpubars draws twice a second, and the MCU shell is also poked by hand, so a
 * few seconds of silence is comfortably abnormal without being twitchy about a
 * host that paused to do something else.
 */
#define STATUS_LINK_STALE_MS 4000

/* One beat of the blink. Everything the LEDs do is counted in these: a fast
 * blink is one beat lit and one dark, a slow blink four and four, and the
 * once-a-second look at the link and the image is every fourth.
 *
 * 250 ms, so the fast blink is twice a second and the slow one once every two:
 * four to one, which is unmistakable at a glance. It was 125 ms at first, a
 * fast blink of four a second - and that is above the three flashes a second
 * that accessibility guidance sets as the ceiling for anything that flashes.
 * A change made so that more people can read these lights should not be the
 * one thing on the board some people cannot look at.
 */
#define STATUS_TICK_MS         250
#define STATUS_TICKS_PER_CHECK (1000 / STATUS_TICK_MS)
#define STATUS_SLOW_TICKS      4 /* lit for this many, then dark for as many */
#define STATUS_FAST_TICKS      1

enum status_colour {
	STATUS_OFF,
	STATUS_GREEN,
	STATUS_YELLOW,
	STATUS_RED,
};

enum status_rhythm {
	STATUS_STEADY,
	STATUS_SLOW,
	STATUS_FAST,
};

struct status_look {
	enum status_colour colour;
	enum status_rhythm rhythm;
};

/** Claim the GPIOs. Safe on a board without them: everything below then does
 *  nothing, and status_leds_present() says so.
 */
void status_leds_init(void);

/** Note that something arrived from the MPU. Cheap - a timestamp, no I/O. */
void status_leds_link_seen(void);

/** LED 3: steady green for a confirmed image, a slow yellow blink for one still
 *  on probation.
 */
void status_leds_set_image_confirmed(bool confirmed);

/** LED 3: a fast red blink, and it stays that way. For a subsystem that failed
 *  to come up.
 */
void status_leds_set_fault(void);

/** True if the GPIOs were found and claimed. */
bool status_leds_present(void);

/* --- what to show: no hardware below this line --------------------------- */

/** LED 3. A fault outranks everything: a board that failed to start a
 *  subsystem is broken whichever image it is running.
 */
static inline struct status_look status_led3_look(bool faulted, bool confirmed)
{
	if (faulted) {
		return (struct status_look){STATUS_RED, STATUS_FAST};
	}
	if (!confirmed) {
		return (struct status_look){STATUS_YELLOW, STATUS_SLOW};
	}
	return (struct status_look){STATUS_GREEN, STATUS_STEADY};
}

/** LED 4. Two states, so two rhythms and no slow blink: silence is not a
 *  degraded link, it is no link.
 */
static inline struct status_look status_led4_look(bool fresh)
{
	if (fresh) {
		return (struct status_look){STATUS_GREEN, STATUS_STEADY};
	}
	return (struct status_look){STATUS_RED, STATUS_FAST};
}

/** Is an LED with this rhythm lit on this beat?
 *
 * One answer per LED per beat, and every channel of the LED is driven from it.
 * That is the whole of how yellow's red and green stay in step: they are never
 * asked separately. Both periods divide 2^32, so the counter wrapping after
 * seventeen years does not cut a blink short either.
 */
static inline bool status_rhythm_lit(enum status_rhythm rhythm, uint32_t tick)
{
	switch (rhythm) {
	case STATUS_SLOW:
		return (tick % (2 * STATUS_SLOW_TICKS)) < STATUS_SLOW_TICKS;
	case STATUS_FAST:
		return (tick % (2 * STATUS_FAST_TICKS)) < STATUS_FAST_TICKS;
	default:
		return true;
	}
}

#endif /* STATUS_LEDS_H */
