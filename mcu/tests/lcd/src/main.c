/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * Host-runnable tests for `app lcd`'s pure half: colors to RGB565, RGB565
 * to the bytes on the wire, and the ID registers' bytes to a controller.
 *
 * The ID bytes are what an ST7796S reads back over 4-wire SPI with 8-bit
 * words. RDID4 (0xD3) gives a dummy byte and then 00 77 96; some parts and
 * some wirings put a single dummy bit first instead, which shifts all of it
 * one bit to the right, and lcd_id_find() has to find it either way.
 *
 * Runs on native_sim via ~/two-computers-one-board/mcu/ztest.sh - no board, no flash cycle.
 */
#include <zephyr/ztest.h>
#include <string.h>

#include "app_proto.h"
#include "lcd.h"

ZTEST(lcd, test_color_names)
{
	uint16_t c;

	zassert_true(lcd_parse_color("red", &c));
	zassert_equal(c, 0xF800);
	zassert_true(lcd_parse_color("green", &c));
	zassert_equal(c, 0x07E0);
	zassert_true(lcd_parse_color("blue", &c));
	zassert_equal(c, 0x001F);
	zassert_true(lcd_parse_color("white", &c));
	zassert_equal(c, 0xFFFF);
	zassert_true(lcd_parse_color("black", &c));
	zassert_equal(c, 0x0000);
	zassert_true(lcd_parse_color("magenta", &c));
	zassert_equal(c, 0xF81F);
}

ZTEST(lcd, test_color_hex)
{
	uint16_t c;

	zassert_true(lcd_parse_color("ff8000", &c));
	zassert_equal(c, 0xFC00, "orange: 31 red, 32 green, 0 blue");
	zassert_true(lcd_parse_color("0000FF", &c));
	zassert_equal(c, 0x001F);
	/* The low bits of each channel are dropped, not rounded. */
	zassert_true(lcd_parse_color("070307", &c));
	zassert_equal(c, 0x0000);
}

ZTEST(lcd, test_color_rejects)
{
	uint16_t c = 0x1234;

	zassert_false(lcd_parse_color("", &c));
	zassert_false(lcd_parse_color("Red", &c));
	zassert_false(lcd_parse_color("fff", &c));
	zassert_false(lcd_parse_color("ff00001", &c));
	zassert_false(lcd_parse_color("gg0000", &c));
	zassert_false(lcd_parse_color("#ff0000", &c));
	zassert_false(lcd_parse_color(NULL, &c));
	zassert_equal(c, 0x1234, "untouched on failure");
}

ZTEST(lcd, test_byte)
{
	uint8_t b = 0x5A;

	zassert_true(lcd_parse_byte("36", &b));
	zassert_equal(b, 0x36);
	zassert_true(lcd_parse_byte("a", &b));
	zassert_equal(b, 0x0A);
	zassert_true(lcd_parse_byte("FF", &b));
	zassert_equal(b, 0xFF);
	b = 0x5A;
	zassert_false(lcd_parse_byte("", &b));
	zassert_false(lcd_parse_byte("100", &b));
	zassert_false(lcd_parse_byte("0x3", &b));
	zassert_false(lcd_parse_byte("-1", &b));
	zassert_false(lcd_parse_byte("z", &b));
	zassert_equal(b, 0x5A, "untouched on failure");
}

ZTEST(lcd, test_pack565)
{
	uint8_t px[2];

	lcd_pack565(0xF800, true, px);
	zassert_equal(px[0], 0xF8, "RGB565X: red's byte first");
	zassert_equal(px[1], 0x00);
	lcd_pack565(0xF800, false, px);
	zassert_equal(px[0], 0x00, "RGB565: the low byte first");
	zassert_equal(px[1], 0xF8);
}

ZTEST(lcd, test_id_find_aligned_and_shifted)
{
	const uint8_t byte_dummy[] = {0x00, 0x00, 0x77, 0x96};
	/* A dummy bit before the dummy byte: 0 00000000 01110111 10010110,
	 * then the line idle low, read eight bits at a time. */
	const uint8_t bit_dummy[] = {0x00, 0x3B, 0xCB, 0x00};

	zassert_equal(lcd_id_find(byte_dummy, sizeof(byte_dummy), 0x7796), 16);
	zassert_equal(lcd_id_find(bit_dummy, sizeof(bit_dummy), 0x7796), 9);
	zassert_equal(lcd_id_find(byte_dummy, sizeof(byte_dummy), 0x9488), -1);
	zassert_equal(lcd_id_find(byte_dummy, 1, 0x7796), -1, "one byte holds no 16-bit ID");
}

ZTEST(lcd, test_id_name)
{
	struct lcd_id st = {.rddid = {0x00, 0x7C, 0x89, 0xF0}, .id4 = {0x00, 0x00, 0x77, 0x96}};
	struct lcd_id ili = {.rddid = {0x00, 0x00, 0x00, 0x00}, .id4 = {0xFF, 0x00, 0x94, 0x88}};
	struct lcd_id low = {0};
	struct lcd_id high;
	struct lcd_id other = {.rddid = {0x12, 0x34, 0x56, 0x78}, .id4 = {0x00, 0x00, 0x12, 0x34}};
	int dummy;

	memset(&high, 0xFF, sizeof(high));
	zassert_str_equal(lcd_id_name(&st, &dummy), "st7796s");
	zassert_equal(dummy, 16);
	zassert_str_equal(lcd_id_name(&ili, &dummy), "ili9488");
	zassert_str_equal(lcd_id_name(&low, &dummy), "none", "MISO held low");
	zassert_equal(dummy, -1);
	zassert_str_equal(lcd_id_name(&high, &dummy), "none", "MISO floating high");
	zassert_str_equal(lcd_id_name(&other, &dummy), "unknown");
	zassert_equal(dummy, -1);
}

ZTEST(lcd, test_id_format)
{
	struct lcd_id st = {.rddid = {0x00, 0x7C, 0x89, 0xF0}, .id4 = {0x00, 0x00, 0x77, 0x96}};
	struct lcd_id other = {.rddid = {0x12, 0x34, 0x56, 0x78}, .id4 = {0xAB, 0xCD, 0xEF, 0x01}};
	char line[APP_LCD_LINE_MAX];

	zassert_true(lcd_id_format(&st, line, sizeof(line)) > 0);
	zassert_str_equal(line, "rddid=007c89f0 id4=00007796 controller=st7796s dummy=16");
	zassert_true(lcd_id_format(&other, line, sizeof(line)) > 0);
	zassert_str_equal(line, "rddid=12345678 id4=abcdef01 controller=unknown dummy=-1");
	zassert_equal(lcd_id_format(&st, line, 10), -ENOSPC);
	zassert_str_equal(line, "", "nothing on failure");
}

ZTEST_SUITE(lcd, NULL, NULL, NULL, NULL, NULL);
