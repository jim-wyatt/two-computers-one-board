/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * The jitter record: histograms of deviations, and the tick bookkeeping that
 * feeds one. See jitter.h for the shape, and app_proto.h for the bins and
 * what the shell prints from them.
 */
#include "jitter.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <zephyr/sys/util.h>

static const int32_t edges_us[APP_JITTER_EDGES] = APP_JITTER_EDGES_US;

int32_t jitter_clamp_ns(int64_t ns)
{
	return (int32_t)CLAMP(ns, INT32_MIN, INT32_MAX);
}

int jitter_bin(int32_t dev_ns)
{
	/* The magnitude in 64 bits, because -INT32_MIN does not fit in 32. */
	int64_t mag = dev_ns < 0 ? -(int64_t)dev_ns : dev_ns;
	int k = APP_JITTER_EDGES; /* past the last edge, unless one holds it */

	for (int i = 0; i < APP_JITTER_EDGES; i++) {
		if (mag <= (int64_t)edges_us[i] * 1000) {
			k = i;
			break;
		}
	}
	/* The middle bin is APP_JITTER_EDGES, and each step out is one edge. */
	return dev_ns < 0 ? APP_JITTER_EDGES - k : APP_JITTER_EDGES + k;
}

void jitter_hist_clear(struct jitter_hist *h)
{
	k_spinlock_key_t key = k_spin_lock(&h->lock);

	memset(h->bins, 0, sizeof(h->bins));
	h->n = 0;
	h->min_ns = 0;
	h->max_ns = 0;
	h->sum_ns = 0;

	k_spin_unlock(&h->lock, key);
}

void jitter_hist_add(struct jitter_hist *h, int64_t dev_ns)
{
	int32_t d = jitter_clamp_ns(dev_ns);
	k_spinlock_key_t key = k_spin_lock(&h->lock);

	if (h->n == 0U) {
		h->min_ns = d;
		h->max_ns = d;
	} else {
		h->min_ns = MIN(h->min_ns, d);
		h->max_ns = MAX(h->max_ns, d);
	}
	h->n++;
	h->sum_ns += d;
	h->bins[jitter_bin(d)]++;

	k_spin_unlock(&h->lock, key);
}

struct jitter_summary jitter_hist_read(struct jitter_hist *h)
{
	struct jitter_summary s;
	k_spinlock_key_t key = k_spin_lock(&h->lock);

	memcpy(s.bins, h->bins, sizeof(s.bins));
	s.n = h->n;
	s.min_ns = h->min_ns;
	s.max_ns = h->max_ns;
	/* Every term is an int32, so the mean of them is one too. */
	s.mean_ns = h->n == 0U ? 0 : (int32_t)(h->sum_ns / (int64_t)h->n);

	k_spin_unlock(&h->lock, key);
	return s;
}

int jitter_format_bins(const uint32_t *bins, char *buf, size_t cap)
{
	size_t len = 0;

	for (int i = 0; i < APP_JITTER_BINS; i++) {
		int w = snprintf(buf + len, cap - len, i == 0 ? "%u" : ",%u",
				 (unsigned int)bins[i]);

		if (w < 0 || (size_t)w >= cap - len) {
			if (cap > 0) {
				buf[0] = '\0';
			}
			return -ENOSPC;
		}
		len += (size_t)w;
	}
	return (int)len;
}

void jitter_ticker_arm(struct jitter_ticker *t, uint32_t period_us)
{
	jitter_hist_clear(&t->hist);
	t->period_us = period_us;
	t->last_us = 0;
	t->have_last = false;
	t->armed = true;
}

void jitter_ticker_stop(struct jitter_ticker *t)
{
	t->armed = false;
}

int jitter_ticker_tick(struct jitter_ticker *t, uint32_t now_us)
{
	uint32_t interval_us;

	if (!t->armed) {
		return -EAGAIN;
	}
	interval_us = now_us - t->last_us; /* modulo 2^32: one wrap is harmless */
	if (t->have_last) {
		jitter_hist_add(&t->hist, ((int64_t)interval_us - t->period_us) * 1000);
	}
	t->last_us = now_us;
	t->have_last = true;
	return 0;
}
