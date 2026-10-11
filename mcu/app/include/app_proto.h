/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * The MPU <-> MCU contract, in one place.
 *
 * Everything here is consumed by three parties that must agree:
 *
 *   - mcu/app/src/main.c        produces the status and temp lines, validates bars
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

#include <stdbool.h>

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
