# capnproto-swift

Native Swift readers for [Cap’n Proto](https://capnproto.org), with a host code
generator and an allocation-free Embedded Swift runtime. Requires Swift 6.4+
and, on Apple platforms, OS 27. The package is a test bed for current Swift
system-programming features and does not back-deploy. Readers-only v1 is released as
`0.1.0`; see [CHANGELOG.md](CHANGELOG.md).

New to Cap'n Proto, or coming from Protocol Buffers? See **Why Cap'n Proto** and the
**Getting Started** tutorial in this package's DocC documentation (`swift package
generate-documentation`, or Xcode's Product ▸ Build Documentation) for a guided
introduction, including what changes on an Embedded Swift target.

## Status at a glance

| Area | State |
|---|---|
| Reading messages — structs, lists, unions, groups, text/data, schema evolution | ✅ Implemented, conformance-tested against the C++ reference implementation |
| Code generation — `capnpc-swift` plugin binary and the SwiftPM build-tool plugin | ✅ Implemented and verified from a separate consumer package |
| Embedded Swift / allocation-free runtime | ✅ Verified: `-no-allocations` compile, allocator-symbol audit, negative control, and 0 `unsafe` expressions under strict memory safety |
| macOS and Linux (glibc) host execution | ✅ Verified in CI (31 runtime tests at 98.7% line coverage, C++ oracle conformance, 25 compile-fail fixtures, output-boundary hardening) |
| ARMv7E-M bare metal | 🟡 Compiles, passes allocation-freedom checks, and links against `ci/firmware/stubs.c` only (`5,358 B` flash / `10,876 B` ELF on 6.4.2; `4,955 B` flash / `9,740 B` ELF on `main-2026-11-01`); not yet run on physical hardware |
| RISC-V 32-bit bare metal (`rv32imac` / ESP32-C6) | 🟡 Compiles, passes allocation-freedom checks, and links against `ci/firmware/stubs.c` only (`6,812 B` flash / `14,612 B` ELF on 6.4.2; `6,405 B` flash / `19,056 B` ELF on `main-2026-11-01`); not yet run on physical hardware |
| WebAssembly / WASI | ✅ Full and Embedded Swift run all 9 aligned + 2 unaligned C++ oracle messages plus 8 32-bit overflow/clamping/malformed edge checks under WasmKit; Embedded allocation freedom checked by call-graph analysis |
| Static Linux (musl) | 🟡 Verified locally on Swift 6.4.2 (`aarch64` native Linux `FROM scratch`, `x86_64` Rosetta-emulated `FROM scratch`); static ELF audit + 9/9 oracle messages pass; native `x86_64` Linux hardware pending |
| Embedded builds with full debug info (`-g`) | 🟡 Fixed on Swift `main` (`main-snapshot-2026-11-01`); Swift 6.4.0–6.4.2 releases still need `-gline-tables-only` — see *Embedded debug info* below |
| Writing or mutating messages (builders) | ⬜ Not implemented — planned for v2 |
| RPC / capabilities | ⬜ Out of scope for this project |
| Tagged release | ✅ `0.1.0` — see [CHANGELOG.md](CHANGELOG.md) |

✅ verified with evidence in CI or this README &nbsp;·&nbsp; 🟡 partially verified, gap noted
&nbsp;·&nbsp; ⬜ not yet done. See **Supported scope** and **Platform evidence** below for
the full, current detail behind each row.

## Generate readers with the SwiftPM plugin

Install the upstream `capnp` compiler (`brew install capnp`, or your platform's
package). Then depend on this package and attach the build-tool plugin to any target
holding `.capnp` schemas. While the version is `0.x`, a minor release may break source
compatibility, so pin to the minor version:

```swift
dependencies: [
    .package(url: "https://github.com/hooman/capnproto-swift", .upToNextMinor(from: "0.1.0"))
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

func readID(_ bytes: [UInt8]) -> UInt64? {
    let arena = Arena(framedBytes: bytes.span.bytes)
    guard arena.error == .none else { return nil }
    let id = arena.withRoot { root in
        let example = Capnp_9eb32e19f86f3a01.ExampleReader(root)
        return example.child.id
    }
    return arena.error == .none ? id : nil
}
```

The runtime borrows storage; it does not allocate, copy the message, or own a
buffer. Keep reads inside `withRoot`. A reader, list, text, or data view cannot
escape that scope, and neither `Arena` nor any view is `Sendable` (`~Sendable`).
Primitive results and caller-created owned results can return. The example above
borrows the array's storage safely through `bytes.span.bytes`; raw pointers from C
can enter through Swift's explicitly unsafe `RawSpan(_unsafeBytes:)` constructor.

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

Lists expose `count` and indexed access (`for i in 0..<list.count`) through
`PrimitiveList<Element>`, `EnumList<Element>`, `VoidList`, and unified generic
`CapnpList<Element>`.
`TextReader` validates UTF-8 once on open and exposes `utf8: UTF8Span` (use
`String(copying: text.utf8)` when an owned `String` is needed), `bytes: Span<UInt8>`,
and `Iterable` borrowing iteration without the wire NUL. `DataReader` exposes
`bytes: Span<UInt8>` and `Iterable` over uninterpreted bytes. Unions expose
`_capnpWhich` (nil for unknown future tags); inactive fields return their schema
defaults. Named union/group fields return a reader over the parent layout.

A schema enum becomes `public enum Name: UInt16, CapnpRuntime.CapnpEnum`, with one case
per enumerant and its ordinal as the raw value. Enum fields return `Name?`: `nil` means an
ordinal this schema version does not know, which a newer writer can send. For each enum
field `x`, `_capnpRaw_x` returns the ordinal itself, after the schema default, so an
unknown value can still be logged or forwarded. `EnumList<Element>` returns `Element?`
from its subscript and the ordinal from `raw(at:)`.

## Supported scope

- Standard unpacked framing, multiple segments, single- and double-far pointers.
- Void, Bool, all signed/unsigned 8/16/32/64-bit integers, Float32/64, Text, Data,
  structs, nested structs, enums, lists (including lists of lists), groups, and unions.
- Scalar XOR defaults, empty pointer defaults, missing-field defaults, compatible
  primitive/pointer-list and struct-list schema evolution. Boolean lists cannot
  upgrade to struct lists.
- Annotations are accepted and ignored, including `$Cxx.namespace` from
  `/capnp/c++.capnp`; annotation declarations generate nothing.
- Schema doc comments become `///` comments on the generated file namespace, structs,
  groups, field accessors, enums and enum cases. Comment text is sanitized, so it cannot leave its
  comment line, and a missing or incomplete `sourceInfo` never fails a build.
- One Embedded-clean generated API for host and embedded use.

The generator diagnoses interfaces, constants, generics, AnyPointer, and non-empty
pointer defaults in the files it generates. It also diagnoses enums that Swift cannot
represent: an enum without enumerants, and an enum named `Void`, `Swift`,
`CapnpRuntime`, `Type`, `Protocol` or a scalar type name such as `UInt16`, which would
shadow names the generated code uses. Two generated types with the same Swift name in one
scope (struct `E` and enum `EReader`) are diagnosed too. An unused interface in an imported
file does not block generation. No builders, RPC, packed-stream decoder,
public async API, or Sendable arena is provided. Apple targets require OS 27 (macOS,
iOS, watchOS, tvOS, visionOS), where SE-0525's safe `RawSpan` loads are available.
Non-Apple targets have no OS availability gate.

## Verification

```sh
swift format lint --strict --recursive Package.swift Sources Tests Plugins ci
swift test
SWIFTC=/path/to/swift.org/usr/bin/swiftc ci/check-embedded-clean.sh
python3 ci/check-readers.py --swiftc /path/to/swiftc --capnp /path/to/capnp \
  --plugin .build/debug/capnpc-swift --work /tmp/readers
python3 ci/check-compile-fail.py --swiftc /path/to/swiftc --mode all \
  --generated /tmp/readers/readers.capnp.swift
python3 ci/check-cross.py --swiftc /path/to/swiftc \
  --target armv7em-none-none-eabi --generated /tmp/readers/readers.capnp.swift
python3 ci/check-cross.py --swiftc /path/to/swiftc \
  --target riscv32-none-none-eabi --generated /tmp/readers/readers.capnp.swift
SWIFTC=/path/to/swift.org/usr/bin/swiftc ci/check-debug-info.sh
SWIFTC=/path/to/swift.org/usr/bin/swiftc ci/check-link.sh
SWIFTC=/path/to/swift.org/usr/bin/swiftc TARGET=riscv32-none-none-eabi ci/check-link.sh
python3 ci/check-wasm.py --swiftc /path/to/swiftc --readers-work /tmp/readers \
  --wasm-sdk /path/to/swift-6.4.0-RELEASE_wasm/wasm32-unknown-wasip1
python3 ci/check-static-linux.py --swiftc /path/to/swiftc --readers-work /tmp/readers \
  --sdk-id swift-6.4.2-RELEASE_static-linux-0.1.0
```

Use a Swift.org toolchain containing the Embedded standard library. `SDKROOT` can
select a compatible Apple SDK for older compilers. Cross-OS checks accept
`--stdlib` pointing to the **same compiler version’s** Embedded modules from the
target OS toolchain. Verification covers host tests, C++ oracle messages, compile-fail
contracts (lifetimes, arena noncopyability, non-`Sendable`, strict memory safety) and
watchlist tripwires, generated readers across a module boundary, allocator symbol audits,
and an allocating negative control. Formatting follows the committed `.swift-format`
(apply with `swift format --in-place --recursive …`; CI lints it). ARMv7E-M and x86-64 Linux compile probes do not
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

| Target | Verified with Swift 6.4.0 / 6.4.2 (and `main-2026-11-01` locally) | Remaining validation |
|---|---|---|
| macOS host | 31 runtime tests (98.7% line coverage), generator + output-boundary hardening, C++ fixtures, 25 compile-fail fixtures, Embedded object checks | iOS/watchOS/tvOS/visionOS device execution |
| Linux x86-64 (glibc) | Host execution, strict `swift format` lint, and Embedded object checks in CI | Additional architectures and distributions |
| ARMv7E-M bare metal | Runtime and generated-reader compilation, symbol audit, and negative control; firmware image links against `ci/firmware/stubs.c` only (`5,358 B` flash / `10,876 B` ELF on 6.4.2; `4,955 B` flash / `9,740 B` ELF on `main-2026-11-01` with PAL `_swift_deallocate` negative-control rejection, zero atomic stubs) | Device or QEMU execution |
| RISC-V 32-bit bare metal (`rv32imac`) | Runtime and generated-reader compilation, symbol audit, and negative control; firmware image links against `ci/firmware/stubs.c` only (`6,812 B` flash / `14,612 B` ELF on 6.4.2; `6,405 B` flash / `19,056 B` ELF on `main-2026-11-01`, zero atomic stubs) | Real hardware (e.g. ESP32-C6) execution |
| Static Linux SDK (musl) | Verified locally with Swift 6.4.2 (`swift-6.4.2-RELEASE_static-linux-0.1.0`, musl 1.2.5): `aarch64` and `x86_64` statically linked ELF executables (`INTERP`/`DYNAMIC`/`NEEDED` absent) run all 9 C++ oracle messages + wrong-mode negative control in `FROM scratch` Linux containers (`aarch64` native arm64 Linux, `x86_64` Rosetta-emulated on Apple Silicon); SwiftPM `--swift-sdk` builds `CapnpRuntime` cleanly (SDK ships no `Testing` module). Full-Swift static binaries allocate; this is separate from `-no-allocations` | Native `x86_64` Linux hardware execution |
| WebAssembly / WASI | Full and Embedded builds run all 9 aligned + 2 unaligned (`+1`/`+3` byte shifted) C++ oracle messages plus 8 32-bit edge checks (single/double-far `Int32.max` overflow guards, `signedOffsetWords` overflow, `Atomic<UInt>` budget clamping, amplification, unaligned `UTF8Span`, malformed frame/UTF-8) under WasmKit (CI and local) and wasmtime (local) with host-identical results. Embedded allocation freedom by call-graph analysis with a negative control; `-no-allocations` itself is unusable on this SDK because its concurrency scaffolding allocates | Browser/JS hosts |

Snapshot or vendor compilers reporting a newer Swift version are not automatically
qualified by these results. Static linking, Embedded mode and allocation freedom are
separate properties; a Linux glibc check proves neither musl nor Wasm support.

### Embedded debug info

Swift 6.4.0–6.4.2 releases crash in the compiler (`IRGenDebugInfo`, "Don't know how
to emit debug info for type") when an Embedded build of `CapnpRuntime` uses full debug
info (`-g`). This crash is fixed on Swift `main` (verified on `main-snapshot-2026-11-01`).
Until the fix ships in a release, SwiftPM passes `-g` on every build, so an Embedded
package consumer on 6.4.x needs line tables (or no debug info). SwiftPM 6.4's default
build system ignores both overrides, so select the native build system:

```sh
swift build --build-system native -Xswiftc -gline-tables-only   # or: -debug-info-format none
```

Verified with Swift 6.4.0 for a `wasm-embedded` consumer package in release
configuration.

Host (non-Embedded) builds are unaffected. `ci/check-debug-info.sh` tracks the crash and
reports when a toolchain fixes it.

### Known follow-up work

Unsupported v1 features listed above are deliberate scope limits, not silent stubs.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the storage, lifetime, and validation model.
Licensed under [MIT](LICENSE).
