/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * The temperature log: the MCU samples its die temperature on its own clock
 * and keeps the record until Linux comes for it.
 *
 * Everything else on this link is a reply. Linux asks, the MCU answers, and
 * what the MCU knows is what it measured at that moment. The log is the one
 * place the MCU is the producer: a k_timer paces the samples, Linux's load
 * cannot delay them, and a reader that stops for ten minutes loses nothing.
 *
 * TWO HALVES
 * ----------
 * The ring buffer (templog_record, templog_read, templog_stat) touches no
 * hardware and no kernel object but a spinlock, so mcu/tests/templog/ runs it
 * on native_sim: wraparound, `since`, gaps, the batch cap, the drop count.
 *
 * templog_start() is the clock: a k_timer, and a work item on the system
 * workqueue that does the read, because a sensor read takes a mutex and
 * waits on the ADC and a timer expiry runs in an interrupt. The read itself
 * is a function pointer, so the firmware hands it the die-temperature sensor
 * and a test hands it a fake. See app_proto.h for the shell formats.
 */

#ifndef TEMPLOG_H
#define TEMPLOG_H

#include <stdbool.h>
#include <stdint.h>
#include <zephyr/spinlock.h>

#include "app_proto.h"

/** Read the temperature: 0 and millidegrees Celsius in *temp_mc, or a
 *  negative errno and *temp_mc untouched. */
typedef int (*templog_read_fn)(int32_t *temp_mc);

/* One slot of the ring. The sequence number is not stored: it follows from
 * the slot's place relative to the newest, so it costs nothing. */
struct templog_entry {
	int64_t ms;
	int32_t value; /* millidegrees if ok, else the negative errno */
	bool ok;
};

struct templog {
	struct templog_entry ring[APP_TEMPLOG_SIZE];
	uint32_t head;  /* sequence number of the newest sample; 0 = none yet */
	uint32_t count; /* samples held, at most APP_TEMPLOG_SIZE */
	struct k_spinlock lock;
};

/* A sample as templog_read() hands it out, with its sequence number. */
struct templog_sample {
	uint32_t seq;
	int64_t ms;
	int32_t value;
	bool ok;
};

/* What one templog_read() found, besides the samples themselves. */
struct templog_batch {
	uint32_t head;      /* newest sequence number held when it was read */
	uint32_t n;         /* samples written to out[] */
	uint32_t gap_first; /* first sequence number lost; 0 = no gap */
	uint32_t gap_last;  /* last sequence number lost, inclusive */
	uint32_t more;      /* samples newer than out[n - 1] still waiting */
};

struct templog_stat {
	uint32_t head;
	uint32_t count;
	uint32_t dropped; /* overwritten: head - count */
};

/** Empty the log. The next sample is sequence number 1. */
void templog_init(struct templog *tl);

/** Add one sample: rc 0 and temp_mc, or a negative errno from the read. When
 *  the ring is full the oldest sample is overwritten and counts as dropped. */
void templog_record(struct templog *tl, int64_t ms, int rc, int32_t temp_mc);

/** Take one sample now, with `read`, and record it at uptime `ms`. */
void templog_sample(struct templog *tl, templog_read_fn read, int64_t ms);

/** Copy out up to `max` samples, oldest first.
 *
 * has_since false: from the oldest held, and no gap is reported.
 * has_since true:  from since + 1. If some of those were overwritten, the
 *                  batch starts at the oldest held and gap_first..gap_last
 *                  names the ones that were lost.
 *
 * Returns 0, or -ERANGE if `since` is beyond the newest sample - which means
 * the caller's number came from before a restart. b->head is filled in either
 * way. All of it is one look under the lock, so a sample recorded while this
 * runs is either wholly in the batch or counted in `more`.
 */
int templog_read(struct templog *tl, bool has_since, uint32_t since, struct templog_sample *out,
		 uint32_t max, struct templog_batch *b);

/** The counters `app temp log stat` prints. */
struct templog_stat templog_stat(struct templog *tl);

/** Start sampling into `tl` every `period_ms`, the first sample one period
 *  from now. There is one sampler: calling this again repoints it. */
void templog_start(struct templog *tl, templog_read_fn read, uint32_t period_ms);

/** Stop the sampler. A sample already being taken still lands. */
void templog_stop(void);

#endif /* TEMPLOG_H */
