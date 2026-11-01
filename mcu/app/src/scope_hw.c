/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * The scope's hardware, and `app scope`. See scope.h for what it is, and
 * app_proto.h for the commands and their lines.
 *
 *   generator   TIM7's update event triggers DAC1 channel 1, and each
 *               trigger takes the next word of the table from GPDMA1
 *               channel SCOPE_DAC_DMA_CH, round and round (cyclic). No CPU
 *               after the start.
 *   capture     TIM6's update event triggers ADC1 on channel 9, and each
 *               conversion goes to RAM by GPDMA1 channel SCOPE_ADC_DMA_CH,
 *               once (one-shot), n samples. The DMA's completion interrupt
 *               is the only CPU in it.
 *
 * Both outputs are PA4: the DAC drives the pin through its buffer, and the
 * ADC's channel 9 is the same pin, so a capture reads what the generator is
 * playing. With the generator off the DAC lets go of the pin, and a capture
 * reads whatever is wired to A0.
 *
 * WHY REGISTERS
 * -------------
 * Zephyr's STM32 DAC driver writes one value from software; it has no
 * trigger and no DMA. Its ADC driver starts each conversion from software,
 * and with CONFIG_ADC_STM32_DMA moves one sequence per DMA transfer, so a
 * burst would be a software-timed loop. The timers, the DAC and the ADC's
 * trigger are therefore set with STM32Cube LL here. What Zephyr does do is
 * used: its GPDMA driver moves the data (cyclic for the DAC, a single block
 * for the ADC), and its clock control turns the peripherals' clocks on.
 *
 * SHARING ADC1
 * ------------
 * The die temperature (main.c, templog.c) reads adc1 through Zephyr's ADC
 * driver, which still owns the converter. A capture borrows it: it takes
 * adc1_lock, which every temperature read takes too, saves the registers
 * the driver relies on, programs its own, and when the burst is in puts the
 * saved ones back and leaves the ADC disabled, the state the driver's next
 * read expects to enable it from. The driver re-programs resolution,
 * sequence and preselection on every read; what it never touches - the
 * trigger, the DMA mode, the interrupt enables it leaves set - is what has
 * to be restored, and this restores all of them anyway.
 */
#include <errno.h>
#include <zephyr/device.h>
#include <zephyr/drivers/clock_control.h>
#include <zephyr/drivers/clock_control/stm32_clock_control.h>
#include <zephyr/drivers/dma.h>
#include <zephyr/kernel.h>
#include <zephyr/shell/shell.h>
#include <zephyr/sys/util.h>

#include <stm32_ll_adc.h>
#include <stm32_ll_dac.h>
#include <stm32_ll_dma.h>
#include <stm32_ll_tim.h>

#include "app_proto.h"
#include "scope.h"
#include "status_leds.h"

/* GPDMA1 channels. Nothing else in this build uses the GPDMA: the SPI link
 * and the ADC driver are both built without DMA. */
#define SCOPE_ADC_DMA_CH 14
#define SCOPE_DAC_DMA_CH 15

/* TIM6 and TIM7 count the APB1 timer clock: PCLK1, doubled when APB1 is
 * divided. 160 MHz on this board. */
#define SCOPE_HCLK_HZ (STM32_HCLK_FREQUENCY / STM32_AHB_PRESCALER)
#define SCOPE_TIMER_HZ                                                                             \
	(STM32_APB1_PRESCALER == 1 ? SCOPE_HCLK_HZ : 2 * SCOPE_HCLK_HZ / STM32_APB1_PRESCALER)

/* How long a capture may take past its own length before it is abandoned. */
#define SCOPE_CAPTURE_SLACK_MS 100
/* The ADC's enable and disable take a few of its clock cycles; this is far
 * past that, and only there so a converter that never answers cannot hang
 * the shell. */
#define SCOPE_ADC_WAIT_US      1000

K_MUTEX_DEFINE(adc1_lock);

static const struct device *const dma = DEVICE_DT_GET(DT_NODELABEL(gpdma1));
static const struct device *const rcc = DEVICE_DT_GET(STM32_CLOCK_CONTROL_NODE);
static const struct stm32_pclken tim6_clk = STM32_CLOCK_INFO(0, DT_NODELABEL(timers6));
static const struct stm32_pclken tim7_clk = STM32_CLOCK_INFO(0, DT_NODELABEL(timers7));
static const struct stm32_pclken dac1_clk = STM32_CLOCK_INFO(0, DT_NODELABEL(dac1));

static uint32_t dac_table[APP_SCOPE_POINTS];
static uint16_t samples[APP_SCOPE_N_MAX];
/* Empty until the first capture: valid false, so the SPI service answers
 * "unavailable" rather than handing out zeros. */
static struct scope_burst burst = {.buf = samples, .cap = APP_SCOPE_N_MAX};
static K_SEM_DEFINE(capture_done, 0, 1);
static volatile int capture_status;
static bool clocks_on;
static enum scope_wave wave = SCOPE_WAVE_OFF;
static uint64_t wave_mhz; /* the waveform's frequency, millihertz */

static int scope_clocks_on(void)
{
	int rc;

	if (clocks_on) {
		return 0;
	}
	if (!device_is_ready(rcc) || !device_is_ready(dma)) {
		return -ENODEV;
	}
	rc = clock_control_on(rcc, (clock_control_subsys_t)&tim6_clk);
	if (rc == 0) {
		rc = clock_control_on(rcc, (clock_control_subsys_t)&tim7_clk);
	}
	if (rc == 0) {
		rc = clock_control_on(rcc, (clock_control_subsys_t)&dac1_clk);
	}
	clocks_on = rc == 0;
	return rc;
}

struct scope_burst *scope_burst_get(void)
{
	return &burst;
}

/* A basic timer whose update event is its trigger output, stopped. The
 * forced update loads the prescaler now rather than at the first overflow;
 * whatever it triggers is ignored, because the DAC and ADC are armed after. */
static void timer_setup(TIM_TypeDef *tim, const struct scope_div *d)
{
	LL_TIM_DisableCounter(tim);
	LL_TIM_SetPrescaler(tim, d->psc);
	LL_TIM_SetAutoReload(tim, d->arr);
	LL_TIM_SetCounter(tim, 0);
	LL_TIM_GenerateEvent_UPDATE(tim);
	LL_TIM_ClearFlag_UPDATE(tim);
	LL_TIM_SetTriggerOutput(tim, LL_TIM_TRGO_UPDATE);
}

static void print_mhz(uint64_t mhz, unsigned int *whole, unsigned int *frac)
{
	*whole = (unsigned int)(mhz / 1000U);
	*frac = (unsigned int)(mhz % 1000U);
}

/* --- the generator --------------------------------------------------------- */

static void gen_stop(void)
{
	LL_TIM_DisableCounter(TIM7);
	LL_DAC_Disable(DAC1, LL_DAC_CHANNEL_1);
	LL_DAC_DisableDMAReq(DAC1, LL_DAC_CHANNEL_1);
	LL_DAC_DisableTrigger(DAC1, LL_DAC_CHANNEL_1);
	(void)dma_stop(dma, SCOPE_DAC_DMA_CH);
	wave = SCOPE_WAVE_OFF;
	wave_mhz = 0;
}

static int gen_start(enum scope_wave w, uint32_t hz)
{
	struct dma_block_config blk = {
		.source_address = (uint32_t)dac_table,
		.dest_address = LL_DAC_DMA_GetRegAddr(DAC1, LL_DAC_CHANNEL_1,
						      LL_DAC_DMA_REG_DATA_12BITS_RIGHT_ALIGNED),
		.block_size = sizeof(dac_table),
		.source_addr_adj = DMA_ADDR_ADJ_INCREMENT,
		.dest_addr_adj = DMA_ADDR_ADJ_NO_CHANGE,
		.source_reload_en = 1, /* cyclic: round the table for ever */
	};
	struct dma_config cfg = {
		.dma_slot = LL_GPDMA1_REQUEST_DAC1_CH1,
		.channel_direction = MEMORY_TO_PERIPHERAL,
		.cyclic = 1,
		.source_data_size = 4,
		.dest_data_size = 4,
		.source_burst_length = 4,
		.dest_burst_length = 4,
		.block_count = 1,
		.head_block = &blk,
	};
	struct scope_div d;
	int rc;

	gen_stop();
	rc = scope_wave_fill(w, dac_table);
	if (rc == 0) {
		rc = scope_timer_div(SCOPE_TIMER_HZ, hz * APP_SCOPE_POINTS, &d);
	}
	if (rc != 0) {
		return rc;
	}
	timer_setup(TIM7, &d);

	/* Above 80 MHz of AHB clock the DAC's bus interface has to be told. */
	LL_DAC_SetHighFrequencyMode(DAC1, SCOPE_HCLK_HZ > 80000000
						  ? LL_DAC_HIGH_FREQ_MODE_ABOVE_80MHZ
						  : LL_DAC_HIGH_FREQ_MODE_DISABLE);
	LL_DAC_ConfigOutput(DAC1, LL_DAC_CHANNEL_1, LL_DAC_OUTPUT_MODE_NORMAL,
			    LL_DAC_OUTPUT_BUFFER_ENABLE, LL_DAC_OUTPUT_CONNECT_GPIO);
	LL_DAC_SetTriggerSource(DAC1, LL_DAC_CHANNEL_1, LL_DAC_TRIG_EXT_TIM7_TRGO);
	LL_DAC_EnableTrigger(DAC1, LL_DAC_CHANNEL_1);
	LL_DAC_EnableDMAReq(DAC1, LL_DAC_CHANNEL_1);
	LL_DAC_ConvertData12RightAligned(DAC1, LL_DAC_CHANNEL_1, dac_table[0]);

	rc = dma_config(dma, SCOPE_DAC_DMA_CH, &cfg);
	if (rc == 0) {
		rc = dma_start(dma, SCOPE_DAC_DMA_CH);
	}
	if (rc != 0) {
		gen_stop();
		return rc;
	}
	/* The driver interrupts at each half and each end of the table, to call
	 * a callback there is none of: up to 20000 interrupts a second at the
	 * top frequency, for nothing. Errors still interrupt. */
	LL_DMA_DisableIT_HT(GPDMA1, LL_DMA_CHANNEL_15);
	LL_DMA_DisableIT_TC(GPDMA1, LL_DMA_CHANNEL_15);

	LL_DAC_Enable(DAC1, LL_DAC_CHANNEL_1);
	k_busy_wait(10); /* the output buffer's wake-up, 8 us at most */
	LL_TIM_EnableCounter(TIM7);

	wave = w;
	wave_mhz = d.rate_mhz / APP_SCOPE_POINTS;
	return 0;
}
BUILD_ASSERT(SCOPE_DAC_DMA_CH == 15, "gen_start() names LL_DMA_CHANNEL_15");

/* --- the capture ----------------------------------------------------------- */

static void on_capture_dma(const struct device *dev, void *user_data, uint32_t channel, int status)
{
	ARG_UNUSED(dev);
	ARG_UNUSED(user_data);
	ARG_UNUSED(channel);

	/* Stop the trigger at once: the burst is in. */
	LL_TIM_DisableCounter(TIM6);
	capture_status = status;
	k_sem_give(&capture_done);
}

static bool adc_wait(bool (*done)(void))
{
	for (int us = 0; us < SCOPE_ADC_WAIT_US; us++) {
		if (done()) {
			return true;
		}
		k_busy_wait(1);
	}
	return done();
}

static bool adc_disabled(void)
{
	return LL_ADC_IsEnabled(ADC1) == 0U;
}

static bool adc_ready(void)
{
	return LL_ADC_IsActiveFlag_ADRDY(ADC1) != 0U;
}

static bool adc_stopped(void)
{
	return LL_ADC_REG_IsConversionOngoing(ADC1) == 0U;
}

static int adc_disable(void)
{
	if (!adc_wait(adc_stopped)) {
		LL_ADC_REG_StopConversion(ADC1);
	}
	if (!adc_wait(adc_stopped)) {
		return -ETIMEDOUT;
	}
	if (LL_ADC_IsEnabled(ADC1) != 0U) {
		LL_ADC_Disable(ADC1);
	}
	return adc_wait(adc_disabled) ? 0 : -ETIMEDOUT;
}

/* What the ADC driver left, and gets back. */
struct adc_saved {
	uint32_t cfgr1, cfgr2, smpr1, smpr2, sqr1, pcsel, ier;
};

static int capture(uint16_t n, const struct scope_div *d)
{
	struct dma_block_config blk = {
		.source_address = LL_ADC_DMA_GetRegAddr(ADC1, LL_ADC_DMA_REG_REGULAR_DATA),
		.dest_address = (uint32_t)samples,
		.block_size = n * sizeof(samples[0]),
		.source_addr_adj = DMA_ADDR_ADJ_NO_CHANGE,
		.dest_addr_adj = DMA_ADDR_ADJ_INCREMENT,
	};
	struct dma_config cfg = {
		.dma_slot = LL_GPDMA1_REQUEST_ADC1,
		.channel_direction = PERIPHERAL_TO_MEMORY,
		.source_data_size = 2,
		.dest_data_size = 2,
		.source_burst_length = 2,
		.dest_burst_length = 2,
		.block_count = 1,
		.head_block = &blk,
		.dma_callback = on_capture_dma,
	};
	uint32_t ms = (uint32_t)((uint64_t)n * 1000000U / d->rate_mhz) + SCOPE_CAPTURE_SLACK_MS;
	struct adc_saved s;
	int rc;

	rc = adc_disable();
	if (rc != 0) {
		return rc;
	}
	s = (struct adc_saved){ADC1->CFGR1, ADC1->CFGR2, ADC1->SMPR1, ADC1->SMPR2,
			       ADC1->SQR1,  ADC1->PCSEL, ADC1->IER};

	/* The driver's end-of-conversion interrupt would read DR itself, into
	 * whatever buffer its last read left it - off for the burst. */
	ADC1->IER = 0;
	LL_ADC_SetResolution(ADC1, LL_ADC_RESOLUTION_14B);
	LL_ADC_REG_SetTriggerSource(ADC1, LL_ADC_REG_TRIG_EXT_TIM6_TRGO);
	LL_ADC_REG_SetTriggerEdge(ADC1, LL_ADC_REG_TRIG_EXT_RISING);
	LL_ADC_REG_SetContinuousMode(ADC1, LL_ADC_REG_CONV_SINGLE);
	LL_ADC_REG_SetDataTransferMode(ADC1, LL_ADC_REG_DMA_TRANSFER_LIMITED);
	LL_ADC_REG_SetOverrun(ADC1, LL_ADC_REG_OVR_DATA_OVERWRITTEN);
	LL_ADC_REG_SetSequencerLength(ADC1, LL_ADC_REG_SEQ_SCAN_DISABLE);
	LL_ADC_REG_SetSequencerRanks(ADC1, LL_ADC_REG_RANK_1, LL_ADC_CHANNEL_9);
	LL_ADC_SetChannelSamplingTime(ADC1, LL_ADC_CHANNEL_9, LL_ADC_SAMPLINGTIME_68CYCLES);
	LL_ADC_SetChannelPreselection(ADC1, LL_ADC_CHANNEL_9);
	timer_setup(TIM6, d);

	k_sem_reset(&capture_done);
	capture_status = -EINPROGRESS;
	LL_ADC_ClearFlag_ADRDY(ADC1);
	LL_ADC_Enable(ADC1);
	rc = adc_wait(adc_ready) ? 0 : -ETIMEDOUT;
	if (rc == 0) {
		rc = dma_config(dma, SCOPE_ADC_DMA_CH, &cfg);
	}
	if (rc == 0) {
		rc = dma_start(dma, SCOPE_ADC_DMA_CH);
	}
	if (rc == 0) {
		/* Armed: the conversions wait for TIM6. */
		LL_ADC_REG_StartConversion(ADC1);
		LL_TIM_EnableCounter(TIM6);
		rc = k_sem_take(&capture_done, K_MSEC(ms));
		rc = rc == 0 ? capture_status : -ETIMEDOUT;
	}

	LL_TIM_DisableCounter(TIM6);
	(void)dma_stop(dma, SCOPE_ADC_DMA_CH);
	(void)adc_disable();
	ADC1->CFGR1 = s.cfgr1;
	ADC1->CFGR2 = s.cfgr2;
	ADC1->SMPR1 = s.smpr1;
	ADC1->SMPR2 = s.smpr2;
	ADC1->SQR1 = s.sqr1;
	ADC1->PCSEL = s.pcsel;
	ADC1->ISR = ADC1->ISR; /* every flag is cleared by writing it back */
	ADC1->IER = s.ier;
	return rc;
}

/* --- the shell ------------------------------------------------------------- */

static int cmd_scope_gen(const struct shell *sh, size_t argc, char **argv)
{
	status_leds_link_seen();
	enum scope_wave w;
	unsigned int whole, frac;
	int hz;
	int rc;

	ARG_UNUSED(argc);

	if (scope_wave_parse(argv[1], &w) != 0) {
		shell_error(sh, APP_ERR "wave: '%s' is not %s or %s", argv[1], APP_SCOPE_WAVE_SINE,
			    APP_SCOPE_WAVE_TRIANGLE);
		return -EINVAL;
	}
	if (!app_parse_int(argv[2], &hz) || !app_scope_wave_hz_valid(hz)) {
		shell_error(sh, APP_ERR "hz: '%s' is not %d..%d", argv[2], APP_SCOPE_WAVE_HZ_MIN,
			    APP_SCOPE_WAVE_HZ_MAX);
		return -EINVAL;
	}
	rc = scope_clocks_on();
	if (rc == 0) {
		rc = gen_start(w, (uint32_t)hz);
	}
	if (rc != 0) {
		shell_error(sh, APP_ERR "the generator did not start (%d)", rc);
		return rc;
	}
	print_mhz(wave_mhz, &whole, &frac);
	shell_print(sh, APP_SCOPE_GEN_FMT, scope_wave_name(w), (unsigned int)hz, whole, frac);
	return 0;
}

static int cmd_scope_capture(const struct shell *sh, size_t argc, char **argv)
{
	status_leds_link_seen();
	struct scope_div d;
	uint16_t lo, hi, mean;
	unsigned int whole, frac;
	uint32_t id;
	int n, rate;
	int rc;

	ARG_UNUSED(argc);

	if (!app_parse_int(argv[1], &n) || !app_parse_int(argv[2], &rate) ||
	    !app_scope_capture_valid(n, rate)) {
		shell_error(sh,
			    APP_ERR "capture: n %d..%d at %d..%d Hz, at most %d ms long: "
				    "'%s %s' is not",
			    APP_SCOPE_N_MIN, APP_SCOPE_N_MAX, APP_SCOPE_RATE_HZ_MIN,
			    APP_SCOPE_RATE_HZ_MAX, APP_SCOPE_BURST_MS_MAX, argv[1], argv[2]);
		return -EINVAL;
	}
	rc = scope_clocks_on();
	if (rc == 0) {
		rc = scope_timer_div(SCOPE_TIMER_HZ, (uint32_t)rate, &d);
	}
	if (rc == 0) {
		rc = scope_burst_begin(&burst, (uint16_t)n, (uint32_t)d.rate_mhz);
	}
	if (rc != 0) {
		shell_error(sh, APP_ERR "capture did not start (%d)", rc);
		return rc;
	}

	k_mutex_lock(&adc1_lock, K_FOREVER);
	rc = capture((uint16_t)n, &d);
	k_mutex_unlock(&adc1_lock);
	id = scope_burst_end(&burst, rc == 0);
	if (rc != 0) {
		shell_error(sh, APP_ERR "capture failed (%d)", rc);
		return rc;
	}

	scope_summary(samples, (size_t)n, &lo, &hi, &mean);
	print_mhz(d.rate_mhz, &whole, &frac);
	shell_print(sh, APP_SCOPE_CAPTURE_FMT, (unsigned int)id, (unsigned int)n, whole, frac,
		    (unsigned int)lo, (unsigned int)hi, (unsigned int)mean);
	return 0;
}

static int cmd_scope_stat(const struct shell *sh, size_t argc, char **argv)
{
	status_leds_link_seen();
	struct scope_burst_info i = scope_burst_info(&burst);
	unsigned int ww, wf, rw, rf;

	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	print_mhz(wave_mhz, &ww, &wf);
	print_mhz(i.rate_mhz, &rw, &rf);
	shell_print(sh, APP_SCOPE_STAT_FMT, scope_wave_name(wave), ww, wf, (unsigned int)i.id,
		    (unsigned int)i.n, rw, rf, (unsigned int)i.busy, (unsigned int)i.errors);
	return 0;
}

static int cmd_scope_off(const struct shell *sh, size_t argc, char **argv)
{
	status_leds_link_seen();
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	if (clocks_on) {
		gen_stop();
	}
	shell_print(sh, APP_SCOPE_OFF_FMT);
	return 0;
}

/* Not SHELL_STATIC_SUBCMD_SET_CREATE, whose set is static: main.c's `app`
 * table names this one, so it has to be visible there. */
static const struct shell_static_entry scope_entries[] = {
	SHELL_CMD_ARG(gen, NULL, "Play a wave out of A0: app scope gen <sine|triangle> <hz>",
		      cmd_scope_gen, 3, 0),
	SHELL_CMD_ARG(capture, NULL, "Sample A0 into RAM: app scope capture <n> <rate_hz>",
		      cmd_scope_capture, 3, 0),
	SHELL_CMD(stat, NULL, "The wave playing and the last capture", cmd_scope_stat),
	SHELL_CMD(off, NULL, "Stop the wave; the capture stays", cmd_scope_off),
	SHELL_SUBCMD_SET_END,
};
const union shell_cmd_entry scope_cmds = {.entry = scope_entries};
