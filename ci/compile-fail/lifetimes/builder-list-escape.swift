// EXPECT-ERROR: lifetime-dependent value escapes its scope

import CapnpRuntime

@_lifetime(copy storage)
private func bad(_ storage: consuming MutableRawSpan) -> PrimitiveListBuilder<UInt32> {
    var message = MessageBuilder(storage: storage)
    var root = message.initRoot(dataWords: 0, pointerCount: 1)
    return root.initList(PrimitiveListBuilder<UInt32>.self, at: 0, count: 1)
}
