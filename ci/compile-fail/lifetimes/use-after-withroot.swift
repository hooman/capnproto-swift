// EXPECT-ERROR: lifetime-dependent variable 'leaked' escapes its scope

import CapnpRuntime

private func bad(_ outer: borrowing Arena, _ inner: borrowing Arena) -> UInt64 {
    outer.withRoot { outerRoot in
        var leaked = outerRoot.borrowed()
        inner.withRoot { innerRoot in
            leaked = innerRoot.borrowed()
        }
        return leaked.data(at: 0, default: UInt64(0))
    }
}
