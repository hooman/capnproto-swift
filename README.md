# capnproto-swift

Native Swift readers for [Cap’n Proto](https://capnproto.org), with a host code
generator and an allocation-free Embedded Swift runtime. Requires Swift 6.2+;
verified with 6.2.4 and 6.3.1. Readers-only v1 is implemented; no release is tagged yet.

New to Cap'n Proto, or coming from Protocol Buffers? See **Why Cap'n Proto** and the
**Getting Started** tutorial in this package's DocC documentation (`swift package
generate-documentation`, or Xcode's Product ▸ Build Documentation) for a guided
introduction, including what changes on an Embedded Swift target.

## Status at a glance

| Area | State |
|---|---|
| Reading messages — structs, lists, unions, groups, text/data, schema evolution | ✅ Implemented, conformance-tested against the C++ reference implementation |
| Code generation — `capnpc-swift` plugin binary and the SwiftPM build-tool plugin | ✅ Implemented and verified from a separate consumer package |
| Embedded Swift / allocation-free runtime | ✅ Verified: `-no-allocations` compile, allocator-symbol audit, and a negative control that must fail |
| macOS and Linux (glibc) host execution | ✅ Verified in CI |
| ARMv7E-M bare-metal compilation | 🟡 Compiles and passes the allocation-freedom checks; not yet run on physical hardware |
| Static Linux (musl) / WebAssembly | ⬜ Not yet verified |
| Writing or mutating messages (builders) | ⬜ Not implemented — planned for v2 |
| RPC / capabilities | ⬜ Out of scope for this project |
| Tagged release | ⬜ None yet — depend on a commit revision (see below) |

✅ verified with evidence in CI or this README &nbsp;·&nbsp; 🟡 partially verified, gap noted
&nbsp;·&nbsp; ⬜ not yet done. See **Supported scope** and **Platform evidence** below for
the full, current detail behind each row.

## Generate readers with the SwiftPM plugin

Install the upstream `capnp` compiler (`brew install capnp`, or your platform's
package). Then depend on this package and attach the build-tool plugin to any target
holding `.capnp` schemas. No release is tagged yet, so pin a specific commit revision
rather than a branch — a branch reference can change under you between builds:

```swift
dependencies: [
    .package(url: "https://github.com/hooman/capnproto-swift", revision: "<commit-sha>")
]
```

```swift
.executableTarget(
    name: "Demo",
    dependencies: [.product(name: "CapnpRuntime", package: "capnproto-swift")],
    swiftSettings: [.enableExperimentalFeature("Lifetimes")],
    plugins: [.plugin(name: "CapnpGeneratorPlugin", package: "capnproto-swift")]
)
```

Put `schema.capnp` beside the target's Swift sources and build. The plugin runs `capnp`
once per schema, regenerates whenever a schema changes, and adds the generated
`schema.capnp.swift` to the target — nothing is checked in. Schemas that import each
other must live in the same target; names resolve against the target's source directory.

SwiftPM will warn `found 1 file(s) which are unhandled` for each `.capnp` file — that is
expected; the plugin, not the target, consumes them. **Do not** follow that warning's own
suggestion to add the schema to `exclude:`: SwiftPM then stops listing it as a source file
at all, the plugin sees no schemas and silently generates nothing, and the only symptom is
an unrelated `cannot find 'Capnp_...' in scope` error in your own code.

The plugin finds `capnp` via `CAPNP`, then `PATH`, then the usual package-manager
prefixes. A build machine without `capnp` fails the build with that message.

Two requirements the plugin cannot supply for you: a build-tool plugin cannot add
settings to its host target, so **every target using the readers must enable the
`Lifetimes` experimental feature and depend on `CapnpRuntime`** itself.

## Generate readers manually

If you would rather not use the plugin, install `capnp` and build this package:

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

### Documentation

The package depends on [`swift-docc-plugin`](https://github.com/swiftlang/swift-docc-plugin)
(host tooling only — it never links into `CapnpRuntime` or `capnpc-swift`) so the DocC
catalog at `Sources/CapnpRuntime/CapnpRuntime.docc` builds without extra setup:

```sh
swift package generate-documentation --target CapnpRuntime
swift package --disable-sandbox preview-documentation --target CapnpRuntime
```

Xcode's Product ▸ Build Documentation does the same. The catalog holds the **Why Cap'n
Proto** article and the **Getting Started** tutorial referenced above, plus the API
reference generated from doc comments.

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
