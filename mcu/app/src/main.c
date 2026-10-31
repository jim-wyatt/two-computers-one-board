/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * MCU side of the UNO Q hybrid link.
 *
 * Console + interactive shell + SMP/MCUmgr all share lpuart1, the UART wired
 * to the Linux MPU (/dev/ttyHS1). See boards/arduino_uno_q.overlay.
 *
 * The whole firmware is an "app" shell command group the MPU drives over that
 * link, plus one piece of state (panel orientation) persisted in NVS so it
 * survives power cycles and firmware updates.
 *
 * `app bars` is the MCU half of the CPU monitor: the MPU measures
 * (python/unoq/cpu.py), this side draws. See docs/mpu.md.
 *
 * The MCU also watches itself: guard.c arms the chip's watchdog at boot, and
 * `app reset` says why the last reset happened. See guard.h.
 *
 * `app jitter` measures how well Linux keeps a schedule, against how well the
 * MCU's own timers do. The record is jitter.c; the clocks are here. See
 * jitter.h.
 *
 * There is no main loop. Everything that runs after init runs on its own:
 * the shell has a thread, and the panel is refreshed from a timer ISR inside
 * matrix.c. A loop here would have nothing to do but sleep, and printing from
 * one would fight the shell prompt.
 */
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/counter.h>
#include <zephyr/drivers/pwm.h>
#include <zephyr/drivers/sensor.h>
#include <zephyr/shell/shell.h>
#include <zephyr/settings/settings.h>
#include <zephyr/dfu/mcuboot.h>
#include <stdlib.h>
#include <string.h>

#include "app_proto.h"
#include "bars.h"
#include "guard.h"
#include "jitter.h"
#include "matrix.h"
#include "spi_proto.h"
#include "status_leds.h"
#include "templog.h"

/* Panel state. `frame` is the last thing drawn, kept so a command that changes
 * orientation can redraw it rather than blanking the display. */
static uint8_t frame[APP_MATRIX_LEDS];
static uint8_t bar_pct[APP_BARS_MAX];
static int bar_count;
static uint8_t flip; /* 0/1, persisted - see APP_SETTINGS_FLIP */

/* --- persistent settings ------------------------------------------------- */

static int app_settings_set(const char *name, size_t len, settings_read_cb read_cb, void *cb_arg)
{
	if (settings_name_steq(name, "flip", NULL) && len == sizeof(flip)) {
		return read_cb(cb_arg, &flip, sizeof(flip)) > 0 ? 0 : -EINVAL;
	}
	return -ENOENT;
}

SETTINGS_STATIC_HANDLER_DEFINE(app, "app", NULL, app_settings_set, NULL, NULL);

/* --- shell commands: the MPU drives these over the serial link ----------- */

/* Every command handler starts here. LED 4 is the MCU saying "something
 * arrived and I dealt with it" - which is a different claim from Linux's "I
 * sent something", and the difference is exactly what you want when the link
 * has gone quiet and you are trying to work out which end stopped.
 */
static int cmd_app_status(const struct shell *sh, size_t argc, char **argv)
{
	status_leds_link_seen();
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);
	shell_print(sh, APP_STATUS_FMT, k_uptime_get(), flip != 0, matrix_sweeps());
	return 0;
}

/* The chip's own temperature, which only this side of the board can read.
 *
 * Zephyr's board file already enables the sensor and the ADC it is read
 * through (die_temp -> adc1 channel 19), so there is no overlay entry for it;
 * prj.conf turns the drivers on. The driver converts with ST's two factory
 * calibration points and hands back a sensor_value, which is taken to
 * millidegrees with integer arithmetic - see APP_TEMP_FMT for why.
 *
 * Every way this can fail prints APP_TEMP_ERR_FMT and nothing else. A reading
 * that is wrong but plausible is worse than no reading, so nothing here falls
 * back to a default or to the previous sample.
 */
static const struct device *const die_temp = DEVICE_DT_GET(DT_ALIAS(die_temp0));

/* Two threads read the sensor now: the shell's, for `app temp`, and the
 * system workqueue's, for the log. The driver locks the conversion but not
 * the step after it, which converts whatever raw value the last conversion
 * left - so without this, one thread could report the other's reading. */
static K_MUTEX_DEFINE(die_temp_lock);

static int read_die_temp(int32_t *temp_mc)
{
	struct sensor_value val;
	int rc;

	/* Not ready means its init failed at boot - the ADC did not come up, or
	 * the calibration words could not be read. Calling into it anyway would
	 * convert against calibration data that was never loaded. */
	if (!device_is_ready(die_temp)) {
		return -ENODEV;
	}

	k_mutex_lock(&die_temp_lock, K_FOREVER);
	rc = sensor_sample_fetch(die_temp);
	if (rc == 0) {
		rc = sensor_channel_get(die_temp, SENSOR_CHAN_DIE_TEMP, &val);
	}
	k_mutex_unlock(&die_temp_lock);

	if (rc == 0) {
		*temp_mc = (int32_t)sensor_value_to_milli(&val);
	}
	return rc;
}

static int cmd_app_temp(const struct shell *sh, size_t argc, char **argv)
{
	status_leds_link_seen();
	int32_t temp_mc;
	int rc;

	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	rc = read_die_temp(&temp_mc);
	if (rc != 0) {
		shell_error(sh, APP_TEMP_ERR_FMT, rc);
		return rc;
	}

	shell_print(sh, APP_TEMP_FMT, (int)temp_mc);
	return 0;
}

/* --- the temperature log -------------------------------------------------- */

/* The record itself, filled once a second by templog.c's own timer whether or
 * not anything is reading it, and the batch one `app temp log` copies out of
 * it. Static rather than on the shell's stack, which is not sized for 1 KB. */
static struct templog temp_log;
static struct templog_sample temp_log_batch[APP_TEMPLOG_BATCH];

/* The SPI link's TEMPLOG service answers from this same log. spi_link.c has a
 * weak default returning NULL, and until this definition existed the service
 * answered "unavailable"; see spi_proto.h. */
struct templog *spi_link_templog(void)
{
	return &temp_log;
}

/* `app temp log [since]` - see app_proto.h for the lines and their order. */
static int cmd_app_temp_log(const struct shell *sh, size_t argc, char **argv)
{
	status_leds_link_seen();
	struct templog_batch b;
	bool has_since = argc > 1;
	int since = 0;
	int rc;

	if (has_since && (!app_parse_int(argv[1], &since) || since < 0)) {
		shell_error(sh, APP_ERR "since: '%s' is not a sequence number", argv[1]);
		return -EINVAL;
	}

	rc = templog_read(&temp_log, has_since, (uint32_t)since, temp_log_batch,
			  ARRAY_SIZE(temp_log_batch), &b);
	if (rc != 0) {
		shell_error(sh,
			    APP_ERR "since %d is past the newest sample, %u: the MCU has "
				    "restarted since that number was read",
			    since, (unsigned int)b.head);
		return rc;
	}

	if (b.gap_first != 0) {
		shell_print(sh, APP_TEMPLOG_GAP_FMT, (unsigned int)b.gap_first,
			    (unsigned int)b.gap_last);
	}
	for (uint32_t i = 0; i < b.n; i++) {
		const struct templog_sample *s = &temp_log_batch[i];

		shell_print(sh, s->ok ? APP_TEMPLOG_FMT : APP_TEMPLOG_ERR_FMT, (unsigned int)s->seq,
			    (long long)s->ms, (int)s->value);
	}
	shell_print(sh, APP_TEMPLOG_END_FMT, (unsigned int)b.head, (unsigned int)b.more);
	return 0;
}

static int cmd_app_temp_log_stat(const struct shell *sh, size_t argc, char **argv)
{
	status_leds_link_seen();
	struct templog_stat st = templog_stat(&temp_log);

	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	shell_print(sh, APP_TEMPLOG_STAT_FMT, (unsigned int)st.head, (unsigned int)st.count,
		    (unsigned int)APP_TEMPLOG_SIZE, (unsigned int)st.dropped,
		    (unsigned int)APP_TEMPLOG_PERIOD_MS);
	return 0;
}

/* --- the watchdog --------------------------------------------------------- */

/* `app reset`: why the MCU last reset. See APP_RESET_FMT. */
static int cmd_app_reset(const struct shell *sh, size_t argc, char **argv)
{
	status_leds_link_seen();
	char names[GUARD_RESET_NAMES_MAX];

	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	if (guard_reset_cause_known()) {
		(void)guard_reset_names(guard_reset_cause(), names, sizeof(names));
	} else {
		strcpy(names, GUARD_RESET_UNKNOWN);
	}
	shell_print(sh, APP_RESET_FMT, names);
	return 0;
}

/* `app hang yes`: stall until the watchdog resets the chip.
 *
 * k_sched_lock() stops every other thread from running, the system workqueue
 * included, and the status-LED beat that feeds the watchdog is a work item on
 * it. The beat never runs again, so the dog is never fed again. Interrupts
 * still run, so the panel keeps its last frame lit to the end: the sweep
 * count climbing is not enough on its own to feed the dog, which is what this
 * demonstrates. The shell stops answering, LED 3 and LED 4 freeze where they
 * are, and about eight seconds later the chip resets and `app reset` says
 * "watchdog".
 *
 * The pause before the lock lets the shell's interrupt-driven output finish
 * the line above, so the reader sees why the prompt does not come back.
 */
static int cmd_app_hang(const struct shell *sh, size_t argc, char **argv)
{
	status_leds_link_seen();
	ARG_UNUSED(argc);

	if (strcmp(argv[1], "yes") != 0) {
		shell_error(sh, APP_ERR "this resets the MCU: type app hang yes");
		return -EINVAL;
	}
	shell_print(sh, APP_HANG_FMT, GUARD_TIMEOUT_MS);
	k_msleep(100);

	k_sched_lock();
	for (;;) {
		arch_nop();
	}
	return 0; /* not reached */
}

/* --- jitter: the MCU times what Linux schedules ---------------------------
 *
 * Three of the STM32's general-purpose timers, all on the 160 MHz APB1 timer
 * clock and set up in boards/arduino_uno_q.overlay:
 *
 *   TIM5  a free-running 32-bit counter at 1 MHz. The tick timestamps. The
 *         kernel's own cycle counter is LPTIM1 on the 32 kHz crystal here,
 *         about 30 us a count, too coarse to time a 10 ms schedule by.
 *   TIM3  PWM out on D3 (PB0, TIM3_CH3), counting at 1 MHz.
 *   TIM2  PWM capture in on D2 (PB3, TIM2_CH2), at the full 160 MHz.
 *
 * A jumper from D3 to D2 makes TIM2 measure what TIM3 makes. Both run from
 * the same clock, so any spread in that histogram is the hardware's own, not
 * a disagreement between two crystals. Without the jumper the input is
 * pulled down and nothing is captured: the pwm histogram stays at n=0.
 */
static const struct device *const jitter_clock = DEVICE_DT_GET(DT_NODELABEL(counter_jitter));
static const struct device *const jitter_out = DEVICE_DT_GET(DT_NODELABEL(pwm_jitter_out));
static const struct device *const jitter_in = DEVICE_DT_GET(DT_NODELABEL(pwm_jitter_in));
#define JITTER_OUT_CH   3       /* TIM3_CH3: PB0, D3 */
#define JITTER_IN_CH    2       /* TIM2_CH2: PB3, D2 */
#define JITTER_CLOCK_HZ 1000000 /* TIM5, so a count is a microsecond */

static struct jitter_ticker jitter_ticks;
static struct jitter_hist jitter_pwm;
static uint32_t jitter_pwm_period_us; /* what TIM3 runs at; 0 = never started */
/* Read by the capture interrupt. Written only while the capture is off. */
static uint32_t jitter_expect_cycles; /* one TIM3 period, in TIM2 cycles */
static uint64_t jitter_in_hz;         /* TIM2's counting rate */
static bool jitter_clock_running;

static int jitter_clock_start(void)
{
	int rc;

	if (jitter_clock_running) {
		return 0;
	}
	if (!device_is_ready(jitter_clock)) {
		return -ENODEV;
	}
	/* Everything in jitter.c takes a count to be a microsecond. */
	if (counter_get_frequency(jitter_clock) != JITTER_CLOCK_HZ) {
		return -ENOTSUP;
	}
	rc = counter_start(jitter_clock);
	jitter_clock_running = rc == 0;
	return rc;
}

/* In the timer's interrupt, once per period of the square wave on D2. The
 * driver resets TIM2 on each rising edge and hands over what it had counted
 * to: one period, in cycles. status is -ERANGE if it overflowed first. */
static void jitter_on_capture(const struct device *dev, uint32_t channel, uint32_t period_cycles,
			      uint32_t pulse_cycles, int status, void *user_data)
{
	ARG_UNUSED(dev);
	ARG_UNUSED(channel);
	ARG_UNUSED(pulse_cycles);
	ARG_UNUSED(user_data);

	if (status != 0) {
		return;
	}
	jitter_hist_add(&jitter_pwm, ((int64_t)period_cycles - jitter_expect_cycles) *
					     1000000000LL / (int64_t)jitter_in_hz);
}

static int cmd_app_jitter_arm(const struct shell *sh, size_t argc, char **argv)
{
	status_leds_link_seen();
	int period;
	int rc;

	ARG_UNUSED(argc);

	if (!app_parse_int(argv[1], &period) || period < APP_JITTER_PERIOD_US_MIN ||
	    period > APP_JITTER_PERIOD_US_MAX) {
		shell_error(sh, APP_ERR "period_us: '%s' is not %d..%d", argv[1],
			    APP_JITTER_PERIOD_US_MIN, APP_JITTER_PERIOD_US_MAX);
		return -EINVAL;
	}
	rc = jitter_clock_start();
	if (rc != 0) {
		shell_error(sh, APP_ERR "the TIM5 counter is unavailable (%d)", rc);
		return rc;
	}

	jitter_ticker_arm(&jitter_ticks, (uint32_t)period);
	jitter_hist_clear(&jitter_pwm);
	shell_print(sh, APP_JITTER_ARM_FMT, (unsigned int)period);
	return 0;
}

/* The one command that is the measurement. The timestamp is the first thing
 * it takes, so what it times is Linux, the wire and the shell's parse, and
 * none of this handler. It prints nothing when it works: Linux does not read
 * the reply (see MCU.jitter_tick()). */
static int cmd_app_jitter_tick(const struct shell *sh, size_t argc, char **argv)
{
	uint32_t now = 0;
	int rc = jitter_ticks.armed ? counter_get_value(jitter_clock, &now) : -EAGAIN;

	status_leds_link_seen();
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	if (rc == 0) {
		rc = jitter_ticker_tick(&jitter_ticks, now);
	}
	if (rc != 0) {
		shell_error(sh, APP_ERR "not armed: app jitter arm <period_us> first (%d)", rc);
		return rc;
	}
	return 0;
}

static void jitter_capture_stop(void)
{
	/* 0 whether or not a capture was running. */
	(void)pwm_disable_capture(jitter_in, JITTER_IN_CH);
}

static int cmd_app_jitter_pwm(const struct shell *sh, size_t argc, char **argv)
{
	status_leds_link_seen();
	uint64_t out_hz;
	uint32_t cycles;
	int hz;
	int rc;

	ARG_UNUSED(argc);

	if (!app_parse_int(argv[1], &hz) || hz < APP_JITTER_PWM_HZ_MIN ||
	    hz > APP_JITTER_PWM_HZ_MAX) {
		shell_error(sh, APP_ERR "hz: '%s' is not %d..%d", argv[1], APP_JITTER_PWM_HZ_MIN,
			    APP_JITTER_PWM_HZ_MAX);
		return -EINVAL;
	}
	if (!device_is_ready(jitter_out) || !device_is_ready(jitter_in)) {
		shell_error(sh, APP_ERR "the TIM3 PWM or the TIM2 capture is unavailable");
		return -ENODEV;
	}

	/* The capture comes off first: a period that straddles the change
	 * belongs to neither frequency. */
	jitter_capture_stop();

	rc = pwm_get_cycles_per_sec(jitter_out, JITTER_OUT_CH, &out_hz);
	if (rc == 0) {
		rc = pwm_get_cycles_per_sec(jitter_in, JITTER_IN_CH, &jitter_in_hz);
	}
	if (rc != 0 || out_hz == 0U || jitter_in_hz == 0U) {
		shell_error(sh, APP_ERR "no timer clock rate (%d)", rc);
		return rc != 0 ? rc : -EIO;
	}
	cycles = (uint32_t)(out_hz / (uint64_t)hz);
	rc = pwm_set_cycles(jitter_out, JITTER_OUT_CH, cycles, cycles / 2U, PWM_POLARITY_NORMAL);
	if (rc != 0) {
		shell_error(sh, APP_ERR "PWM on D3 refused %u cycles (%d)", (unsigned int)cycles,
			    rc);
		return rc;
	}
	jitter_pwm_period_us = (uint32_t)((uint64_t)cycles * 1000000U / out_hz);
	jitter_expect_cycles = (uint32_t)((uint64_t)cycles * jitter_in_hz / out_hz);
	jitter_hist_clear(&jitter_pwm);

	rc = pwm_configure_capture(jitter_in, JITTER_IN_CH,
				   PWM_CAPTURE_TYPE_PERIOD | PWM_CAPTURE_MODE_CONTINUOUS |
					   PWM_POLARITY_NORMAL,
				   jitter_on_capture, NULL);
	if (rc == 0) {
		rc = pwm_enable_capture(jitter_in, JITTER_IN_CH);
	}
	if (rc != 0) {
		shell_error(sh, APP_ERR "PWM runs on D3 but capture on D2 failed (%d)", rc);
		return rc;
	}

	shell_print(sh, APP_JITTER_PWM_FMT, (unsigned int)hz, (unsigned int)jitter_pwm_period_us);
	return 0;
}

static void jitter_print(const struct shell *sh, const char *src, uint32_t period_us,
			 struct jitter_hist *h)
{
	/* Static rather than on the shell's stack; only the shell's thread
	 * prints. */
	static char bins[JITTER_BINS_STR_MAX];
	struct jitter_summary s = jitter_hist_read(h);

	(void)jitter_format_bins(s.bins, bins, sizeof(bins));
	shell_print(sh, APP_JITTER_FMT, src, (unsigned int)period_us, (unsigned int)s.n,
		    (int)s.min_ns, (int)s.max_ns, (int)s.mean_ns, bins);
}

static int cmd_app_jitter_stat(const struct shell *sh, size_t argc, char **argv)
{
	status_leds_link_seen();
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	jitter_print(sh, APP_JITTER_SRC_TICK, jitter_ticks.period_us, &jitter_ticks.hist);
	jitter_print(sh, APP_JITTER_SRC_PWM, jitter_pwm_period_us, &jitter_pwm);
	return 0;
}

static int cmd_app_jitter_off(const struct shell *sh, size_t argc, char **argv)
{
	status_leds_link_seen();
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	jitter_ticker_stop(&jitter_ticks);
	if (device_is_ready(jitter_in)) {
		jitter_capture_stop();
	}
	if (device_is_ready(jitter_out)) {
		(void)pwm_set_cycles(jitter_out, JITTER_OUT_CH, 0, 0, PWM_POLARITY_NORMAL);
	}
	shell_print(sh, APP_JITTER_OFF_FMT);
	return 0;
}

/* --- the LED panel -------------------------------------------------------- */

/* Redraw whatever is currently meant to be on screen. Called after anything
 * that changes how a frame maps to pixels, so orientation takes effect
 * immediately instead of at the next update from the MPU. */
static void redraw(void)
{
	if (bar_count > 0) {
		app_bars_render(bar_pct, bar_count, flip != 0, frame);
		matrix_draw(frame);
	}
}

static int cmd_app_bars(const struct shell *sh, size_t argc, char **argv)
{
	status_leds_link_seen();
	int n = (int)argc - 1;

	if (!app_bars_count_valid(n)) {
		shell_error(sh, APP_ERR "usage: app bars <pct> [pct ...] (1..%d values)",
			    APP_BARS_MAX);
		return -EINVAL;
	}

	/* Validate everything before drawing anything: a partly-applied update
	 * would show a frame that never corresponded to a real measurement. */
	for (int i = 0; i < n; i++) {
		int pct;

		if (!app_parse_int(argv[i + 1], &pct)) {
			shell_error(sh, APP_ERR "bar %d: '%s' is not a number", i, argv[i + 1]);
			return -EINVAL;
		}
		if (!app_bars_pct_valid(pct)) {
			shell_error(sh, APP_ERR "bar %d: %d outside 0..%d", i, pct,
				    APP_BARS_PCT_MAX);
			return -EINVAL;
		}
		bar_pct[i] = (uint8_t)pct;
	}
	bar_count = n;

	redraw();
	shell_print(sh, "ok bars=%d", n);
	return 0;
}

/* Light exactly one LED. This is how you find out which corner row 0, column 0
 * really is on a board in front of you - the answer depends on which way round
 * it is mounted, so it is not something the firmware can assume. */
static int cmd_app_matrix_px(const struct shell *sh, size_t argc, char **argv)
{
	status_leds_link_seen();
	static const char *const names[] = {"row", "col", "level"};
	int vals[3];
	int row, col, level;
	int idx;

	ARG_UNUSED(argc);

	for (int i = 0; i < 3; i++) {
		if (!app_parse_int(argv[i + 1], &vals[i])) {
			shell_error(sh, APP_ERR "%s: '%s' is not a number", names[i], argv[i + 1]);
			return -EINVAL;
		}
	}
	row = vals[0];
	col = vals[1];
	level = vals[2];

	if (!app_matrix_pixel_valid(row, col)) {
		shell_error(sh, APP_ERR "row 0..%d, col 0..%d", APP_MATRIX_ROWS - 1,
			    APP_MATRIX_COLS - 1);
		return -EINVAL;
	}
	if (!app_matrix_level_valid(level)) {
		shell_error(sh, APP_ERR "level 0..%d", APP_MATRIX_MAX_LEVEL);
		return -EINVAL;
	}

	/* Same coordinates as `app bars`, flip included, so that once flip is
	 * right for the panel it is right for both. */
	idx = row * APP_MATRIX_COLS + col;
	if (flip) {
		idx = APP_MATRIX_LEDS - 1 - idx;
	}

	memset(frame, 0, sizeof(frame));
	frame[idx] = (uint8_t)level;
	bar_count = 0; /* the bars are gone; do not let a redraw resurrect them */
	matrix_draw(frame);

	shell_print(sh, "ok px row=%d col=%d level=%d", row, col, level);
	return 0;
}

/* Draw a whole picture: `app matrix frame <r0> ... <r7>`, one word of level
 * digits per row. See app_proto.h for the format and why it fits the shell.
 *
 * The picture is built in `frame` and handed to matrix_draw() in one go,
 * which copies it into the refresh buffer with interrupts off. The panel goes
 * from the old picture to the new one at a single point in one 1 ms sweep,
 * not row by row as the words arrive. Like px, the flip in force when the frame
 * arrives is the one it is drawn with; flipping afterwards redraws only bars. */
static int cmd_app_matrix_frame(const struct shell *sh, size_t argc, char **argv)
{
	status_leds_link_seen();
	int lit;

	ARG_UNUSED(argc);

	/* All eight rows before any pixel: a frame with one bad row is not a
	 * picture anybody sent. */
	for (int row = 0; row < APP_MATRIX_ROWS; row++) {
		if (!app_matrix_row_valid(argv[row + 1])) {
			shell_error(sh, APP_ERR "row %d: '%s' is not %d digits 0..%d", row,
				    argv[row + 1], APP_MATRIX_COLS, APP_MATRIX_MAX_LEVEL);
			return -EINVAL;
		}
	}

	lit = app_matrix_frame_fill((const char *const *)&argv[1], flip != 0, frame);
	bar_count = 0; /* as for px: a redraw must not bring the bars back over it */
	matrix_draw(frame);

	shell_print(sh, APP_MATRIX_FRAME_FMT, lit);
	return 0;
}

static int cmd_app_matrix_flip(const struct shell *sh, size_t argc, char **argv)
{
	status_leds_link_seen();
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	int rc;

	flip = !flip;
	rc = settings_save_one(APP_SETTINGS_FLIP, &flip, sizeof(flip));
	redraw();

	/* The flip still applies for this boot - the panel in front of you is
	 * the right way round either way - but "ok" was printed whether or not
	 * it was saved, and a board fitted once and then power-cycled came back
	 * upside down with nothing to say why. An APP_ERR line makes
	 * unoq.MCU.matrix_flip() raise rather than report a setting that is
	 * not there. */
	if (rc != 0) {
		shell_error(sh, APP_ERR "flip=%d applied but not saved (%d): it reverts at reset",
			    flip, rc);
		return rc;
	}

	shell_print(sh, "ok flip=%d", flip);
	return 0;
}

static int cmd_app_matrix_off(const struct shell *sh, size_t argc, char **argv)
{
	status_leds_link_seen();
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	bar_count = 0;
	matrix_off();
	shell_print(sh, "ok matrix off");
	return 0;
}

SHELL_STATIC_SUBCMD_SET_CREATE(
	matrix_cmds,
	SHELL_CMD_ARG(px, NULL, "Light one LED: app matrix px <row> <col> <level>",
		      cmd_app_matrix_px, 4, 0),
	SHELL_CMD_ARG(frame, NULL, "Draw a whole frame: app matrix frame <row0> ... <row7>",
		      cmd_app_matrix_frame, 1 + APP_MATRIX_ROWS, 0),
	SHELL_CMD(flip, NULL, "Rotate the panel 180 degrees (persisted)", cmd_app_matrix_flip),
	SHELL_CMD(off, NULL, "Blank the panel and stop the refresh", cmd_app_matrix_off),
	SHELL_SUBCMD_SET_END);

/* `app temp log 42` matches no subcommand of `log`, and the shell then hands
 * the 42 to log's own handler as its argument - so `stat` and a sequence
 * number share one position without either shadowing the other. */
SHELL_STATIC_SUBCMD_SET_CREATE(temp_log_cmds,
			       SHELL_CMD(stat, NULL, "head, count, size, dropped, period",
					 cmd_app_temp_log_stat),
			       SHELL_SUBCMD_SET_END);

SHELL_STATIC_SUBCMD_SET_CREATE(temp_cmds,
			       SHELL_CMD_ARG(log, &temp_log_cmds,
					     "Logged samples: app temp log [since_seq]",
					     cmd_app_temp_log, 1, 1),
			       SHELL_SUBCMD_SET_END);

SHELL_STATIC_SUBCMD_SET_CREATE(
	jitter_cmds,
	SHELL_CMD_ARG(arm, NULL, "Expect a tick every period: app jitter arm <period_us>",
		      cmd_app_jitter_arm, 2, 0),
	SHELL_CMD(tick, NULL, "Timestamp this arrival on TIM5", cmd_app_jitter_tick),
	SHELL_CMD_ARG(pwm, NULL, "PWM out on D3, captured on D2: app jitter pwm <hz>",
		      cmd_app_jitter_pwm, 2, 0),
	SHELL_CMD(stat, NULL, "Both histograms: tick, then pwm", cmd_app_jitter_stat),
	SHELL_CMD(off, NULL, "Stop the ticks, the PWM and the capture", cmd_app_jitter_off),
	SHELL_SUBCMD_SET_END);

SHELL_STATIC_SUBCMD_SET_CREATE(
	app_cmds,
	SHELL_CMD(status, NULL, "uptime, panel orientation, refresh sweeps", cmd_app_status),
	SHELL_CMD(temp, &temp_cmds, "die temp in millidegrees C", cmd_app_temp),
	SHELL_CMD_ARG(bars, NULL, "Draw CPU bars: app bars <pct> [pct ...]", cmd_app_bars, 2,
		      APP_BARS_MAX - 1),
	SHELL_CMD(matrix, &matrix_cmds, "LED panel control", NULL),
	SHELL_CMD(reset, NULL, "why the MCU last reset", cmd_app_reset),
	SHELL_CMD_ARG(hang, NULL, "Stall until the watchdog resets the MCU: app hang yes",
		      cmd_app_hang, 2, 0),
	SHELL_CMD(jitter, &jitter_cmds, "how well Linux keeps a schedule", NULL),
	SHELL_SUBCMD_SET_END);
SHELL_CMD_REGISTER(app, &app_cmds, "UNO Q application commands", NULL);

/* --- main ---------------------------------------------------------------- */

int main(void)
{
	printk("\n=== UNO Q MCU up: %s ===\n", CONFIG_BOARD_TARGET);

	/* First, so the reset cause is read before anything else can reset
	 * the chip, and so a hang anywhere in the rest of init is caught. The
	 * first feed is the status-LED beat below, well inside the timeout. */
	int wdt_rc = guard_init();
	char why[GUARD_RESET_NAMES_MAX];

	(void)guard_reset_names(guard_reset_cause(), why, sizeof(why));
	printk("reset cause: %s\n", guard_reset_cause_known() ? why : GUARD_RESET_UNKNOWN);
	if (wdt_rc == 0) {
		printk("watchdog armed: %d ms, fed while the panel refresh runs\n",
		       GUARD_TIMEOUT_MS);
	} else {
		printk("watchdog unavailable (%d)\n", wdt_rc);
	}

	/* Load the persisted panel orientation before the matrix comes up, so
	 * the first frame drawn is already the right way round. */
	if (settings_subsys_init() != 0 || settings_load() != 0) {
		printk("settings unavailable - panel orientation not persisted\n");
	}

	/* LED 3 and LED 4. A board without them still runs everything else, so
	 * this only reports. */
	status_leds_init();

	/* LED 3 answers the question you actually have after an update: is this
	 * the firmware that will still be here after the next reset? MCUboot
	 * runs a new image unconfirmed the first time, and reverts it unless
	 * something confirms it - so "unconfirmed" is a real, temporary,
	 * invisible state, and yellow is the only place it is visible without
	 * reading the slot table over the wire. */
	bool confirmed = boot_is_img_confirmed();

	status_leds_set_image_confirmed(confirmed);
	printk("status LEDs %s, image %s\n", status_leds_present() ? "ready" : "unavailable",
	       confirmed ? "confirmed" : "UNCONFIRMED (reverts on next reset)");

	/* The panel stays dark until something draws on it, so a failure here
	 * costs the LED matrix and nothing else - the link and the shell both
	 * still come up. */
	if (matrix_init() == 0) {
		printk("LED matrix ready (%dx%d, flip=%d)\n", APP_MATRIX_ROWS, APP_MATRIX_COLS,
		       flip != 0);
	} else {
		printk("LED matrix unavailable\n");
		status_leds_set_fault();
	}

	/* The log runs whether or not the sensor came up: a sensor that is not
	 * ready gives a sample of -ENODEV every second, which says so in the
	 * record itself instead of leaving it empty. */
	templog_init(&temp_log);
	templog_start(&temp_log, read_die_temp, APP_TEMPLOG_PERIOD_MS);
	printk("temperature log: %d samples, one every %d ms\n", APP_TEMPLOG_SIZE,
	       APP_TEMPLOG_PERIOD_MS);

	return 0;
}
