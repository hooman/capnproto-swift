// The 32-bit generated-builder suite (D-18 item 2), mode 96 of the WASI and QEMU drivers. It
// builds readers.capnp's Example with every generated builder method kind (scalar and union
// setters and getters, struct init and clear, a union group, the generic initRoot) and reads
// the result back with the generated reader. The QEMU image is linked with --gc-sections, so
// this call is what keeps the generated builder code in the audited image. Returns the check
// count; a failed precondition traps.

import CapnpRuntime

typealias GenExample = Capnp_9eb32e19f86f3a01

func verify32BitGeneratedBuilders() -> Int {
    var checks = 0
    var storage = InlineArray<64, UInt64>(repeating: 0)
    var span = storage.mutableSpan
    var message = CapnpRuntime.MessageBuilder(storage: span.mutableBytes)
    do {
        var example = message.initRoot(GenExample.ExampleBuilder.self)
        example.setBoolField(false)
        example.setI8(-1)
        example.setI16(2)
        example.setI32(-3)
        example.setI64(4)
        example.setU8(5)
        example.setU16(6)
        example.setU32(7)
        example.setU64(8)
        example.setF32(0.5)
        example.setF64(-0.25)
        precondition(example.u32() == 7 && !example.boolField() && example.f64() == -0.25)
        do {
            var child = example.initChild()
            child.setId(42)
        }
        example.clearChild()
        do {
            var child = example.initChild()
            child.setId(43)
        }
        example.setIdle()
        example.setValue(9)
        precondition(example._capnpWhich() == .value && example.value() == 9)
        do {
            var detail = example.initDetail()
            detail.setAmount(10)
        }
        precondition(example._capnpWhich() == .detail)
        // Item 3: text, data and lists.
        example.setText("hi".utf8Span)
        do {
            var numbers = example.initNumbers(count: 2)
            numbers.setElement(4_000_000_000, at: 1)
        }
        do {
            var children = example.initChildren(count: 2)
            var second = children.element(at: 1)
            second.setId(77)
            second.setName("n".utf8Span)
        }
        do {
            var matrix = example.initMatrix(count: 1)
            var row = matrix.initElement(at: 0, count: 1)
            row.setElement(5, at: 0)
        }
        checks += 1
    }
    let buildError = message.error
    precondition(buildError == .none)
    let arena = Arena(framedBytes: message.framedBytes)
    let ok = arena.withRoot { root in
        let example = GenExample.ExampleReader(root)
        return !example.boolField && example.i8 == -1 && example.i16 == 2 && example.i32 == -3
            && example.i64 == 4 && example.u8 == 5 && example.u16 == 6 && example.u32 == 7
            && example.u64 == 8 && example.f32 == 0.5 && example.f64 == -0.25
            && example.child.id == 43 && example._capnpWhich == .detail
            && example.detail.amount == 10
    }
    let lists = arena.withRoot { root in
        let example = GenExample.ExampleReader(root)
        return example.text.utf8.count == 2 && example.numbers.count == 2
            && example.numbers[1] == 4_000_000_000 && example.children.count == 2
            && example.children[1].id == 77 && example.children[1].name.utf8.count == 1
            && example.matrix[0][0] == 5
    }
    let readError = arena.error
    precondition(ok && lists && readError == .none)
    checks += 2
    return checks
}
