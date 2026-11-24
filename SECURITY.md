# Security Policy

## Scope

`capnproto-swift` contains two distinct security boundaries:

1. **`CapnpRuntime` (untrusted wire input):** parses untrusted binary Cap'n Proto messages
   over caller-provided borrowed storage without heap allocation. Validation is lazy:
   malformed pointers, bounds overruns, invalid UTF-8, invalid list indexes, and exhausted
   traversal/nesting budgets return empty/default values and record the first failure in
   `Arena.error`. Callers **must** check `Arena.error` after traversal before trusting
   decoded values.
2. **`capnpc-swift` (host build-time compiler plugin):** decodes a bounded (64 MiB)
   `CodeGeneratorRequest` from stdin, validates relative output paths (resolving existing
   parent symlinks and rejecting symlink/directory targets), and writes generated Swift
   files under the output directory. Path validation assumes the output directory is not
   concurrently mutated during compilation.

## Supported Versions

Security fixes land on `main` and ship in a new patch release of the latest minor version
(currently `0.2.x`). Earlier minor versions are not maintained while the version is `0.x`.

## Reporting a Vulnerability

Please **do not** open a public GitHub issue for suspected security vulnerabilities
(such as out-of-bounds reads, integer overflows, amplification/DoS bypasses in
`CapnpRuntime`, or output-directory escape bugs in `capnpc-swift`).

Instead, report vulnerabilities privately through **GitHub Security Advisories**
("Report a vulnerability" under the repository's **Security** tab), including:

- Affected component (`CapnpRuntime`, `capnpc-swift`, or `CapnpGeneratorPlugin`)
- Commit SHA and Swift toolchain/target
- Minimal reproduction input (e.g. hex bytes or schema) and observed vs. expected behavior

We will acknowledge reports and coordinate a fix and disclosure timeline.
