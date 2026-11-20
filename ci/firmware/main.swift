// Bare-metal link probe: one segment of one word with a null root, so every reader
// returns its default. Linked by ci/check-link.sh against stubs.c, with no libc.

@_extern(c, "putchar") func putchar(_ c: Int32) -> Int32

func run() -> UInt64 {
    // Header word: segment count - 1 = 0, segment 0 size = 1 word. A literal, not
    // 1 << 32: the generic UInt64 shift allocates on 32-bit targets.
    var message: InlineArray<2, UInt64> = [0x1_0000_0000, 0]
    return withUnsafeMutableBytes(of: &message) { raw in
        unsafe capnpEmbeddedProbe(raw.baseAddress!, raw.count)
    }
}
_ = putchar(run() == 0 ? 0x4F : 0x58)  // 'O' when the reader path ran clean
