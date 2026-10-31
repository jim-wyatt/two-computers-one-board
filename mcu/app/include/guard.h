/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * The MCU's own watchdog, and why the MCU last reset.
 *
 * LED 4 is the MCU watching Linux: it turns red when the MPU stops talking.
 * This is the other direction - something that resets the MCU when the MCU
 * itself stops working - and the record afterwards of why it reset, which is
 * what lets Linux tell a watchdog reset from a power cut or a firmware update.
 *
 * WHAT IS WATCHED
 * ---------------
 * The STM32's independent watchdog (IWDG) resets the chip unless it is fed
 * at least once every GUARD_TIMEOUT_MS. It runs from its own 32 kHz LSI
 * oscillator, so a stuck CPU clock does not stop it, and once started nothing
 * but a reset stops it.
 *
 * It is fed from one place: the status-LED beat, four times a second on the
 * system workqueue (status_leds.c). And only when the LED panel's refresh has
 * moved on since the previous beat, or the panel is off on purpose. So the
 * feed stops, and the chip resets eight seconds later, if:
 *
 *   - the system workqueue is stuck: a work item that never returns, or a
 *     thread that holds the scheduler locked (that is `app hang yes`)
 *   - the panel's timer interrupt has stopped while the panel is meant to be
 *     on: interrupts locked out, or the timer stopped behind matrix.c's back
 *
 * What it does not watch is the shell thread on its own. A shell command that
 * spins in a preemptible thread does not starve the workqueue, which is
 * cooperative and runs ahead of it, so the dog is still fed. LED 4 going red
 * is how that one shows: the MCU stops answering, and the MPU stops being
 * answered.
 *
 * The decision of whether to feed, and the names `app reset` prints, are the
 * two inline functions at the bottom. They touch no hardware, so
 * mcu/tests/guard/ runs them on the host.
 */
#ifndef GUARD_H
#define GUARD_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include <zephyr/drivers/hwinfo.h>

/* THE TIMEOUT: 8 SECONDS
 * ----------------------
 * Long enough for the longest stall this firmware does on purpose, and short
 * enough that a hung MCU is back before anyone has finished wondering why the
 * panel froze.
 *
 * The longest legitimate stalls are flash operations, and every one is
 * milliseconds. The flash is 8 KiB sectors, and erasing one takes a few
 * milliseconds on this part. A FOTA upload erases slot 1 a sector at a time as
 * the image arrives (CONFIG_IMG_ERASE_PROGRESSIVELY), on the SMP thread, so
 * the workqueue still runs between sectors. Erasing the whole 416 KiB slot at
 * once is 52 sectors, a fraction of a second. A settings write (`app matrix
 * flip`) may make NVS erase one sector of its own. The 115200 link is the
 * slowest thing on the board, and the longest reply, a 32-sample temperature
 * batch, is about a tenth of a second. Eight seconds is more than ten times
 * the worst of these together.
 *
 * And it is in range. The IWDG counts LSI ticks (32 kHz) through a prescaler
 * of 4 to 1024 into a 12-bit reload, so it reaches from 125 us to about 131 s.
 * Zephyr's driver turns 8000 ms into prescaler 64 and reload 3999: 2 ms a
 * count. The LSI is an RC oscillator, good to a few percent, so the real
 * timeout is about 8 s, not exactly 8 s, which is why nothing here is cut
 * close to it.
 *
 * Compare Linux's own watchdog (provision/80-watchdog.sh): 30 s, because a
 * swapping Linux can legitimately stall for seconds. The MCU has no swap and
 * no disk, and a stall of eight seconds there is a bug.
 */
#define GUARD_TIMEOUT_MS 8000

/* The longest reset line guard_reset_names() can produce, with its NUL: every
 * name in the table plus "unknown", comma-separated. mcu/tests/guard/ checks
 * that every bit set at once still fits. */
#define GUARD_RESET_NAMES_MAX 160

/** Read why the MCU last reset, keep it for `app reset`, clear it, and arm the
 *  watchdog. Called once, at the top of main().
 *
 *  Returns 0 with the watchdog armed, or a negative errno if it is not: no
 *  device, or the driver refused the timeout. Everything else still runs
 *  either way - a board without its watchdog is no worse off than before this
 *  existed - and main() says which on the console.
 */
int guard_init(void);

/** Called on every status-LED beat. Feeds the watchdog if the panel's refresh
 *  has moved on since the last beat, or the panel is off. */
void guard_tick(void);

/** The hwinfo reset-cause bits read at boot, or 0 if they could not be read. */
uint32_t guard_reset_cause(void);

/** True if guard_init() read the reset cause; false if hwinfo could not. */
bool guard_reset_cause_known(void);

/* --- no hardware below this line ----------------------------------------- */

/** Feed on this beat?
 *
 * `panel_on` is whether the panel's refresh timer is meant to be running.
 * When it is not - before the first frame, or after `app matrix off` - the
 * sweep count stands still on purpose and says nothing, so the beat itself is
 * the evidence: it ran, so the workqueue is alive.
 *
 * When it is, the count must have moved since the previous beat. A beat is
 * 250 ms and a sweep 1.04 ms, so a healthy panel is about 240 sweeps further
 * on each time. Compared with != rather than >, so the 32-bit count wrapping
 * after 51 days is just another change.
 *
 * One beat can miss its feed when the panel has only just been switched on
 * and has not finished a sweep yet. The next beat feeds, and one missed beat
 * in thirty-two is nowhere near the timeout.
 */
static inline bool guard_should_feed(bool panel_on, uint32_t sweeps, uint32_t last_sweeps)
{
	return !panel_on || sweeps != last_sweeps;
}

/** One reset-cause bit and the word `app reset` prints for it. */
struct guard_reset_name {
	uint32_t bit;
	const char *name;
};

/* In the order they are printed: the cause that explains the reset first,
 * and "pin" last.
 *
 * Last because on the STM32 nearly every reset is also a pin reset. The chip
 * drives its own NRST pin low whatever started the reset, so RCC records the
 * pin as well: a watchdog reset reads "watchdog,pin" and a software reset
 * "software,pin". Only "pin" alone means the reset line really was pulled
 * from outside - on this board, Linux toggling it, or the debugger.
 *
 * And "power_on" is not what a power-on prints here. The STM32U5 has no
 * power-on flag of its own; its brownout flag is set when the supply comes
 * up, so applying power reads "brownout,pin". The name stays in the table for
 * the parts that do have one.
 *
 * Names are lowercase words joined by underscores: no spaces, no '=', no ','.
 * python/tests/test_contract.py reads this table, and unoq.mcu.RESET_CAUSES
 * must list the same names.
 */
static const struct guard_reset_name guard_reset_table[] = {
	{RESET_WATCHDOG, "watchdog"},
	{RESET_CPU_LOCKUP, "lockup"},
	{RESET_SOFTWARE, "software"},
	{RESET_SECURITY, "security"},
	{RESET_BROWNOUT, "brownout"},
	{RESET_POR, "power_on"},
	{RESET_LOW_POWER_WAKE, "low_power_wake"},
	{RESET_DEBUG, "debug"},
	{RESET_PARITY, "parity"},
	{RESET_PLL, "pll"},
	{RESET_CLOCK, "clock"},
	{RESET_HARDWARE, "hardware"},
	{RESET_USER, "user"},
	{RESET_TEMPERATURE, "temperature"},
	{RESET_BOOTLOADER, "bootloader"},
	{RESET_FLASH, "flash"},
	{RESET_PIN, "pin"},
};

/* No bits set. Distinct from "unknown", which is a bit this table has no
 * name for. */
#define GUARD_RESET_NONE    "none"
#define GUARD_RESET_UNKNOWN "unknown"

/** Append `name` to the list in `buf`, which holds `n` characters, if it fits
 *  whole with its comma and the NUL. Returns the new length. */
static inline size_t guard_append_name(char *buf, size_t len, size_t n, const char *name)
{
	size_t w = strlen(name);
	size_t sep = n > 0 ? 1 : 0;

	if (n + sep + w + 1 > len) {
		return n;
	}
	if (sep) {
		buf[n++] = ',';
	}
	memcpy(&buf[n], name, w + 1);
	return n + w;
}

/** Write the names of the bits set in `cause` into `buf`, comma-separated, in
 *  table order: "watchdog,pin". GUARD_RESET_NONE if no bit is set, and
 *  GUARD_RESET_UNKNOWN once, last, for any bits the table has no name for.
 *
 *  Always NUL-terminates a buffer of at least one byte; a name that does not
 *  fit is left out whole rather than cut. GUARD_RESET_NAMES_MAX always fits.
 *  Returns the length written.
 */
static inline size_t guard_reset_names(uint32_t cause, char *buf, size_t len)
{
	size_t n = 0;
	uint32_t named = 0;

	if (len == 0) {
		return 0;
	}
	buf[0] = '\0';

	for (size_t i = 0; i < sizeof(guard_reset_table) / sizeof(guard_reset_table[0]); i++) {
		named |= guard_reset_table[i].bit;
		if ((cause & guard_reset_table[i].bit) != 0) {
			n = guard_append_name(buf, len, n, guard_reset_table[i].name);
		}
	}
	if ((cause & ~named) != 0) {
		n = guard_append_name(buf, len, n, GUARD_RESET_UNKNOWN);
	}
	if (cause == 0) {
		n = guard_append_name(buf, len, n, GUARD_RESET_NONE);
	}
	return n;
}

#endif /* GUARD_H */
