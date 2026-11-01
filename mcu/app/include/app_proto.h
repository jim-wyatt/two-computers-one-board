/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * The MPU <-> MCU contract, in one place.
 *
 * Everything here is consumed by parties that must agree:
 *
 *   - mcu/app/src/main.c        produces the status and temp lines, validates bars
 *   - mcu/app/src/templog.c     keeps the temperature log main.c prints
 *   - mcu/app/include/guard.h   names the reset causes APP_RESET_FMT carries
 *   - mcu/tests/templog/        tests the log's sequence, gap and batch rules
 *   - mcu/app/src/env.c         formats the `app env` line
 *   - mcu/tests/env/            tests it, with the driver's values faked
 *   - mcu/app/src/jitter.c      keeps the jitter histograms `app jitter` prints
 *   - mcu/tests/jitter/         tests their bins, clamp and tick bookkeeping
 *   - mcu/app/src/scope_hw.c    runs `app scope`, the DAC and ADC on PA4
 *   - mcu/tests/scope/          tests its tables, timer division and bursts
 *   - mcu/tests/link_protocol/  tests these definitions directly
 *   - python/unoq/mcu.py        parses those lines, calls `app bars`
 *
 * The definitions used to be duplicated: main.c had the range check and the
 * format string, and the test had its own copy of both. A copy cannot fail
 * when the original changes, so the test proved nothing about the firmware.
 * Include this from both instead.
 *
 * A change here is a protocol change - update unoq/mcu.py and its tests too.
 */
#ifndef APP_PROTO_H
#define APP_PROTO_H

#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

/* The `app status` line, parsed by unoq.MCU.status() into a dict.
 *
 * Format is "key=value" pairs separated by single spaces. The parser splits on
 * whitespace and then on the first '=', so a value must never contain either.
 */
#define APP_STATUS_FMT    "uptime_ms=%lld flip=%d sweeps=%u"
#define APP_STATUS_FIELDS 3

/*
 * What a rejected command starts with. Shared with unoq.MCU.cmd(), which raises
 * on any line that begins with it.
 *
 * shell_error() does not add this. It only colors the line red, and the color
 * is exactly what the Python side strips before it looks. So for as long as the
 * handlers printed a bare message, a command the firmware refused came back to
 * Python looking like a reply, and nothing was raised.
 */
#define APP_ERR "Error: "

/* Every number a command takes is read with this, and a false return is an
 * APP_ERR reply.
 *
 * It was atoi(), which turns anything into a number: `app bars abc` drew an
 * idle core, and `app matrix px x y z` lit the corner pixel and said "ok". A
 * typo at the prompt and a corrupted line on the wire both looked like a valid
 * command. The whole argument has to be one decimal integer that fits an int:
 * nothing before it but what strtol allows, nothing after it at all.
 */
static inline bool app_parse_int(const char *s, int *out)
{
	char *end;
	long v;

	if (s == NULL || *s == '\0') {
		return false;
	}
	errno = 0;
	v = strtol(s, &end, 10);
	if (end == s || *end != '\0' || errno == ERANGE || v < INT_MIN || v > INT_MAX) {
		return false;
	}
	*out = (int)v;
	return true;
}

/* The `app temp` line, parsed by unoq.MCU.die_temp() into degrees Celsius.
 *
 * The STM32U585's internal die temperature sensor, which Linux cannot see at
 * all: its thermal zones are the QRB2210's. It is a command of its own rather
 * than a fourth field of `app status` because reading it is a real ADC
 * conversion that can fail, and status must never fail - and because the status
 * format is pinned by tests and quoted throughout the documentation.
 *
 * The unit is millidegrees Celsius as a signed integer, the same unit Linux
 * uses in /sys/class/thermal, so both processors' temperatures compare without
 * a conversion. An integer because this build has no floating-point printf
 * (CONFIG_CBPRINTF_FP_SUPPORT is off, and costs flash to turn on) and because
 * "%d" is unambiguous to parse where a locale-shaped decimal is not. Signed
 * because the part is rated to -40 C.
 *
 * On failure the firmware prints APP_TEMP_ERR_FMT instead, with the negative
 * errno it got: -19 (ENODEV) when the sensor or the ADC behind it never came
 * up at boot, anything else from the conversion itself. The two lines share no
 * key, so a failure can never be read as a temperature.
 */
#define APP_TEMP_FMT     "temp_mc=%d"
#define APP_TEMP_ERR_FMT "temp_err=%d"

/* --- the temperature log -------------------------------------------------
 *
 * `app temp` is a reading taken when Linux asks. The log is the other way
 * round: the MCU samples on its own timer, whether or not anyone is listening,
 * and keeps the last APP_TEMPLOG_SIZE samples for Linux to collect later. See
 * mcu/app/src/templog.c, and MCU.temp_log() in python/unoq/mcu.py.
 *
 * Every sample gets the next sequence number, starting at 1, and the MCU's
 * own uptime when it was taken. The sequence is what makes a loss visible: a
 * reader that asks for everything after the last number it saw either gets the
 * next number, or is told which numbers it will never get.
 *
 * 600 samples is ten minutes at 1 Hz, so a reader stopped for a restart or an
 * upgrade comes back to an unbroken record. Each sample is 16 bytes of RAM, so
 * the ring is 9600 bytes of the chip's 786 KB.
 */
#define APP_TEMPLOG_SIZE      600
#define APP_TEMPLOG_PERIOD_MS 1000

/* The most samples one `app temp log` prints. The whole ring at once would be
 * 600 lines, about 20 KB and two seconds of the 115200 link in one reply, and
 * a reader's timeout has to allow for the longest reply it can get. 32 lines
 * is about a tenth of a second. APP_TEMPLOG_END_FMT says how many are left.
 */
#define APP_TEMPLOG_BATCH 32

/* `app temp log [since]` prints, in this order:
 *
 *   APP_TEMPLOG_GAP_FMT  once, only if samples after `since` were overwritten
 *                        before anyone asked for them: the first and the last
 *                        sequence number lost, inclusive
 *   APP_TEMPLOG_FMT      one per sample, oldest first, at most
 *                        APP_TEMPLOG_BATCH of them
 *   APP_TEMPLOG_ERR_FMT  in place of a sample whose sensor read failed. It
 *                        keeps its sequence number, so a failed read is never
 *                        mistaken for a lost one, nor a lost one for a failure
 *   APP_TEMPLOG_END_FMT  always, last: the newest sequence number held, and
 *                        how many samples newer than this batch are waiting
 *
 * With no `since` it starts at the oldest sample held and reports no gap. With
 * one, it starts after it - so `since` 0 means "from boot", and does report
 * whatever was lost since boot. A `since` beyond the newest sample is refused
 * with APP_ERR: the MCU has restarted since that number was read, and its
 * sequence has started again.
 *
 * Sequence numbers are unsigned 32-bit; at 1 Hz they wrap after 136 years.
 * The uptime is k_uptime_get(), signed 64-bit milliseconds.
 */
#define APP_TEMPLOG_FMT     "seq=%u ms=%lld temp_mc=%d"
#define APP_TEMPLOG_ERR_FMT "seq=%u ms=%lld temp_err=%d"
#define APP_TEMPLOG_GAP_FMT "gap first=%u last=%u"
#define APP_TEMPLOG_END_FMT "end head=%u more=%u"

/* `app temp log stat`: the newest sequence number (0 before the first
 * sample), how many samples are held, the ring's size, how many were
 * overwritten (whether anyone had read them or not), and the sampling period.
 * head - count is always dropped; it is printed so nobody has to know that.
 */
#define APP_TEMPLOG_STAT_FMT "head=%u count=%u size=%u dropped=%u period_ms=%u"

/* --- the air around the board: `app env` ----------------------------------
 *
 * A BME680 breakout on the header's I2C (i2c2: SDA PB11, SCL PB10), read with
 * Zephyr's driver - see mcu/app/include/env.h. Parsed by unoq.MCU.env() into
 * an EnvReading, and served to a phone over Bluetooth by unoq-ble-sensor.
 *
 * One line, all four channels from the same measurement, in integers for the
 * same reasons as APP_TEMP_FMT: millidegrees Celsius, thousandths of a percent
 * of relative humidity, pascals, and the gas sensor's resistance in ohms. Each
 * is the driver's own resolution or finer. Humidity is capped by the driver
 * at APP_ENV_HUMIDITY_MPCT_MAX.
 *
 * The keys are not APP_TEMP_FMT's line on its own, and the regexes on both
 * sides are anchored, so neither reply can pass for the other.
 *
 * With no sensor, or a read that fails, the reply is APP_ERR followed by
 * APP_ENV_ERR_FMT with the negative errno: -19 (ENODEV) when no BME680
 * answered at its address at boot, anything else from the read itself.
 * The firmware boots, and every other command works, either way.
 */
#define APP_ENV_FMT               "temp_mc=%d humidity_mpct=%u pressure_pa=%u gas_ohm=%u"
#define APP_ENV_ERR_FMT           "env_err=%d"
#define APP_ENV_HUMIDITY_MPCT_MAX 100000

/* --- why the MCU last reset ----------------------------------------------
 *
 * `app reset` prints this one line, parsed by unoq.MCU.reset_cause() into a
 * list of names. The value is the causes RCC recorded for the reset that
 * started this boot, comma-separated, most telling first: "watchdog,pin",
 * "software,pin", "brownout,pin". The names, their order and why "pin" is
 * nearly always there are in mcu/app/include/guard.h. "none" means no flag
 * was set; "unknown" means a flag guard.h has no name for, or that the flags
 * could not be read at all.
 *
 * One token with no spaces and no '=', so it reads the same way the status
 * line's values do. The cause is read once at boot and cleared in the
 * hardware then, so it describes this boot until the next reset, however
 * many times it is asked.
 */
#define APP_RESET_FMT "reset=%s"

/* `app hang yes` stalls the MCU on purpose, to show the watchdog firing: it
 * locks the scheduler and spins, so the beat that feeds the watchdog never
 * runs again. The word "yes" is required, because the command takes the
 * shell and the panel down with it. This is the one line it prints first. */
#define APP_HANG_FMT "hanging: the watchdog resets the MCU in %d ms"

/* --- jitter: the MCU times what Linux schedules ----------------------------
 *
 * Two histograms of the same shape, kept side by side (see jitter.h):
 *
 *   tick  Linux sends `app jitter tick` on a fixed schedule. Each arrival is
 *         timestamped on TIM5, a free-running 32-bit counter at 1 MHz, and
 *         the interval since the previous one is compared with the period
 *         `app jitter arm` was given.
 *   pwm   TIM3 drives a square wave out of D3 (PB0, TIM3_CH3), and with a
 *         jumper from D3 to D2, TIM2 captures its period on D2 (PB3,
 *         TIM2_CH2) in hardware. The same comparison, for timing that never
 *         goes through software.
 *
 * The commands, and the line each answers with:
 *
 *   app jitter arm <period_us>   APP_JITTER_ARM_FMT. Clears both histograms.
 *   app jitter tick              nothing on success: Linux does not wait for
 *                                a reply (MCU.jitter_tick())
 *   app jitter pwm <hz>          APP_JITTER_PWM_FMT, with the period the timer
 *                                really runs at. Clears the pwm histogram.
 *   app jitter stat              APP_JITTER_FMT twice: src=tick, then src=pwm
 *   app jitter off               APP_JITTER_OFF_FMT. Stops the PWM, the
 *                                capture and the ticks; the histograms stay,
 *                                to be read
 *
 * A deviation is the measured interval minus the expected period, in
 * nanoseconds: negative is early, positive late. A tick's is whole
 * microseconds, the counter's resolution; a captured period's is 6.25 ns, one
 * cycle of the 160 MHz timer clock. Each is clamped to the range of an int32
 * (about +-2.1 s), far past the last bin anyway.
 *
 * The bins are by size and sign. APP_JITTER_EDGES_US are the edges in
 * microseconds, and a deviation d goes in the bin of the first edge E with
 * |d| <= E, on its own side of zero; the middle bin, |d| <= 50, has both
 * signs. Past the last edge is one more bin each side. The APP_JITTER_BINS
 * counts run from the earliest to the latest, in microseconds:
 *
 *   0: d < -5000           5: -200 <= d < -100     10: 200 < d <= 500
 *   1: -5000 <= d < -2000  6: -100 <= d < -50      11: 500 < d <= 1000
 *   2: -2000 <= d < -1000  7: -50 <= d <= 50       12: 1000 < d <= 2000
 *   3: -1000 <= d < -500   8: 50 < d <= 100        13: 2000 < d <= 5000
 *   4: -500 <= d < -200    9: 100 < d <= 200       14: 5000 < d
 */
#define APP_JITTER_EDGES_US {50, 100, 200, 500, 1000, 2000, 5000}
#define APP_JITTER_EDGES    7
#define APP_JITTER_BINS     (2 * APP_JITTER_EDGES + 1)

/* What `app jitter arm` and `app jitter pwm` accept. The period floor is a
 * shell command's own cost: below it, what is measured is the shell. The PWM
 * range is TIM3's: a 16-bit timer counting at 1 MHz holds a period of at most
 * 65535 us, just over 15 Hz; and every captured period is an interrupt, so the
 * top is kept well under the panel's 100 kHz refresh.
 */
#define APP_JITTER_PERIOD_US_MIN 100
#define APP_JITTER_PERIOD_US_MAX 10000000
#define APP_JITTER_PWM_HZ_MIN    16
#define APP_JITTER_PWM_HZ_MAX    10000

/* One histogram. `period_us` is what each interval is compared with, 0 when
 * there has been none (never armed, or the PWM never started); it stays
 * through `app jitter off`. `n` counts intervals, one fewer than the ticks
 * that made them. With n = 0, min, max and mean are 0. The mean is the sum
 * over n, rounded toward zero. `bins` is the APP_JITTER_BINS counts,
 * comma-separated, in the order above. */
#define APP_JITTER_FMT      "jitter src=%s period_us=%u n=%u min_ns=%d max_ns=%d mean_ns=%d bins=%s"
#define APP_JITTER_SRC_TICK "tick"
#define APP_JITTER_SRC_PWM  "pwm"

#define APP_JITTER_ARM_FMT "ok jitter arm period_us=%u"
#define APP_JITTER_PWM_FMT "ok jitter pwm hz=%u period_us=%u"
#define APP_JITTER_OFF_FMT "ok jitter off"

/* --- the scope: the DAC and the ADC share a pin ----------------------------
 *
 * PA4, header A0, is both dac1 output 1 and adc1 channel 9. The DAC plays a
 * waveform table out of it, paced by TIM7 and fed by DMA; the ADC samples the
 * same pin in bursts, paced by TIM6 and emptied by DMA into RAM. So the MCU
 * watches its own output with no wire. The samples go up the SPI link
 * (SPI_PROTO_SCOPE in spi_proto.h), not this shell: a whole burst is 8 KB,
 * most of a second of the 115200 line. See scope.h.
 *
 * The commands, and the line each answers with:
 *
 *   app scope gen <wave> <hz>   APP_SCOPE_GEN_FMT. wave is APP_SCOPE_WAVE_SINE
 *                               or APP_SCOPE_WAVE_TRIANGLE; hz the waveform's
 *                               frequency. Replaces whatever was playing.
 *   app scope capture <n> <rate_hz>
 *                               APP_SCOPE_CAPTURE_FMT, once the n samples are
 *                               in: it blocks for n / rate_hz seconds
 *   app scope stat              APP_SCOPE_STAT_FMT
 *   app scope off               APP_SCOPE_OFF_FMT. Stops the DAC; the last
 *                               capture stays, to be read
 *
 * The rates the timers really run at are not always the ones asked for: a
 * timer divides its 160 MHz clock by whole numbers. Every "actual" rate is
 * printed in hertz with three decimals, as %u.%03u, because this build has no
 * floating-point printf.
 *
 * The table is APP_SCOPE_POINTS 12-bit DAC codes around APP_SCOPE_DAC_MID,
 * APP_SCOPE_DAC_AMPLITUDE either side: about 0.33 V to 2.97 V with a 3.3 V
 * reference, kept off the rails, where the output buffer is not linear. The
 * ADC is 14-bit, so a sample reads about four times the DAC code behind it.
 */
#define APP_SCOPE_POINTS        64
#define APP_SCOPE_DAC_MID       2048
#define APP_SCOPE_DAC_AMPLITUDE 1638
#define APP_SCOPE_DAC_MAX       4095
#define APP_SCOPE_ADC_MAX       16383

/* What `app scope gen` takes. The DAC is updated APP_SCOPE_POINTS times a
 * period, so the top is a 640 kHz update rate, under the DAC's rated
 * 1 Msps with its output buffer on. */
#define APP_SCOPE_WAVE_HZ_MIN 1
#define APP_SCOPE_WAVE_HZ_MAX 10000

/* What `app scope capture` takes. The burst buffer holds APP_SCOPE_N_MAX
 * samples, 8 KB. The top rate leaves room under the ADC's own conversion
 * time: 68 cycles of sampling and about 17 of conversion at 14 bits, on a
 * 40 MHz ADC clock, is about 2 us. And a capture borrows adc1 from the die
 * temperature for its whole length, so its length is held to
 * APP_SCOPE_BURST_MS_MAX: a temperature sample is late by at most that much,
 * never lost. */
#define APP_SCOPE_N_MIN        16
#define APP_SCOPE_N_MAX        4096
#define APP_SCOPE_RATE_HZ_MIN  100
#define APP_SCOPE_RATE_HZ_MAX  250000
#define APP_SCOPE_BURST_MS_MAX 500

#define APP_SCOPE_WAVE_OFF      "off"
#define APP_SCOPE_WAVE_SINE     "sine"
#define APP_SCOPE_WAVE_TRIANGLE "triangle"

static inline bool app_scope_wave_hz_valid(int hz)
{
	return hz >= APP_SCOPE_WAVE_HZ_MIN && hz <= APP_SCOPE_WAVE_HZ_MAX;
}

/* n samples at rate_hz: each in range, and the burst no longer than
 * APP_SCOPE_BURST_MS_MAX. */
static inline bool app_scope_capture_valid(int n, int rate_hz)
{
	return n >= APP_SCOPE_N_MIN && n <= APP_SCOPE_N_MAX && rate_hz >= APP_SCOPE_RATE_HZ_MIN &&
	       rate_hz <= APP_SCOPE_RATE_HZ_MAX &&
	       (int64_t)n * 1000 <= (int64_t)APP_SCOPE_BURST_MS_MAX * rate_hz;
}

/* `app scope gen`: the wave, the frequency asked for, and the one TIM7 gives.
 *
 * `app scope capture`: the capture's id (1, 2, ... since boot, and what the
 * SPI service is asked for), its samples, the rate TIM6 gives, and the
 * smallest, largest and mean sample, so the shell alone shows whether it
 * worked.
 *
 * `app scope stat`: the wave playing and the frequency TIM7 gives it
 * (APP_SCOPE_WAVE_OFF at 0.000 if none), the capture held (id 0, n 0, rate
 * 0.000 if none can be read), whether a capture is running, and how many
 * have failed since boot. */
#define APP_SCOPE_GEN_FMT     "ok scope gen wave=%s hz=%u actual_hz=%u.%03u"
#define APP_SCOPE_CAPTURE_FMT "ok scope capture id=%u n=%u rate_hz=%u.%03u min=%u max=%u mean=%u"
#define APP_SCOPE_STAT_FMT "scope wave=%s hz=%u.%03u id=%u n=%u rate_hz=%u.%03u busy=%u failed=%u"
#define APP_SCOPE_OFF_FMT  "ok scope off"

/* --- LED matrix ----------------------------------------------------------
 *
 * 104 blue LEDs, charlieplexed on PF0..PF10 and refreshed by a timer ISR - see
 * mcu/app/src/matrix.c. Geometry is fixed by the panel, so it lives here where
 * both sides and the tests can see it.
 *
 * LED index i is row-major: row = i / APP_MATRIX_COLS, col = i % APP_MATRIX_COLS.
 * Row 0 / column 0 is the corner nearest the USB-C connectors; `app matrix px`
 * exists to confirm that on a board rather than trusting this comment.
 */
#define APP_MATRIX_ROWS 8
#define APP_MATRIX_COLS 13
#define APP_MATRIX_LEDS (APP_MATRIX_ROWS * APP_MATRIX_COLS)

/* 3-bit grayscale: 0 is off, APP_MATRIX_MAX_LEVEL is fully on. */
#define APP_MATRIX_MAX_LEVEL 7

/* Refresh sweeps per second while the panel is on - one sweep per pass over
 * all 104 LEDs, at the 10us slot matrix.c programs. `app status` reports the
 * running count, and this is what to expect it to climb by each second: it is
 * the only evidence from the far end of a serial cable that the panel is
 * really being driven. See matrix.h. */
#define APP_MATRIX_SWEEPS_PER_S 962

static inline bool app_matrix_level_valid(int level)
{
	return level >= 0 && level <= APP_MATRIX_MAX_LEVEL;
}

static inline bool app_matrix_pixel_valid(int row, int col)
{
	return row >= 0 && row < APP_MATRIX_ROWS && col >= 0 && col < APP_MATRIX_COLS;
}

/* --- a whole frame -------------------------------------------------------
 *
 * `app matrix frame <r0> <r1> ... <r7>` draws a whole picture in one command:
 * eight words, one per row from row 0, each exactly APP_MATRIX_COLS characters
 * and each character a level '0'..'7'. A heart, row by row:
 *
 *   app matrix frame 0000000000000 0007700077000 0077770777700 0077777777700
 *                    0007777777000 0000777770000 0000077700000 0000007000000
 *
 * Digits rather than hex or a packed encoding so that the command stays one a
 * person can type and read, the same reason `app bars` takes whole percent.
 *
 * It fits the shell's limits with room to spare: the line is 17 + 8 * 14 = 129
 * bytes against CONFIG_SHELL_CMD_BUFF_SIZE (256 by default), it is 11 words
 * against CONFIG_SHELL_ARGC_MAX (20), and it arrives into a 256-byte serial
 * receive ring. python/tests/test_contract.py fails if prj.conf ever sets
 * either of the first two below what this needs.
 *
 * Every row is checked before any pixel changes, so a bad row leaves the panel
 * as it was and the reply is an APP_ERR line. On success the reply is
 * APP_MATRIX_FRAME_FMT with the number of LEDs lit (level above 0), which
 * unoq.MCU.matrix_frame() compares with what it sent.
 */
#define APP_MATRIX_FRAME_FMT "ok frame lit=%d"

/* One row of `app matrix frame`: exactly APP_MATRIX_COLS level digits. A short
 * row stops at its terminator, which is not a digit, so this never reads past
 * the end of the string it was given. */
static inline bool app_matrix_row_valid(const char *s)
{
	if (s == NULL) {
		return false;
	}
	for (int i = 0; i < APP_MATRIX_COLS; i++) {
		if (s[i] < '0' || s[i] > '0' + APP_MATRIX_MAX_LEVEL) {
			return false;
		}
	}
	return s[APP_MATRIX_COLS] == '\0';
}

/* Turn APP_MATRIX_ROWS rows, every one already passed by app_matrix_row_valid(),
 * into the APP_MATRIX_LEDS levels matrix_draw() takes. With flip set the frame
 * is turned 180 degrees, LED i to LED APP_MATRIX_LEDS - 1 - i, which is what
 * `app matrix px` does with one pixel. Returns the number of LEDs lit. */
static inline int app_matrix_frame_fill(const char *const *rows, bool flip, uint8_t *out)
{
	int lit = 0;

	for (int row = 0; row < APP_MATRIX_ROWS; row++) {
		for (int col = 0; col < APP_MATRIX_COLS; col++) {
			int idx = row * APP_MATRIX_COLS + col;
			uint8_t level = (uint8_t)(rows[row][col] - '0');

			out[flip ? APP_MATRIX_LEDS - 1 - idx : idx] = level;
			lit += level > 0;
		}
	}
	return lit;
}

/* --- CPU bars -------------------------------------------------------------
 *
 * `app bars <pct> [pct ...]` draws one vertical bar per value. The MPU sends
 * whole percentages - it owns the measurement (python/unoq/cpu.py), the MCU
 * owns the pixels. Keeping the wire format integer percent means the shell
 * command is still something a human can type by hand while debugging.
 *
 * The cap is the panel's, not the host's. Bars are one column wide at minimum
 * and always separated by one blank column, so n bars need 2n-1 columns: 7 is
 * the most that fit. A host with more cores than that has to aggregate.
 */
#define APP_BARS_MAX     ((APP_MATRIX_COLS + 1) / 2)
#define APP_BARS_PCT_MAX 100

static inline bool app_bars_pct_valid(int pct)
{
	return pct >= 0 && pct <= APP_BARS_PCT_MAX;
}

static inline bool app_bars_count_valid(int n)
{
	return n >= 1 && n <= APP_BARS_MAX;
}

/* Settings key (NVS, storage_partition).
 *
 * The panel's orientation is persisted because it is a property of how the
 * board is mounted, not of the running session: whoever fits the board decides
 * it once with `app matrix flip` and it survives power cycles and updates.
 */
#define APP_SETTINGS_FLIP "app/flip"

#endif /* APP_PROTO_H */
