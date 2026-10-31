/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * The temperature log's ring buffer and its clock. See templog.h for the
 * shape, and app_proto.h for what the shell prints from it.
 */
#include "templog.h"

#include <errno.h>
#include <string.h>
#include <zephyr/kernel.h>

void templog_init(struct templog *tl)
{
	memset(tl, 0, sizeof(*tl));
}

/* The slot sequence number `seq` lives in, for any seq still held. Slot
 * (seq - 1) % SIZE: sample 1 goes in slot 0, and the ring needs no index of
 * its own beside the head. */
static struct templog_entry *slot(struct templog *tl, uint32_t seq)
{
	return &tl->ring[(seq - 1U) % APP_TEMPLOG_SIZE];
}

void templog_record(struct templog *tl, int64_t ms, int rc, int32_t temp_mc)
{
	k_spinlock_key_t key = k_spin_lock(&tl->lock);
	struct templog_entry *e;

	tl->head++;
	if (tl->count < APP_TEMPLOG_SIZE) {
		tl->count++;
	}
	e = slot(tl, tl->head);
	e->ms = ms;
	e->ok = rc == 0;
	e->value = rc == 0 ? temp_mc : rc;

	k_spin_unlock(&tl->lock, key);
}

void templog_sample(struct templog *tl, templog_read_fn read, int64_t ms)
{
	int32_t temp_mc = 0;
	int rc = read(&temp_mc);

	templog_record(tl, ms, rc, temp_mc);
}

int templog_read(struct templog *tl, bool has_since, uint32_t since, struct templog_sample *out,
		 uint32_t max, struct templog_batch *b)
{
	k_spinlock_key_t key = k_spin_lock(&tl->lock);
	/* With nothing held, oldest is head + 1: the first sample to come. */
	uint32_t oldest = tl->head - tl->count + 1U;
	uint32_t first;
	int rc = 0;

	memset(b, 0, sizeof(*b));
	b->head = tl->head;

	if (!has_since) {
		first = oldest;
	} else if (since > tl->head) {
		rc = -ERANGE;
		goto out;
	} else {
		first = since + 1U;
		if (first < oldest) {
			b->gap_first = first;
			b->gap_last = oldest - 1U;
			first = oldest;
		}
	}

	/* first is at most head + 1, so this never underflows. */
	b->n = MIN(max, tl->head + 1U - first);
	for (uint32_t i = 0; i < b->n; i++) {
		const struct templog_entry *e = slot(tl, first + i);

		out[i] = (struct templog_sample){
			.seq = first + i,
			.ms = e->ms,
			.value = e->value,
			.ok = e->ok,
		};
	}
	b->more = tl->head + 1U - first - b->n;

out:
	k_spin_unlock(&tl->lock, key);
	return rc;
}

struct templog_stat templog_stat(struct templog *tl)
{
	k_spinlock_key_t key = k_spin_lock(&tl->lock);
	struct templog_stat s = {
		.head = tl->head,
		.count = tl->count,
		.dropped = tl->head - tl->count,
	};

	k_spin_unlock(&tl->lock, key);
	return s;
}

/* --- the clock -------------------------------------------------------------
 *
 * The timer fixes when samples are due, and the work item does the read. A
 * k_timer is periodic against the kernel's tick, not against whenever the
 * last read happened to finish, so a slow read never pushes later samples
 * back. The timestamp is taken when the read is, because that is when the
 * temperature was what the sample says.
 */

static struct templog *sampler_log;
static templog_read_fn sampler_read;

static void on_sample(struct k_work *work)
{
	ARG_UNUSED(work);
	templog_sample(sampler_log, sampler_read, k_uptime_get());
}

static K_WORK_DEFINE(sample_work, on_sample);

static void on_timer(struct k_timer *timer)
{
	ARG_UNUSED(timer);
	/* Already queued means the previous read has not started yet. Then this
	 * tick is lost: the sequence number it would have had is never issued,
	 * so the record has no hole in it - only a longer step in `ms`. */
	(void)k_work_submit(&sample_work);
}

static K_TIMER_DEFINE(sample_timer, on_timer, NULL);

void templog_start(struct templog *tl, templog_read_fn read, uint32_t period_ms)
{
	k_timer_stop(&sample_timer);
	(void)k_work_cancel(&sample_work);
	sampler_log = tl;
	sampler_read = read;
	k_timer_start(&sample_timer, K_MSEC(period_ms), K_MSEC(period_ms));
}

void templog_stop(void)
{
	k_timer_stop(&sample_timer);
}
