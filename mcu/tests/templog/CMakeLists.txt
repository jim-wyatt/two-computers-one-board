# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(templog_test)
# The temperature log the firmware ships, compiled a second time for the host:
# the same source file mcu/app builds, not a copy. The sensor is the one part
# left behind - it is a function pointer, and these tests hand it a fake.
target_sources(app PRIVATE src/main.c ../../app/src/templog.c)
target_include_directories(app PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../app/include)
