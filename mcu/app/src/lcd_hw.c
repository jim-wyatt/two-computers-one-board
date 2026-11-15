/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * `app lcd`: the 3.5" panel on spi2, driven when Linux - or anyone at the
 * shell - asks.
 *
 * Two devices from the overlay. lcd_dbi is the bus: spi2, a GPIO chip select
 * on D10, data/command on D9 and reset on D8. lcd_panel is Zephyr's ST7796S
 * driver on it, deferred, so nothing is said to the panel at boot and a board
 * with no LCD boots as it always did.
 *
 *   app lcd id                 read the controller's ID registers
 *   app lcd on                 start the driver, backlight on
 *   app lcd fill <color>      the whole screen one color
 *   app lcd off                blank the panel, backlight off
 *   app lcd cmd <cmd> [b ...]  one raw command, in hex, for bring-up
 *
 * The pure half - colors, bytes, and which controller answered - is lcd.c.
 */
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/display.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/mipi_dbi.h>
#include <zephyr/drivers/spi.h>
#include <zephyr/shell/shell.h>
#include <zephyr/sys/printk.h>

#include "app_proto.h"
#include "lcd.h"
#include "status_leds.h"

#define LCD_DBI   DT_NODELABEL(lcd_dbi)
#define LCD_PANEL DT_NODELABEL(lcd_panel)

/* Reads are slower than writes on these parts - the ST7796S wants 150 ns a
 * read clock against 66 ns a write - so the ID is asked for well under both.
 * The SPI driver rounds down to the prescaler it has: 2.5 MHz from 160. */
#define LCD_READ_HZ 4000000

/* Rows sent in one write by `app lcd fill`: 16 of 320 pixels, 10 KB. */
#define LCD_FILL_ROWS 16
#define LCD_MAX_W     DT_PROP(LCD_PANEL, width)

/* The most parameter bytes `app lcd cmd` takes. The gamma tables are 14. */
#define LCD_CMD_MAX_PARAMS 16

static const struct device *const dbi = DEVICE_DT_GET(LCD_DBI);
static const struct device *const panel = DEVICE_DT_GET(LCD_PANEL);
static const struct gpio_dt_spec backlight = GPIO_DT_SPEC_GET(DT_PATH(zephyr_user), lcd_bl_gpios);

/* The panel's own bus settings, as its driver builds them from the overlay;
 * `app lcd cmd` writes with them. reads are the same at LCD_READ_HZ, set in
 * lcd_report(). */
static const struct mipi_dbi_config write_cfg = {
	.mode = MIPI_DBI_MODE_SPI_4WIRE,
	.config = MIPI_DBI_SPI_CONFIG_DT(LCD_PANEL, SPI_OP_MODE_MASTER | SPI_WORD_SET(8), 0),
};
static struct mipi_dbi_config read_cfg = {
	.mode = MIPI_DBI_MODE_SPI_4WIRE,
	.config = MIPI_DBI_SPI_CONFIG_DT(LCD_PANEL, SPI_OP_MODE_MASTER | SPI_WORD_SET(8), 0),
};

static uint8_t fill_buf[LCD_FILL_ROWS * LCD_MAX_W * 2];

static int fail(const struct shell *sh, int rc)
{
	shell_error(sh, APP_ERR APP_LCD_ERR_FMT, rc);
	return rc;
}

/* The driver's init pulses reset, sends the power, gamma and timing tables,
 * and turns the display on; after that the panel shows whatever its memory
 * held, so the backlight comes on only once that has gone right. */
static int panel_start(void)
{
	int rc;

	if (!device_is_ready(dbi)) {
		return -ENODEV;
	}
	if (!device_is_ready(panel)) {
		rc = device_init(panel);
		/* -EALREADY with the device not ready is an init that already
		 * ran and failed: the driver does not get a second go. */
		if (rc == -EALREADY || !device_is_ready(panel)) {
			return -ENODEV;
		}
		if (rc < 0) {
			return rc;
		}
	}
	rc = display_blanking_off(panel);
	if (rc == 0 && gpio_is_ready_dt(&backlight)) {
		rc = gpio_pin_set_dt(&backlight, 1);
	}
	return rc;
}

int cmd_app_lcd_id(const struct shell *sh, size_t argc, char **argv)
{
	struct lcd_id id = {0};
	uint8_t cmd;
	char line[APP_LCD_LINE_MAX];
	int rc;

	ARG_UNUSED(argc);
	ARG_UNUSED(argv);
	status_leds_link_seen();

	if (!device_is_ready(dbi)) {
		return fail(sh, -ENODEV);
	}
	cmd = LCD_CMD_RDDID;
	rc = mipi_dbi_command_read(dbi, &read_cfg, &cmd, 1, id.rddid, sizeof(id.rddid));
	if (rc == 0) {
		cmd = LCD_CMD_RDID4;
		rc = mipi_dbi_command_read(dbi, &read_cfg, &cmd, 1, id.id4, sizeof(id.id4));
	}
	if (rc == 0) {
		rc = lcd_id_format(&id, line, sizeof(line));
	}
	if (rc < 0) {
		return fail(sh, rc);
	}
	shell_print(sh, "%s", line);
	return 0;
}

int cmd_app_lcd_on(const struct shell *sh, size_t argc, char **argv)
{
	struct display_capabilities caps;
	int rc;

	ARG_UNUSED(argc);
	ARG_UNUSED(argv);
	status_leds_link_seen();

	rc = panel_start();
	if (rc < 0) {
		return fail(sh, rc);
	}
	display_get_capabilities(panel, &caps);
	shell_print(sh, APP_LCD_ON_FMT, caps.x_resolution, caps.y_resolution);
	return 0;
}

int cmd_app_lcd_off(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);
	status_leds_link_seen();

	if (gpio_is_ready_dt(&backlight)) {
		gpio_pin_set_dt(&backlight, 0);
	}
	if (device_is_ready(panel)) {
		display_blanking_on(panel);
	}
	shell_print(sh, "ok");
	return 0;
}

int cmd_app_lcd_fill(const struct shell *sh, size_t argc, char **argv)
{
	struct display_capabilities caps;
	struct display_buffer_descriptor desc;
	uint16_t color;
	uint8_t px[2];
	int64_t t0;
	int rc;

	ARG_UNUSED(argc);
	status_leds_link_seen();

	if (!lcd_parse_color(argv[1], &color)) {
		shell_error(sh,
			    APP_ERR "'%s' is not a color: a name (red, green, blue, "
				    "white, black, yellow, cyan, magenta) or rrggbb",
			    argv[1]);
		return -EINVAL;
	}
	rc = panel_start();
	if (rc < 0) {
		return fail(sh, rc);
	}
	display_get_capabilities(panel, &caps);
	if (caps.x_resolution > LCD_MAX_W) {
		return fail(sh, -ENOTSUP);
	}

	/* The driver says which byte order it wants: RGB565X is red's byte
	 * first, RGB565 the other way round. */
	lcd_pack565(color, caps.current_pixel_format == PIXEL_FORMAT_RGB_565X, px);
	for (size_t i = 0; i < sizeof(fill_buf); i += 2) {
		fill_buf[i] = px[0];
		fill_buf[i + 1] = px[1];
	}

	t0 = k_uptime_get();
	for (uint16_t y = 0; y < caps.y_resolution && rc == 0; y += LCD_FILL_ROWS) {
		uint16_t rows = MIN(LCD_FILL_ROWS, caps.y_resolution - y);

		desc = (struct display_buffer_descriptor){
			.buf_size = (uint32_t)rows * caps.x_resolution * 2,
			.width = caps.x_resolution,
			.height = rows,
			.pitch = caps.x_resolution,
			.frame_incomplete = (y + rows) < caps.y_resolution,
		};
		rc = display_write(panel, 0, y, &desc, fill_buf);
	}
	if (rc < 0) {
		return fail(sh, rc);
	}
	shell_print(sh, APP_LCD_FILL_FMT, color, (unsigned int)(k_uptime_get() - t0));
	return 0;
}

int cmd_app_lcd_cmd(const struct shell *sh, size_t argc, char **argv)
{
	uint8_t cmd;
	uint8_t params[LCD_CMD_MAX_PARAMS];
	size_t n = argc - 2;
	int rc;

	status_leds_link_seen();

	if (n > LCD_CMD_MAX_PARAMS) {
		shell_error(sh, APP_ERR "at most %d parameter bytes", LCD_CMD_MAX_PARAMS);
		return -EINVAL;
	}
	if (!lcd_parse_byte(argv[1], &cmd)) {
		shell_error(sh, APP_ERR "command '%s' is not a hex byte", argv[1]);
		return -EINVAL;
	}
	for (size_t i = 0; i < n; i++) {
		if (!lcd_parse_byte(argv[i + 2], &params[i])) {
			shell_error(sh, APP_ERR "parameter %u: '%s' is not a hex byte",
				    (unsigned int)i, argv[i + 2]);
			return -EINVAL;
		}
	}
	if (!device_is_ready(dbi)) {
		return fail(sh, -ENODEV);
	}
	rc = mipi_dbi_command_write(dbi, &write_cfg, cmd, params, n);
	if (rc < 0) {
		return fail(sh, rc);
	}
	shell_print(sh, "ok");
	return 0;
}

void lcd_report(void)
{
	read_cfg.config.frequency = LCD_READ_HZ;

	/* Off until the panel has been told what to show. Left floating the
	 * module's own pull decides, and the screen lights up white. */
	if (gpio_is_ready_dt(&backlight)) {
		gpio_pin_configure_dt(&backlight, GPIO_OUTPUT_INACTIVE);
	}
	if (device_is_ready(dbi)) {
		printk("lcd: st7796s on spi2, not started - `app lcd id`, `app lcd on`\n");
	} else {
		printk("lcd: spi2 or its pins did not come up - `app lcd` will say so\n");
	}
}
