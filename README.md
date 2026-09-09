# capnproto-swift

Native Swift readers for [Cap’n Proto](https://capnproto.org), with a host code
generator and an allocation-free Embedded Swift runtime. Requires Swift 6.2+;
verified with 6.2.4 and 6.3.1. Readers-only v1 is implemented; no release is tagged yet.

## Generate readers

Install the upstream `capnp` compiler, then build this package:

```sh
swift build -c release
mkdir -p Generated
capnp compile -o "$PWD/.build/release/capnpc-swift:Generated" schema.capnp
```

Compile the resulting `schema.capnp.swift` with the `CapnpRuntime` product. Enable
`.enableExperimentalFeature("Lifetimes")` in every SwiftPM target using the readers
(or pass `-enable-experimental-feature Lifetimes` to `swiftc`). Generate imported
schema files too, and compile their generated Swift in the same target.

Each schema file has a collision-resistant namespace `Capnp_<file ID in hex>`;
`struct Person` becomes `Capnp_<id>.PersonReader`. Nested types stay nested.
Fields retain their schema names, escaped for Swift keywords. `_capnp` and
`_Capnp` prefixes are reserved for generated support. See
[the example schema](ci/fixtures/readers.capnp) and [compiled usage](ci/fixtures/verify.swift).

## Read a message

This example uses the checked-in example schema (file ID `9eb32e19f86f3a01`):

```swift
import CapnpRuntime

@available(macOS 15, iOS 18, watchOS 11, tvOS 18, visionOS 2, *)
func readID(_ bytes: [UInt8]) -> UInt64? {
    bytes.withUnsafeBytes { raw in
        let arena = Arena(framedBytes: RawSpan(_unsafeBytes: raw))
        guard arena.error == .none else { return nil }
        let id = arena.withRoot { root in
            let example = Capnp_9eb32e19f86f3a01.ExampleReader(root)
            return example.child.id
        }
        return arena.error == .none ? id : nil
    }
}
```

The runtime borrows storage; it does not allocate, copy the message, or own a
buffer. Keep reads inside `withRoot`. A reader, list, text, or data view cannot
escape that scope. Primitive results and caller-created owned results can return.
Raw pointers enter through Swift’s explicitly unsafe `RawSpan` constructor; the
caller must supply valid storage for that scope. The example borrows an array’s
storage through `withUnsafeBytes`.

`arena.error` records the first failure. Missing fields and null pointers read
schema defaults without an error. Malformed pointers, invalid UTF-8/text terminators,
type mismatches, invalid list indexes, and exhausted budgets return empty/default
values and set the error. Check it **after traversal** before accepting results.
Unvisited fields are not eagerly validated. Capability pointers dereference as empty
without an error in v1; `PointerReader.isNull` still tests the literal wire null.

`ReaderOptions` defaults to an 8,388,608-word (64 MiB) traversal budget, nesting depth 64,
and 512 segments. Repeated pointer reads, including through copied views, consume
the shared budget. Lists of zero-sized elements consume virtual words to prevent
amplification. `consumedByteCount` identifies the first frame when bytes contain
concatenated messages. Packed streams must be unpacked before calling the runtime.

Lists expose `count` and indexed access: `for i in 0..<list.count`. Text exposes
validated UTF-8 bytes without its wire NUL; data exposes uninterpreted bytes.
Unions expose `_capnpWhich` (nil for unknown future tags); inactive fields return
their schema defaults. Named union/group fields return a reader over the parent layout.

## Supported scope

- Standard unpacked framing, multiple segments, single- and double-far pointers.
- Void, Bool, all signed/unsigned 8/16/32/64-bit integers, Float32/64, Text, Data,
  structs, nested structs, lists (including lists of lists), groups, and unions.
- Scalar XOR defaults, empty pointer defaults, missing-field defaults, compatible
  primitive/pointer-list and struct-list schema evolution. Boolean lists cannot
  upgrade to struct lists.
- One Embedded-clean generated API for host and embedded use.

The generator diagnoses enums, interfaces, constants, annotations, generics,
AnyPointer, and non-empty pointer defaults. No builders, RPC, packed-stream decoder,
public async API, or Sendable arena is provided. Apple readers require macOS 15 /
iOS 18 / watchOS 11 / tvOS 18 / visionOS 2 because the arena uses Synchronization.
Non-Apple readers have no OS availability gate.

## Verification

```sh
swift test
SWIFTC=/path/to/swift.org/usr/bin/swiftc ci/check-embedded-clean.sh
python3 ci/check-readers.py --swiftc /path/to/swiftc --capnp /path/to/capnp \
  --plugin .build/debug/capnpc-swift --work /tmp/readers
python3 ci/check-cross.py --swiftc /path/to/swiftc \
  --target armv7em-none-none-eabi --generated /tmp/readers/readers.capnp.swift
```

Use a Swift.org toolchain containing the Embedded standard library. `SDKROOT` can
select a compatible Apple SDK for older compilers. Cross-OS checks accept
`--stdlib` pointing to the **same compiler version’s** Embedded modules from the
target OS toolchain. CI covers host tests, C++ oracle messages, compile-time lifetime
rejections, generated readers across a module boundary, allocator symbol audits,
and an allocating negative control. ARMv7E-M and x86-64 Linux compile probes do not
substitute for execution on physical embedded hardware.

### Platform evidence

| Target | Verified with Swift 6.2.4 and 6.3.1 | Remaining validation |
|---|---|---|
| macOS host | Runtime tests, generator and C++ fixtures; Embedded object checks | Older supported Apple OS/device execution |
| Linux x86-64 (glibc) | Host execution and Embedded object checks in CI | Additional architectures and distributions |
| ARMv7E-M bare metal | Runtime and generated-reader compilation, symbol audit and negative control | Firmware linking and device execution |
| Static Linux SDK (musl) | Not yet verified | Separate SDK build, static link and Linux execution |
| WebAssembly / WASI | Not yet verified | Full and Embedded SDK builds, imports audit and execution |

Snapshot or vendor compilers reporting a newer Swift version are not automatically
qualified by these results. Static linking, Embedded mode and allocation freedom are
separate properties; a Linux glibc check proves neither musl nor Wasm support.

### Known follow-up work

Schema `sourceInfo` documentation is not yet propagated into generated Swift comments.
Filesystem rejection tests do not yet cover path/symlink escapes or injected partial-write
failures. These gaps are marked at the relevant decoder and verification code. The
internal trusted scalar-fixture initializer is also marked for relocation into tests.
Unsupported v1 features listed above are deliberate scope limits, not silent stubs.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the storage, lifetime, and validation model.
Licensed under [MIT](LICENSE).
