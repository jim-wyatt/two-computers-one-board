# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(hybrid_link)
target_sources(app PRIVATE src/main.c src/matrix.c src/bars.c src/status_leds.c src/templog.c
		   src/guard.c src/spi_link.c src/spi_proto.c src/jitter.c src/scope.c src/scope_hw.c)
# app_proto.h holds the MPU <-> MCU contract, shared with mcu/tests/, and
# bars.c, templog.c, spi_proto.c, jitter.c and scope.c are compiled a second time by
# mcu/tests/ to run on the host.
target_include_directories(app PRIVATE include)
