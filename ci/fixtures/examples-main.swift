// Host driver for list, text and data builders (D-18 item 3), written against the intended
// generated API before the generator change (answer key). Each argument is `mode:path`:
// build message `mode` of readers.capnp with generated builders and write its framed bytes.
// ci/check-readers.py compares modes 0-2 with the 9 C++ oracle messages (the same three
// contents at three segment sizes) in canonical form, and modes 20-24 with `capnp encode` of
// their final content, and requires every word no pointer reaches to be zero.
//
// Generated API for pointer fields: text `setFoo(_: UTF8Span)`, data `setFoo(_: Span<UInt8>)`,
// lists `initFoo(count:)` returning a typed list builder, and `clearFoo()` for each.

import CapnpRuntime
import Foundation

typealias R = Capnp_9eb32e19f86f3a01

func buildExample(_ mode: Int, into message: inout CapnpRuntime.MessageBuilder) {
    var example = message.initRoot(R.ExampleBuilder.self)
    switch mode {
    case 0:
        break
    case 1:  // the oracle's `full`
        example.setBoolField(false)
        example.setText("hi!".utf8Span)
        let data: [UInt8] = [0x00, 0xFF]
        example.setData(data.span)
        do {
            var child = example.initChild()
            child.setId(99)
            child.setName("x".utf8Span)
        }
        do {
            var children = example.initChildren(count: 2)
            do {
                var first = children.element(at: 0)
                first.setId(11)
            }
            var second = children.element(at: 1)
            second.setId(22)
        }
        do {
            var bits = example.initBits(count: 3)
            bits.setElement(true, at: 0)
            bits.setElement(false, at: 1)
            bits.setElement(true, at: 2)
        }
        do {
            var numbers = example.initNumbers(count: 3)
            numbers.setElement(0, at: 0)
            numbers.setElement(11, at: 1)
            numbers.setElement(4_000_000_000, at: 2)
        }
        do {
            var texts = example.initTexts(count: 2)
            texts.setElement("a".utf8Span, at: 0)
            texts.setElement("b".utf8Span, at: 1)
        }
        do {
            var blobs = example.initBlobs(count: 2)
            let one: [UInt8] = [0x01]
            let two: [UInt8] = [0x02]
            blobs.setElement(one.span, at: 0)
            blobs.setElement(two.span, at: 1)
        }
        do {
            var matrix = example.initMatrix(count: 2)
            do {
                var row = matrix.initElement(at: 0, count: 1)
                row.setElement(11, at: 0)
            }
            var row = matrix.initElement(at: 1, count: 2)
            row.setElement(21, at: 0)
            row.setElement(22, at: 1)
        }
        _ = example.initVoids(count: 3)
        do {
            var detail = example.initDetail()
            detail.setLabel("ok".utf8Span)
            detail.setAmount(123)
        }
    case 20:  // a union group with text, then a scalar member: the text is zeroed
        do {
            var detail = example.initDetail()
            detail.setLabel("a long label".utf8Span)
        }
        example.setValue(5)
    case 21:  // a list re-initialized
        do {
            var numbers = example.initNumbers(count: 4)
            numbers.setElement(9, at: 3)
        }
        var numbers = example.initNumbers(count: 1)
        numbers.setElement(1, at: 0)
    case 22:  // text replaced by shorter text
        example.setText("a longer text".utf8Span)
        example.setText("b".utf8Span)
    case 23:  // a struct list whose elements hold text, then cleared
        do {
            var children = example.initChildren(count: 2)
            var first = children.element(at: 0)
            first.setName("gone".utf8Span)
        }
        example.clearChildren()
    case 24:  // a list of lists re-initialized
        do {
            var matrix = example.initMatrix(count: 2)
            var row = matrix.initElement(at: 1, count: 3)
            row.setElement(7, at: 2)
        }
        var matrix = example.initMatrix(count: 1)
        var row = matrix.initElement(at: 0, count: 1)
        row.setElement(8, at: 0)
    default:
        preconditionFailure("unknown mode \(mode)")
    }
}

func buildOld(into message: inout CapnpRuntime.MessageBuilder) {
    var old = message.initRoot(R.OldBuilder.self)
    old.setValue(42)
    var values = old.initValues(count: 2)
    values.setElement(11, at: 0)
    values.setElement(22, at: 1)
}

@main
struct ExamplesMain {
    static func main() throws {
        for argument in CommandLine.arguments.dropFirst() {
            let parts = argument.split(separator: ":", maxSplits: 1)
            let mode = Int(parts[0])!
            var storage = [UInt8](repeating: 0xAA, count: 4096)
            var framed = Data()
            do {
                var span = storage.mutableSpan
                var message = CapnpRuntime.MessageBuilder(storage: span.mutableBytes)
                if mode == 2 {
                    buildOld(into: &message)
                } else {
                    buildExample(mode, into: &message)
                }
                precondition(message.error == .none, "mode \(mode): \(message.error)")
                let bytes = message.framedBytes
                for i in 0..<bytes.byteCount {
                    framed.append(bytes.load(fromByteOffset: i, as: UInt8.self))
                }
            }
            try framed.write(to: URL(fileURLWithPath: String(parts[1])))
        }
        print("PASS list, text and data builders")
    }
}
