# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(status_leds_test)
# Only the header: the decisions about what each LED shows are inline functions
# in status_leds.h, and those are the ones the firmware calls. status_leds.c is
# GPIO and MCUboot and is not built here.
target_sources(app PRIVATE src/main.c)
target_include_directories(app PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../app/include)
