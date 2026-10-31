# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(jitter_test)
# The jitter record the firmware ships, compiled a second time for the host:
# the same source file mcu/app builds, not a copy. The timers that feed it in
# the firmware are main.c's, and these tests hand it timestamps instead.
target_sources(app PRIVATE src/main.c ../../app/src/jitter.c)
target_include_directories(app PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../app/include)
