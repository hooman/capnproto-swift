// EXPECT-ERROR: lifetime-dependent value escapes its scope

import CapnpRuntime

// A MessageBuilder cannot outlive the caller storage it writes into.
private func bad() -> MessageBuilder {
    var storage = [UInt64](repeating: 0, count: 4)
    var span = storage.mutableSpan
    return MessageBuilder(storage: span.mutableBytes)
}
