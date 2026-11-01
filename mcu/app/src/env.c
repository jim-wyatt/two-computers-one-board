/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * `app env`'s pure half: what the BME680 driver hands back, turned into the
 * line Linux reads. See env.h, and APP_ENV_FMT in app_proto.h.
 *
 * Compiled twice: into the firmware, and by mcu/tests/env/ for native_sim.
 */
#include <errno.h>
#include <stdio.h>

#include "app_proto.h"
#include "env.h"

/* A sensor_value is val1 whole units and val2 millionths, both carrying the
 * sign. Scaled by 1000 - degrees to millidegrees, percent to thousandths of
 * one, kilopascals to pascals - into an int64, so nothing can overflow before
 * the range check. val2 / 1000 truncates toward zero, which drops nothing:
 * the driver never gives these channels a finer resolution than that. */
static int64_t milli(const struct sensor_value *v)
{
	return (int64_t)v->val1 * 1000 + v->val2 / 1000;
}

int env_from_values(const struct sensor_value *temp, const struct sensor_value *humidity,
		    const struct sensor_value *press, const struct sensor_value *gas,
		    struct env_reading *out)
{
	int64_t temp_mc = milli(temp);
	int64_t humidity_mpct = milli(humidity);
	int64_t pressure_pa = milli(press);
	/* Ohms are whole: the driver puts the resistance in val1 and 0 in val2. */
	int64_t gas_ohm = gas->val1;

	if (temp_mc < INT32_MIN || temp_mc > INT32_MAX) {
		return -ERANGE;
	}
	if (humidity_mpct < 0 || humidity_mpct > APP_ENV_HUMIDITY_MPCT_MAX) {
		return -ERANGE;
	}
	if (pressure_pa < 0 || pressure_pa > UINT32_MAX || gas_ohm < 0) {
		return -ERANGE;
	}

	out->temp_mc = (int32_t)temp_mc;
	out->humidity_mpct = (uint32_t)humidity_mpct;
	out->pressure_pa = (uint32_t)pressure_pa;
	out->gas_ohm = (uint32_t)gas_ohm;
	return 0;
}

int env_format(const struct env_reading *r, char *buf, size_t len)
{
	int n = snprintf(buf, len, APP_ENV_FMT, (int)r->temp_mc, (unsigned int)r->humidity_mpct,
			 (unsigned int)r->pressure_pa, (unsigned int)r->gas_ohm);

	if (n < 0 || (size_t)n >= len) {
		if (len > 0) {
			buf[0] = '\0';
		}
		return -ENOSPC;
	}
	return n;
}
