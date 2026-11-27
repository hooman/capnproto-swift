// EXPECT-ERROR: overlapping accesses to 'root'

import CapnpRuntime

// A child view borrows its parent exclusively: writing the parent while the child lives
// is an aliased mutation (D-18, Q2).
private func bad(_ storage: consuming MutableRawSpan) {
    var message = MessageBuilder(storage: storage)
    var root = message.initRoot(dataWords: 1, pointerCount: 1)
    var child = root.initStruct(at: 0, dataWords: 1, pointerCount: 0)
    root.setData(UInt64(1), at: 0, default: 0)
    child.setData(UInt64(2), at: 0, default: 0)
}
