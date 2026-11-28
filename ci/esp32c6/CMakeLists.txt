# ESP32-C6 hardware run for ci/check-esp32c6.py. The script compiles the Swift objects (the
# runtime, generated readers, the shared fixtures and ci/esp32c6/driver.swift) with the QEMU
# check's flags, generates the input table, and passes their folder as CAPNP_GENERATED.
cmake_minimum_required(VERSION 3.16)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(capnp_esp32c6)
