// Bare-metal driver for ci/check-qemu.py, built Embedded and -no-allocations into one image
// per target. QEMU's generic loader places one input (ci/fixtures/embedded-driver.swift gives
// its layout) at capnp_input() before boot. Output and exit go through semihosting
// (ci/qemu/start.c). A failed precondition traps into the fault handler, which exits non-zero,
// so the exit status reports assertion failures.

@_extern(c, "capnp_input") func capnpInput() -> UnsafeRawPointer

runInput(unsafe capnpInput())
