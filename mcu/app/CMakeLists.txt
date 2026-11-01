# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
cmake_minimum_required(VERSION 3.20.0)
# The BME680's I2C address, into the overlay's preprocessor (see `app env` in
# boards/arduino_uno_q.overlay): 0x77 unless the build says otherwise, with
#   mcu/zbuild.sh -- -DUNOQ_BME680_ADDR=0x76
# A cache variable, so it holds for that build directory until a pristine one.
set(UNOQ_BME680_ADDR 0x77 CACHE STRING "I2C address of the BME680 on i2c2: 0x76 or 0x77")
set_property(CACHE UNOQ_BME680_ADDR PROPERTY STRINGS 0x76 0x77)
if(NOT UNOQ_BME680_ADDR MATCHES "^0x7[67]$")
  message(FATAL_ERROR "UNOQ_BME680_ADDR is ${UNOQ_BME680_ADDR}: a BME680 answers only on 0x76 or 0x77")
endif()
list(APPEND DTS_EXTRA_CPPFLAGS -DUNOQ_BME680_ADDR=${UNOQ_BME680_ADDR})
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(hybrid_link)
target_sources(app PRIVATE src/main.c src/matrix.c src/bars.c src/status_leds.c src/templog.c
		   src/guard.c src/spi_link.c src/spi_proto.c src/jitter.c src/scope.c src/scope_hw.c)
# `app env`: the pure half is also compiled by mcu/tests/env/.
target_sources(app PRIVATE src/env.c src/env_sensor.c)
# app_proto.h holds the MPU <-> MCU contract, shared with mcu/tests/, and
# bars.c, templog.c, spi_proto.c, jitter.c and scope.c are compiled a second time by
# mcu/tests/ to run on the host.
target_include_directories(app PRIVATE include)
