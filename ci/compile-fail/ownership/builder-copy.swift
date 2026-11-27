// EXPECT-ERROR: 'copy' cannot be applied to noncopyable types

import CapnpRuntime

private func bad(_ storage: consuming MutableRawSpan) {
    var message = MessageBuilder(storage: storage)
    var root = message.initRoot(dataWords: 1, pointerCount: 0)
    var alias = copy root
    alias.setData(UInt64(1), at: 0, default: 0)
    root.setData(UInt64(2), at: 0, default: 0)
}
