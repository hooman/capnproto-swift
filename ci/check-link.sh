#!/usr/bin/env bash
# Link a bare-metal reader image: CapnpRuntime + the exported entry + a tiny main, built
# under Embedded + -no-allocations, linked by ld.lld against ci/firmware/stubs.c only (no
# libc, no allocator). A successful link proves the complete platform surface the
# reader needs; the image is then audited for allocator symbols. The allocating
# negative control, built without -no-allocations, must FAIL to link: that is what gives
# the link step teeth. This links only; it does not execute on hardware.
#
# -function-sections lets --gc-sections drop unused runtime helpers that newer main
# snapshots emit into every Embedded object (swift_intToFloat32/64 and their soft-float
# calls), which would otherwise demand floating-point builtins the reader never uses.
set -euo pipefail

SWIFTC="${SWIFTC:-$HOME/Library/Developer/Toolchains/swift-6.4.0-RELEASE.xctoolchain/usr/bin/swiftc}"
TARGET="${TARGET:-armv7em-none-none-eabi}"
BIN="$(dirname "$SWIFTC")"
CLANG="${CLANG:-$BIN/clang}"
LLD="${LLD:-$BIN/ld.lld}"
NM="${NM:-$BIN/llvm-nm}"
OBJDUMP="${OBJDUMP:-$BIN/llvm-objdump}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SRCS=()
while IFS= read -r f; do SRCS+=("$f"); done < <(find "$ROOT/Sources/CapnpRuntime" -name '*.swift' -not -path '*.docc/*' | sort)
FLAGS=( -swift-version 6
        -enable-experimental-feature Embedded
        -enable-experimental-feature Lifetimes
        -enable-experimental-feature Extern
        -wmo -Osize -strict-memory-safety
        -Xfrontend -function-sections
        -target "$TARGET"
        -module-cache-path "$WORK/cache" )

echo "swiftc: $SWIFTC"
echo "target: $TARGET"
"$CLANG" -target "$TARGET" -mthumb -mfloat-abi=soft -ffreestanding -Os \
    -c "$ROOT/ci/firmware/stubs.c" -o "$WORK/stubs.o"

"$SWIFTC" "${FLAGS[@]}" -no-allocations -module-name firmware -c "${SRCS[@]}" \
    "$ROOT/ci/runtime-entry.swift" "$ROOT/ci/firmware/main.swift" -o "$WORK/firmware.o"
"$LLD" -e _start --gc-sections "$WORK/firmware.o" "$WORK/stubs.o" -o "$WORK/firmware.elf"
FLASH_SUMMARY="$("$OBJDUMP" -h "$WORK/firmware.elf" | python3 -c '
import re, sys
secs = {}
for line in sys.stdin:
    m = re.match(r"\s*\d+\s+(\.\S+)\s+([0-9a-fA-F]+)\s+", line)
    if m:
        secs[m.group(1)] = int(m.group(2), 16)
flash = sum(secs.get(s, 0) for s in (".text", ".rodata", ".ARM.exidx", ".data", ".got"))
txt, ro = secs.get(".text", 0), secs.get(".rodata", 0)
print(f"flash={flash} B (.text={txt} B, .rodata={ro} B)")
')"
echo "PASS: linked $(wc -c < "$WORK/firmware.elf" | tr -d ' ')-byte ELF (${FLASH_SUMMARY}) against stubs.c only"

ALLOCATORS="$(grep -v '^#' "$ROOT/ci/allocator-symbols.txt" | paste -sd '|' -)"
if "$NM" "$WORK/firmware.elf" | grep -E "(^| )_?(${ALLOCATORS})\$"; then
    echo "FAIL: allocator symbols in the linked image (above)." >&2
    exit 1
fi
echo "PASS: no allocator symbols in the linked image"

# -Onone: at -Osize the optimizer deletes the fixture's dead allocation and it links.
"$SWIFTC" "${FLAGS[@]}" -Onone -module-name negative -c "$ROOT/ci/negative-control.swift" \
    "$ROOT/ci/firmware/negative/main.swift" -o "$WORK/negative.o"
if "$LLD" -e _start --gc-sections "$WORK/negative.o" "$WORK/stubs.o" -o "$WORK/negative.elf" 2> "$WORK/negative.err"; then
    echo "FAIL: the allocating negative control linked; the link step proves nothing." >&2
    exit 1
fi
if ! grep -Eq "undefined symbol: _?(${ALLOCATORS})\$" "$WORK/negative.err"; then
    echo "FAIL: negative control failed to link, but not on an allocator:" >&2
    cat "$WORK/negative.err" >&2
    exit 1
fi
echo "PASS: negative control rejected at link: $(grep -Eo "undefined symbol: _?(${ALLOCATORS})\$" "$WORK/negative.err" | head -1)"
echo "LINK CHECK: PASS"
