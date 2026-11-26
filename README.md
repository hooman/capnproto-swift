# capnproto-swift

Native Swift readers for [Cap’n Proto](https://capnproto.org): a host code generator and
an allocation-free runtime that also builds for Embedded Swift. Requires Swift 6.4 or
later and, on Apple platforms, OS 27; there is no back-deployment, because the package
tracks current Swift systems-programming features. The current release is `0.3.0`
(readers only); see [CHANGELOG.md](CHANGELOG.md).

New to Cap'n Proto, or coming from Protocol Buffers? The DocC documentation has a **Why
Cap'n Proto** article and a **Getting Started** tutorial, including what changes on an
Embedded target. Build it with `swift package generate-documentation` or Xcode's
Product ▸ Build Documentation.

## Status at a glance

| Area | State |
|---|---|
| Reading messages — structs, lists, unions, groups, text/data, schema evolution, unpacked and packed framing | ✅ Implemented, conformance-tested against the C++ reference implementation |
| Code generation — `capnpc-swift` plugin binary and the SwiftPM build-tool plugin | ✅ Implemented and verified from a separate consumer package |
| Embedded Swift / allocation-free runtime | ✅ `-no-allocations` compile, allocator-symbol audit and negative control; zero `unsafe` expressions under strict memory safety |
| macOS and Linux (glibc) hosts | ✅ In CI: 48 runtime tests (97.5% line coverage), C++ oracle conformance, 25 compile-fail fixtures, output-boundary hardening |
| ARMv7E-M bare metal (Cortex-M4) | 🟡 Links against `ci/firmware/stubs.c` only (`7,006 B` flash on 6.4.2), and a full reader image runs under QEMU with host-identical results. Firmware on a Cortex-M4F or M7 must enable the FPU first. Not yet run on hardware |
| RISC-V 32-bit bare metal (`rv32imac`, ESP32-C6) | 🟡 Links against `ci/firmware/stubs.c` only (`8,836 B` flash on 6.4.2), and a full reader image runs under QEMU with host-identical results. Not yet run on hardware |
| WebAssembly / WASI | ✅ Full and Embedded Swift run every oracle message (aligned, unaligned and packed) and the 32-bit edge checks under WasmKit |
| Static Linux (musl) | 🟡 Verified locally on 6.4.2 (`aarch64` native, `x86_64` under Rosetta); not yet on native `x86_64` hardware |
| Embedded builds with full debug info (`-g`) | 🟡 Swift 6.4.0–6.4.2 need `-gline-tables-only`; fixed on `main` (see *Embedded debug info*) |
| Writing messages (builders) | ⬜ Designed for v2 (one caller buffer, exclusive builder views); not implemented |
| RPC / capabilities | ⬜ Out of scope |
| Tagged release | ✅ `0.3.0`, see [CHANGELOG.md](CHANGELOG.md) |

✅ verified, with evidence in CI or below &nbsp;·&nbsp; 🟡 partly verified, gap named
&nbsp;·&nbsp; ⬜ not done. *Supported scope* and *Platform evidence* below give the detail
behind each row.

## Generate readers with the SwiftPM plugin

Install the upstream `capnp` compiler (`brew install capnp`, or your platform's
package). Then depend on this package and attach the build-tool plugin to any target
holding `.capnp` schemas. While the version is `0.x`, a minor release may break source
compatibility, so pin to the minor version:

```swift
dependencies: [
    .package(url: "https://github.com/hooman/capnproto-swift", .upToNextMinor(from: "0.3.0"))
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

A build-tool plugin can't add settings to its target, so **every target that uses the
readers must enable the `Lifetimes` experimental feature and depend on `CapnpRuntime`**
itself.

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
concatenated messages.

Packed messages are unpacked one frame at a time into storage you provide, then read as
usual. The runtime still does not allocate: an Embedded target can unpack into a static
or stack `InlineArray`.

```swift
func readPackedID(_ packed: [UInt8]) -> UInt64? {
    var storage = InlineArray<512, UInt64>(repeating: 0)  // 4 KiB of output
    var words = storage.mutableSpan
    var output = words.mutableBytes
    guard let (consumed, written) = Packed.unpackFrame(packed.span.bytes, into: &output)
    else { return nil }  // malformed, truncated, over the limits, or too large for 4 KiB
    _ = consumed  // the next packed frame, if any, starts here
    let arena = Arena(framedBytes: output.bytes.extracting(0..<written))
    let id = arena.withRoot { Capnp_9eb32e19f86f3a01.ExampleReader($0).child.id }
    let error = arena.error
    return error == .none ? id : nil
}
```

`Packed.unpackedFrameByteCount` walks the same frame without writing, to size the
output first. Both reject a frame whose total segment size exceeds
`ReaderOptions.traversalLimitWords` or whose segment count exceeds `segmentLimit`, before
walking its body, so a few packed bytes cannot make the unpacker write more than you
allowed. Zero and literal runs may cross the segment table and segment boundaries, but
not the end of the frame.

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

Scalar and enum constants become computed static properties of the file namespace or the
enclosing struct's reader: `const answer :Int32 = 42;` is
`public static var answer: Int32 { Int32(42) }`, and an enum constant returns its case.
Float constants are written by bit pattern, so NaN, infinities and `-0.0` are exact.

## Supported scope

- Standard framing, unpacked or packed (`Packed.unpackFrame` into caller storage),
  multiple segments, single- and double-far pointers.
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
- Scalar and enum constants, at file scope and nested in structs.
- One Embedded-clean generated API for host and embedded use.

The generator diagnoses, in the files it generates:

- interfaces, generics, AnyPointer, and non-empty pointer defaults
- text, data, struct, list and AnyPointer constants
- enums Swift can't represent: one without enumerants, or one named `Void`, `Swift`,
  `CapnpRuntime`, `Type`, `Protocol` or a scalar type such as `UInt16`, which would shadow
  names the generated code uses
- two generated types with the same Swift name in one scope (struct `E` and enum `EReader`)

An unused interface in an imported file doesn't block generation.

Not provided: builders, RPC, a streaming packed decoder, a public async API, or a
`Sendable` arena. Apple targets require OS 27 (macOS, iOS, watchOS, tvOS, visionOS), where
SE-0525's safe `RawSpan` loads are available; non-Apple targets have no OS gate.

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
python3 ci/check-qemu.py --swiftc /path/to/swiftc --readers-work /tmp/readers
python3 ci/check-static-linux.py --swiftc /path/to/swiftc --readers-work /tmp/readers \
  --sdk-id swift-6.4.2-RELEASE_static-linux-0.1.0
```

Use a Swift.org toolchain that includes the Embedded standard library. `SDKROOT` can
select a compatible Apple SDK for older compilers. Cross-OS checks accept `--stdlib`
pointing to the **same compiler version's** Embedded modules from the target OS toolchain.

Together these cover host tests, the C++ oracle messages, compile-fail contracts
(lifetimes, arena noncopyability, non-`Sendable`, strict memory safety) and watchlist
tripwires, generated readers across a module boundary, allocator-symbol audits, an
allocating negative control, and execution on emulated 32-bit targets. Emulation doesn't
replace execution on physical hardware. Formatting follows the committed `.swift-format`
(`swift format --in-place --recursive …`); CI lints it.

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
| macOS host | 48 runtime tests (97.5% line coverage on 6.4.2), generator + output-boundary hardening, C++ fixtures, 25 compile-fail fixtures, Embedded object checks | iOS/watchOS/tvOS/visionOS device execution |
| Linux x86-64 (glibc) | Host execution, strict `swift format` lint, and Embedded object checks in CI | Additional architectures and distributions |
| ARMv7E-M bare metal | Runtime and generated-reader compilation, symbol audit, and negative control; firmware image links against `ci/firmware/stubs.c` only (`7,006 B` flash / `13,244 B` ELF on 6.4.2; `6,451 B` flash / `11,816 B` ELF on `main-2026-11-01`, including the packed unpacker; `5,358 B` / `4,955 B` flash without it, with PAL `_swift_deallocate` negative-control rejection, zero atomic stubs). **Executed under QEMU** (`ci/check-qemu.py`, Cortex-M4 on `mps2-an386`, in CI): a `-no-allocations` image of the runtime, generated readers and shared assertions (`16,032 B` flash on 6.4.2, `15,649 B` on `main-2026-11-01`; peak stack `3,780 B` reading unpacked messages, `12,072 B` with the driver's 8 KiB packed-output buffer on the stack) runs the same inputs as Wasm with host-identical checksums, and two negative controls trap to the fault handler. The runtime and generated readers use VFP registers, so the startup enables the Cortex-M4F FPU; without it the first `Float` read faults (NOCP) | Physical hardware execution; cores without an FPU (Cortex-M3, M4 without F) |
| RISC-V 32-bit bare metal (`rv32imac`) | Runtime and generated-reader compilation, symbol audit, and negative control; firmware image links against `ci/firmware/stubs.c` only (`8,836 B` flash / `17,864 B` ELF on 6.4.2; `8,239 B` flash / `23,492 B` ELF on `main-2026-11-01`, including the packed unpacker; `6,798 B` / `6,395 B` flash without it, zero atomic stubs). **Executed under QEMU** (`ci/check-qemu.py`, `rv32imac` on `virt`, in CI): the same image and inputs as ARMv7E-M (`18,998 B` flash on 6.4.2, `18,855 B` on `main-2026-11-01`; peak stack `3,908 B` unpacked, `12,164 B` packed) | Real hardware (e.g. ESP32-C6) execution |
| Static Linux SDK (musl) | Verified locally with Swift 6.4.2 (`swift-6.4.2-RELEASE_static-linux-0.1.0`, musl 1.2.5): `aarch64` and `x86_64` statically linked ELF executables (`INTERP`/`DYNAMIC`/`NEEDED` absent) run all 9 C++ oracle messages + wrong-mode negative control in `FROM scratch` Linux containers (`aarch64` native arm64 Linux, `x86_64` Rosetta-emulated on Apple Silicon); SwiftPM `--swift-sdk` builds `CapnpRuntime` cleanly (SDK ships no `Testing` module). Full-Swift static binaries allocate; this is separate from `-no-allocations` | Native `x86_64` Linux hardware execution |
| WebAssembly / WASI | Full and Embedded builds run all 9 aligned + 2 unaligned (`+1`/`+3` byte shifted) C++ oracle messages and the same 9 packed, plus 8 32-bit edge checks (single/double-far `Int32.max` overflow guards, `signedOffsetWords` overflow, `Atomic<UInt>` budget clamping, amplification, unaligned `UTF8Span`, malformed frame/UTF-8) and 5 packed ones (hostile segment tables past a 32-bit `Int`, amplification bounded by the output, a segment-crossing run) under WasmKit (CI and local) and wasmtime (local) with host-identical results. Embedded allocation freedom by call-graph analysis with a negative control; `-no-allocations` itself is unusable on this SDK because its concurrency scaffolding allocates | Browser/JS hosts |

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

## More

Unsupported features listed above are deliberate scope limits, not silent stubs.
[ARCHITECTURE.md](ARCHITECTURE.md) describes the storage, lifetime and validation model.
Licensed under [MIT](LICENSE).
