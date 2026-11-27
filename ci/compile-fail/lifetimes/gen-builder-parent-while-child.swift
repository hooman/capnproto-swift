// REQUIRES: generated
// EXPECT-ERROR: overlapping accesses to 'example'

import CapnpRuntime

private func bad(_ storage: consuming MutableRawSpan) {
    var message = MessageBuilder(storage: storage)
    var example = message.initRoot(Capnp_9eb32e19f86f3a01.ExampleBuilder.self)
    var child = example.initChild()
    example.setU8(1)
    child.setId(2)
}
