/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * Host-runnable tests for the SPI link's frames and services.
 *
 * A frame that decodes wrongly on the MCU is a request answered with nonsense,
 * and nothing on the wire would say so. So these check the framing at each
 * edge - round trips at every size, a CRC that is off by one bit, lengths that
 * are too long or run past the transaction, the wrong magic - and then the
 * services, through spi_proto_handle(), the same call spi_link.c makes.
 *
 * Runs on native_sim via ~/two-computers-one-board/mcu/ztest.sh - no board, no flash cycle.
 */
#include <zephyr/ztest.h>
#include <zephyr/sys/byteorder.h>
#include <errno.h>
#include <string.h>

#include "spi_proto.h"

static uint8_t buf[SPI_PROTO_XFER_LEN];
static uint8_t tx[SPI_PROTO_XFER_LEN];
static uint8_t payload[SPI_PROTO_MAX_PAYLOAD + 1];
static struct templog tl;

static void reset(void *fixture)
{
	ARG_UNUSED(fixture);
	memset(buf, 0, sizeof(buf));
	memset(tx, 0, sizeof(tx));
	for (size_t i = 0; i < sizeof(payload); i++) {
		payload[i] = (uint8_t)(i * 7U + 3U);
	}
	templog_stop();
	templog_init(&tl);
}

/* Decode tx as an answer, and check it is the given type and seq. */
static struct spi_proto_frame answer(uint8_t type, uint8_t seq)
{
	struct spi_proto_frame f;

	zassert_ok(spi_proto_decode(tx, sizeof(tx), &f), "the answer itself does not decode");
	zassert_equal(f.type, type, "answer type 0x%02x, wanted 0x%02x", f.type, type);
	zassert_equal(f.seq, seq, "answer seq %u, wanted %u", f.seq, seq);
	return f;
}

static void assert_error(uint8_t seq, uint8_t code, uint8_t req_type, uint32_t detail)
{
	struct spi_proto_frame f = answer(SPI_PROTO_ERROR, seq);

	zassert_equal(f.len, SPI_PROTO_ERROR_LEN);
	zassert_equal(f.payload[0], code, "error code %u, wanted %u", f.payload[0], code);
	zassert_equal(f.payload[1], req_type);
	zassert_equal(sys_get_le32(&f.payload[2]), detail, "detail %u, wanted %u",
		      sys_get_le32(&f.payload[2]), detail);
}

/* Run one request through the service layer, from a full transaction. */
static bool handle(const struct spi_proto_services *svc)
{
	bool decoded = false;

	zassert_true(spi_proto_handle(buf, sizeof(buf), tx, sizeof(tx), svc, &decoded) > 0);
	return decoded;
}

/* --- the CRC ------------------------------------------------------------ */

ZTEST(spi_proto, test_the_crc_is_ccitt_false)
{
	/* The catalogued check value: what Python's binascii.crc_hqx gives too. */
	zassert_equal(spi_proto_crc16((const uint8_t *)"123456789", 9), 0x29B1);
	zassert_equal(spi_proto_crc16(NULL, 0), 0xFFFF, "nothing at all is the seed");
}

/* --- encode and decode -------------------------------------------------- */

ZTEST(spi_proto, test_a_frame_has_the_documented_layout)
{
	const uint8_t p[] = {0xAA, 0xBB};
	int n = spi_proto_encode(buf, sizeof(buf), SPI_PROTO_ECHO, 0x42, p, sizeof(p));

	zassert_equal(n, SPI_PROTO_OVERHEAD + 2);
	zassert_equal(buf[0], 'U');
	zassert_equal(buf[1], 'Q');
	zassert_equal(buf[2], SPI_PROTO_ECHO);
	zassert_equal(buf[3], 0x42);
	zassert_equal(sys_get_le16(&buf[4]), 2);
	zassert_mem_equal(&buf[6], p, 2);
	zassert_equal(sys_get_le16(&buf[8]), spi_proto_crc16(buf, 8));
	/* The same ten bytes are a recorded frame in python/tests/test_spilink.py:
	 * 55 51 01 42 02 00 aa bb 34 f9. */
	zassert_equal(sys_get_le16(&buf[8]), 0xF934);
}

ZTEST(spi_proto, test_frames_round_trip_at_every_edge_size)
{
	const uint16_t sizes[] = {
		0, 1, 2, 255, 256, SPI_PROTO_MAX_PAYLOAD - 1, SPI_PROTO_MAX_PAYLOAD};

	for (size_t i = 0; i < ARRAY_SIZE(sizes); i++) {
		struct spi_proto_frame f;
		int n = spi_proto_encode(buf, sizeof(buf), SPI_PROTO_ECHO, (uint8_t)i, payload,
					 sizes[i]);

		zassert_equal(n, SPI_PROTO_OVERHEAD + sizes[i], "size %u", sizes[i]);
		zassert_ok(spi_proto_decode(buf, sizeof(buf), &f), "size %u", sizes[i]);
		zassert_equal(f.type, SPI_PROTO_ECHO);
		zassert_equal(f.seq, (uint8_t)i);
		zassert_equal(f.len, sizes[i]);
		zassert_mem_equal(f.payload, payload, sizes[i]);
		/* Exactly the frame's own bytes is enough to decode it. */
		zassert_ok(spi_proto_decode(buf, (size_t)n, &f), "size %u, tight", sizes[i]);
	}
}

ZTEST(spi_proto, test_the_largest_frame_fills_one_transaction)
{
	zassert_equal(spi_proto_encode(buf, sizeof(buf), SPI_PROTO_ECHO, 0, payload,
				       SPI_PROTO_MAX_PAYLOAD),
		      SPI_PROTO_XFER_LEN);
}

ZTEST(spi_proto, test_encode_refuses_a_payload_too_long_or_a_buffer_too_short)
{
	zassert_equal(spi_proto_encode(buf, sizeof(buf), SPI_PROTO_ECHO, 0, payload,
				       SPI_PROTO_MAX_PAYLOAD + 1),
		      -EMSGSIZE);
	zassert_equal(spi_proto_encode(buf, SPI_PROTO_OVERHEAD + 9, SPI_PROTO_ECHO, 0, payload, 10),
		      -ENOSPC);
	zassert_equal(
		spi_proto_encode(buf, SPI_PROTO_OVERHEAD + 10, SPI_PROTO_ECHO, 0, payload, 10),
		SPI_PROTO_OVERHEAD + 10);
}

ZTEST(spi_proto, test_a_frame_with_one_bit_wrong_fails_its_crc)
{
	struct spi_proto_frame f;
	int n = spi_proto_encode(buf, sizeof(buf), SPI_PROTO_ECHO, 9, payload, 32);

	/* Every bit of the header, the payload and the CRC itself. The magic
	 * bytes and the length are skipped: those fail their own checks first. */
	for (int byte = 2; byte < n; byte++) {
		if (byte == 4 || byte == 5) {
			continue;
		}
		for (int bit = 0; bit < 8; bit++) {
			buf[byte] ^= BIT(bit);
			zassert_equal(spi_proto_decode(buf, sizeof(buf), &f), -EILSEQ,
				      "byte %d bit %d flipped and still decoded", byte, bit);
			buf[byte] ^= BIT(bit);
		}
	}
	zassert_ok(spi_proto_decode(buf, sizeof(buf), &f));
	zassert_equal(f.seq, 9);
}

ZTEST(spi_proto, test_a_bad_magic_is_not_a_frame)
{
	struct spi_proto_frame f;

	spi_proto_encode(buf, sizeof(buf), SPI_PROTO_NOP, 0, NULL, 0);
	buf[0] = 'Q';
	buf[1] = 'U';
	zassert_equal(spi_proto_decode(buf, sizeof(buf), &f), -EBADMSG, "byte-swapped magic");

	/* What an idle or missed transaction reads as: all zeros, all ones. */
	memset(buf, 0x00, sizeof(buf));
	zassert_equal(spi_proto_decode(buf, sizeof(buf), &f), -EBADMSG);
	memset(buf, 0xFF, sizeof(buf));
	zassert_equal(spi_proto_decode(buf, sizeof(buf), &f), -EBADMSG);
}

ZTEST(spi_proto, test_a_frame_shorter_than_a_header_is_not_a_frame)
{
	struct spi_proto_frame f;

	spi_proto_encode(buf, sizeof(buf), SPI_PROTO_NOP, 0, NULL, 0);
	zassert_equal(spi_proto_decode(buf, SPI_PROTO_HEADER_LEN - 1, &f), -EBADMSG);
	zassert_equal(spi_proto_decode(buf, 0, &f), -EBADMSG);
}

ZTEST(spi_proto, test_a_length_past_the_end_is_refused_before_the_crc)
{
	struct spi_proto_frame f;
	int n = spi_proto_encode(buf, sizeof(buf), SPI_PROTO_ECHO, 5, payload, 20);

	/* One byte short of the CRC's last byte. */
	zassert_equal(spi_proto_decode(buf, (size_t)n - 1, &f), -EMSGSIZE);
	zassert_equal(f.seq, 5, "the seq is still reported, so the error can name it");
	zassert_equal(f.type, SPI_PROTO_ECHO);

	/* A length no transaction could hold. */
	sys_put_le16(SPI_PROTO_MAX_PAYLOAD + 1, &buf[4]);
	zassert_equal(spi_proto_decode(buf, sizeof(buf), &f), -EMSGSIZE);
	zassert_equal(f.len, SPI_PROTO_MAX_PAYLOAD + 1);
	sys_put_le16(0xFFFF, &buf[4]);
	zassert_equal(spi_proto_decode(buf, sizeof(buf), &f), -EMSGSIZE);
}

ZTEST(spi_proto, test_an_error_frame_carries_code_type_and_detail)
{
	struct spi_proto_frame f;

	zassert_equal(spi_proto_encode_error(buf, sizeof(buf), 3, SPI_PROTO_ERR_RANGE,
					     SPI_PROTO_TEMPLOG, 0x12345678),
		      SPI_PROTO_OVERHEAD + SPI_PROTO_ERROR_LEN);
	zassert_ok(spi_proto_decode(buf, sizeof(buf), &f));
	zassert_equal(f.type, SPI_PROTO_ERROR);
	zassert_equal(f.payload[0], SPI_PROTO_ERR_RANGE);
	zassert_equal(f.payload[1], SPI_PROTO_TEMPLOG);
	zassert_equal(sys_get_le32(&f.payload[2]), 0x12345678);
}

/* --- the services, through spi_proto_handle() ---------------------------- */

ZTEST(spi_proto, test_nop_answers_with_an_empty_nop)
{
	const struct spi_proto_services svc = {0};

	spi_proto_encode(buf, sizeof(buf), SPI_PROTO_NOP, 77, NULL, 0);
	zassert_true(handle(&svc));
	zassert_equal(answer(SPI_PROTO_NOP | SPI_PROTO_RESPONSE, 77).len, 0);
}

ZTEST(spi_proto, test_echo_answers_with_the_same_payload_at_full_size)
{
	const struct spi_proto_services svc = {0};
	struct spi_proto_frame f;

	spi_proto_encode(buf, sizeof(buf), SPI_PROTO_ECHO, 200, payload, SPI_PROTO_MAX_PAYLOAD);
	zassert_true(handle(&svc));
	f = answer(SPI_PROTO_ECHO | SPI_PROTO_RESPONSE, 200);
	zassert_equal(f.len, SPI_PROTO_MAX_PAYLOAD);
	zassert_mem_equal(f.payload, payload, SPI_PROTO_MAX_PAYLOAD);
}

ZTEST(spi_proto, test_garbage_is_answered_with_a_magic_error)
{
	const struct spi_proto_services svc = {0};

	memset(buf, 0xFF, sizeof(buf));
	zassert_false(handle(&svc));
	assert_error(0, SPI_PROTO_ERR_MAGIC, 0, 0);
}

ZTEST(spi_proto, test_a_bad_crc_is_answered_with_the_crc_it_got)
{
	const struct spi_proto_services svc = {0};

	spi_proto_encode(buf, sizeof(buf), SPI_PROTO_ECHO, 12, payload, 4);
	buf[6] ^= 1U;
	zassert_false(handle(&svc));
	assert_error(12, SPI_PROTO_ERR_CRC, SPI_PROTO_ECHO, sys_get_le16(&buf[10]));
}

ZTEST(spi_proto, test_a_bad_length_is_answered_with_the_length_it_got)
{
	const struct spi_proto_services svc = {0};

	spi_proto_encode(buf, sizeof(buf), SPI_PROTO_ECHO, 13, NULL, 0);
	sys_put_le16(2000, &buf[4]);
	zassert_false(handle(&svc));
	assert_error(13, SPI_PROTO_ERR_LENGTH, SPI_PROTO_ECHO, 2000);
}

ZTEST(spi_proto, test_an_unknown_type_is_named_in_the_error)
{
	const struct spi_proto_services svc = {0};

	spi_proto_encode(buf, sizeof(buf), 0x55, 14, NULL, 0);
	zassert_true(handle(&svc), "it decoded; it just is not a request");
	assert_error(14, SPI_PROTO_ERR_TYPE, 0x55, 0);
}

ZTEST(spi_proto, test_stat_reports_the_counters_in_order)
{
	const struct spi_proto_stat st = {
		.transactions = 1, .requests = 2, .bad_frames = 3, .spi_errors = 4};
	const struct spi_proto_services svc = {.stat = &st};
	struct spi_proto_frame f;

	spi_proto_encode(buf, sizeof(buf), SPI_PROTO_STAT, 15, NULL, 0);
	zassert_true(handle(&svc));
	f = answer(SPI_PROTO_STAT | SPI_PROTO_RESPONSE, 15);
	zassert_equal(f.len, SPI_PROTO_STAT_LEN);
	for (uint32_t i = 0; i < SPI_PROTO_STAT_COUNT; i++) {
		zassert_equal(sys_get_le32(&f.payload[i * 4]), i + 1, "counter %u", i);
	}
}

ZTEST(spi_proto, test_stat_without_counters_is_zeros_and_takes_no_payload)
{
	const struct spi_proto_services svc = {0};
	struct spi_proto_frame f;

	spi_proto_encode(buf, sizeof(buf), SPI_PROTO_STAT, 16, NULL, 0);
	handle(&svc);
	f = answer(SPI_PROTO_STAT | SPI_PROTO_RESPONSE, 16);
	for (uint32_t i = 0; i < SPI_PROTO_STAT_COUNT; i++) {
		zassert_equal(sys_get_le32(&f.payload[i * 4]), 0);
	}

	spi_proto_encode(buf, sizeof(buf), SPI_PROTO_STAT, 17, payload, 1);
	handle(&svc);
	assert_error(17, SPI_PROTO_ERR_REQUEST, SPI_PROTO_STAT, 1);
}

/* --- TEMPLOG ------------------------------------------------------------ */

static void templog_request(uint8_t seq, bool has_since, uint32_t since)
{
	uint8_t p[SPI_PROTO_TEMPLOG_REQ_LEN];

	p[0] = has_since ? SPI_PROTO_TEMPLOG_SINCE : 0U;
	sys_put_le32(since, &p[1]);
	spi_proto_encode(buf, sizeof(buf), SPI_PROTO_TEMPLOG, seq, p, sizeof(p));
}

static void fill(uint32_t n)
{
	for (uint32_t i = 0; i < n; i++) {
		uint32_t seq = tl.head + 1U;

		templog_record(&tl, (int64_t)seq * 1000, 0, 20000 + (int32_t)seq);
	}
}

ZTEST(spi_proto, test_templog_without_a_log_is_unavailable)
{
	const struct spi_proto_services svc = {0};

	templog_request(20, false, 0);
	zassert_true(handle(&svc));
	assert_error(20, SPI_PROTO_ERR_UNAVAILABLE, SPI_PROTO_TEMPLOG, 0);
}

ZTEST(spi_proto, test_templog_wants_exactly_its_request_payload)
{
	const struct spi_proto_services svc = {.templog = &tl};

	spi_proto_encode(buf, sizeof(buf), SPI_PROTO_TEMPLOG, 21, payload, 4);
	handle(&svc);
	assert_error(21, SPI_PROTO_ERR_REQUEST, SPI_PROTO_TEMPLOG, 4);
}

ZTEST(spi_proto, test_templog_since_returns_the_samples_after_it)
{
	const struct spi_proto_services svc = {.templog = &tl};
	struct spi_proto_frame f;
	const uint8_t *s;

	fill(10);
	templog_record(&tl, 11000, -EIO, 0);

	templog_request(22, true, 7);
	zassert_true(handle(&svc));
	f = answer(SPI_PROTO_TEMPLOG | SPI_PROTO_RESPONSE, 22);
	zassert_equal(f.len, SPI_PROTO_TEMPLOG_HDR_LEN + 4 * SPI_PROTO_TEMPLOG_SAMPLE_LEN);
	zassert_equal(sys_get_le32(&f.payload[0]), 11, "head");
	zassert_equal(sys_get_le32(&f.payload[4]), 0, "no gap");
	zassert_equal(sys_get_le32(&f.payload[12]), 0, "nothing more");
	zassert_equal(sys_get_le16(&f.payload[16]), 4, "n");

	s = &f.payload[SPI_PROTO_TEMPLOG_HDR_LEN];
	for (uint32_t seq = 8; seq <= 10; seq++, s += SPI_PROTO_TEMPLOG_SAMPLE_LEN) {
		zassert_equal(sys_get_le32(&s[0]), seq);
		zassert_equal(sys_get_le64(&s[4]), (uint64_t)seq * 1000);
		zassert_equal((int32_t)sys_get_le32(&s[12]), 20000 + (int32_t)seq);
		zassert_equal(s[16], 1, "ok");
	}
	/* The failed read: its errno, and not ok. */
	zassert_equal(sys_get_le32(&s[0]), 11);
	zassert_equal((int32_t)sys_get_le32(&s[12]), -EIO);
	zassert_equal(s[16], 0);
}

ZTEST(spi_proto, test_templog_caps_one_answer_and_says_how_many_wait)
{
	const struct spi_proto_services svc = {.templog = &tl};
	struct spi_proto_frame f;

	fill(SPI_PROTO_TEMPLOG_MAX + 5);
	templog_request(23, false, 0);
	handle(&svc);
	f = answer(SPI_PROTO_TEMPLOG | SPI_PROTO_RESPONSE, 23);
	zassert_equal(sys_get_le16(&f.payload[16]), SPI_PROTO_TEMPLOG_MAX);
	zassert_equal(sys_get_le32(&f.payload[12]), 5, "more");
	zassert_true(f.len <= SPI_PROTO_MAX_PAYLOAD, "a full answer still fits a transaction");
}

ZTEST(spi_proto, test_templog_reports_a_gap_like_the_shell)
{
	const struct spi_proto_services svc = {.templog = &tl};
	struct spi_proto_frame f;

	fill(APP_TEMPLOG_SIZE + 10);
	templog_request(24, true, 3);
	handle(&svc);
	f = answer(SPI_PROTO_TEMPLOG | SPI_PROTO_RESPONSE, 24);
	zassert_equal(sys_get_le32(&f.payload[4]), 4, "gap_first");
	zassert_equal(sys_get_le32(&f.payload[8]), 10, "gap_last");
}

ZTEST(spi_proto, test_templog_since_past_the_head_is_a_range_error_naming_the_head)
{
	const struct spi_proto_services svc = {.templog = &tl};

	fill(3);
	templog_request(25, true, 99);
	handle(&svc);
	assert_error(25, SPI_PROTO_ERR_RANGE, SPI_PROTO_TEMPLOG, 3);
}

ZTEST(spi_proto, test_templog_never_writes_past_a_small_buffer)
{
	const struct spi_proto_services svc = {.templog = &tl};
	const size_t cap =
		SPI_PROTO_OVERHEAD + SPI_PROTO_TEMPLOG_HDR_LEN + 2 * SPI_PROTO_TEMPLOG_SAMPLE_LEN;
	struct spi_proto_frame f;
	bool decoded;

	fill(10);
	templog_request(26, false, 0);
	memset(tx, 0xEE, sizeof(tx));
	zassert_equal(spi_proto_handle(buf, sizeof(buf), tx, cap, &svc, &decoded), (int)cap);
	zassert_equal(tx[cap], 0xEE, "wrote past cap");
	zassert_ok(spi_proto_decode(tx, cap, &f));
	zassert_equal(sys_get_le16(&f.payload[16]), 2);
	zassert_equal(sys_get_le32(&f.payload[12]), 8, "more");

	/* Not even room for the header: refused outright, nothing written. */
	memset(tx, 0xEE, sizeof(tx));
	zassert_equal(spi_proto_handle(buf, sizeof(buf), tx,
				       SPI_PROTO_OVERHEAD + SPI_PROTO_TEMPLOG_HDR_LEN - 1, &svc,
				       &decoded),
		      -ENOSPC);
	zassert_equal(tx[0], 0xEE);
}

/* --- SCOPE --------------------------------------------------------------- */

static uint16_t scope_buf[APP_SCOPE_N_MAX];
static struct scope_burst sb;

static void scope_request(uint8_t seq, uint32_t id, uint16_t offset)
{
	uint8_t p[SPI_PROTO_SCOPE_REQ_LEN];

	sys_put_le32(id, &p[0]);
	sys_put_le16(offset, &p[4]);
	spi_proto_encode(buf, sizeof(buf), SPI_PROTO_SCOPE, seq, p, sizeof(p));
}

/* A capture of n samples whose value is 3 * index + 1, as the DMA would have
 * left it, at 50 kHz. */
static uint32_t scope_capture(uint16_t n)
{
	scope_burst_init(&sb, scope_buf, ARRAY_SIZE(scope_buf));
	zassert_ok(scope_burst_begin(&sb, n, 50000000));
	for (uint16_t i = 0; i < n; i++) {
		scope_buf[i] = (uint16_t)(3U * i + 1U);
	}
	return scope_burst_end(&sb, true);
}

ZTEST(spi_proto, test_scope_without_a_burst_is_unavailable)
{
	const struct spi_proto_services svc = {0};

	scope_request(40, 0, 0);
	zassert_true(handle(&svc));
	assert_error(40, SPI_PROTO_ERR_UNAVAILABLE, SPI_PROTO_SCOPE, 0);
}

ZTEST(spi_proto, test_scope_wants_exactly_its_request_payload)
{
	const struct spi_proto_services svc = {.scope = &sb};

	spi_proto_encode(buf, sizeof(buf), SPI_PROTO_SCOPE, 41, payload, 5);
	handle(&svc);
	assert_error(41, SPI_PROTO_ERR_REQUEST, SPI_PROTO_SCOPE, 5);
}

ZTEST(spi_proto, test_scope_before_any_capture_and_during_one_is_unavailable)
{
	const struct spi_proto_services svc = {.scope = &sb};

	scope_burst_init(&sb, scope_buf, ARRAY_SIZE(scope_buf));
	scope_request(42, 0, 0);
	handle(&svc);
	assert_error(42, SPI_PROTO_ERR_UNAVAILABLE, SPI_PROTO_SCOPE, 0);

	zassert_ok(scope_burst_begin(&sb, 100, 1000000));
	scope_request(43, 0, 0);
	handle(&svc);
	assert_error(43, SPI_PROTO_ERR_UNAVAILABLE, SPI_PROTO_SCOPE, 1);
}

ZTEST(spi_proto, test_scope_reads_a_whole_burst_in_pieces)
{
	const struct spi_proto_services svc = {.scope = &sb};
	const uint16_t n = APP_SCOPE_N_MAX;
	uint32_t id = scope_capture(n);
	uint16_t offset = 0;
	uint8_t seq = 44;
	int answers = 0;

	zassert_equal(id, 1);
	do {
		struct spi_proto_frame f;
		uint16_t count;

		scope_request(seq, answers == 0 ? 0 : id, offset);
		zassert_true(handle(&svc));
		f = answer(SPI_PROTO_SCOPE | SPI_PROTO_RESPONSE, seq);
		zassert_equal(sys_get_le32(&f.payload[0]), id, "id");
		zassert_equal(sys_get_le32(&f.payload[4]), 50000000, "rate_mhz");
		zassert_equal(sys_get_le16(&f.payload[8]), n, "n");
		zassert_equal(sys_get_le16(&f.payload[10]), offset, "offset");
		count = sys_get_le16(&f.payload[12]);
		zassert_equal(count, MIN(SPI_PROTO_SCOPE_MAX, n - offset));
		zassert_equal(f.len, SPI_PROTO_SCOPE_HDR_LEN + count * SPI_PROTO_SCOPE_SAMPLE_LEN);
		for (uint16_t i = 0; i < count; i++) {
			zassert_equal(sys_get_le16(&f.payload[SPI_PROTO_SCOPE_HDR_LEN + 2 * i]),
				      3U * (offset + i) + 1U, "sample %u", offset + i);
		}
		offset += count;
		seq++;
		answers++;
	} while (offset < n);
	zassert_equal(answers, DIV_ROUND_UP(n, SPI_PROTO_SCOPE_MAX));

	/* At the end: an empty answer, not an error. */
	scope_request(seq, id, n);
	handle(&svc);
	zassert_equal(sys_get_le16(&answer(SPI_PROTO_SCOPE | SPI_PROTO_RESPONSE, seq).payload[12]),
		      0);
}

ZTEST(spi_proto, test_scope_past_the_end_is_a_range_error_naming_n)
{
	const struct spi_proto_services svc = {.scope = &sb};

	scope_capture(100);
	scope_request(50, 0, 101);
	handle(&svc);
	assert_error(50, SPI_PROTO_ERR_RANGE, SPI_PROTO_SCOPE, 100);
}

ZTEST(spi_proto, test_scope_names_the_capture_held_when_asked_for_another)
{
	const struct spi_proto_services svc = {.scope = &sb};

	scope_capture(100);
	zassert_ok(scope_burst_begin(&sb, 100, 50000000));
	zassert_equal(scope_burst_end(&sb, true), 2);
	scope_request(51, 1, 0);
	handle(&svc);
	assert_error(51, SPI_PROTO_ERR_STALE, SPI_PROTO_SCOPE, 2);
}

ZTEST(spi_proto, test_scope_never_writes_past_a_small_buffer)
{
	const struct spi_proto_services svc = {.scope = &sb};
	const size_t cap = SPI_PROTO_OVERHEAD + SPI_PROTO_SCOPE_HDR_LEN + 3 * 2;
	struct spi_proto_frame f;
	bool decoded;

	scope_capture(100);
	scope_request(52, 0, 0);
	memset(tx, 0xEE, sizeof(tx));
	zassert_equal(spi_proto_handle(buf, sizeof(buf), tx, cap, &svc, &decoded), (int)cap);
	zassert_equal(tx[cap], 0xEE, "wrote past cap");
	zassert_ok(spi_proto_decode(tx, cap, &f));
	zassert_equal(sys_get_le16(&f.payload[12]), 3);

	memset(tx, 0xEE, sizeof(tx));
	zassert_equal(spi_proto_handle(buf, sizeof(buf), tx,
				       SPI_PROTO_OVERHEAD + SPI_PROTO_SCOPE_HDR_LEN - 1, &svc,
				       &decoded),
		      -ENOSPC);
	zassert_equal(tx[0], 0xEE);
}

ZTEST_SUITE(spi_proto, NULL, NULL, reset, NULL, NULL);
