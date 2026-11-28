# CAPNP_GENERATED comes from the environment: ESP-IDF first evaluates this file in a
# requirements pass (CMAKE_BUILD_EARLY_EXPANSION) that does not see -D variables.
set(generated "$ENV{CAPNP_GENERATED}")
if(NOT generated AND NOT CMAKE_BUILD_EARLY_EXPANSION)
    message(FATAL_ERROR "run ci/check-esp32c6.py, which sets CAPNP_GENERATED")
endif()
# CMake links .o sources as objects.
set(swift_objects "${generated}/runtime.o" "${generated}/image.o")
idf_component_register(
    SRCS "app_main.c" "${generated}/inputs.c" ${swift_objects}
    PRIV_REQUIRES esp_timer heap freertos)
