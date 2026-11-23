# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). While the version is `0.x`, a minor release
may contain breaking changes; pin with `.upToNextMinor(from:)`.

Releases are cut by the `release` workflow, which requires an entry here headed
`## [X.Y.Z] - YYYY-MM-DD`.

## [Unreleased]

### Added

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

- `capnpc-swift` failed with `invalid CodeGeneratorRequest: typeMismatch` on a non-empty
  list default whose element type is unsupported, such as `List(MyEnum) = [a, b]`. It now
  reports the unsupported default.

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
