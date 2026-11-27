// EXPECT-ERROR: type 'MessageBuilder' does not conform to.*'Sendable'

import CapnpRuntime

private func requireSendable<T: Sendable & ~Copyable & ~Escapable>(_: borrowing T) {}

private func bad(_ message: borrowing MessageBuilder) {
    requireSendable(message)
}
