# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(lcd_test)
# `app lcd`'s pure half, the same source file mcu/app builds. The other half,
# lcd_hw.c, talks to the panel over spi2; these tests hand lcd.c the bytes a
# controller reads back and the arguments the shell would.
target_sources(app PRIVATE src/main.c ../../app/src/lcd.c)
target_include_directories(app PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../app/include)
