# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(spi_proto_test)
# The SPI link's frames and services as the firmware ships them, compiled a
# second time for the host: spi_proto.c, and templog.c for TEMPLOG to read
# from. spi_link.c, the part that drives spi3, is left behind.
target_sources(app PRIVATE src/main.c ../../app/src/spi_proto.c ../../app/src/templog.c)
target_include_directories(app PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../app/include)
