/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * `app env`: the BME680 on the header's I2C, read when Linux asks.
 *
 * The device is the overlay's env_bme680 node, at 0x77 unless the build chose
 * 0x76 (see boards/arduino_uno_q.overlay). At boot Zephyr's driver asks it
 * for its chip ID; with no BME680 there to answer, the device is not ready,
 * the firmware boots the same, and `app env` says there is no sensor.
 *
 * A read is a forced-mode measurement: the driver starts one, waits for it,
 * and reads all four channels from it, so they describe the same moment. It
 * takes a little under 200 ms with the driver's default oversampling and the
 * gas sensor's hot plate, and blocks only the shell thread.
 *
 * The pure half - the driver's values to the line Linux reads - is env.c.
 */
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/sensor.h>
#include <zephyr/shell/shell.h>
#include <zephyr/sys/printk.h>

#include "app_proto.h"
#include "env.h"
#include "status_leds.h"

#define ENV_NODE DT_NODELABEL(env_bme680)

static const struct device *const env_dev = DEVICE_DT_GET(ENV_NODE);

static int read_env(const struct device *dev, struct env_reading *r)
{
	struct sensor_value temp, humidity, press, gas;
	int rc;

	rc = sensor_sample_fetch(dev);
	if (rc == 0) {
		rc = sensor_channel_get(dev, SENSOR_CHAN_AMBIENT_TEMP, &temp);
	}
	if (rc == 0) {
		rc = sensor_channel_get(dev, SENSOR_CHAN_HUMIDITY, &humidity);
	}
	if (rc == 0) {
		rc = sensor_channel_get(dev, SENSOR_CHAN_PRESS, &press);
	}
	if (rc == 0) {
		rc = sensor_channel_get(dev, SENSOR_CHAN_GAS_RES, &gas);
	}
	if (rc == 0) {
		rc = env_from_values(&temp, &humidity, &press, &gas, r);
	}
	return rc;
}

int cmd_app_env(const struct shell *sh, size_t argc, char **argv)
{
	struct env_reading r;
	char line[APP_ENV_LINE_MAX];
	int rc;

	ARG_UNUSED(argc);
	ARG_UNUSED(argv);
	status_leds_link_seen();

	/* Not ready means no BME680 answered at boot: nothing wired, wired to
	 * the wrong pins, unpowered, or on the other address. A part plugged
	 * in after boot is not seen until the next one. */
	rc = device_is_ready(env_dev) ? read_env(env_dev, &r) : -ENODEV;
	if (rc == 0) {
		rc = env_format(&r, line, sizeof(line));
	}
	if (rc < 0) {
		shell_error(sh, APP_ERR APP_ENV_ERR_FMT, rc);
		return rc;
	}
	shell_print(sh, "%s", line);
	return 0;
}

void env_report(void)
{
	if (device_is_ready(env_dev)) {
		printk("env: BME680 at 0x%02x on i2c2\n", (unsigned int)DT_REG_ADDR(ENV_NODE));
	} else {
		printk("env: no BME680 at 0x%02x on i2c2 - `app env` will say so\n",
		       (unsigned int)DT_REG_ADDR(ENV_NODE));
	}
}
