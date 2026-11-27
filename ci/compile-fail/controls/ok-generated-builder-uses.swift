// REQUIRES: generated
// EXPECT-PASS

import CapnpRuntime

// The positive control for the generated-builder fixtures, against readers.capnp.
private func useGeneratedBuilder(_ storage: consuming MutableRawSpan) -> UInt64 {
    var message = MessageBuilder(storage: storage)
    do {
        var example = message.initRoot(Capnp_9eb32e19f86f3a01.ExampleBuilder.self)
        example.setU64(1)
        do {
            var child = example.initChild()
            child.setId(2)
        }
        example.clearChild()
        example.setValue(3)
        do {
            var detail = example.initDetail()
            detail.setAmount(4)
        }
        _ = example._capnpWhich()
        _ = example.u64()
    }
    guard message.error == .none else { return 0 }
    let arena = Arena(framedBytes: message.framedBytes)
    return arena.withRoot { Capnp_9eb32e19f86f3a01.ExampleReader($0).u64 }
}
