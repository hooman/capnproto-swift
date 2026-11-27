// EXPECT-ERROR: type 'StructBuilder' does not conform to.*'Sendable'

import CapnpRuntime

private func requireSendable<T: Sendable & ~Copyable & ~Escapable>(_: borrowing T) {}

private func bad(_ builder: borrowing StructBuilder) {
    requireSendable(builder)
}
