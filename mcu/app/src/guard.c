/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * The MCU's watchdog and its reset cause. See guard.h for what is watched and
 * why the timeout is what it is.
 *
 * WHY MCUBOOT'S SWAP IS NOT AFFECTED
 * ----------------------------------
 * The app arms the watchdog, and MCUboot runs before the app. A firmware
 * update is uploaded by this app (the dog armed and fed throughout, see
 * guard.h for why the upload's flash erases fit inside the timeout), and then
 * the chip resets. MCUboot does the swap on the way back up, before any of
 * this code exists to arm anything, and the reset that started it stopped the
 * IWDG: once it is running nothing but a reset stops it, and a system reset,
 * the software one an update ends with included, does - its registers go back
 * to their reset values, and only the hardware option below restarts it. So
 * the swap, which takes as long as it takes, runs with no watchdog at all,
 * and the new image arms its own when it gets to main().
 *
 * Two things could break that, and both were checked:
 *
 *   MCUboot arming it first. MCUboot can (CONFIG_BOOT_WATCHDOG_SETUP_AT_BOOT,
 *   with a five-minute default and feeds during the swap), but only when its
 *   own build has CONFIG_WATCHDOG, and mcu/flash-all.sh builds it without:
 *   its .config says "CONFIG_WATCHDOG is not set". mcu/mcuboot.conf leaves it
 *   that way. Turning it on there would be a choice to revisit this.
 *
 *   The option bytes starting it in hardware. The STM32U5 can start the IWDG
 *   at every reset by itself (IWDG_SW cleared in FLASH_OPTR), at its shortest
 *   setting of about half a second. ST ships the part in software mode, and
 *   nothing in this project writes option bytes. A board in hardware mode
 *   could never have run the firmware before this one, which fed nothing: it
 *   would have reset every half second. That is the evidence it is not; it has
 *   not been read off the chip.
 *
 * And a watchdog reset mid-upload is safe anyway: the upload goes to slot 1,
 * which is not the image that is running, and an incomplete image there fails
 * MCUboot's signature check and is never swapped in.
 */
#include "guard.h"
#include "matrix.h"

#include <zephyr/device.h>
#include <zephyr/drivers/hwinfo.h>
#include <zephyr/drivers/watchdog.h>
#include <zephyr/kernel.h>

static const struct device *const wdt = DEVICE_DT_GET_OR_NULL(DT_ALIAS(watchdog0));

static int channel = -1; /* >= 0 once armed */
static uint32_t last_sweeps;
static uint32_t reset_cause;
static bool reset_known;

int guard_init(void)
{
	/* The cause first, and cleared straight after. RCC's reset flags are
	 * sticky: they collect every reset since the last power-on until
	 * something clears them, and MCUboot does not. Left alone, a board
	 * that had once been reset by its watchdog would say "watchdog" after
	 * every reset that followed. */
	if (hwinfo_get_reset_cause(&reset_cause) == 0) {
		reset_known = true;
		(void)hwinfo_clear_reset_cause();
	}

	if (wdt == NULL || !device_is_ready(wdt)) {
		return -ENODEV;
	}

	const struct wdt_timeout_cfg cfg = {
		.window = {.min = 0, .max = GUARD_TIMEOUT_MS},
		.callback = NULL,
		.flags = WDT_FLAG_RESET_SOC,
	};
	int id = wdt_install_timeout(wdt, &cfg);
	int rc;

	if (id < 0) {
		return id;
	}
	/* Paused while a debugger has the core halted. Without it, sitting on
	 * a breakpoint for eight seconds resets the chip out from under the
	 * debugger. */
	rc = wdt_setup(wdt, WDT_OPT_PAUSE_HALTED_BY_DBG);
	if (rc < 0) {
		return rc;
	}
	last_sweeps = matrix_sweeps();
	channel = id;
	return 0;
}

void guard_tick(void)
{
	uint32_t sweeps = matrix_sweeps();
	bool feed = guard_should_feed(matrix_running(), sweeps, last_sweeps);

	last_sweeps = sweeps;
	if (channel >= 0 && feed) {
		(void)wdt_feed(wdt, channel);
	}
}

uint32_t guard_reset_cause(void)
{
	return reset_cause;
}

bool guard_reset_cause_known(void)
{
	return reset_known;
}
