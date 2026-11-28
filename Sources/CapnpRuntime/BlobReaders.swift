// Blob readers retain validated, zero-copy stdlib spans instead of allocating Data or
// String. Text is validated once when opened through UTF8Span(validating:); subsequent
// indexing returns UTF-8 code units, excludes the wire terminator, and reports
// .invalidIndex instead of trapping on out-of-range reads.

/// Borrowed byte view over a validated Data field, conforming to `Iterable`.
public struct DataReader: ~Escapable, ~Sendable, Iterable, CapnpListElement {
    let context: ReadContext
    private let _bytes: Span<UInt8>

    @_lifetime(copy context)
    init(context: ReadContext, start: Int = 0, count: Int = 0) {
        self.context = context
        self._bytes = Span<UInt8>(viewing: context.bytes.extracting(start..<(start + count)))
    }

    /// Borrowed zero-copy view of the underlying bytes.
    public var bytes: Span<UInt8> {
        @_lifetime(copy self)
        borrow { return _bytes }
    }

    public var count: Int { _bytes.count }

    public subscript(index: Int) -> UInt8 {
        guard index >= 0, index < _bytes.count else {
            context.report(.invalidIndex)
            return 0
        }
        return _bytes[index]
    }

    @_lifetime(borrow self)
    public func makeBorrowingIterator() -> Span<UInt8>.BorrowingIterator {
        _bytes.makeBorrowingIterator()
    }

    public static var listElementEncoding: ElementSize { .pointer }

    @_lifetime(copy list)
    public static func decodeElement(from list: borrowing ListReader, at index: Int) -> Self {
        list.pointer(at: index).data()
    }
}

/// Valid UTF-8 bytes, excluding the wire NUL terminator. No allocating String conversion.
public struct TextReader: ~Escapable, ~Sendable, Iterable, CapnpListElement {
    let context: ReadContext
    private let _utf8: UTF8Span

    @_lifetime(copy context)
    init(context: ReadContext) {
        self.context = context
        // An empty byte slice is unconditionally valid UTF-8.
        let empty = Span<UInt8>(viewing: context.bytes.extracting(0..<0))
        self._utf8 = try! UTF8Span(validating: empty)
    }

    @_lifetime(copy context, copy utf8)
    init(context: ReadContext, utf8: UTF8Span) {
        self.context = context
        self._utf8 = utf8
    }

    /// Borrowed zero-copy validated UTF-8 span (code units, scalars, and characters).
    public var utf8: UTF8Span {
        @_lifetime(copy self)
        borrow { return _utf8 }
    }

    /// Validated UTF-8 code units without the wire NUL terminator.
    public var bytes: Span<UInt8> {
        @_lifetime(copy self)
        get { _utf8.span }
    }

    public var count: Int { _utf8.count }

    public subscript(index: Int) -> UInt8 {
        guard index >= 0, index < _utf8.count else {
            context.report(.invalidIndex)
            return 0
        }
        return _utf8.span[index]
    }

    /// Borrowing iterator over validated UTF-8 code units.
    public struct BorrowingIterator: BorrowingIteratorProtocol, ~Escapable, ~Sendable {
        let span: Span<UInt8>
        var position: Int = 0

        @_lifetime(copy span)
        init(_ span: Span<UInt8>) { self.span = span }

        @_lifetime(&self)
        @_lifetime(self: copy self)
        public mutating func nextSpan(maxCount: Int) -> Span<UInt8> {
            // Clamp to what is left before adding, so `maxCount: .max` ("the rest") cannot
            // overflow `position + maxCount`.
            let end = position + min(max(0, maxCount), span.count - position)
            let chunk = span.extracting(position..<end)
            position = end
            return chunk
        }
    }

    @_lifetime(borrow self)
    public func makeBorrowingIterator() -> BorrowingIterator {
        BorrowingIterator(_utf8.span)
    }

    public static var listElementEncoding: ElementSize { .pointer }

    @_lifetime(copy list)
    public static func decodeElement(from list: borrowing ListReader, at index: Int) -> Self {
        list.pointer(at: index).text()
    }
}
