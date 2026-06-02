#!/usr/bin/env bash
# check-embedded-clean.sh — the Embedded-clean gate for CapnpRuntime (INVARIANT 2).
#
# Compiles CapnpRuntime under Embedded + -no-allocations on the host Apple triple.
# The COMPILE PASS is the authoritative gate: any reachable heap allocation is a
# compile error (compiler-enforced, stronger than reading symbols). Two backups:
#   * nm audit (secondary): assert SPECIFIC allocator symbols are absent. Never a
#     generic "alloc" grep — a clean object still defines _swift_allocEmptyBox /
#     _swift_setDeallocating (embedded-runtime support), so "nm | grep alloc" would
#     false-positive on a clean build (R1 finding I5).
#   * negative control: ci/negative-control.swift (a heap allocation) MUST be
#     rejected, so the gate can never silently pass vacuously (e.g. a flag silently
#     ignored). It lives under ci/, never Sources/, so it is never linked.
#
# Requires a Swift.org toolchain that ships the embedded stdlib — the Xcode/Command
# Line Tools Swift does NOT (no usr/lib/swift/embedded), so point SWIFTC at a
# download.swift.org toolchain (R1 findings I6/I13).
#
# Usage:   ci/check-embedded-clean.sh
# Env:
#   SWIFTC   swiftc to use (default: 6.3.1 Swift.org toolchain)
#   TARGET   target triple (default: arm64-apple-macos15)
set -euo pipefail

SWIFTC="${SWIFTC:-$HOME/Library/Developer/Toolchains/swift-6.3.1-RELEASE.xctoolchain/usr/bin/swiftc}"
TARGET="${TARGET:-arm64-apple-macos15}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRCDIR="$ROOT/Sources/CapnpRuntime"
NEGCTL="$ROOT/ci/negative-control.swift"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FLAGS=( -enable-experimental-feature Embedded
        -enable-experimental-feature Lifetimes
        -wmo -no-allocations
        -target "$TARGET"
        -parse-as-library )

echo "== toolchain =="
"$SWIFTC" --version
echo "swiftc:  $SWIFTC"
echo "target:  $TARGET"

EMB_STDLIB="$(dirname "$SWIFTC")/../lib/swift/embedded"
if [ ! -d "$EMB_STDLIB" ]; then
  echo "FAIL: toolchain has no embedded stdlib at $EMB_STDLIB" >&2
  echo "      Use a download.swift.org toolchain, not Xcode/Command Line Tools." >&2
  exit 2
fi

echo
echo "== [1/3] primary gate: compile CapnpRuntime under -no-allocations (must pass) =="
SRCS=()
while IFS= read -r f; do SRCS+=("$f"); done < <(find "$SRCDIR" -name '*.swift' | sort)
if [ "${#SRCS[@]}" -eq 0 ]; then echo "FAIL: no sources under $SRCDIR" >&2; exit 2; fi
printf '  source: %s\n' "${SRCS[@]#"$ROOT"/}"
"$SWIFTC" "${FLAGS[@]}" -c "${SRCS[@]}" -o "$WORK/CapnpRuntime-embedded.o"
echo "  PASS — compiled clean under Embedded + -no-allocations."

echo
echo "== [2/3] nm audit (secondary): assert no real allocator symbols =="
if nm "$WORK/CapnpRuntime-embedded.o" \
     | grep -E '(^| )_(free|posix_memalign|swift_allocObject|swift_slowAlloc)$'; then
  echo "  FAIL — real allocator symbols present (above)." >&2
  exit 1
fi
echo "  PASS — no _free / _posix_memalign / _swift_allocObject / _swift_slowAlloc."

echo
echo "== [3/3] negative control: ci/negative-control.swift MUST be rejected (gate has teeth) =="
if [ ! -f "$NEGCTL" ]; then echo "FAIL: missing negative control $NEGCTL" >&2; exit 2; fi
if "$SWIFTC" "${FLAGS[@]}" -c "$NEGCTL" -o "$WORK/neg.o" 2>"$WORK/neg.err"; then
  echo "  FAIL — negative control COMPILED; the gate is vacuous (not diagnosing allocation)." >&2
  exit 1
fi
# Confirm it failed for the RIGHT reason (allocation diagnostic), robustly across
# toolchain wording: the -no-allocations error text always contains "alloc".
if ! grep -Eqi 'alloc' "$WORK/neg.err"; then
  echo "  FAIL — negative control failed for the wrong reason:" >&2
  sed 's/^/    /' "$WORK/neg.err" >&2
  exit 1
fi
echo "  PASS — allocation rejected: $(grep -Ei 'alloc' "$WORK/neg.err" | head -1 | sed -E 's/^ *//')"

echo
echo "EMBEDDED-CLEAN GATE: PASS"
