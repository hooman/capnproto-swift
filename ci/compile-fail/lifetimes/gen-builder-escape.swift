// REQUIRES: generated
// EXPECT-ERROR: lifetime-dependent value escapes its scope

import CapnpRuntime

@_lifetime(copy storage)
private func bad(_ storage: consuming MutableRawSpan) -> Capnp_9eb32e19f86f3a01.ExampleBuilder {
    var message = MessageBuilder(storage: storage)
    return message.initRoot(Capnp_9eb32e19f86f3a01.ExampleBuilder.self)
}
