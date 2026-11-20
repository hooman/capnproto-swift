// REQUIRES: generated
// EXPECT-PASS

import CapnpRuntime

private func useGenerated(_ bytes: [UInt8]) -> UInt64 {
    let arena = Arena(framedBytes: bytes.span.bytes)
    let result = arena.withRoot { root -> UInt64 in
        let example = Capnp_9eb32e19f86f3a01.ExampleReader(root.borrowed())
        let copied = example
        var sum = copied.u64
        if copied.boolField { sum &+= 1 }
        if copied.text.count > 0 { sum &+= UInt64(copied.text[0]) }
        if copied.data.count > 0 { sum &+= UInt64(copied.data[0]) }
        sum &+= copied.child.id
        let children = copied.children
        if children.count > 0 { sum &+= children[0].id }
        if copied.bits.count > 0 && copied.bits[0] { sum &+= 2 }
        if copied.numbers.count > 0 { sum &+= UInt64(copied.numbers[0]) }
        if copied.texts.count > 0 && copied.texts[0].count > 0 {
            sum &+= UInt64(copied.texts[0][0])
        }
        if copied.blobs.count > 0 && copied.blobs[0].count > 0 {
            sum &+= UInt64(copied.blobs[0][0])
        }
        if copied.matrix.count > 0 && copied.matrix[0].count > 0 {
            sum &+= UInt64(copied.matrix[0][0])
        }
        if copied.voids.count > 0 { copied.voids[0] }
        if copied._capnpWhich == .detail {
            let detail = copied.detail
            sum &+= detail.amount &+ UInt64(detail.label.count)
        } else {
            sum &+= UInt64(copied.value)
        }
        let upgraded = Capnp_9eb32e19f86f3a01.NewReader(root.borrowed())
        if upgraded.values.count > 0 { sum &+= upgraded.values[0].extra }
        return sum
    }
    return arena.error == .none ? result : 0
}
