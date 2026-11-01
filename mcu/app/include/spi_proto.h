/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * The SPI link's contract: the frame both chips put on /dev/spidev0.0 <-> spi3.
 *
 * Linux is the SPI master and the MCU is the slave, so the MCU never speaks
 * first. Every exchange is one TRANSACTION of exactly SPI_PROTO_XFER_LEN bytes,
 * with chip select held low throughout, and both directions carry a frame at
 * once: Linux's request goes down while the MCU's answer to the PREVIOUS
 * request comes up. A request is answered one transaction later.
 *
 *   transaction n:    MOSI  request k            MISO  answer to k - 1
 *   transaction n+1:  MOSI  request k+1 (or NOP) MISO  answer to k
 *
 * Fixed length, because Zephyr's STM32 slave driver ends a transfer when its
 * buffers are full, not when chip select rises. A master that clocked any other
 * length would leave the slave counting across transaction boundaries.
 *
 * THE FRAME, little-endian, at the start of the transaction:
 *
 *   offset  size  field
 *   0       2     magic, SPI_PROTO_MAGIC: 'U' 'Q' on the wire
 *   2       1     type: a request below, or a request | SPI_PROTO_RESPONSE,
 *                 or SPI_PROTO_ERROR
 *   3       1     seq: chosen by Linux, echoed in the answer, so an answer
 *                 can be matched to its request and a stale one recognized
 *   4       2     length of the payload, 0..SPI_PROTO_MAX_PAYLOAD
 *   6       len   payload
 *   6+len   2     CRC-16/CCITT-FALSE over bytes 0..6+len-1 (poly 0x1021, init
 *                 0xFFFF, no reflection): Python's binascii.crc_hqx(b, 0xFFFF)
 *
 * The rest of the transaction is padding, and is ignored.
 *
 * Python's half is python/unoq/spilink.py, and python/tests/test_spilink.py
 * parses this header to check that the two agree. Change a number here and
 * that test fails before the board does.
 *
 * Everything in this header and spi_proto.c is pure: buffers in, buffers out,
 * no hardware. mcu/tests/spi_proto/ runs it on native_sim. spi_link.c is the
 * part that touches spi3.
 */

#ifndef SPI_PROTO_H
#define SPI_PROTO_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "scope.h"
#include "templog.h"

/* One transaction, both ways: well under the 4096 bytes Linux's spidev takes
 * in one transfer by default (its bufsiz parameter). */
#define SPI_PROTO_XFER_LEN 1024

#define SPI_PROTO_MAGIC       0x5155 /* 'U' then 'Q' on the wire */
#define SPI_PROTO_HEADER_LEN  6
#define SPI_PROTO_CRC_LEN     2
#define SPI_PROTO_OVERHEAD    (SPI_PROTO_HEADER_LEN + SPI_PROTO_CRC_LEN)
#define SPI_PROTO_MAX_PAYLOAD (SPI_PROTO_XFER_LEN - SPI_PROTO_OVERHEAD)

/* --- types ---------------------------------------------------------------- */

/* Requests, Linux to MCU. */
#define SPI_PROTO_NOP     0x00 /* nothing to ask: collects the last answer */
#define SPI_PROTO_ECHO    0x01 /* payload: anything; answered with the same */
#define SPI_PROTO_TEMPLOG 0x02 /* payload: SPI_PROTO_TEMPLOG_REQ_LEN bytes */
#define SPI_PROTO_STAT    0x03 /* payload: none; answered with the counters */
#define SPI_PROTO_SCOPE   0x04 /* payload: SPI_PROTO_SCOPE_REQ_LEN bytes */

/* An answer's type is its request's with this bit set. */
#define SPI_PROTO_RESPONSE  0x80
/* Or this, for a request that could not be answered. Payload: code, the
 * request's type, and a 32-bit detail. */
#define SPI_PROTO_ERROR     0x7F
#define SPI_PROTO_ERROR_LEN 6

/* Error codes. */
#define SPI_PROTO_ERR_MAGIC       1 /* no frame at the start of the transaction */
#define SPI_PROTO_ERR_CRC         2 /* detail: the CRC that was received */
#define SPI_PROTO_ERR_LENGTH      3 /* detail: the length that was received */
#define SPI_PROTO_ERR_TYPE        4 /* not a request this firmware knows */
#define SPI_PROTO_ERR_REQUEST     5 /* known type, wrong payload size */
#define SPI_PROTO_ERR_RANGE       6 /* past the end; detail: TEMPLOG head, SCOPE n */
#define SPI_PROTO_ERR_UNAVAILABLE 7 /* nothing behind it; SCOPE detail: 1 if busy */
#define SPI_PROTO_ERR_STALE       8 /* not the capture asked for; detail: the one held */

/* --- TEMPLOG -------------------------------------------------------------- */
/*
 * Request payload, 5 bytes:   flags u8 (bit 0: since is given), since u32
 * Answer payload:             head u32, gap_first u32, gap_last u32,
 *                             more u32, n u16, then n samples of
 *                             seq u32, ms u64, value i32, ok u8
 *
 * The same meaning as `app temp log [since]` on the shell (templog.h,
 * app_proto.h): gap_first 0 means no gap, value is millidegrees if ok and the
 * negative errno if not. Up to SPI_PROTO_TEMPLOG_MAX samples per answer; ask
 * again with since = the last seq while `more` is not 0.
 */
#define SPI_PROTO_TEMPLOG_REQ_LEN    5
#define SPI_PROTO_TEMPLOG_SINCE      0x01
#define SPI_PROTO_TEMPLOG_HDR_LEN    18
#define SPI_PROTO_TEMPLOG_SAMPLE_LEN 17
#define SPI_PROTO_TEMPLOG_MAX                                                                      \
	((SPI_PROTO_MAX_PAYLOAD - SPI_PROTO_TEMPLOG_HDR_LEN) / SPI_PROTO_TEMPLOG_SAMPLE_LEN)

/* --- STAT ----------------------------------------------------------------- */
/* Answer payload: SPI_PROTO_STAT_COUNT u32 counters, in struct order. */
#define SPI_PROTO_STAT_COUNT 4
#define SPI_PROTO_STAT_LEN   (SPI_PROTO_STAT_COUNT * 4)

struct spi_proto_stat {
	uint32_t transactions; /* transfers the slave completed */
	uint32_t requests;     /* of those, frames that decoded */
	uint32_t bad_frames;   /* of those, ones that did not */
	uint32_t spi_errors;   /* transfers the driver failed: overrun, underrun */
};

/* --- SCOPE ---------------------------------------------------------------- */
/*
 * The burst the last `app scope capture` took (scope.h, app_proto.h), in
 * pieces: a burst is up to 8 KB and an answer holds SPI_PROTO_SCOPE_MAX
 * samples, so a reader asks again with offset += count until offset is n.
 *
 * Request payload, 6 bytes:   id u32, offset u16
 * Answer payload:             id u32, rate_mhz u32, n u16, offset u16,
 *                             count u16, then count samples of u16
 *
 * id 0 asks for whatever capture is held, and every answer names the one it
 * came from; a reader asks for that id from then on, so a capture taken in
 * the middle of its reading is SPI_PROTO_ERR_STALE, not a burst stitched from
 * two. rate_mhz is the sample rate in millihertz, n the samples in the whole
 * capture. A sample is the ADC's 14-bit code, 0..APP_SCOPE_ADC_MAX.
 *
 * Errors: SPI_PROTO_ERR_UNAVAILABLE with detail 0 before any good capture or
 * after a failed one, 1 while a capture is running; SPI_PROTO_ERR_STALE;
 * SPI_PROTO_ERR_RANGE for an offset past n.
 */
#define SPI_PROTO_SCOPE_REQ_LEN    6
#define SPI_PROTO_SCOPE_HDR_LEN    14
#define SPI_PROTO_SCOPE_SAMPLE_LEN 2
#define SPI_PROTO_SCOPE_MAX                                                                        \
	((SPI_PROTO_MAX_PAYLOAD - SPI_PROTO_SCOPE_HDR_LEN) / SPI_PROTO_SCOPE_SAMPLE_LEN)

/* --- frames --------------------------------------------------------------- */

/* A decoded frame. payload points into the buffer it was decoded from. */
struct spi_proto_frame {
	uint8_t type;
	uint8_t seq;
	uint16_t len;
	const uint8_t *payload;
};

/** CRC-16/CCITT-FALSE of `len` bytes. "123456789" gives 0x29B1. */
uint16_t spi_proto_crc16(const uint8_t *data, size_t len);

/** Write one frame into buf[0..cap). Returns the frame's length, or -EMSGSIZE
 *  if len is over SPI_PROTO_MAX_PAYLOAD, or -ENOSPC if it does not fit in cap.
 *  `payload` may be NULL when len is 0. */
int spi_proto_encode(uint8_t *buf, size_t cap, uint8_t type, uint8_t seq, const uint8_t *payload,
		     uint16_t len);

/** Find the frame at the start of buf[0..n).
 *
 * Returns 0 and fills *out, or:
 *   -EBADMSG   n is shorter than a header, or the magic is wrong
 *   -EMSGSIZE  the length is over SPI_PROTO_MAX_PAYLOAD, or runs past n
 *   -EILSEQ    the CRC does not match
 * For -EMSGSIZE and -EILSEQ, out->type and out->seq are filled in, so an error
 * answer can still name the request.
 */
int spi_proto_decode(const uint8_t *buf, size_t n, struct spi_proto_frame *out);

/** Write an SPI_PROTO_ERROR frame. Same returns as spi_proto_encode(). */
int spi_proto_encode_error(uint8_t *buf, size_t cap, uint8_t seq, uint8_t code, uint8_t req_type,
			   uint32_t detail);

/* What the services answer from. Any pointer may be NULL: TEMPLOG and SCOPE
 * then answer SPI_PROTO_ERR_UNAVAILABLE, STAT answers zeros. */
struct spi_proto_services {
	struct templog *templog;
	const struct spi_proto_stat *stat;
	struct scope_burst *scope;
};

/** The whole slave side of one transaction, without the SPI: decode what came
 *  down in rx[0..n), and write the answer to send up next into tx[0..cap).
 *  With cap at least SPI_PROTO_XFER_LEN it always writes a frame, an error
 *  frame if nothing else, and returns its length; a smaller cap may give
 *  -ENOSPC. *decoded is set true if rx held a valid frame. rx and tx must not
 *  overlap. Not reentrant: TEMPLOG and SCOPE answer from static batches. */
int spi_proto_handle(const uint8_t *rx, size_t n, uint8_t *tx, size_t cap,
		     const struct spi_proto_services *svc, bool *decoded);

/*
 * The firmware's hook for the temperature log, which is main.c's and static
 * there. spi_link.c has a weak default that returns NULL, so TEMPLOG answers
 * SPI_PROTO_ERR_UNAVAILABLE; main.c gives the link its log by defining
 *
 *   struct templog *spi_link_templog(void) { return &temp_log; }
 */
struct templog *spi_link_templog(void);

#endif /* SPI_PROTO_H */
