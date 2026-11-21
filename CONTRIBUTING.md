# Contributing to capnproto-swift

Thank you for your interest in contributing to `capnproto-swift`.

## Prerequisites

- **Swift 6.4+** from [swift.org](https://www.swift.org/install/) (a Swift.org toolchain
  is required for Embedded Swift checks; Xcode's bundled toolchain does not ship the
  Embedded standard library).
- **Apple OS 27 SDK** on macOS (non-Apple targets have no OS gate).
- **`capnp`** compiler (`brew install capnp` or your platform's package manager) for
  end-to-end generator and C++ wire-oracle tests.
- **Python 3** for verification scripts under `ci/`.

## Core Constraints

Before opening a PR, keep these project invariants in mind (see
[ARCHITECTURE.md](ARCHITECTURE.md) for details):

- **Zero heap allocations in `CapnpRuntime`:** all runtime changes must pass Embedded
  compilation under `-no-allocations`, the allocator symbol audit, and the allocating
  negative control.
- **Zero `unsafe` in `Sources/CapnpRuntime/` and `Sources/capnpc-swift/`:** both targets
  build with `-strict-memory-safety -warnings-as-errors`.
- **Single Embedded-clean generated API:** no `Foundation`, existential dispatch, or
  mutable message storage in `CapnpRuntime` or generated readers.
- **Scope:** v1 is readers-only, synchronous, and non-`Sendable` (`~Sendable`). Discuss
  scope changes in an issue before implementing.

## Local Verification

Run formatting and tests before submitting a pull request:

```sh
# Formatting (must pass strictly)
swift format --in-place --recursive Package.swift Sources Tests Plugins ci
swift format lint --strict --recursive Package.swift Sources Tests Plugins ci

# Host unit tests
swift test

# Embedded-clean gate (requires Swift.org toolchain)
SWIFTC=/path/to/swift.org/usr/bin/swiftc ci/check-embedded-clean.sh

# C++ wire oracle, compile-fail contracts, output-boundary hardening, and Embedded module boundary
python3 ci/check-readers.py --swiftc /path/to/swiftc --capnp /path/to/capnp \
  --plugin .build/debug/capnpc-swift --work /tmp/readers

# ARMv7E-M cross-compile and bare-metal link gate
python3 ci/check-cross.py --swiftc /path/to/swiftc \
  --target armv7em-none-none-eabi --generated /tmp/readers/readers.capnp.swift
SWIFTC=/path/to/swift.org/usr/bin/swiftc ci/check-link.sh

# DocC catalog build
swift package generate-documentation --target CapnpRuntime
```

## Pull Requests

- Keep PRs focused and include tests for new behavior or bug fixes.
- Update [README.md](README.md), [ARCHITECTURE.md](ARCHITECTURE.md), and DocC comments
  when changing public behavior or supported-target evidence.
- Only claim platform support that has been verified with automated positive and negative
  controls.
