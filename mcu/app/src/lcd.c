/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * `app lcd`'s pure half: colors, bytes, and which controller answered. See
 * lcd.h, and APP_LCD_* in app_proto.h.
 *
 * Compiled twice: into the firmware, and by mcu/tests/lcd/ for native_sim.
 */
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <zephyr/sys/util.h>

#include "app_proto.h"
#include "lcd.h"

/* 8 bits a channel down to 5, 6 and 5, keeping the top of each. */
static uint16_t rgb565(uint8_t r, uint8_t g, uint8_t b)
{
	return (uint16_t)(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3));
}

static const struct {
	const char *name;
	uint32_t rgb;
} colors[] = {
	{"black", 0x000000}, {"white", 0xFFFFFF},  {"red", 0xFF0000},  {"green", 0x00FF00},
	{"blue", 0x0000FF},  {"yellow", 0xFFFF00}, {"cyan", 0x00FFFF}, {"magenta", 0xFF00FF},
};

static int hex_digit(char c)
{
	if (c >= '0' && c <= '9') {
		return c - '0';
	}
	if (c >= 'a' && c <= 'f') {
		return c - 'a' + 10;
	}
	if (c >= 'A' && c <= 'F') {
		return c - 'A' + 10;
	}
	return -1;
}

/* Exactly n hex digits, nothing after them. */
static bool parse_hex(const char *s, size_t n, uint32_t *out)
{
	uint32_t v = 0;

	if (s == NULL || strlen(s) != n) {
		return false;
	}
	for (size_t i = 0; i < n; i++) {
		int d = hex_digit(s[i]);

		if (d < 0) {
			return false;
		}
		v = (v << 4) | (uint32_t)d;
	}
	*out = v;
	return true;
}

bool lcd_parse_color(const char *s, uint16_t *out)
{
	uint32_t rgb;

	if (s == NULL) {
		return false;
	}
	for (size_t i = 0; i < ARRAY_SIZE(colors); i++) {
		if (strcmp(s, colors[i].name) == 0) {
			rgb = colors[i].rgb;
			goto found;
		}
	}
	if (!parse_hex(s, 6, &rgb)) {
		return false;
	}
found:
	*out = rgb565((uint8_t)(rgb >> 16), (uint8_t)(rgb >> 8), (uint8_t)rgb);
	return true;
}

bool lcd_parse_byte(const char *s, uint8_t *out)
{
	uint32_t v;

	if (!parse_hex(s, 1, &v) && !parse_hex(s, 2, &v)) {
		return false;
	}
	*out = (uint8_t)v;
	return true;
}

void lcd_pack565(uint16_t c, bool msb_first, uint8_t out[2])
{
	out[msb_first ? 0 : 1] = (uint8_t)(c >> 8);
	out[msb_first ? 1 : 0] = (uint8_t)c;
}

int lcd_id_find(const uint8_t *raw, size_t n, uint16_t id)
{
	uint64_t bits = 0;

	if (n < 2 || n > 8) {
		return -1;
	}
	for (size_t i = 0; i < n; i++) {
		bits = (bits << 8) | raw[i];
	}
	for (size_t off = 0; off + 16 <= n * 8; off++) {
		if ((uint16_t)(bits >> (n * 8 - 16 - off)) == id) {
			return (int)off;
		}
	}
	return -1;
}

/* What RDID4 carries on the parts this panel size comes with. The ST7796S
 * is what Waveshare's 3.5" capacitive module is sold with; the ILI parts
 * are what the cheaper 3.5" modules use, and answer the same command. */
static const struct {
	uint16_t id4;
	const char *name;
} controllers[] = {
	{0x7796, "st7796s"},
	{0x9488, "ili9488"},
	{0x9486, "ili9486"},
};

const char *lcd_id_name(const struct lcd_id *id, int *dummy)
{
	bool same = true;

	*dummy = -1;
	for (size_t i = 0; i < LCD_ID_LEN; i++) {
		if (id->rddid[i] != id->id4[0] || id->id4[i] != id->id4[0]) {
			same = false;
		}
	}
	if (same) {
		return "none";
	}
	for (size_t i = 0; i < ARRAY_SIZE(controllers); i++) {
		int off = lcd_id_find(id->id4, LCD_ID_LEN, controllers[i].id4);

		if (off >= 0) {
			*dummy = off;
			return controllers[i].name;
		}
	}
	return "unknown";
}

int lcd_id_format(const struct lcd_id *id, char *buf, size_t len)
{
	int dummy;
	const char *name = lcd_id_name(id, &dummy);
	int n = snprintf(buf, len, APP_LCD_ID_FMT, id->rddid[0], id->rddid[1], id->rddid[2],
			 id->rddid[3], id->id4[0], id->id4[1], id->id4[2], id->id4[3], name, dummy);

	if (n < 0 || (size_t)n >= len) {
		if (len > 0) {
			buf[0] = '\0';
		}
		return -ENOSPC;
	}
	return n;
}
