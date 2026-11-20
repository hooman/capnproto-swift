// EXPECT-ERROR: type 'StructReader' does not conform to protocol 'Escapable'

import CapnpRuntime

private func probe(_ span: Span<StructReader>) -> Int {
    span.count
}
