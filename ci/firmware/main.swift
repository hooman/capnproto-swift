// Bare-metal link probe: one segment of one word with a null root, so every reader
// returns its default, read directly and after unpacking its packed form; then a builder
// round trip. Linked by
// ci/check-link.sh against stubs.c, with no libc.

@_extern(c, "putchar") func putchar(_ c: Int32) -> Int32

func run() -> UInt64 {
    // Header word: segment count - 1 = 0, segment 0 size = 1 word. A literal, not
    // 1 << 32: the generic UInt64 shift allocates on 32-bit targets.
    var message: InlineArray<2, UInt64> = [0x1_0000_0000, 0]
    return withUnsafeMutableBytes(of: &message) { raw in
        unsafe capnpEmbeddedProbe(raw.baseAddress!, raw.count)
    }
}
// The same frame packed: table tag 0x10 with size 1, then a zero word with no run.
func runPacked() -> UInt64 {
    var packed: InlineArray<4, UInt8> = [0x10, 0x01, 0x00, 0x00]
    var output: InlineArray<2, UInt64> = [0xA5A5, 0xA5A5]
    return withUnsafeMutableBytes(of: &packed) { input in
        withUnsafeMutableBytes(of: &output) { raw in
            unsafe capnpEmbeddedPackedProbe(input.baseAddress!, 4, raw.baseAddress!, raw.count)
        }
    }
}
// The builder probe's frame is 96 bytes: header 8, root pointer 8, root sections 64, child
// 8, and the re-initialized child 8. A clean build returns 7 + 1 (root and child values) + 96.
func runBuilder() -> UInt64 {
    var storage = InlineArray<18, UInt64>(repeating: 0)
    return withUnsafeMutableBytes(of: &storage) { raw in
        unsafe capnpEmbeddedBuilderProbe(raw.baseAddress!, raw.count)
    }
}
// 'O' when both reader paths and the builder path ran clean
_ = putchar(run() == 0 && runPacked() == 0 && runBuilder() == 104 ? 0x4F : 0x58)
