// Bare-metal driver for ci/check-qemu.py: the same inputs and output lines as the WASI driver
// (ci/fixtures/wasi/main.swift), built Embedded and -no-allocations into one image per
// target. QEMU's generic loader places the input at capnp_input() before boot: byte 0 is the
// mode (0/1/2 = oracle, 98 = 32-bit packed suite, 99 = 32-bit edge suite), byte 1 a 0...7
// byte unalignment shift, a nonzero byte 2 marks the message as packed, bytes 4...7 hold
// its little-endian byte count, and the message starts at offset 8 + shift. Output and exit
// go through semihosting (ci/qemu/start.c). A failed precondition traps into the fault
// handler, which exits non-zero, so the exit status reports assertion failures.

import CapnpRuntime

@_extern(c, "capnp_input") func capnpInput() -> UnsafeRawPointer
@_extern(c, "putchar") func putchar(_ c: Int32) -> Int32

func put(_ text: StaticString) {
    unsafe text.withUTF8Buffer { bytes in
        for byte in bytes { _ = putchar(Int32(byte)) }
    }
}

/// `value / 10` and `value % 10` by shift-and-subtract: 64-bit division on these 32-bit
/// targets would call compiler-rt (__udivdi3, __aeabi_uldivmod), which the image lacks.
func divide10(_ value: UInt64) -> (quotient: UInt64, digit: UInt8) {
    var rest = value
    var quotient: UInt64 = 0
    var remainder: UInt32 = 0
    for _ in 0..<64 {
        remainder = remainder &<< 1 | UInt32(truncatingIfNeeded: (rest &>> 63)._lowWord)
        rest = rest &<< 1
        quotient = quotient &<< 1
        if remainder >= 10 {
            remainder -= 10
            quotient |= 1
        }
    }
    return (quotient, UInt8(truncatingIfNeeded: remainder))
}

/// Print `value` in decimal, without the allocating String interpolation.
func put(_ value: UInt64) {
    var digits = InlineArray<20, UInt8>(repeating: 0)
    var count = 0
    var rest = value
    repeat {
        let (quotient, digit) = divide10(rest)
        digits[count] = 0x30 &+ digit
        rest = quotient
        count += 1
    } while rest != 0
    while count > 0 {
        count -= 1
        _ = putchar(Int32(digits[count]))
    }
}

let base = unsafe capnpInput()
let mode = Int32(unsafe base.load(fromByteOffset: 0, as: UInt8.self))
let shift = Int(unsafe base.load(fromByteOffset: 1, as: UInt8.self))
let packed = unsafe base.load(fromByteOffset: 2, as: UInt8.self) != 0
var count = 0
for i in 0..<4 {
    count |= Int(unsafe base.load(fromByteOffset: 4 + i, as: UInt8.self)) &<< (8 * i)
}
precondition(shift < 8 && count < 64 * 1024, "invalid input header")

if mode == 99 {
    put("PASS mode=99 checks=")
    put(UInt64(verify32BitEdges()))
} else if mode == 98 {
    put("PASS mode=98 checks=")
    put(UInt64(verify32BitPacked()))
} else {
    precondition(count > 0, "message missing")
    let start = unsafe base + 8 + shift
    let checksum =
        packed
        ? unsafe verifyPacked(start, count, mode) : unsafe verifyReaders(start, count, mode)
    put(packed ? "PASS packed mode=" : "PASS mode=")
    put(UInt64(mode))
    put(" shift=")
    put(UInt64(shift))
    put(" checksum=")
    put(checksum)
}
put("\n")
