# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). While the version is `0.x`, a minor release
may contain breaking changes; pin with `.upToNextMinor(from:)`.

Releases are cut by the `release` workflow, which requires an entry here headed
`## [X.Y.Z] - YYYY-MM-DD`.

## [Unreleased]

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
