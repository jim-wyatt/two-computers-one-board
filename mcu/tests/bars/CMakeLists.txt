# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(bars_test)
# The rasterizer the firmware ships, compiled a second time for the host. This
# is the same source file mcu/app builds - not a copy - so a change to the
# drawing rules cannot pass here and fail on the board.
target_sources(app PRIVATE src/main.c ../../app/src/bars.c)
target_include_directories(app PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../app/include)
