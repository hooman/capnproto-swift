// EXPECT-ERROR: 'pointer' is inaccessible due to 'internal' protection level

// 0.1.0 API tiering: StructReader exposes pointer fields as PointerReader
// (`pointerField(at:)`), not as raw pointer words.
import CapnpRuntime

private func bad(_ framed: [UInt8]) -> Bool {
    let arena = Arena(framedBytes: framed.span.bytes)
    return arena.withRoot { root in root.pointer(at: 0).isNull }
}
