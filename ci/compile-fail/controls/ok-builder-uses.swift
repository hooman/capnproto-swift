// EXPECT-PASS

import CapnpRuntime

// The positive control for the builder fixtures: sequential children, a re-initialized
// pointer, reading back through the builder and then through an Arena.
private func useBuilder(_ storage: consuming MutableRawSpan) -> UInt64 {
    var message = MessageBuilder(storage: storage)
    do {
        var root = message.initRoot(dataWords: 1, pointerCount: 2)
        root.setData(UInt64(1), at: 0, default: 0)
        do {
            var first = root.initStruct(at: 0, dataWords: 1, pointerCount: 0)
            first.setData(UInt64(2), at: 0, default: 0)
        }
        do {
            var second = root.initStruct(at: 1, dataWords: 1, pointerCount: 0)
            second.setData(UInt64(3), at: 0, default: 0)
        }
        root.clearPointer(at: 0)
        _ = root.data(at: 0, default: UInt64(0))
    }
    guard message.error == .none, message.requiredByteCount > 0 else { return 0 }
    let arena = Arena(framedBytes: message.framedBytes)
    return arena.withRoot { $0.data(at: 0, default: UInt64(0)) }
}
