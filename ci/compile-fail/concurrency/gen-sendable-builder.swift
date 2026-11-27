// REQUIRES: generated
// EXPECT-ERROR: type 'Capnp_9eb32e19f86f3a01\.ExampleBuilder' does not conform to.*'Sendable'

import CapnpRuntime

private func requireSendable<T: Sendable & ~Copyable & ~Escapable>(_: borrowing T) {}

private func bad(_ example: borrowing Capnp_9eb32e19f86f3a01.ExampleBuilder) {
    requireSendable(example)
}
