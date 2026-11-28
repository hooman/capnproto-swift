#!/usr/bin/env python3
"""Check CapnpRuntime on WebAssembly/WASI, as full Swift and as Embedded Swift.

1. Allocation gate. -no-allocations cannot be used on the wasm-embedded SDK: the SDK's
   own concurrency scaffolding (CooperativeExecutor) fails it before user code is
   reached. Instead, walk the object's call graph (llvm-objdump relocations) from the
   exported reader entry point and require that no allocator is reachable. The
   allocating negative control must be caught by the same walk. Both compile at
   -Onone, because at higher levels the optimizer deletes the fixture's dead allocation
   and the walk would pass vacuously. This is one rung weaker than -no-allocations:
   indirect calls are seen only through table-index relocations.
2. Execution. Build the shared fixture assertions (ci/fixtures/verify.swift) with
   generated readers into WASI executables, run every C++-encoded message from a
   check-readers.py work directory under each available runner, and require the same
   checksum as the host driver.

Requires a Swift.org toolchain, its matching Wasm SDK bundle, and the --work
directory produced by ci/check-readers.py (generated readers, messages, host driver).
"""
import argparse
import collections
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--swiftc', required=True)
parser.add_argument('--wasm-sdk', required=True,
                    help='SDK target directory containing WASI.sdk and swift.xctoolchain '
                         '(…/swift-6.4.0-RELEASE_wasm/wasm32-unknown-wasip1)')
parser.add_argument('--readers-work', required=True, help='work directory of check-readers.py')
parser.add_argument('--work', default=None)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
work = Path(args.work or tempfile.mkdtemp(prefix='capnp-wasm-')).resolve()
work.mkdir(parents=True, exist_ok=True)
readers = Path(args.readers_work).resolve()
sdk = Path(args.wasm_sdk).resolve()
swiftc = shutil.which(args.swiftc) or args.swiftc
bin_dir = Path(swiftc).resolve().parent
objdump = shutil.which('llvm-objdump', path=str(bin_dir)) or shutil.which('llvm-objdump')
print(f'Artifacts: {work}', flush=True)

allocators = '|'.join(line.strip() for line in (root / 'ci/allocator-symbols.txt').read_text().splitlines()
                      if line.strip() and not line.startswith('#'))
allocator = re.compile(rf'^_?({allocators})$')
sources = sorted((root / 'Sources/CapnpRuntime').glob('*.swift'))
common = [swiftc, '-swift-version', '6', '-enable-experimental-feature', 'Lifetimes',
          '-target', 'wasm32-unknown-wasip1', '-sdk', str(sdk / 'WASI.sdk'),
          '-module-cache-path', str(work / 'cache')]
lib = sdk / 'swift.xctoolchain/usr/lib'
variants = {
    'full': ['-resource-dir', str(lib / 'swift_static'), '-static-stdlib', '-wmo'],
    'embedded': ['-resource-dir', str(lib / 'swift'), '-enable-experimental-feature', 'Embedded',
                 '-wmo', '-Xlinker', '-lc++', '-Xlinker', '-lswift_Concurrency'],
}


def run(command, *, data=None):
    result = subprocess.run([str(x) for x in command], input=data, capture_output=True)
    if result.returncode:
        raise RuntimeError(f'{command}\n{result.stdout.decode()}\n{result.stderr.decode()}')
    return result.stdout.decode()


def reachable_allocators(obj, entry):
    graph = collections.defaultdict(set)
    current = None
    for line in run([objdump, '-dr', obj]).splitlines():
        header = re.match(r'^[0-9a-f]+ <(.+)>:$', line)
        if header:
            current = header.group(1)
            continue
        edge = re.search(r'R_WASM_(?:FUNCTION_INDEX_LEB|TABLE_INDEX\w*)\s+(\S+?)(?:[+-]\d+)?$', line.rstrip())
        if edge and current:
            graph[current].add(edge.group(1))
    assert entry in graph, f'{entry} not found in {obj}'
    seen, stack = set(), [entry]
    while stack:
        name = stack.pop()
        if name not in seen:
            seen.add(name)
            stack.extend(graph.get(name, ()))
    return sorted(name for name in seen if allocator.match(name))


# 1. Allocation gate.
embedded = [*common, *variants['embedded'][:5], '-parse-as-library', '-Onone']
runtime_obj, negative_obj = work / 'gate-runtime.o', work / 'gate-negative.o'
run([*embedded, '-strict-memory-safety', '-module-name', 'CapnpRuntime', '-c', *sources,
     root / 'ci/runtime-entry.swift', '-o', runtime_obj])
run([*embedded, '-module-name', 'negative', '-c', root / 'ci/negative-control.swift', '-o', negative_obj])
for entry in ['capnp_embedded_probe', 'capnp_embedded_packed_probe', 'capnp_embedded_builder_probe']:
    found = reachable_allocators(runtime_obj, entry)
    assert not found, f'allocators reachable from {entry}: {found}'
caught = reachable_allocators(negative_obj, '_negative_control')
assert caught, 'negative control reaches no allocator: the call-graph gate is vacuous'
print(f'PASS wasm-embedded allocation gate: runtime, packed and builder probes reach none; negative control reaches {caught}', flush=True)

# 2. Execution under every available runner.
runners = []
wasmkit = shutil.which('wasmkit', path=str(bin_dir)) or shutil.which('wasmkit')
if wasmkit:
    runners.append(('wasmkit', [wasmkit, 'run']))
if shutil.which('wasmtime'):
    runners.append(('wasmtime', [shutil.which('wasmtime'), 'run']))
assert runners, 'no WASI runner found (wasmkit ships with Swift.org toolchains)'

messages = sorted(readers.glob('message-*.bin'))
assert len(messages) == 9, f'expected 9 messages in {readers}, found {len(messages)}'
expected = {}
for message in messages:
    mode = message.name.split('-')[1]
    host = run([readers / 'host/verify', message, mode])
    expected[message] = re.search(r'checksum=(\d+)', host).group(1)

for name, flags in variants.items():
    out = work / name
    out.mkdir(exist_ok=True)
    build = [*common, *flags, '-O']
    run([*build, '-parse-as-library', '-emit-module', '-emit-object', '-module-name', 'CapnpRuntime',
         '-emit-module-path', out / 'CapnpRuntime.swiftmodule', *sources, '-o', out / 'runtime.o'])
    wasm = out / 'verify.wasm'
    # Link against the SDK's clang runtime (builtins), not the host toolchain's.
    clang_resources = ['-Xclang-linker', '-resource-dir', '-Xclang-linker', str(Path(flags[1]) / 'clang')]
    run([*build, *clang_resources, '-I', out, readers / 'readers.capnp.swift', root / 'ci/fixtures/verify.swift',
         root / 'ci/fixtures/edges32.swift', root / 'ci/fixtures/build32.swift', root / 'ci/fixtures/genbuild32.swift',
         root / 'ci/fixtures/wasi/main.swift', out / 'runtime.o', '-o', wasm])
    for runner, command in runners:
        for message in messages:
            mode = int(message.name.split('-')[1])
            data = bytes([mode, 0]) + bytes(6) + message.read_bytes()
            output = run([*command, wasm], data=data)
            got = re.search(r'checksum=(\d+)', output)
            assert got and got.group(1) == expected[message], f'{name}/{runner}/{message.name}: {output!r}'
            # The same message packed by capnp (committed by the answer key), unpacked on 32-bit.
            packed = root / 'ci/fixtures/packed' / message.name.replace('.bin', '.packed')
            output = run([*command, wasm], data=bytes([mode, 0, 1]) + bytes(5) + packed.read_bytes())
            got = re.search(r'PASS packed .*checksum=(\d+)', output)
            assert got and got.group(1) == expected[message], f'{name}/{runner}/{packed.name}: {output!r}'
        # Unaligned (+1 and +3 byte shifted) execution of a populated multi-segment oracle message.
        populated = [m for m in messages if m.name.startswith('message-1-')][0]
        for shift in (1, 3):
            data = bytes([1, shift]) + bytes(6 + shift) + populated.read_bytes()
            output = run([*command, wasm], data=data)
            got = re.search(r'checksum=(\d+)', output)
            assert got and got.group(1) == expected[populated], f'{name}/{runner}/shift={shift}: {output!r}'
        # 32-bit overflow, Atomic<UInt> clamping, amplification, unaligned UTF-8, and malformed suite.
        edge_out = run([*command, wasm], data=bytes([99, 0]) + bytes(6))
        assert re.search(r'PASS mode=99 checks=9\b', edge_out), f'{name}/{runner}/mode=99: {edge_out!r}'
        # 32-bit packed suite: hostile segment tables, amplification, a segment-crossing run.
        packed_out = run([*command, wasm], data=bytes([98, 0]) + bytes(6))
        # The 2 MiB hostile table (R1) needs a heap array, so only the full variant runs it.
        packed_checks = 7 if name == 'full' else 6
        assert re.search(rf'PASS mode=98 checks={packed_checks}\b', packed_out), f'{name}/{runner}/mode=98: {packed_out!r}'
        # 32-bit builder suite (D-18): layouts, out-of-space sweep with guard bytes, limits.
        build_out = run([*command, wasm], data=bytes([97, 0]) + bytes(6))
        assert re.search(r'PASS mode=97 checks=9\b', build_out), f'{name}/{runner}/mode=97: {build_out!r}'
        gen_out = run([*command, wasm], data=bytes([96, 0]) + bytes(6))
        assert re.search(r'PASS mode=96 checks=3\b', gen_out), f'{name}/{runner}/mode=96: {gen_out!r}'
        print(f'PASS wasm {name} under {runner}: {len(messages)} aligned + 2 unaligned oracle messages, '
              f'{len(messages)} packed, 9 32-bit edge checks, {packed_checks} packed, 9 builder and 3 generated-builder ({wasm.stat().st_size} bytes)',
              flush=True)
print('WASM CHECK: PASS', flush=True)
