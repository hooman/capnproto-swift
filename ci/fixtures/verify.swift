// The same assertions run against C++-encoded messages on the host and compile through
// generated readers in a separate Embedded module. The exported entry point prevents
// unused generic paths from making the allocation check vacuous.
// Modes: 0 = schema defaults, 1 = populated fields, 2 = old wire layout read as new.

import CapnpRuntime

@c(verify_readers)
public func verifyReaders(_ pointer: UnsafeRawPointer, _ count: Int, _ mode: Int32) -> UInt64 {
    let raw = unsafe UnsafeRawBufferPointer(start: pointer, count: count)
    let arena = Arena(framedBytes: unsafe RawSpan(_unsafeBytes: raw))
    let sum = arena.withRoot { root -> UInt64 in
        if mode == 2 {
            let new = Capnp_9eb32e19f86f3a01.NewReader(root.borrowed())
            precondition(new.value == 42 && new.added == 123 && new.text.count == 0)
            let values = new.values
            precondition(values.count == 2)
            precondition(values[0].value == 11 && values[1].value == 22)
            precondition(values[1].extra == 456)
            return 75
        }
        let value = Capnp_9eb32e19f86f3a01.ExampleReader(root.borrowed())
        precondition(value.i8 == -12 && value.i16 == -1234 && value.i32 == -123456)
        precondition(value.i64 == -1234567890123 && value.u8 == 250 && value.u16 == 65000)
        precondition(value.u32 == 4000000000 && value.u64 == 18000000000000000000)
        precondition(value.f32 == 1.5 && value.f64 == -2.25)
        if mode == 0 {
            precondition(value.boolField && value.text.count == 0 && value.data.count == 0)
            precondition(value.child.id == 9 && value.children.count == 0)
            precondition(value._capnpWhich == .idle && value.value == 77)
            return 9
        }
        precondition(!value.boolField && value.text.count == 3 && value.text[0] == 104)
        precondition(value.data.count == 2 && value.data[1] == 255)
        precondition(value.child.id == 99 && value.child.name.count == 1)
        let children = value.children
        precondition(children.count == 2 && children[0].id == 11 && children[1].id == 22)
        precondition(value.bits.count == 3 && value.bits[0] && !value.bits[1] && value.bits[2])
        precondition(value.numbers.count == 3 && value.numbers[2] == 4000000000)
        precondition(value.texts.count == 2 && value.texts[1][0] == 98)
        precondition(value.blobs.count == 2 && value.blobs[1][0] == 2)
        precondition(value.matrix.count == 2 && value.matrix[1][1] == 22)
        precondition(value.voids.count == 3)
        value.voids[2]
        precondition(value._capnpWhich == .detail && value.detail.amount == 123)
        precondition(value.detail.label.count == 2 && value.value == 77)
        return children[0].id &+ children[1].id &+ value.child.id
    }
    precondition(arena.error == .none)
    return sum
}
