// EXPECT-ERROR: has no member 'ref'

private struct NonCopyableBox: ~Copyable {
    let value: UInt64
}

private func probe(_ box: borrowing NonCopyableBox?) -> UInt64 {
    if let ref = box.ref() {
        return ref.value.value
    }
    return 0
}
