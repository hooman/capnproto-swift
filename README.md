# capnproto-swift

A native-Swift [Cap'n Proto](https://capnproto.org) implementation for **Swift 6.3+** with **Embedded Swift** support.

> **Status: early bootstrap.** The design is settled; implementation has not started. Not yet usable.

Two products in one package:

- **`CapnpRuntime`** — an allocation-free, Foundation-free runtime that decodes Cap'n Proto messages with zero copies. Compiles under Embedded Swift's `-no-allocations` (any reachable heap use is a compile error), so it runs on bare metal and microcontrollers with no C++ dependency. Lifetime-safe by construction via `~Escapable` + `@_lifetime`.
- **`capnpc-swift`** — the host-side code-generator plugin (`capnp compile -o swift`). Unconstrained.

### Scope (v1)
Serialization only — readers, synchronous, wire-format-compatible with the Cap'n Proto spec. No RPC, no mutable builders, no async API. (Builders are planned for v2; RPC is out of scope.)

### Requirements
Swift 6.2+ (developed on 6.3.1).

### Status / roadmap
See the design and roadmap in the (private) project workspace. This repo will fill in as the runtime and code generator land.

### License
TBD.
