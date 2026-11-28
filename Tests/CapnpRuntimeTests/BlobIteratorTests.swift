// Answer key for TextReader.BorrowingIterator, written before the fix (PR #24, T1): a caller
// may ask for "the rest" with maxCount: .max, and must get every remaining byte, then an empty
// span, with no overflow. Span's own iterator behaves this way; DataReader uses it.

import Testing

@testable import CapnpRuntime

/// A framed message whose root has one pointer: the text "hello".
private func helloMessage() -> [UInt8] {
    var buffer = [UInt8](repeating: 0, count: 64)
    var framed: [UInt8] = []
    do {
        var span = buffer.mutableSpan
        var message = MessageBuilder(storage: span.mutableBytes)
        do {
            var root = message.initRoot(dataWords: 0, pointerCount: 1)
            root.setText("hello".utf8Span, at: 0)
        }
        #expect(message.error == .none)
        let bytes = message.framedBytes
        for i in 0..<bytes.byteCount {
            framed.append(bytes.load(fromByteOffset: i, as: UInt8.self))
        }
    }
    return framed
}

@Suite struct BlobIteratorTests {
    @Test func textIteratorHandsOutTheRestThenNothing() {
        let bytes = helloMessage()
        let arena = Arena(framedBytes: bytes.span.bytes)
        arena.withRoot { root in
            let text = root.pointerField(at: 0).text()
            var iterator = text.makeBorrowingIterator()
            let first = iterator.nextSpan(maxCount: 2).count
            #expect(first == 2)
            var restCount = 0
            var restEnds = false
            do {
                let rest = iterator.nextSpan(maxCount: .max)
                restCount = rest.count
                // No `&&`: its autoclosure would capture the nonescapable span.
                if rest.count == 3 {
                    let l = rest[0]
                    let o = rest[2]
                    restEnds = l == UInt8(ascii: "l") && o == UInt8(ascii: "o")
                }
            }
            #expect(restCount == 3)
            #expect(restEnds)
            let after = iterator.nextSpan(maxCount: .max).count
            #expect(after == 0)
            let none = iterator.nextSpan(maxCount: 0).count
            #expect(none == 0)
        }
        #expect(arena.error == .none)
    }

    @Test func textIteratorTakesEverythingInOneCall() {
        let bytes = helloMessage()
        let arena = Arena(framedBytes: bytes.span.bytes)
        arena.withRoot { root in
            let text = root.pointerField(at: 0).text()
            var iterator = text.makeBorrowingIterator()
            let all = iterator.nextSpan(maxCount: .max).count
            #expect(all == 5)
            let after = iterator.nextSpan(maxCount: .max).count
            #expect(after == 0)
        }
    }
}
