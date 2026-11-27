# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). While the version is `0.x`, a minor release
may contain breaking changes; pin with `.upToNextMinor(from:)`.

Releases are cut by the `release` workflow, which requires an entry here headed
`## [X.Y.Z] - YYYY-MM-DD`.

## [Unreleased]

### Added

- `CapnpRuntime` builds messages: the runtime core of v2 builders (D-18).
  `MessageBuilder(storage:)` writes one single-segment framed message into a caller
  `MutableRawSpan` without allocating; `initRoot(dataWords:pointerCount:)` and
  `StructBuilder.initStruct(at:dataWords:pointerCount:)` return exclusive views, and
  `setData(_:at:default:)`, `data(at:default:)` and `clearPointer(at:)` write and read
  fields. Errors are sticky (`BuildError`) and never trap; `requiredByteCount` is the exact
  size to retry with after `.outOfSpace`. `framedBytes` opens directly in `Arena`. A
  message uses at most 4 GiB of storage, so every pointer offset fits its field.
- `capnpc-swift` generates a builder beside each struct's reader (`ExampleBuilder` beside
  `ExampleReader`) for scalars, enums, nested structs, groups and unions:
  `message.initRoot(ExampleBuilder.self)`, then `setFoo(_:)`, `foo()`, `initFoo()` and
  `clearFoo()`. Setting a union member zeroes the previous member's storage. Builders are
  checked against the C++ encoder (`capnp encode`) in canonical form. Existing generated
  reader code is
  unchanged; generated files grow by the builder code, which the linker strips when unused
  (about 80 bytes of flash remain in a reader-only Cortex-M4 image).
- `CapnpRuntime` adds `CapnpStructBuilder` (generated-code only, like `CapnpStructReader`),
  `MessageBuilder.initRoot(_:)` and `StructBuilder.reborrow()`.
- Text, data and lists can be built. Generated builders get `setFoo(_: UTF8Span)` for text,
  `setFoo(_: Span<UInt8>)` for data and `initFoo(count:)` for lists, each with `clearFoo()`.
  `CapnpRuntime` adds `StructBuilder.setText(_:at:)`, `setBytes(_:at:)` and
  `initList(_:at:count:)`, and the typed list builders `PrimitiveListBuilder`,
  `EnumListBuilder`, `VoidListBuilder`, `TextListBuilder`, `DataListBuilder`,
  `StructListBuilder` and `ListListBuilder` (`CapnpListBuilder`, generated-code only). More
  than 2^29 − 1 elements is `.listTooLong`, and a struct list whose element sizes are
  outside 0...65535 is `.invalidLayout`. A list view that fails for lack of space keeps
  its count, so `requiredByteCount` still counts what a loop over `count` writes. Swift builders rebuild every C++ oracle message
  of the test suite byte-equivalently.
- `CapnpPrimitive` gains `storeMasked(_:into:atBitOffset:default:)`. The protocol stays
  closed to outside conformances.

## [0.3.0] - 2026-11-26

Packed framing: the runtime now reads packed messages, one frame at a time into storage
the caller provides, without allocating. The generator is unchanged. The readers now also
run on emulated 32-bit bare metal in CI.

### Added

- `CapnpRuntime` reads packed messages. `Packed.unpackFrame(_:into:options:)` unpacks
  exactly one packed frame into a caller-provided `MutableRawSpan` and returns the packed
  bytes consumed and the bytes written; open `Arena(framedBytes:)` over the written
  prefix. `Packed.unpackedFrameByteCount(_:options:)` returns the size without writing.
  Neither allocates. A frame whose segment sizes exceed `traversalLimitWords`, whose
  segment count exceeds `segmentLimit`, or that does not fit the output is rejected
  before its body is unpacked.
- Verification: `ci/check-qemu.py` boots a `-no-allocations` image of the runtime and
  generated readers on emulated Cortex-M4 (`mps2-an386`) and RV32 (`virt`) under QEMU, in
  CI. It runs every oracle message (aligned, unaligned and packed) and the 32-bit edge
  suites with host-identical results, and two negative controls must fault. Firmware on a
  Cortex-M4F or M7 must enable the FPU before calling the runtime, because Swift's
  `armv7em` code uses it for `Float` and `Double` fields.

### Not yet supported

- Builders (writing messages; designed for v2), RPC and interfaces, generics, AnyPointer,
  text, data, struct, list and AnyPointer constants, non-empty pointer defaults, and
  streaming packed decoding.

## [0.2.0] - 2026-11-23

Readers-only schema completeness: the generator now accepts annotations, doc comments,
enums, and scalar and enum constants. The runtime still only reads.

### Added

- `capnpc-swift` generates scalar and enum constants as computed static properties of the
  file namespace or the enclosing struct's reader, for example
  `public static var answer: Int32 { Int32(42) }`. Float constants keep their exact bit
  pattern. Text, data, struct, list and AnyPointer constants are still diagnosed.
- `capnpc-swift` generates Swift enums for Cap'n Proto enums:
  `public enum Name: UInt16, CapnpRuntime.CapnpEnum`. Enum fields, including defaults and
  fields in unions and groups, return `Name?`, where `nil` means an ordinal this schema
  version does not know. `_capnpRaw_<field>` returns the ordinal itself. Enum doc comments
  carry over, enumerants included.
- `CapnpRuntime` adds `CapnpEnum`, the constraint generated enums conform to (not an
  extension point), and `EnumList<Element>` for `List(SomeEnum)`, with an optional subscript
  and `raw(at:)`. `List(List(SomeEnum))` is `CapnpList<EnumList<SomeEnum>>`.
- `capnpc-swift` carries schema doc comments (`CodeGeneratorRequest.sourceInfo`) into
  generated `///` comments on the file namespace, structs, groups and field accessors.
  Comment text cannot escape its comment line: line breaks start a new `///` line, and
  control characters and bidi overrides are removed. Schemas without doc comments
  generate the same output as before.

### Changed

- `capnpc-swift` accepts and ignores annotations. A schema that uses
  `$Cxx.namespace` (from `/capnp/c++.capnp`), or declares or applies its own
  annotations, now generates readers instead of failing with `annotations are outside
  readers-only v1`. Annotation declarations generate no Swift.

### Fixed

- A struct with an enum field was reported as `field offset exceeds struct pointer section`
  instead of an unsupported field type.
- `capnpc-swift` failed with `invalid CodeGeneratorRequest: typeMismatch` on a non-empty
  list default whose element type is unsupported, such as `List(MyEnum) = [a, b]`. It now
  reports the unsupported default.
- `capnpc-swift --version` printed `0.1.0-dev`; it now prints the release version.

### Not yet supported

- Builders (writing messages), RPC and interfaces, generics, AnyPointer, text, data,
  struct, list and AnyPointer constants, non-empty pointer defaults, and packed framing.

## [0.1.0] - 2026-11-21

First public release: readers-only, synchronous v1.

### Added

- `CapnpRuntime`, an allocation-free reader runtime. It compiles under Embedded Swift
  `-no-allocations` and contains zero `unsafe` expressions. `Arena` borrows caller storage
  (`RawSpan`). Readers are `~Escapable` and `~Sendable` and cannot outlive
  `Arena.withRoot`. Reads fail soft: a malformed field returns its schema default and
  records the first error in `Arena.error`.
- Traversal and nesting budgets (`ReaderOptions`), multi-segment framing, and
  single/double-far pointers.
- `TextReader.utf8: UTF8Span` and `DataReader.bytes: Span<UInt8>` views, plus `Iterable`
  iteration on both.
- Generic `CapnpList<Element>`, `PrimitiveList<T>`, and `VoidList` for list fields.
- `capnpc-swift`, a code generator for structs, groups, unions, scalars, text, data, and
  lists. Unsupported nodes, types, and defaults are diagnosed rather than miscompiled.
  The output path handling rejects lexical and symbolic-link escapes and rolls back
  partially written files on failure.
- `CapnpGeneratorPlugin`, a SwiftPM build-tool plugin that regenerates readers
  whenever a `.capnp` schema changes.
- Verification: the C++ reference implementation's oracle messages, a compile-fail
  contract suite (lifetimes, ownership, `Sendable`, memory safety, API tiering), allocator
  symbol audits with negative controls, and Embedded builds for ARMv7E-M, RISC-V 32,
  Wasm32 (executed under WasmKit), and static Linux (musl).

### Requirements

- Swift 6.4 or later; Apple platforms OS 27 or later, with no back-deployment. CI runs
  Swift.org 6.4.0 on macOS and Linux.

### Not yet supported

- Builders (writing messages), RPC, enums, constants, non-empty pointer defaults, and
  packed framing.
