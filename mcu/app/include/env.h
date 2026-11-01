/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * The air around the board: a BME680 on the header's I2C, read by `app env`.
 *
 * The part is Bosch's temperature, humidity, pressure and gas sensor, on a
 * breakout wired to SDA/SCL beside AREF (i2c2, PB11/PB10). Zephyr's driver
 * does the reading and the compensation; what is here is what the firmware
 * makes of the answer.
 *
 * TWO HALVES
 * ----------
 * env.c is pure: four sensor_values in, one reading out, and the reading to
 * the line `app env` prints. No device, no bus, no kernel object, so
 * mcu/tests/env/ runs it on native_sim. Zephyr has no emulator for this part,
 * so that is as close to the sensor as a test gets before there is one.
 *
 * env_sensor.c is the other half: the devices, the read, and the shell
 * command. It is only built into the firmware, and only proven on a board.
 *
 * The line's format is APP_ENV_FMT in app_proto.h.
 */

#ifndef ENV_H
#define ENV_H

#include <stddef.h>
#include <stdint.h>
#include <zephyr/drivers/sensor.h>

struct shell;

/* One reading, in the integer units `app env` prints. The driver's own
 * resolution is 0.01 C, 0.001 %RH, 1 Pa and 1 ohm, so none of these loses
 * anything it has. */
struct env_reading {
	int32_t temp_mc;        /* millidegrees Celsius */
	uint32_t humidity_mpct; /* thousandths of a percent relative humidity */
	uint32_t pressure_pa;   /* pascals */
	uint32_t gas_ohm;       /* the gas sensor's hot plate, in ohms */
};

/* The four channels as the driver hands them back - temperature in degrees,
 * humidity in percent, pressure in kilopascals, gas resistance in ohms - into
 * a reading. Returns 0, or -ERANGE for a value no BME680 can give: negative
 * humidity, pressure or resistance, humidity over 100 %, or a number too big
 * for its field. *out is untouched on failure, so a bad read is never half a
 * reading. */
int env_from_values(const struct sensor_value *temp, const struct sensor_value *humidity,
		    const struct sensor_value *press, const struct sensor_value *gas,
		    struct env_reading *out);

/* The reading as the APP_ENV_FMT line, NUL-terminated, without a newline.
 * Returns its length, or -ENOSPC if buf is too small for all of it (buf then
 * holds nothing). APP_ENV_LINE_MAX always fits. */
int env_format(const struct env_reading *r, char *buf, size_t len);

/* The longest line env_format() can write, with its terminator: every field
 * at its widest. */
#define APP_ENV_LINE_MAX 96

/* `app env` (env_sensor.c). */
int cmd_app_env(const struct shell *sh, size_t argc, char **argv);

/* One boot line saying whether the driver found the part, and at which
 * address, so the console shows it without anybody having to ask. */
void env_report(void);

#endif /* ENV_H */
