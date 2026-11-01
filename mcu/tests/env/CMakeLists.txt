# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(env_test)
# `app env`'s pure half, the same source file mcu/app builds. The other half,
# env_sensor.c, talks to the BME680, and Zephyr has no emulator for it: these
# tests hand env.c the sensor_values the driver would.
target_sources(app PRIVATE src/main.c ../../app/src/env.c)
target_include_directories(app PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../app/include)
