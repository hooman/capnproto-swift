#!/usr/bin/env bash
# Compile an exported runtime call graph under Embedded + -no-allocations, audit its
# object, and require an allocating negative control to fail. All three checks matter:
# synthesized coroutine allocations can escape the compiler diagnostic, while a
# negative control catches a disabled or ineffective no-allocation check.
# Match specific allocator symbols: generic "alloc" searches also match harmless
# Embedded support symbols such as _swift_allocEmptyBox and _swift_setDeallocating.
#
# Requires a toolchain with lib/swift/embedded. Set SWIFTC and TARGET to select it;
# all intermediate files are temporary. The cross-target/generated-reader companion
# is ci/check-cross.py.
set -euo pipefail

SWIFTC="${SWIFTC:-$HOME/Library/Developer/Toolchains/swift-6.4.0-RELEASE.xctoolchain/usr/bin/swiftc}"
TARGET="${TARGET:-arm64-apple-macos27}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRCDIR="$ROOT/Sources/CapnpRuntime"
NEGCTL="$ROOT/ci/negative-control.swift"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FLAGS=( -swift-version 6
        -enable-experimental-feature Embedded
        -enable-experimental-feature Lifetimes
        -wmo -no-allocations
        -strict-memory-safety -warnings-as-errors
        -target "$TARGET"
        -module-cache-path "$WORK/cache"
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
# Exclude *.docc: SwiftPM itself treats any such directory as a documentation catalog,
# not a source directory, and this project's catalog carries standalone tutorial code
# snapshots (intentionally not part of the CapnpRuntime module) that would otherwise
# leak into this gate's naive filesystem glob.
while IFS= read -r f; do SRCS+=("$f"); done < <(find "$SRCDIR" -name '*.swift' -not -path '*.docc/*' | sort)
if [ "${#SRCS[@]}" -eq 0 ]; then echo "FAIL: no sources under $SRCDIR" >&2; exit 2; fi
SRCS+=("$ROOT/ci/runtime-entry.swift")
printf '  source: %s\n' "${SRCS[@]#"$ROOT"/}"
"$SWIFTC" "${FLAGS[@]}" -c "${SRCS[@]}" -o "$WORK/CapnpRuntime-embedded.o"
echo "  PASS — compiled clean under Embedded + -no-allocations."

echo
echo "== [2/3] nm audit (secondary): assert no real allocator symbols =="
ALLOCATORS="$(grep -v '^#' "$ROOT/ci/allocator-symbols.txt" | paste -sd '|' -)"
if nm "$WORK/CapnpRuntime-embedded.o" | grep -E "(^| )_?(${ALLOCATORS})\$"; then
  echo "  FAIL — real allocator symbols present (above)." >&2
  exit 1
fi
echo "  PASS — no heap allocator or coroutine allocator symbols."

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
