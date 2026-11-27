// EXPECT-ERROR: lifetime-dependent value escapes its scope

import CapnpRuntime

// A view cannot outlive the MessageBuilder it borrows.
@_lifetime(copy storage)
private func bad(_ storage: consuming MutableRawSpan) -> StructBuilder {
    var message = MessageBuilder(storage: storage)
    return message.initRoot(dataWords: 1, pointerCount: 0)
}
