// EXPECT-ERROR: overlapping accesses to 'numbers'

import CapnpRuntime

// A list's element views borrow the list exclusively: two struct elements at once alias.
private struct Item: ~Copyable, ~Escapable, CapnpStructBuilder {
    var builder: StructBuilder
    static var _capnpDataWords: Int { 1 }
    static var _capnpPointerCount: Int { 0 }
    @_lifetime(copy builder)
    init(_ builder: consuming StructBuilder) { self.builder = builder }
}

private func bad(_ storage: consuming MutableRawSpan) {
    var message = MessageBuilder(storage: storage)
    var root = message.initRoot(dataWords: 0, pointerCount: 1)
    var numbers = root.initList(StructListBuilder<Item>.self, at: 0, count: 2)
    var first = numbers.element(at: 0)
    var second = numbers.element(at: 1)
    first.builder.setData(UInt64(1), at: 0, default: 0)
    second.builder.setData(UInt64(2), at: 0, default: 0)
}
