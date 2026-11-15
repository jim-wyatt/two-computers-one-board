/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * A 3.5" 320x480 touch LCD on the header's SPI, run by `app lcd` (#225).
 *
 * The module is Waveshare's, wired to spi2 on D10..D13 with its control lines
 * on D6..D9 - boards/arduino_uno_q.overlay has the pins. Its panel controller
 * is most likely a Sitronix ST7796S, which Zephyr drives over MIPI DBI on
 * SPI, and its touch controller a FocalTech FT6336U at 0x38 on i2c2, which
 * this step does not use yet.
 *
 * TWO HALVES
 * ----------
 * lcd.c is pure: a color's name to the 16 bits the panel takes, those bits
 * to bytes on the wire, the ID registers' raw bytes to a controller's name,
 * and the lines `app lcd` prints. mcu/tests/lcd/ runs it on native_sim.
 *
 * lcd_hw.c is the other half: the bus, the driver, the backlight and the
 * shell command. It is only built into the firmware, and only proven on a
 * board.
 *
 * The lines' formats are APP_LCD_* in app_proto.h.
 */

#ifndef LCD_H
#define LCD_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct shell;

/* The controller's commands this file uses by number. */
#define LCD_CMD_RDDID 0x04 /* read display ID: a dummy bit, then 24 bits */
#define LCD_CMD_RDID4 0xD3 /* read ID4: a dummy byte, then 00 77 96 on an ST7796S */

/* Bytes read back after each ID command. Four, so that whichever dummy the
 * part puts first - a bit, or a whole byte - the ID still fits. */
#define LCD_ID_LEN 4

struct lcd_id {
	uint8_t rddid[LCD_ID_LEN];
	uint8_t id4[LCD_ID_LEN];
};

/* A color by name (black, white, red, green, blue, yellow, cyan, magenta)
 * or as six hex digits, rrggbb, into RGB565: red in the top five bits, then
 * six of green, then five of blue. Anything else is false, and *out is
 * untouched. */
bool lcd_parse_color(const char *s, uint16_t *out);

/* One or two hex digits, nothing else, into a byte: `app lcd cmd`'s
 * arguments. */
bool lcd_parse_byte(const char *s, uint8_t *out);

/* RGB565 as the two bytes the bus carries, in the order the driver says it
 * wants: big-endian (red first) when msb_first, as PIXEL_FORMAT_RGB_565X
 * asks, little-endian otherwise. */
void lcd_pack565(uint16_t c, bool msb_first, uint8_t out[2]);

/* Where a 16-bit ID starts in raw, counted in bits from the first byte's top
 * bit, or -1 if it is not there. Read with 8-bit words, a part that clocks
 * out one dummy bit first leaves its ID straddling bytes; this finds it at
 * any offset rather than guessing which dummy the part uses. */
int lcd_id_find(const uint8_t *raw, size_t n, uint16_t id);

/* Which controller answered: a name, "none" when every byte of both reads is
 * the same (MISO idle high or low - nothing drove it), or "unknown". *dummy
 * is lcd_id_find()'s answer for the ID that matched, or -1. */
const char *lcd_id_name(const struct lcd_id *id, int *dummy);

/* The APP_LCD_ID_FMT line, NUL-terminated, without a newline. Returns its
 * length, or -ENOSPC if buf is too small (buf then holds nothing).
 * APP_LCD_LINE_MAX always fits. */
int lcd_id_format(const struct lcd_id *id, char *buf, size_t len);

/* The longest line lcd.c can write, with its terminator. */
#define APP_LCD_LINE_MAX 80

/* `app lcd` and its subcommands (lcd_hw.c). */
int cmd_app_lcd_id(const struct shell *sh, size_t argc, char **argv);
int cmd_app_lcd_on(const struct shell *sh, size_t argc, char **argv);
int cmd_app_lcd_off(const struct shell *sh, size_t argc, char **argv);
int cmd_app_lcd_fill(const struct shell *sh, size_t argc, char **argv);
int cmd_app_lcd_cmd(const struct shell *sh, size_t argc, char **argv);

/* At boot: the backlight off, and one line saying the panel is there to be
 * started. */
void lcd_report(void);

#endif /* LCD_H */
