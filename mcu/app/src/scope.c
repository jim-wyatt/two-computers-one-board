/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * The scope's arithmetic: waveform tables, timer division and the burst's
 * bookkeeping. No hardware; see scope.h, and scope_hw.c for the rest.
 */
#include "scope.h"

#include <errno.h>
#include <string.h>
#include <zephyr/sys/util.h>

BUILD_ASSERT(APP_SCOPE_POINTS % 4 == 0, "the sine is built from a quarter");
BUILD_ASSERT(APP_SCOPE_DAC_MID - APP_SCOPE_DAC_AMPLITUDE >= 0 &&
		     APP_SCOPE_DAC_MID + APP_SCOPE_DAC_AMPLITUDE <= APP_SCOPE_DAC_MAX,
	     "the wave has to fit the DAC");

/* sin(2 pi k / 64) for k = 0..16, in Q15: a quarter period of the table,
 * from which the other three are mirrored. Integers, so the table is the
 * same on the board and on native_sim, and needs no libm. */
static const int32_t quarter_sine_q15[APP_SCOPE_POINTS / 4 + 1] = {
	0,     3212,  6393,  9512,  12539, 15446, 18204, 20787, 23170,
	25329, 27245, 28898, 30273, 31356, 32137, 32609, 32767,
};
BUILD_ASSERT(APP_SCOPE_POINTS == 64, "quarter_sine_q15 is for a 64-point table");

const char *scope_wave_name(enum scope_wave w)
{
	switch (w) {
	case SCOPE_WAVE_SINE:
		return APP_SCOPE_WAVE_SINE;
	case SCOPE_WAVE_TRIANGLE:
		return APP_SCOPE_WAVE_TRIANGLE;
	default:
		return APP_SCOPE_WAVE_OFF;
	}
}

int scope_wave_parse(const char *name, enum scope_wave *out)
{
	if (name != NULL && strcmp(name, APP_SCOPE_WAVE_SINE) == 0) {
		*out = SCOPE_WAVE_SINE;
		return 0;
	}
	if (name != NULL && strcmp(name, APP_SCOPE_WAVE_TRIANGLE) == 0) {
		*out = SCOPE_WAVE_TRIANGLE;
		return 0;
	}
	return -EINVAL;
}

/* The amplitude times a Q15 fraction, rounded to the nearest code. */
static int32_t scale_q15(int32_t q15)
{
	int32_t p = q15 * APP_SCOPE_DAC_AMPLITUDE;

	return p >= 0 ? (p + 16384) >> 15 : -((-p + 16384) >> 15);
}

int scope_wave_fill(enum scope_wave w, uint32_t *table)
{
	const int quarter = APP_SCOPE_POINTS / 4;

	if (w != SCOPE_WAVE_SINE && w != SCOPE_WAVE_TRIANGLE) {
		return -EINVAL;
	}
	for (int i = 0; i < APP_SCOPE_POINTS; i++) {
		/* Where in the quarter, and which way up: the first half rises
		 * to the top and back, the second is the first upside down. */
		int k = i % (2 * quarter);
		int sign = i < 2 * quarter ? 1 : -1;
		int32_t q15;

		k = k <= quarter ? k : 2 * quarter - k;
		if (w == SCOPE_WAVE_SINE) {
			q15 = quarter_sine_q15[k];
		} else {
			q15 = k * 32767 / quarter; /* straight lines through the same points */
		}
		table[i] = (uint32_t)(APP_SCOPE_DAC_MID + sign * scale_q15(q15));
	}
	return 0;
}

int scope_timer_div(uint32_t clk_hz, uint32_t rate_hz, struct scope_div *out)
{
	uint64_t cycles;
	uint64_t div;
	uint64_t ticks;

	if (rate_hz == 0U || rate_hz > clk_hz / 2U) {
		return -EINVAL;
	}
	/* Clock cycles per update, rounded; at most clk_hz, so 32 bits. */
	cycles = ((uint64_t)clk_hz + rate_hz / 2U) / rate_hz;
	/* The smallest prescaler that brings the count under 2^16. */
	div = (cycles - 1U) / 65536U + 1U;
	ticks = (cycles + div / 2U) / div;
	ticks = CLAMP(ticks, 2U, 65536U);

	out->psc = (uint32_t)(div - 1U);
	out->arr = (uint32_t)(ticks - 1U);
	out->rate_mhz = (uint64_t)clk_hz * 1000U / (div * ticks);
	return 0;
}

void scope_burst_init(struct scope_burst *b, uint16_t *buf, uint16_t cap)
{
	memset(b, 0, sizeof(*b));
	b->buf = buf;
	b->cap = cap;
}

int scope_burst_begin(struct scope_burst *b, uint16_t n, uint32_t rate_mhz)
{
	k_spinlock_key_t key = k_spin_lock(&b->lock);
	int rc = 0;

	if (n == 0U || n > b->cap) {
		rc = -EINVAL;
	} else if (b->busy) {
		rc = -EBUSY;
	} else {
		b->busy = true;
		b->valid = false;
		b->n = n;
		b->rate_mhz = rate_mhz;
	}

	k_spin_unlock(&b->lock, key);
	return rc;
}

uint32_t scope_burst_end(struct scope_burst *b, bool ok)
{
	k_spinlock_key_t key = k_spin_lock(&b->lock);
	uint32_t id = 0;

	b->busy = false;
	b->valid = ok;
	if (ok) {
		b->id = b->id == UINT32_MAX ? 1U : b->id + 1U;
		id = b->id;
	} else {
		b->errors++;
	}

	k_spin_unlock(&b->lock, key);
	return id;
}

int scope_burst_read(struct scope_burst *b, uint32_t id, uint16_t offset, uint16_t *out,
		     uint16_t max, struct scope_chunk *c)
{
	k_spinlock_key_t key = k_spin_lock(&b->lock);
	int rc = 0;

	memset(c, 0, sizeof(*c));
	if (b->busy) {
		rc = -EBUSY;
	} else if (!b->valid) {
		rc = -ENODATA;
	} else {
		c->id = b->id;
		c->rate_mhz = b->rate_mhz;
		c->n = b->n;
		c->offset = offset;
		if (id != 0U && id != b->id) {
			rc = -ESTALE;
		} else if (offset > b->n) {
			rc = -ERANGE;
		} else {
			c->count = MIN(max, b->n - offset);
			memcpy(out, &b->buf[offset], c->count * sizeof(uint16_t));
		}
	}

	k_spin_unlock(&b->lock, key);
	return rc;
}

struct scope_burst_info scope_burst_info(struct scope_burst *b)
{
	k_spinlock_key_t key = k_spin_lock(&b->lock);
	struct scope_burst_info i = {
		.id = b->valid ? b->id : 0U,
		.rate_mhz = b->valid ? b->rate_mhz : 0U,
		.errors = b->errors,
		.n = b->valid ? b->n : 0U,
		.busy = b->busy,
		.valid = b->valid,
	};

	k_spin_unlock(&b->lock, key);
	return i;
}

void scope_summary(const uint16_t *s, size_t n, uint16_t *min, uint16_t *max, uint16_t *mean)
{
	uint64_t sum = 0;

	*min = 0;
	*max = 0;
	*mean = 0;
	for (size_t i = 0; i < n; i++) {
		if (i == 0 || s[i] < *min) {
			*min = s[i];
		}
		if (i == 0 || s[i] > *max) {
			*max = s[i];
		}
		sum += s[i];
	}
	if (n > 0) {
		*mean = (uint16_t)(sum / n);
	}
}
