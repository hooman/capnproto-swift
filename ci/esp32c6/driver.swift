// The ESP32-C6 entry points (ci/check-esp32c6.py): run each input of the generated table
// (ci/fixtures/embedded-driver.swift gives the layout) and print its PASS line, then how long
// it took in microseconds, decode and checks only. The negative control runs a message whose checks must fail.

@_extern(c, "capnp_input_count") func inputCount() -> Int32
@_extern(c, "capnp_input_at") func input(at index: Int32) -> UnsafeRawPointer
@_extern(c, "capnp_negative_input") func negativeInput() -> UnsafeRawPointer
@_extern(c, "capnp_micros") func micros() -> UInt64
@_extern(c, "capnp_flush") func flush()

@_cdecl("capnp_run")
func run() {
    var index: Int32 = 0
    while index < inputCount() {
        // Timed without the UART: output is buffered until the flush (app_main.c).
        let start = micros()
        runInput(unsafe input(at: index))
        let elapsed = micros() &- start
        put("time us=")
        put(elapsed)
        put("\n")
        flush()
        index += 1
    }
}

@_cdecl("capnp_run_negative")
func runNegative() {
    runInput(unsafe negativeInput())
}
