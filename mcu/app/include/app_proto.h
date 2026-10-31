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
