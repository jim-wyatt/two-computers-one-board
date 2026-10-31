/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * The MCU's end of the SPI link: spi3 as a slave, facing Linux's
 * /dev/spidev0.0. The frames and the services are spi_proto.c; this file is
 * the thread that moves them.
 *
 * One thread, started by K_THREAD_DEFINE, so main.c does not call anything:
 *
 *   1. wait for chip select (PG12) to be high, so the slave is never armed in
 *      the middle of a transaction Linux has already begun
 *   2. arm one SPI_PROTO_XFER_LEN transfer: tx holds the answer to the last
 *      request, rx takes the next one
 *   3. block until Linux has clocked the whole transaction
 *   4. decode it, and build the answer the next transaction will carry
 *
 * Between 3 and 2 the slave is not listening. A transaction Linux starts in
 * that window is missed by the MCU and reads back as no frame at all, which
 * spilink.py treats as "ask again". The answer it was waiting for is not lost:
 * tx still holds it, and goes up on the next transaction instead.
 *
 * The transfer is interrupt-driven, one interrupt per byte. That is what caps
 * the clock: past some rate the CPU stops keeping the FIFO fed, the driver
 * reports an underrun or overrun, and the transaction is counted in
 * spi_errors. `python -m unoq.spilink bench` finds where that is. DMA would
 * lift it; it is part of #159's second half.
 */
#include <errno.h>
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/spi.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>

#include "spi_proto.h"
#include "templog.h"

#define SPI_LINK_NODE     DT_NODELABEL(spi3)
/* Chip select, as the board file's spi3 pinctrl has it: spi3_nss_pg12. Read
 * through the port's input register, which an STM32 pin in its alternate
 * function still updates - the read does not take the pin from the SPI. */
#define SPI_LINK_NSS_PORT DT_NODELABEL(gpiog)
#define SPI_LINK_NSS_PIN  12

#define SPI_LINK_STACK_SIZE 1024
#define SPI_LINK_PRIORITY   K_PRIO_PREEMPT(7)

/* See spi_proto.h: main.c's to override. Until it does, TEMPLOG answers
 * SPI_PROTO_ERR_UNAVAILABLE rather than handing out a second, empty log. */
__weak struct templog *spi_link_templog(void)
{
	return NULL;
}

static uint8_t rx_buf[SPI_PROTO_XFER_LEN];
static uint8_t tx_buf[SPI_PROTO_XFER_LEN];
static struct spi_proto_stat stat;

static const struct spi_config spi_link_cfg = {
	/* Mode 0, 8-bit, MSB first: what spidev uses unless told otherwise.
	 * The frequency is Linux's to choose; a slave's is only checked against
	 * the prescaler table, so any rate the table holds will do. */
	.frequency = 1000000,
	.operation = SPI_OP_MODE_SLAVE | SPI_WORD_SET(8) | SPI_TRANSFER_MSB,
};

static bool nss_low(const struct device *port)
{
	gpio_port_value_t v;

	return gpio_port_get_raw(port, &v) == 0 && (v & BIT(SPI_LINK_NSS_PIN)) == 0U;
}

static void spi_link_thread(void *a, void *b, void *c)
{
	const struct device *spi = DEVICE_DT_GET(SPI_LINK_NODE);
	const struct device *port = DEVICE_DT_GET(SPI_LINK_NSS_PORT);
	const struct spi_buf txb = {.buf = tx_buf, .len = sizeof(tx_buf)};
	const struct spi_buf rxb = {.buf = rx_buf, .len = sizeof(rx_buf)};
	const struct spi_buf_set txs = {.buffers = &txb, .count = 1};
	const struct spi_buf_set rxs = {.buffers = &rxb, .count = 1};
	struct spi_proto_services svc = {.stat = &stat};
	bool decoded;

	ARG_UNUSED(a);
	ARG_UNUSED(b);
	ARG_UNUSED(c);

	if (!device_is_ready(spi) || !device_is_ready(port)) {
		printk("spi link unavailable\n");
		return;
	}
	svc.templog = spi_link_templog();

	/* Something to send before any request has come: a NOP answer, seq 0. */
	(void)spi_proto_encode(tx_buf, sizeof(tx_buf), SPI_PROTO_NOP | SPI_PROTO_RESPONSE, 0, NULL,
			       0);
	printk("spi link: spi3 slave, %d-byte transactions\n", SPI_PROTO_XFER_LEN);

	for (;;) {
		int rc;

		while (nss_low(port)) {
			k_sleep(K_TICKS(1));
		}

		rc = spi_transceive(spi, &spi_link_cfg, &txs, &rxs);
		stat.transactions++;
		if (rc < 0) {
			/* tx is left as it was: the answer Linux did not get yet. */
			stat.spi_errors++;
			continue;
		}

		(void)spi_proto_handle(rx_buf, sizeof(rx_buf), tx_buf, sizeof(tx_buf), &svc,
				       &decoded);
		if (decoded) {
			stat.requests++;
		} else {
			stat.bad_frames++;
		}
	}
}

K_THREAD_DEFINE(spi_link, SPI_LINK_STACK_SIZE, spi_link_thread, NULL, NULL, NULL, SPI_LINK_PRIORITY,
		0, 0);
