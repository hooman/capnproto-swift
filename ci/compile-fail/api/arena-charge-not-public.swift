// EXPECT-ERROR: 'charge' is inaccessible due to 'internal' protection level

// 0.1.0 API tiering: manual traversal charging is internal; observe the budget
// through the public `remainingTraversalWords` instead.
import CapnpRuntime

private func bad(_ arena: borrowing Arena) -> Bool { arena.charge(words: 1) }
