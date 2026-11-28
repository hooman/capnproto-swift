/* ESP32-C6 firmware for ci/check-esp32c6.py. Runs every input through the shared Swift driver
 * (ci/fixtures/embedded-driver.swift, via ci/esp32c6/driver.swift), with the heap measured
 * around the run and the main task's stack high-water mark after it, then runs the negative
 * control, which must trap: the panic handler prints it and halts. Output goes to UART0, the
 * DevKitC-1's USB-UART bridge. Test harness only. */
#include <stdint.h>
#include <stdio.h>

#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "sdkconfig.h"

void capnp_run(void);
void capnp_run_negative(void);

uint64_t capnp_micros(void) { return (uint64_t)esp_timer_get_time(); }

/* stdout is fully buffered during the run, so a timed input pays for a few buffered
 * putchar calls, not for its line crossing the 115,200-baud UART (about 3.5 ms). */
static char output[1024];
void capnp_flush(void) { fflush(stdout); }

void app_main(void) {
    printf("\nCAPNP BEGIN\n");
    fflush(stdout);
    setvbuf(stdout, output, _IOFBF, sizeof output);
    size_t free_before = heap_caps_get_free_size(MALLOC_CAP_DEFAULT);
    size_t low_before = heap_caps_get_minimum_free_size(MALLOC_CAP_DEFAULT);
    capnp_run();
    size_t free_after = heap_caps_get_free_size(MALLOC_CAP_DEFAULT);
    size_t low_after = heap_caps_get_minimum_free_size(MALLOC_CAP_DEFAULT);
    /* ESP-IDF's FreeRTOS counts stack in bytes. */
    UBaseType_t unused = uxTaskGetStackHighWaterMark(NULL);
    setvbuf(stdout, NULL, _IOLBF, 0);
    printf("heap free_before=%u free_after=%u low_before=%u low_after=%u\n",
           (unsigned)free_before, (unsigned)free_after, (unsigned)low_before, (unsigned)low_after);
    printf("stack size=%d unused=%u\n", CONFIG_ESP_MAIN_TASK_STACK_SIZE, (unsigned)unused);
    printf("CAPNP NEGATIVE CONTROL\n");
    fflush(stdout);
    capnp_run_negative();
    printf("CAPNP NEGATIVE CONTROL DID NOT TRAP\n");
    fflush(stdout);
}
