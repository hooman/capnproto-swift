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

## Sign Your Work (DCO)

Every commit in a pull request must be signed off under the
[Developer Certificate of Origin 1.1](https://developercertificate.org/). The sign-off
certifies that you wrote the change, or otherwise have the right to submit it under this
project's MIT license. Sign off with `git commit -s`, which adds:

```text
Signed-off-by: Your Name <you@example.com>
```

The email must match the commit author. The required `DCO` check enforces this. To sign
off commits you already made, run `git rebase --signoff origin/main` and force-push your
branch. There is no CLA.

## AI-Assisted Contributions

AI coding assistants are welcome here. The maintainer uses them too: maintainer commits
written with an agent carry a `Co-Authored-By:` trailer naming the model. The rules:

- **A human is responsible for every PR.** You must have read and understood every line
  you submit, and be able to explain and defend it in review. Unreviewed agent output
  will be closed.
- **The sign-off is yours.** Only a person can certify the DCO. Never add a
  `Signed-off-by:` for an AI tool, and do not let an agent sign off for you on code you
  have not reviewed.
- **Disclose material assistance.** Say in the PR description which parts an AI tool wrote
  or substantially shaped. A `Co-Authored-By:` or `Assisted-by:` trailer is welcome. You
  don't need to mention autocomplete-level help.
- **The same bar applies.** AI-written code passes the same gates (`-no-allocations`, zero
  `unsafe`, compile-fail contracts, tests) and gets the same review. Generated tests must
  test real behavior, not mirror the implementation.
- **Mind provenance.** Do not submit output you have reason to believe reproduces code
  under an incompatible license.

## Pull Requests

- Keep PRs focused and include tests for new behavior or bug fixes.
- Update [README.md](README.md), [ARCHITECTURE.md](ARCHITECTURE.md), and DocC comments
  when changing public behavior or supported-target evidence.
- Only claim platform support that has been verified with automated positive and negative
  controls.

## Changelog and releases

- Add a line under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md) for any user-visible
  change.
- Maintainers cut releases with the `release` workflow
  (`gh workflow run release.yml -f version=X.Y.Z`) after renaming `[Unreleased]` to
  `## [X.Y.Z] - YYYY-MM-DD`. The workflow runs the full CI gates on that commit, creates the
  tag and GitHub Release, and attaches a source archive with a build-provenance attestation
  (`gh attestation verify capnproto-swift-X.Y.Z.tar.gz -R hooman/capnproto-swift`).
  Release tags are immutable; fix a bad release with a new patch release.
