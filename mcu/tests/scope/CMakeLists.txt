# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(scope_test)
# The scope's arithmetic as the firmware ships it, compiled a second time for
# the host: scope.c, not a copy. scope_hw.c, which drives the DAC, the ADC,
# the timers and the DMA, is left behind; these tests are what it computes.
target_sources(app PRIVATE src/main.c ../../app/src/scope.c)
target_include_directories(app PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../app/include)
