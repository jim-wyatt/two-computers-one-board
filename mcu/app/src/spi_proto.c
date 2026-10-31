/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * The SPI link's frames and services, without the SPI. See spi_proto.h.
 */
#include <errno.h>
#include <string.h>
#include <zephyr/sys/byteorder.h>
#include <zephyr/sys/util.h>
#include <zephyr/sys/crc.h>

#include "spi_proto.h"

uint16_t spi_proto_crc16(const uint8_t *data, size_t len)
{
	/* crc16_itu_t is CRC-16/CCITT-FALSE when seeded with 0xFFFF. */
	return crc16_itu_t(0xFFFF, data, len);
}

int spi_proto_encode(uint8_t *buf, size_t cap, uint8_t type, uint8_t seq, const uint8_t *payload,
		     uint16_t len)
{
	size_t total = SPI_PROTO_OVERHEAD + (size_t)len;

	if (len > SPI_PROTO_MAX_PAYLOAD) {
		return -EMSGSIZE;
	}
	if (total > cap) {
		return -ENOSPC;
	}

	sys_put_le16(SPI_PROTO_MAGIC, &buf[0]);
	buf[2] = type;
	buf[3] = seq;
	sys_put_le16(len, &buf[4]);
	/* memmove, not memcpy: ECHO encodes its answer from a payload that may
	 * sit in the same buffer. */
	if (len > 0U) {
		memmove(&buf[SPI_PROTO_HEADER_LEN], payload, len);
	}
	sys_put_le16(spi_proto_crc16(buf, SPI_PROTO_HEADER_LEN + (size_t)len),
		     &buf[SPI_PROTO_HEADER_LEN + (size_t)len]);
	return (int)total;
}

int spi_proto_encode_error(uint8_t *buf, size_t cap, uint8_t seq, uint8_t code, uint8_t req_type,
			   uint32_t detail)
{
	uint8_t p[SPI_PROTO_ERROR_LEN];

	p[0] = code;
	p[1] = req_type;
	sys_put_le32(detail, &p[2]);
	return spi_proto_encode(buf, cap, SPI_PROTO_ERROR, seq, p, sizeof(p));
}

int spi_proto_decode(const uint8_t *buf, size_t n, struct spi_proto_frame *out)
{
	uint16_t len;

	if (n < SPI_PROTO_HEADER_LEN || sys_get_le16(&buf[0]) != SPI_PROTO_MAGIC) {
		return -EBADMSG;
	}

	len = sys_get_le16(&buf[4]);
	out->type = buf[2];
	out->seq = buf[3];
	out->len = len;
	out->payload = &buf[SPI_PROTO_HEADER_LEN];

	if (len > SPI_PROTO_MAX_PAYLOAD || SPI_PROTO_OVERHEAD + (size_t)len > n) {
		return -EMSGSIZE;
	}
	if (sys_get_le16(&buf[SPI_PROTO_HEADER_LEN + (size_t)len]) !=
	    spi_proto_crc16(buf, SPI_PROTO_HEADER_LEN + (size_t)len)) {
		return -EILSEQ;
	}
	return 0;
}

/* --- services --------------------------------------------------------------- */

/* One answer's worth, static: 1.4 KB is more than the link thread's stack
 * should carry, and spi_link.c has one thread, so there is one caller. */
static struct templog_sample templog_batch[SPI_PROTO_TEMPLOG_MAX];

static int answer_templog(const struct spi_proto_frame *req, uint8_t *tx, size_t cap,
			  struct templog *tl)
{
	uint8_t *p = &tx[SPI_PROTO_HEADER_LEN];
	const size_t fixed = SPI_PROTO_OVERHEAD + SPI_PROTO_TEMPLOG_HDR_LEN;
	struct templog_batch b;
	uint32_t max;
	bool has_since;
	uint32_t since;
	int rc;

	if (cap < fixed) {
		return -ENOSPC;
	}
	/* The samples are written before the frame is, so the cap on them has to
	 * be worked out here: spi_proto_encode() would only find out too late. */
	max = MIN(SPI_PROTO_TEMPLOG_MAX, (cap - fixed) / SPI_PROTO_TEMPLOG_SAMPLE_LEN);

	if (req->len != SPI_PROTO_TEMPLOG_REQ_LEN) {
		return spi_proto_encode_error(tx, cap, req->seq, SPI_PROTO_ERR_REQUEST, req->type,
					      req->len);
	}
	if (tl == NULL) {
		return spi_proto_encode_error(tx, cap, req->seq, SPI_PROTO_ERR_UNAVAILABLE,
					      req->type, 0);
	}

	has_since = (req->payload[0] & SPI_PROTO_TEMPLOG_SINCE) != 0U;
	since = sys_get_le32(&req->payload[1]);
	rc = templog_read(tl, has_since, since, templog_batch, max, &b);
	if (rc != 0) {
		return spi_proto_encode_error(tx, cap, req->seq, SPI_PROTO_ERR_RANGE, req->type,
					      b.head);
	}

	/* Built in place after the header, then framed around itself. */
	sys_put_le32(b.head, &p[0]);
	sys_put_le32(b.gap_first, &p[4]);
	sys_put_le32(b.gap_last, &p[8]);
	sys_put_le32(b.more, &p[12]);
	sys_put_le16((uint16_t)b.n, &p[16]);
	p += SPI_PROTO_TEMPLOG_HDR_LEN;
	for (uint32_t i = 0; i < b.n; i++) {
		const struct templog_sample *s = &templog_batch[i];

		sys_put_le32(s->seq, &p[0]);
		sys_put_le64((uint64_t)s->ms, &p[4]);
		sys_put_le32((uint32_t)s->value, &p[12]);
		p[16] = s->ok ? 1U : 0U;
		p += SPI_PROTO_TEMPLOG_SAMPLE_LEN;
	}
	return spi_proto_encode(
		tx, cap, req->type | SPI_PROTO_RESPONSE, req->seq, &tx[SPI_PROTO_HEADER_LEN],
		(uint16_t)(SPI_PROTO_TEMPLOG_HDR_LEN + b.n * SPI_PROTO_TEMPLOG_SAMPLE_LEN));
}

static int answer_stat(const struct spi_proto_frame *req, uint8_t *tx, size_t cap,
		       const struct spi_proto_stat *st)
{
	static const struct spi_proto_stat zero;
	uint8_t p[SPI_PROTO_STAT_LEN];

	if (req->len != 0U) {
		return spi_proto_encode_error(tx, cap, req->seq, SPI_PROTO_ERR_REQUEST, req->type,
					      req->len);
	}
	if (st == NULL) {
		st = &zero;
	}
	sys_put_le32(st->transactions, &p[0]);
	sys_put_le32(st->requests, &p[4]);
	sys_put_le32(st->bad_frames, &p[8]);
	sys_put_le32(st->spi_errors, &p[12]);
	return spi_proto_encode(tx, cap, req->type | SPI_PROTO_RESPONSE, req->seq, p, sizeof(p));
}

int spi_proto_handle(const uint8_t *rx, size_t n, uint8_t *tx, size_t cap,
		     const struct spi_proto_services *svc, bool *decoded)
{
	struct spi_proto_frame req;
	int rc = spi_proto_decode(rx, n, &req);

	*decoded = rc == 0;
	switch (rc) {
	case 0:
		break;
	case -EMSGSIZE:
		return spi_proto_encode_error(tx, cap, req.seq, SPI_PROTO_ERR_LENGTH, req.type,
					      req.len);
	case -EILSEQ:
		return spi_proto_encode_error(tx, cap, req.seq, SPI_PROTO_ERR_CRC, req.type,
					      sys_get_le16(&rx[SPI_PROTO_HEADER_LEN + req.len]));
	default:
		return spi_proto_encode_error(tx, cap, 0, SPI_PROTO_ERR_MAGIC, 0, 0);
	}

	switch (req.type) {
	case SPI_PROTO_NOP:
		return spi_proto_encode(tx, cap, SPI_PROTO_NOP | SPI_PROTO_RESPONSE, req.seq, NULL,
					0);
	case SPI_PROTO_ECHO:
		return spi_proto_encode(tx, cap, SPI_PROTO_ECHO | SPI_PROTO_RESPONSE, req.seq,
					req.payload, req.len);
	case SPI_PROTO_TEMPLOG:
		return answer_templog(&req, tx, cap, svc->templog);
	case SPI_PROTO_STAT:
		return answer_stat(&req, tx, cap, svc->stat);
	default:
		return spi_proto_encode_error(tx, cap, req.seq, SPI_PROTO_ERR_TYPE, req.type, 0);
	}
}
