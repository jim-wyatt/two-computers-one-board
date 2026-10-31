# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(guard_test)
# Only the header: the feed decision and the reset-cause names are inline
# functions in guard.h, and those are the ones the firmware calls. guard.c is
# the watchdog and hwinfo drivers and is not built here.
target_sources(app PRIVATE src/main.c)
target_include_directories(app PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../app/include)
