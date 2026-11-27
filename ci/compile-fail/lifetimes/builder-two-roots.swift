// EXPECT-ERROR: overlapping accesses to 'message'

import CapnpRuntime

private func bad(_ storage: consuming MutableRawSpan) {
    var message = MessageBuilder(storage: storage)
    var first = message.initRoot(dataWords: 1, pointerCount: 0)
    var second = message.initRoot(dataWords: 1, pointerCount: 0)
    first.setData(UInt64(1), at: 0, default: 0)
    second.setData(UInt64(2), at: 0, default: 0)
}
