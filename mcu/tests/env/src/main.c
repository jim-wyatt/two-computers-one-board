/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * Host-runnable tests for `app env`'s pure half: the BME680 driver's values
 * to the line Linux reads.
 *
 * There is no emulator for the part, so the inputs here are the sensor_values
 * Zephyr's driver builds (drivers/sensor/bosch/bme680, bme680_channel_get):
 * temperature from hundredths of a degree, humidity from thousandths of a
 * percent, pressure from pascals as kilopascals, resistance in whole ohms.
 * The lines are written out in full, so the format is pinned here as well as
 * by python/tests/test_contract.py on the other side.
 *
 * Runs on native_sim via ~/two-computers-one-board/mcu/ztest.sh - no board, no flash cycle.
 */
#include <zephyr/ztest.h>
#include <errno.h>
#include <string.h>

#include "app_proto.h"
#include "env.h"

/* What bme680_channel_get() makes of the driver's integers. */
static struct sensor_value temp_c100(int32_t c100)
{
	return (struct sensor_value){.val1 = c100 / 100, .val2 = c100 % 100 * 10000};
}

static struct sensor_value humidity_m(int32_t mpct)
{
	return (struct sensor_value){.val1 = mpct / 1000, .val2 = mpct % 1000 * 1000};
}

static struct sensor_value press_pa(int32_t pa)
{
	return (struct sensor_value){.val1 = pa / 1000, .val2 = pa % 1000 * 1000};
}

static struct sensor_value gas_ohm(int32_t ohm)
{
	return (struct sensor_value){.val1 = ohm, .val2 = 0};
}

static int convert(int32_t c100, int32_t mpct, int32_t pa, int32_t ohm, struct env_reading *r)
{
	struct sensor_value t = temp_c100(c100), h = humidity_m(mpct), p = press_pa(pa),
			    g = gas_ohm(ohm);

	return env_from_values(&t, &h, &p, &g, r);
}

static void assert_line(const struct env_reading *r, const char *want)
{
	char buf[APP_ENV_LINE_MAX];
	int n = env_format(r, buf, sizeof(buf));

	zassert_equal(n, (int)strlen(want), "length %d for %s", n, buf);
	zassert_str_equal(buf, want);
}

ZTEST(env, test_a_room_reads_back_in_the_units_linux_is_told)
{
	struct env_reading r;

	zassert_ok(convert(2153, 45123, 101325, 52345, &r));
	zassert_equal(r.temp_mc, 21530);
	zassert_equal(r.humidity_mpct, 45123U);
	zassert_equal(r.pressure_pa, 101325U);
	zassert_equal(r.gas_ohm, 52345U);
	assert_line(&r, "temp_mc=21530 humidity_mpct=45123 pressure_pa=101325 gas_ohm=52345");
}

/* A sensor_value carries the sign in both halves, so -0.5 C is 0 and
 * -500000. Taking val2 as a positive fraction would read it as +0.5 C. */
ZTEST(env, test_below_zero_keeps_its_sign_in_both_halves)
{
	struct env_reading r;

	zassert_ok(convert(-50, 0, 30000, 0, &r));
	zassert_equal(r.temp_mc, -500);
	zassert_ok(convert(-4000, 0, 30000, 0, &r));
	assert_line(&r, "temp_mc=-40000 humidity_mpct=0 pressure_pa=30000 gas_ohm=0");
}

ZTEST(env, test_the_driver_cap_on_humidity_is_a_reading)
{
	struct env_reading r;

	zassert_ok(convert(2500, APP_ENV_HUMIDITY_MPCT_MAX, 100000, 1, &r));
	zassert_equal(r.humidity_mpct, 100000U);
}

ZTEST(env, test_a_value_no_bme680_gives_is_refused_and_leaves_the_reading_alone)
{
	struct env_reading r = {.temp_mc = 1, .humidity_mpct = 2, .pressure_pa = 3, .gas_ohm = 4};

	zassert_equal(convert(2500, APP_ENV_HUMIDITY_MPCT_MAX + 1, 100000, 1, &r), -ERANGE);
	zassert_equal(convert(2500, -1, 100000, 1, &r), -ERANGE);
	zassert_equal(convert(2500, 50000, -1, 1, &r), -ERANGE);
	zassert_equal(convert(2500, 50000, 100000, -1, &r), -ERANGE);
	zassert_equal(r.temp_mc, 1);
	zassert_equal(r.humidity_mpct, 2U);
	zassert_equal(r.pressure_pa, 3U);
	zassert_equal(r.gas_ohm, 4U);
}

ZTEST(env, test_a_temperature_past_an_int32_of_millidegrees_is_refused)
{
	struct sensor_value t = {.val1 = 2147484, .val2 = 0}, h = humidity_m(0), p = press_pa(0),
			    g = gas_ohm(0);
	struct env_reading r;

	zassert_equal(env_from_values(&t, &h, &p, &g, &r), -ERANGE);
	t.val1 = -2147484;
	zassert_equal(env_from_values(&t, &h, &p, &g, &r), -ERANGE);
	t.val1 = 2147483;
	t.val2 = 647000;
	zassert_ok(env_from_values(&t, &h, &p, &g, &r));
	zassert_equal(r.temp_mc, INT32_MAX);
}

/* Every field at its widest has to fit the buffer the shell handler uses. */
ZTEST(env, test_the_widest_line_fits_app_env_line_max)
{
	struct env_reading r = {.temp_mc = INT32_MIN,
				.humidity_mpct = UINT32_MAX,
				.pressure_pa = UINT32_MAX,
				.gas_ohm = UINT32_MAX};
	char buf[APP_ENV_LINE_MAX];

	zassert_true(env_format(&r, buf, sizeof(buf)) > 0);
	zassert_str_equal(buf, "temp_mc=-2147483648 humidity_mpct=4294967295 "
			       "pressure_pa=4294967295 gas_ohm=4294967295");
}

ZTEST(env, test_a_short_buffer_is_refused_and_left_empty)
{
	struct env_reading r = {
		.temp_mc = 21530, .humidity_mpct = 45123, .pressure_pa = 101325, .gas_ohm = 52345};
	char buf[16];

	memset(buf, 'x', sizeof(buf));
	zassert_equal(env_format(&r, buf, sizeof(buf)), -ENOSPC);
	zassert_equal(buf[0], '\0');
	zassert_equal(env_format(&r, buf, 0), -ENOSPC);
}

/* The line one byte too long for the buffer is refused, not cut short: a
 * truncated gas figure would still parse, as the wrong number. */
ZTEST(env, test_one_byte_short_is_refused_not_truncated)
{
	struct env_reading r = {
		.temp_mc = 21530, .humidity_mpct = 45123, .pressure_pa = 101325, .gas_ohm = 52345};
	const char *want = "temp_mc=21530 humidity_mpct=45123 pressure_pa=101325 gas_ohm=52345";
	char buf[APP_ENV_LINE_MAX];

	zassert_equal(env_format(&r, buf, strlen(want)), -ENOSPC);
	zassert_equal(env_format(&r, buf, strlen(want) + 1), (int)strlen(want));
}

ZTEST_SUITE(env, NULL, NULL, NULL, NULL, NULL);
