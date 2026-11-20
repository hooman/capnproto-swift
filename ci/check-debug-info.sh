#!/usr/bin/env bash
# Compile CapnpRuntime as an Embedded consumer would, with debug info. SwiftPM passes
# -g on every build, so a debug-info crash blocks every Embedded package consumer.
#
# Swift 6.4.0 and main (checked through the 2026-10-12 nightly) crash in IRGenDebugInfo
# on the Builtin borrow type behind Ref<T> when Embedded and full -g are combined
# (session-starters/probe4-embedded-pal-feedback.md in the workspace). Line tables avoid
# it, so -gline-tables-only must pass. Full -g must either pass or fail with that exact
# crash; any other failure is a regression. When -g passes, the known crash is fixed in
# this toolchain: make full -g required and drop the README workaround.
set -euo pipefail

SWIFTC="${SWIFTC:-$HOME/Library/Developer/Toolchains/swift-6.4.0-RELEASE.xctoolchain/usr/bin/swiftc}"
TARGET="${TARGET:-arm64-apple-macos27}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
KNOWN_CRASH="Don't know how to emit debug info for type"

SRCS=()
while IFS= read -r f; do SRCS+=("$f"); done < <(find "$ROOT/Sources/CapnpRuntime" -name '*.swift' -not -path '*.docc/*' | sort)
SRCS+=("$ROOT/ci/runtime-entry.swift")
FLAGS=( -swift-version 6
        -enable-experimental-feature Embedded
        -enable-experimental-feature Lifetimes
        -wmo -strict-memory-safety
        -target "$TARGET"
        -module-cache-path "$WORK/cache"
        -parse-as-library )

echo "swiftc: $SWIFTC"
echo "target: $TARGET"
for opt in -Onone -O; do
    "$SWIFTC" "${FLAGS[@]}" "$opt" -gline-tables-only -c "${SRCS[@]}" -o "$WORK/lines.o"
    echo "PASS: Embedded $opt -gline-tables-only"
    if "$SWIFTC" "${FLAGS[@]}" "$opt" -g -c "${SRCS[@]}" -o "$WORK/full.o" 2> "$WORK/full.err"; then
        echo "NOTICE: Embedded $opt -g compiles; the known debug-info crash is fixed in this toolchain."
        echo "::notice title=Embedded -g fixed::Make full -g required in ci/check-debug-info.sh and drop the README workaround."
    elif grep -q "$KNOWN_CRASH" "$WORK/full.err"; then
        echo "KNOWN: Embedded $opt -g hits the upstream debug-info crash (expected until fixed)."
    else
        echo "FAIL: Embedded $opt -g failed for an unexpected reason:" >&2
        head -20 "$WORK/full.err" >&2
        exit 1
    fi
done
echo "DEBUG-INFO CHECK: PASS"
