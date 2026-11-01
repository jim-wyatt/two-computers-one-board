/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * The scope: a signal generator and an oscilloscope on one pin.
 *
 * PA4 (header A0) is dac1 output 1 and adc1 channel 9 at once. The DAC plays
 * a table out of it; the ADC samples the same pin in bursts, and the MCU
 * reads its own output back with no wire. Linux asks for a burst on the
 * shell (`app scope capture`) and collects the samples over the SPI link
 * (SPI_PROTO_SCOPE), because 8 KB is too much for the serial line.
 *
 * TWO HALVES
 * ----------
 * This file and scope.c are the arithmetic: the waveform tables, the timer
 * division that turns a rate into a prescaler and a reload, and the burst's
 * bookkeeping, which decides when a burst is whole and safe to hand out.
 * None of it touches hardware, so mcu/tests/scope/ runs it on native_sim.
 *
 * scope_hw.c is the hardware, and is register-level, because Zephyr's
 * drivers stop short of it: the STM32 DAC driver writes one value at a time,
 * with no trigger and no DMA, and the STM32 ADC driver starts every
 * conversion from software, so it has no timer trigger and its DMA mode
 * fetches one sequence at a time. scope_hw.c drives TIM6, TIM7, DAC1 and
 * ADC1 with STM32Cube LL, and moves the data with Zephyr's own GPDMA driver.
 * See boards/arduino_uno_q.overlay and app_proto.h.
 */

#ifndef SCOPE_H
#define SCOPE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <zephyr/kernel.h>
#include <zephyr/spinlock.h>

#include "app_proto.h"

/* --- waveforms ------------------------------------------------------------ */

enum scope_wave {
	SCOPE_WAVE_OFF,
	SCOPE_WAVE_SINE,
	SCOPE_WAVE_TRIANGLE,
};

/** The name app_proto.h gives a wave: APP_SCOPE_WAVE_OFF, _SINE, _TRIANGLE. */
const char *scope_wave_name(enum scope_wave w);

/** The wave a name means. Returns 0, or -EINVAL for anything but sine and
 *  triangle: off is not something to generate. */
int scope_wave_parse(const char *name, enum scope_wave *out);

/** Fill APP_SCOPE_POINTS DAC codes for one period, starting at the middle
 *  and rising, as a sine does. 32-bit entries because the DAC's data
 *  register is a word and the DMA moves the same width at both ends.
 *  Returns 0, or -EINVAL for SCOPE_WAVE_OFF. */
int scope_wave_fill(enum scope_wave w, uint32_t *table);

/* --- timers ---------------------------------------------------------------- */

/* A 16-bit timer's division of its clock: it counts (psc + 1) * (arr + 1)
 * clock cycles per update. */
struct scope_div {
	uint32_t psc;
	uint32_t arr;
	uint64_t rate_mhz; /* the update rate it gives, in millihertz */
};

/** The division nearest to `rate_hz` updates a second from a `clk_hz` clock,
 *  with the prescaler as small as will do, for the finest step. Returns 0,
 *  or -EINVAL if rate_hz is 0 or above clk_hz / 2. */
int scope_timer_div(uint32_t clk_hz, uint32_t rate_hz, struct scope_div *out);

/* --- bursts ---------------------------------------------------------------- */

/*
 * One buffer of samples, written by DMA during a capture and read by the SPI
 * link's thread afterwards. A reader must never see a buffer the DMA is still
 * writing, nor one a failed capture left half written, nor half of one
 * capture and half of the next; the lock and the id are how.
 *
 *   begin   valid false, busy true: from here the DMA owns the buffer
 *   end     busy false; on success valid true and a new id
 *   read    copies out under the lock, only while valid and not busy, and
 *           only from the capture the reader names
 */
struct scope_burst {
	uint16_t *buf;
	uint16_t cap;
	uint16_t n;        /* samples in the capture now held, or being taken */
	uint32_t rate_mhz; /* its sample rate, in millihertz */
	uint32_t id;       /* the last good capture, 1, 2, ...; 0 before any */
	uint32_t errors;   /* captures that failed */
	bool busy;
	bool valid;
	struct k_spinlock lock;
};

/* What scope_burst_read() says about the capture it read from. */
struct scope_chunk {
	uint32_t id;
	uint32_t rate_mhz;
	uint16_t n;      /* samples in the whole capture */
	uint16_t offset; /* of the first one copied */
	uint16_t count;  /* copied */
};

/* One consistent look at a burst, for `app scope stat`. */
struct scope_burst_info {
	uint32_t id;
	uint32_t rate_mhz;
	uint32_t errors;
	uint16_t n;
	bool busy;
	bool valid;
};

/** An empty burst over buf[0..cap). */
void scope_burst_init(struct scope_burst *b, uint16_t *buf, uint16_t cap);

/** Claim the buffer for a capture of n samples at rate_mhz. Returns 0, or
 *  -EINVAL if n is 0 or over the capacity, or -EBUSY during another
 *  capture. */
int scope_burst_begin(struct scope_burst *b, uint16_t n, uint32_t rate_mhz);

/** The capture is over: the DMA has stopped writing. On success the burst
 *  becomes readable under the next id, which skips 0 when it wraps; on
 *  failure it is not readable at all, and the failure is counted. Returns
 *  the new id, or 0 for a failure. */
uint32_t scope_burst_end(struct scope_burst *b, bool ok);

/** Copy up to `max` samples, from `offset` on, of capture `id` (0: whichever
 *  is held) into out, and describe them in *c.
 *
 * Returns 0 - count may be 0, at offset == n - or:
 *   -EBUSY    a capture is running
 *   -ENODATA  there is no good capture
 *   -ESTALE   the capture held is not `id`; c->id says which it is
 *   -ERANGE   offset is past the end; c->n says where that is
 */
int scope_burst_read(struct scope_burst *b, uint32_t id, uint16_t offset, uint16_t *out,
		     uint16_t max, struct scope_chunk *c);

/** The burst's state, all of it under the lock. */
struct scope_burst_info scope_burst_info(struct scope_burst *b);

/** The smallest, largest and mean (rounded down) of n samples; all 0 when n
 *  is 0. */
void scope_summary(const uint16_t *s, size_t n, uint16_t *min, uint16_t *max, uint16_t *mean);

/* --- the firmware's ------------------------------------------------------- */

/* scope_hw.c's burst, for the SPI link's SCOPE service. */
struct scope_burst *scope_burst_get(void);

/* adc1 is shared: the die temperature reads it through Zephyr's ADC driver,
 * and a capture takes it over at the register level. Whoever touches it
 * holds this. Defined in scope_hw.c; main.c's read_die_temp() takes it. */
extern struct k_mutex adc1_lock;

#endif /* SCOPE_H */
