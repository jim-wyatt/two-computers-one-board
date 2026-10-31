<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# What the board can do

Every peripheral and subsystem found on the two chips, whether this project
uses it, and which ones are worth a demonstration. It is the survey
[issue #34](https://github.com/jim-wyatt/two-computers-one-board/issues/34)
asked for before any second app is built, and it ends with the
demonstrations proposed from it.

> [!NOTE]
> Only what there is evidence for is listed, and the **Evidence** column says
> where it is. The MCU side was read from Zephyr's board files
> (`zephyr/boards/arduino/uno_q/arduino_uno_q.dts`,
> `arduino_uno_q-common.dtsi`, `arduino_r3_connector.dtsi`) and this project's
> [overlay](../../mcu/app/boards/arduino_uno_q.overlay) and
> [`prj.conf`](../../mcu/app/prj.conf). The MPU side was read from `/sys` and
> `/proc` on one running board (kernel `7.0.0-g122c2c22d838`, 2026-10-31),
> without writing to anything. "Exists in a devicetree" is not "reaches a pin
> you can touch"; where the physical end has not been traced, the table says
> so.

## How to read the tables

| Column | Means |
|---|---|
| **Used today** | Where in this repository it is used, or "no" |
| **Demo** | **Yes**: one of the demonstrations below uses it. **Maybe**: worth one, not proposed yet. **No**: infrastructure, or already fully shown |

---

## The MCU: STM32U585, Zephyr

The board file enables these. The SoC has more (see
[the end of this section](#on-the-chip-but-not-enabled-by-the-board)).

### Clocks, time, and memory

| Item | What it is | Evidence | Used today | Demo |
|---|---|---|---|---|
| Core clock | Cortex-M33 at 160 MHz, from `pll1` fed by MSIS; a 16 MHz HSE and 32.768 kHz LSE crystal are also enabled | `&rcc`, `&pll1`, `&clk_hse`, `&clk_lse` in `-common.dtsi` | Implicitly, by everything | No |
| `lptim1` | Low-power timer, Zephyr's system tick, clocked from the LSE | `stm32_lp_tick_source: &lptim1` | Implicitly: Zephyr's kernel clock | No |
| `timers17` | General-purpose timer | project overlay, `counter_matrix` | **Yes**: paces the LED panel refresh, [`matrix.c`](../../mcu/app/src/matrix.c) | No |
| `rtc` | Real-time clock on the LSE crystal | `&rtc` `okay` | No | Maybe |
| `iwdg` | Independent watchdog, `watchdog0` alias | `&iwdg` `okay` | **No**: the MCU's watchdog is unclaimed | **Yes**: [#161](https://github.com/jim-wyatt/two-computers-one-board/issues/161) |
| `flash0` | 2 MB; partitions `mcuboot` 64K, `image-0` and `image-1` 416K each, `storage` 128K | `&flash0` partitions in `arduino_uno_q.dts` | **Yes**: MCUboot slots and FOTA ([`fota.py`](../../python/unoq/fota.py)); `storage` holds one byte, the panel orientation (NVS) | No |
| `gpdma1` | General-purpose DMA controller | `&gpdma1` `okay` in `arduino_uno_q.dts` | No | **Yes**: [#159](https://github.com/jim-wyatt/two-computers-one-board/issues/159) |

### Analog

| Item | What it is | Evidence | Used today | Demo |
|---|---|---|---|---|
| `adc1` | 14-bit ADC; channels 9, 10, 11, 12, 2, 1 on PA4, PA5, PA6, PA7, PC1, PC0 (header A0..A5) | `&adc1` channels, `arduino_r3_connector.dtsi` | Only its internal channel, for the die temperature | **Yes**: [#157](https://github.com/jim-wyatt/two-computers-one-board/issues/157), [#159](https://github.com/jim-wyatt/two-computers-one-board/issues/159) |
| `die_temp` | The STM32's internal temperature sensor, read through `adc1` | `&die_temp` `okay`, `CONFIG_STM32_TEMP=y` | **Yes**: `app temp`, `MCU.die_temp()` | **Yes**: [#157](https://github.com/jim-wyatt/two-computers-one-board/issues/157), [#162](https://github.com/jim-wyatt/two-computers-one-board/issues/162) |
| `vref1` | Internal reference voltage sensor | `&vref1` `okay`, alias `volt-sensor0` | No: `CONFIG_STM32_VREF=n` | **Yes**: [#157](https://github.com/jim-wyatt/two-computers-one-board/issues/157) |
| `adc4`, `vbat4` | Second ADC, and the battery-voltage sensor it serves | `&adc4`, `&vbat4`, alias `volt-sensor1` | **Switched off** by the project overlay: its bring-up waits with no timeout, and nothing reads it | No |
| `dac1` | Two DAC outputs, on PA4 and PA5: the same pins as A0 and A1 | `&dac1` `pinctrl-0 = <&dac1_out1_pa4 &dac1_out2_pa5>` | No | **Yes**: [#159](https://github.com/jim-wyatt/two-computers-one-board/issues/159) |

PA4 being both `dac1` output 1 and `adc1` channel 9 is worth pointing out: the
MCU can sample its own analog output with no wire at all.

### Serial buses

| Item | What it is | Evidence | Used today | Demo |
|---|---|---|---|---|
| `lpuart1` | UART on PG7/PG8 with RTS/CTS, 115200; wired to Linux as `/dev/ttyHS1` | `&lpuart1`; project overlay makes it `zephyr,console` and `zephyr,shell-uart` | **Yes**: the whole link: shell, `app` commands, SMP for FOTA | No |
| `usart1` | UART on PB6/PB7, header D0/D1 (`arduino_serial`) | `&usart1`; upstream's default console | No | Maybe |
| `i2c2` | I2C on PB10/PB11, 400 kHz (`arduino_i2c`) | `&i2c2` `okay` | No: `CONFIG_I2C_SHELL=y` lets you poke it, nothing in the firmware uses it | **Yes**: [#163](https://github.com/jim-wyatt/two-computers-one-board/issues/163) |
| `i2c4` | I2C on PD12/PD13, 400 kHz; a comment names PF14/PF15 as the alternative for the "JMISC" connector | `&i2c4` `okay` | No. Which connector PD12/PD13 reach (Qwiic is the usual guess) is **not traced** | **Yes**: [#163](https://github.com/jim-wyatt/two-computers-one-board/issues/163) |
| `spi2` | SPI on PB13/PB14/PB15, NSS PB9 (`arduino_spi`, header D13/D12/D11/D10); a comment names the ICSP pins as the alternative | `&spi2` `okay` | No | Maybe |
| `spi3` | SPI on PG9/PG10/PB5/PG12: the MCU's end of the SPI link to Linux, as slave | `&spi3` `okay`; wiring verified by experiment in [hardware.md](hardware.md#there-is-an-spi-link-between-the-two-chips-and-nothing-here-uses-it) | **Yes**: `spi_link.c`, a framed request/response transport with a CRC ([hardware.md](hardware.md#there-is-an-spi-link-between-the-two-chips-and-nothing-here-uses-it)) | **Yes**: [#159](https://github.com/jim-wyatt/two-computers-one-board/issues/159), whose scope half needs it |
| `usbotg_fs` | USB full-speed device on PA11/PA12 | `&usbotg_fs` **`disabled`**; `board.yml` comments `usbd` out | No | No: disabled by the board, and where PA11/PA12 go is not traced |

### GPIO, LEDs, and the panel

| Item | What it is | Evidence | Used today | Demo |
|---|---|---|---|---|
| Header GPIO | D0..D13 and A0..A5, mapped to ports A, B and C | `arduino_r3_connector.dtsi` `gpio-map` | No | **Yes**: [#158](https://github.com/jim-wyatt/two-computers-one-board/issues/158) (PWM and input capture on header pins) |
| LED panel | 104 LEDs charlieplexed on PF0..PF10 | project overlay (`&gpiof`); not in Zephyr's board at all | **Yes**: CPU bars, [`matrix.c`](../../mcu/app/src/matrix.c), [`bars.c`](../../mcu/app/src/bars.c) | Reused by [#160](https://github.com/jim-wyatt/two-computers-one-board/issues/160) |
| LED 3, LED 4 | Two RGB LEDs on PH10..PH15, active low | `leds` node, `led3_*` and `led4_*` | **Yes**: image state and link health, [`status_leds.c`](../../mcu/app/src/status_leds.c) | No |
| `gpiog` | Port G: the `lpuart1` and `spi3` pins | `&gpiog` `okay` | **Yes**: the serial link | No |

### Security

| Item | What it is | Evidence | Used today | Demo |
|---|---|---|---|---|
| `rng` | True random number generator | `&rng` `okay` | No | Maybe |
| `aes` | AES accelerator | `&aes` `okay` | No | Maybe |
| MCUboot signing | Signed images, no downgrade | `CONFIG_BOOTLOADER_MCUBOOT=y`, `CONFIG_MCUBOOT_BOOTLOADER_NO_DOWNGRADE=y` | **Yes**: every build is signed; see [mcu.md](mcu.md) | No |

### On the chip, but not enabled by the board

The STM32U585's own devicetree (`zephyr/dts/arm/st/u5/stm32u5.dtsi` and
`stm32u585.dtsi`) declares more than the board turns on: `usart3`, `uart4`,
`uart5`, `spi1`, `i2c1`, `i2c3`, `lptim2`..`lptim4`, `timers1`..`timers16`,
`octospi1`, `octospi2`, `sdmmc1`, `sai1`, `fdcan1`, `hash`, `crc`,
`vrefbuf` and a backup SRAM. Enabling one is an overlay change. Whether its
pins reach anything on this board needs the schematic, so none of them is
proposed here. The general-purpose timers are the exception: they drive pins
the header already exposes, which is what PWM on an Arduino header has always
been, and [#158](https://github.com/jim-wyatt/two-computers-one-board/issues/158)
uses one.

---

## The MPU: QRB2210, Linux

### Compute, power, and heat

| Item | What it is | Evidence | Used today | Demo |
|---|---|---|---|---|
| CPU | Four cores (`CPU part 0x801`), one cpufreq policy for all four | `/proc/cpuinfo`; `policy0/affected_cpus` = `0 1 2 3` | **Yes**: CPU bars samples `/proc/stat`, [`cpu.py`](../../python/unoq/cpu.py) | No |
| cpufreq | `qcom-cpufreq-hw`; 300 MHz to 2.016 GHz in nine steps; governor `schedutil` of `ondemand userspace performance schedutil`; `stats/time_in_state` present | `/sys/devices/system/cpu/cpufreq/policy0/` | No | **Yes**: [#162](https://github.com/jim-wyatt/two-computers-one-board/issues/162), for [#11](https://github.com/jim-wyatt/two-computers-one-board/issues/11) |
| cpuidle | **Absent**: no `cpu0/cpuidle` directory | `/sys/devices/system/cpu/cpu0/` | n/a: [#39](https://github.com/jim-wyatt/two-computers-one-board/issues/39) | No |
| Thermal zones | Ten: `mapss`, `video`, `wlan`, `cpuss0`, `cpuss1`, `mdm0`, `mdm1`, `gpu`, `hm-center`, `camera`, all `step_wise`; mirrored as `hwmon0..9` | `/sys/class/thermal/thermal_zone*/type` | **Yes**: read by [`thermal.py`](../../python/unoq/thermal.py) | **Yes**: [#162](https://github.com/jim-wyatt/two-computers-one-board/issues/162) |
| Cooling devices | `devfreq-5900000.gpu` (3 states), `ath10k_thermal` (100) | `/sys/class/thermal/cooling_device*/type` | No | **Yes**: [#162](https://github.com/jim-wyatt/two-computers-one-board/issues/162) |
| Memory | 3.6 GiB, and a 1.8 GiB zram swap | `/proc/meminfo`, `/sys/block/zram0/disksize` | **Yes**: explained in [mpu.md](mpu.md#swap-in-use-is-not-a-problem-here) | No |
| Watchdog | `qcom_wdt`, 30 s timeout, `inactive` unless armed | `/sys/class/watchdog/watchdog0/` | **Yes**, opt-in: `./bootstrap.sh --with-watchdog`, [`80-watchdog.sh`](../../provision/80-watchdog.sh) | Paired with the MCU's in [#161](https://github.com/jim-wyatt/two-computers-one-board/issues/161) |
| RTC | `rtc-pm8xxx`, in the PMIC | `/sys/class/rtc/rtc0/name` | No. The board has no battery for it | No |
| Remote processors | `modem` and `adsp`, both `running` (`qcom/qcm2290/*.mbn`) | `/sys/class/remoteproc/*/` | No (audio and wifi depend on them) | No |

### Radios and network

| Item | What it is | Evidence | Used today | Demo |
|---|---|---|---|---|
| Wifi | `wlan0`, driver `ath10k_snoc`, `phy0` | `/sys/class/net/wlan0/device/uevent` | **Yes**: the uplink, [`net/wifi.sh`](../../net/wifi.sh) | **Yes**: [#160](https://github.com/jim-wyatt/two-computers-one-board/issues/160) |
| Bluetooth | `hci0`, `hci_uart_qca` on a UART of its own (`serial@4a8c000`) | `/sys/class/bluetooth/hci0/device/uevent` | **Disabled**: `bluetooth.service` is turned off by [`10-optimize-board.sh`](../../provision/10-optimize-board.sh), with the revert command beside it | **Yes**: [#163](https://github.com/jim-wyatt/two-computers-one-board/issues/163) |
| USB-C | One port, `4e00000.usb`, data role `host [device]`, `power_operation_mode` `default` | `/sys/class/typec/port0/`, `/sys/class/udc/` | **Yes**: the composite gadget and `br-usb`, [usb.md](usb.md) | No (already a whole reference page) |

### Media

| Item | What it is | Evidence | Used today | Demo |
|---|---|---|---|---|
| GPU | Adreno, driver `adreno`; devfreq `simple_ondemand`, 355 to 845 MHz; `/dev/dri/renderD128` | `/sys/class/devfreq/5900000.gpu/` | No | Maybe |
| Display | DRM `card0`, driver `msm_dpu`, one connector `card0-DP-1` (`disconnected`), through the `anx7625` bridge on I2C bus 1 | `/sys/class/drm/` | **Deliberately off**: the desktop stack is disabled when headless | Maybe |
| Video codec | Venus hardware decoder and encoder: `/dev/video0`, `/dev/video1` | `/sys/class/video4linux/*/name` | No | Maybe |
| Camera | **No camera device found**: no V4L2 capture node and no media controller. A `camera-thermal` zone exists, which is not a camera | `/sys/class/video4linux/`, `/dev/media*` | n/a | No |
| Audio | ALSA card `ArduinoImolaHPH` (`qcm2290`, "Arduino-Imola-HPH-LOUT"), four playback and four capture PCMs, a headset-jack input device | `/proc/asound/cards`, `/proc/asound/card0/pcm*`, `/sys/class/input/input2` | No. Where its outputs reach physically is **not traced** | Maybe |

### Storage

| Item | What it is | Evidence | Used today | Demo |
|---|---|---|---|---|
| eMMC | `mmcblk0`, `BUTC42`, about 29 GiB, plus `boot0`/`boot1` hardware partitions | `/sys/block/mmcblk0/` | **Yes**: the root filesystem; `boot_a`/`boot_b` hold U-Boot | Used by [#157](https://github.com/jim-wyatt/two-computers-one-board/issues/157) for its record |

### GPIO, buses, and LEDs

| Item | What it is | Evidence | Used today | Demo |
|---|---|---|---|---|
| `gpiochip0` | PMIC GPIO, 10 lines | `gpiodetect` (reads labels only) | No | No |
| `gpiochip1` | SoC pin controller `500000.pinctrl`, 127 lines | `gpiodetect` | **Yes**: lines 25, 26, 37, 38, 70 (SWD, BOOT0, link enable), [hardware.md](hardware.md#the-two-gpios-nobody-documents) | No |
| `gpiochip2` | `a7c0000.pinctrl`, 19 lines | `gpiodetect` | No | No |
| Two keys | `gpio-keys` declares "Volume Up" and "Volume Down" | `/sys/firmware/devicetree/base/gpio-keys/`, `/proc/bus/input/devices` | No. Whether buttons exist on this board, or the node is inherited, is **not verified** | No |
| Power key | `pm8941_pwrkey`, the PMIC's power-key input | `/sys/class/input/input1/name` | No | No |
| `/dev/i2c-0` | Free: nothing registered | `/sys/bus/i2c/devices/` | No. Which connector it reaches is **not traced**; see [hardware.md](hardware.md#the-i2c-buses) | Maybe |
| `/dev/i2c-1`, `/dev/i2c-2` | The display bridge and its AUX channel | `/sys/bus/i2c/devices/1-0058` and others | No, and should not be | No |
| `/dev/spidev0.0` | The SPI link **to the MCU** (`arduino,unoq-mcu`), Linux as master | `/sys/bus/spi/devices/spi0.0/of_node/compatible` | **Yes**: `unoq.spilink` speaks the framed protocol, and `python -m unoq.spilink bench` measures it | **Yes**: [#159](https://github.com/jim-wyatt/two-computers-one-board/issues/159), whose scope half needs it |
| `/dev/ttyHS1` | The UART link to the MCU | `4a88000.serial` | **Yes**: everything that talks to the MCU | Every MCU demo; see [who owns it](#who-owns-the-serial-port) |
| `/dev/ttyMSM0` | Linux's own console UART | `/sys/class/tty/console/active` | **Yes**: a login, `serial-getty@ttyMSM0` | No |
| LED 1, LED 2 | Six `gpio-leds` channels, two RGB packages | `/sys/class/leds/unoq:*` | **Yes**: uplink and health, [`leds.sh`](../../status/leds.sh) | No |
| `mmc0::` | An LED the MMC controller registers; nothing is wired to it | `/sys/class/leds/mmc0::` | n/a | No |

### Security

| Item | What it is | Evidence | Used today | Demo |
|---|---|---|---|---|
| Crypto engine | Qualcomm `qce` drivers registered with the kernel crypto API | `/proc/crypto` (`ccm-aes-qce` and others) | No | Maybe |
| `/dev/hwrng` | The node exists, but `rng_current` reads `none`: no hardware RNG is bound | `/sys/class/misc/hw_random/` | No | Maybe: the MCU's `rng` could feed it |

---

## Proposed demonstrations

Seven, each showing something [CPU bars](mpu.md#cpu-bars-on-the-led-matrix)
does not, chosen so that no two teach the same thing. Each is an issue, and
each is meant to be a chapter or an exercise as well as an app, opt-in at
provisioning and tested on the testable side of its hardware boundary, as
[#34](https://github.com/jim-wyatt/two-computers-one-board/issues/34) asks.

CPU bars already shows: Linux drives the MCU, on a clock, over the serial
shell, with the panel as output. So none of these is about that.

| # | Demonstration | New ground | Issue |
|---|---|---|---|
| 1 | Temperature logger | The MCU produces and Linux consumes; unasked-for messages | [#157](https://github.com/jim-wyatt/two-computers-one-board/issues/157) |
| 2 | Jitter, measured | A deadline, and Linux visibly missing it; timers and PWM | [#158](https://github.com/jim-wyatt/two-computers-one-board/issues/158) |
| 3 | Two-chip oscilloscope | DMA, the DAC, high-rate ADC, the SPI link | [#159](https://github.com/jim-wyatt/two-computers-one-board/issues/159) |
| 4 | Build light | The network; event-driven output | [#160](https://github.com/jim-wyatt/two-computers-one-board/issues/160) |
| 5 | Each chip watches the other | Failure and recovery; the MCU's watchdog; reset causes | [#161](https://github.com/jim-wyatt/two-computers-one-board/issues/161) |
| 6 | Heat under load | Power, heat and the governor | [#162](https://github.com/jim-wyatt/two-computers-one-board/issues/162) |
| 7 | Bluetooth sensor | An I2C peripheral on the MCU; the second radio | [#163](https://github.com/jim-wyatt/two-computers-one-board/issues/163) |

The first is the one #34 suggests building first. The two that overlap most
are 1 and 3, both of which read `adc1`: the line between them is that the
logger takes one slow conversion at a time and is about the direction of
the data, and the oscilloscope is about rate, DMA, and the transport.

### 1. Temperature logger ([#157](https://github.com/jim-wyatt/two-computers-one-board/issues/157))

- **MCU:** samples the die temperature, the internal reference and optionally one header pin on its own timer, and sends each record unasked, with its own uptime and a sequence number.
- **Linux:** a service stores the records, finds gaps from the sequence numbers, and graphs them beside the host's thermal zones on the board's web server.
- **Extra hardware:** none; a potentiometer or light sensor on A0 if you want something to move.
- **Tested without a board:** the record format in a shared header, tested by ztest on `native_sim`; the parser, gap detection and storage by pytest with a fake port replaying recorded lines.

### 2. Jitter, measured ([#158](https://github.com/jim-wyatt/two-computers-one-board/issues/158))

- **MCU:** timestamps the arrival of each message from Linux with a microsecond timer and builds a histogram; for comparison, generates a hardware-timer PWM on one header pin and measures it by input capture on another.
- **Linux:** sends on a fixed schedule, idle and then under load it creates itself, and prints both histograms.
- **Extra hardware:** one jumper wire, for the input-capture half.
- **Tested without a board:** the histogram code by ztest; the schedule and statistics by pytest with a fake clock and port.

### 3. Two-chip oscilloscope ([#159](https://github.com/jim-wyatt/two-computers-one-board/issues/159))

- **MCU:** plays a waveform out of the DAC on PA4 by DMA, and samples the same pin with `adc1`, timer-triggered and by DMA, in bursts.
- **Linux:** requests bursts over the SPI link, checks their framing, and draws them in a browser page.
- **Extra hardware:** none; the DAC and ADC share the pin.
- **Tested without a board:** the burst frame in a shared header, tested by ztest; decoding by pytest with a fake spidev returning recorded bursts.
- **Depends on:** [#28](https://github.com/jim-wyatt/two-computers-one-board/issues/28), the SPI protocol. At 115200 baud the serial line moves about 11 KB/s, and one burst is several KB.

### 4. Build light ([#160](https://github.com/jim-wyatt/two-computers-one-board/issues/160))

- **MCU:** shows a glyph for the state on the panel.
- **Linux:** polls a CI workflow's status over wifi or the computer's connection, and tells "the build failed" apart from "I cannot reach the network".
- **Extra hardware:** none.
- **Tested without a board:** pytest against recorded API responses, with no network in any test; the glyphs on whichever side draws them.

### 5. Each chip watches the other ([#161](https://github.com/jim-wyatt/two-computers-one-board/issues/161))

- **MCU:** arms its independent watchdog, feeds it only while the panel refresh and the shell are alive, and reports why it last reset.
- **Linux:** reads and logs the reset cause; already has its own watchdog (`--with-watchdog`). LED 4 already shows the MCU noticing a silent Linux; this is the other direction.
- **Extra hardware:** none.
- **Tested without a board:** the reset-cause line in `app_proto.h`, tested by ztest and parsed by pytest.

### 6. Heat under load ([#162](https://github.com/jim-wyatt/two-computers-one-board/issues/162))

- **MCU:** an independent stopwatch and a temperature from a chip the workload does not run on.
- **Linux:** runs one workload under each governor and records the thermal zones, time at each frequency, the GPU's state, and how long it took; puts the original governor back however it exits.
- **Extra hardware:** none; a USB power meter in line with the cable makes it much better.
- **Tested without a board:** pytest against a fake sysfs tree, as `unoq.thermal` is now.
- **Depends on:** it produces the measurements [#11](https://github.com/jim-wyatt/two-computers-one-board/issues/11) needs.

### 7. Bluetooth sensor ([#163](https://github.com/jim-wyatt/two-computers-one-board/issues/163))

- **MCU:** reads an I2C sensor through a Zephyr sensor driver, on `i2c2` or `i2c4`.
- **Linux:** turns BlueZ back on and publishes the reading as a Bluetooth LE service a phone can read.
- **Extra hardware:** an I2C sensor Zephyr has a driver for, and a phone.
- **Tested without a board:** the firmware on `native_sim` against Zephyr's I2C emulator; the GATT layer by pytest with a fake in place of BlueZ.

### Who owns the serial port

`/dev/ttyHS1` has one owner at a time: [`unoq.mcu.open_port()`](../../python/unoq/mcu.py)
takes both an advisory lock and the kernel's exclusive flag, and a second
opener gets `PortBusy`. So every demonstration has to say whether it holds the
port for as long as it runs, as CPU bars does, or only for a single command.

| Demonstration | Holds `/dev/ttyHS1` | Also holds | Runs alongside CPU bars? |
|---|---|---|---|
| 1. Temperature logger | its service, while running | | No: chosen instead of it at provisioning |
| 2. Jitter, measured | a one-shot command, for the run | | No: stop `unoq-cpu-bars` first |
| 3. Two-chip oscilloscope | its service, for commands | `/dev/spidev0.0`, for data | No: chosen instead of it |
| 4. Build light | its service, while running | | No: chosen instead of it |
| 5. Each chip watches the other | whichever owner is running reads the reset cause; the deliberate hang is a one-shot | | Yes, for reading the cause |
| 6. Heat under load | a one-shot command, for the run | root, to switch the governor | No: stop `unoq-cpu-bars` first |
| 7. Bluetooth sensor | its service, while running | `hci0` | No: chosen instead of it |

Four long-running owners competing for one port is the contention #34 says is
worth demonstrating rather than hiding. One way through it, once a second
service exists, is a single owner that the others talk to; that is a design
decision for whoever builds the second one, not for this page.
