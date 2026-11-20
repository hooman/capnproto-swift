#!/usr/bin/env python3
"""Use the independent C++ encoder as the wire oracle for generated Swift readers.
Run shared fixture assertions on the host, then compile them across an Embedded module
boundary to check specialization and allocation freedom. Negative cases cover malformed
requests, unsupported schemas and (via ci/check-compile-fail.py) compile-time safety
contracts. Retain all artifacts in --work.
Requires Python 3, capnp and a Swift.org toolchain.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--swiftc', default=os.environ.get('SWIFTC', 'swiftc'))
parser.add_argument('--capnp', default=os.environ.get('CAPNP', 'capnp'))
parser.add_argument('--plugin', required=True)
parser.add_argument('--work', default=None)
parser.add_argument('--host-only', action='store_true')
parser.add_argument('--skip-compile-fail', action='store_true')
parser.add_argument('--iterations', type=int, default=1)
args = parser.parse_args()
assert args.iterations > 0
root = Path(__file__).resolve().parent.parent
allocators = '|'.join(line.strip() for line in (root / 'ci/allocator-symbols.txt').read_text().splitlines()
                      if line.strip() and not line.startswith('#'))
work = Path(args.work or tempfile.mkdtemp(prefix='capnp-readers-')).resolve()
work.mkdir(parents=True, exist_ok=True)
print(f'Artifacts: {work}', flush=True)
fixture = root / 'ci/fixtures'
plugin = str(Path(args.plugin).resolve())
swiftc = shutil.which(args.swiftc) or args.swiftc
capnp = shutil.which(args.capnp) or args.capnp

def run(command, *, data=None, reject=None):
    result = subprocess.run([str(x) for x in command], input=data, capture_output=True, cwd=work)
    if reject is not None:
        assert result.returncode != 0, f'Unexpected success: {command}'
        assert re.search(reject, result.stderr.decode(), re.I), result.stderr.decode()
    elif result.returncode:
        raise RuntimeError(f'{command}\n{result.stdout.decode()}\n{result.stderr.decode()}')
    return result.stdout

run([capnp, 'compile', '-o', f'{plugin}:{work}', f'--src-prefix={fixture}', fixture / 'readers.capnp'])
generated = work / 'readers.capnp.swift'
assert generated.is_file()
# Regeneration is byte-for-byte deterministic.
first = generated.read_bytes()
run([capnp, 'compile', '-o', f'{plugin}:{work}', f'--src-prefix={fixture}', fixture / 'readers.capnp'])
assert generated.read_bytes() == first

host_target = run([swiftc, '-print-target-info']).decode()
import json
triple = json.loads(host_target)['target']['triple']
if 'apple-macos' in triple:
    triple = triple.split('-apple-')[0] + '-apple-macos27'
flags = ['-swift-version', '6', '-enable-experimental-feature', 'Lifetimes',
         '-module-cache-path', str(work / 'cache'), '-target', triple]
if 'apple-macos' in triple:
    flags += ['-sdk', os.environ.get('SDKROOT') or run(['xcrun', '--show-sdk-path']).decode().strip()]
sources = sorted((root / 'Sources/CapnpRuntime').glob('*.swift'))
host = work / 'host'
host.mkdir(exist_ok=True)
run([swiftc, *flags, '-strict-memory-safety', '-warnings-as-errors',
     '-O', '-wmo', '-parse-as-library', '-emit-module', '-emit-object',
     '-module-name', 'CapnpRuntime', '-emit-module-path', host / 'CapnpRuntime.swiftmodule',
     *sources, '-o', host / 'runtime.o'])
# Standalone executables need the selected toolchain's compatibility libraries on
# older macOS hosts; compiling successfully does not ensure dyld can find RawSpan support.
link_flags = []
for library_path in json.loads(host_target)['paths']['runtimeLibraryPaths']:
    link_flags += ['-Xlinker', '-rpath', '-Xlinker', library_path]
run([swiftc, *flags, *link_flags, '-O', '-I', host, generated, fixture / 'verify.swift',
     fixture / 'main.swift', host / 'runtime.o', '-o', host / 'verify'])

full = b"""(boolField = false, text = "hi!", data = 0x"00ff", child = (id = 99, name = "x"),
children = [(id = 11), (id = 22)], bits = [true, false, true], numbers = [0, 11, 4000000000],
texts = ["a", "b"], blobs = [0x"01", 0x"02"], matrix = [[11], [21, 22]],
voids = [void, void, void], detail = (label = "ok", amount = 123))"""
for mode, typename, message in [(0, 'Example', b'()'), (1, 'Example', full),
                                (2, 'Old', b'(value = 42, values = [11, 22])')]:
    for segment_size in [None, 1, 4]:
        command = [capnp, 'encode', fixture / 'readers.capnp', typename]
        if segment_size:
            command += [f'--segment-size={segment_size}']
        data = run(command, data=message)
        segments = struct.unpack_from('<I', data)[0] + 1
        if segment_size and mode == 1:
            assert segments > 1
        path = work / f'message-{mode}-{segment_size}.bin'
        path.write_bytes(data)
        print(f'segments={segments}: ' + run([host / 'verify', path, mode, args.iterations]).decode().strip(), flush=True)

if not args.skip_compile_fail:
    output = run([
        sys.executable, root / 'ci/check-compile-fail.py',
        '--swiftc', swiftc,
        '--mode', 'contract',
        '--runtime-module-dir', host,
        '--generated', generated,
        '--work', work / 'compile-fail',
    ]).decode().strip()
    if output:
        print(output, flush=True)

# Compiler diagnostics must be nonzero, actionable, and leave no partial output.
# TODO(output-tests): cover lexical and symlink output-directory escapes, and inject
# filesystem failures to verify/report partial multi-file writes. Current rejection
# cases exercise request/schema validation, not the output filesystem boundary.
unsupported = {
    'enum': 'enum Color { red @0; }',
    'interface': 'interface Service {}',
    'const': 'const value :UInt32 = 1;',
    'generic': 'struct Box(T) { value @0 :T; }',
    'any': 'struct Box { value @0 :AnyPointer; }',
    'text-default': 'struct Box { value @0 :Text = "no"; }',
    'list-default': 'struct Box { value @0 :List(UInt32) = [1]; }',
    'struct-default': 'struct Box { value @0 :Inner = (value = 1); struct Inner { value @0 :UInt32; } }',
    'annotation': 'annotation note(struct) :Void; struct Box $note {}',
}
for name, schema in unsupported.items():
    path = work / f'{name}.capnp'
    path.write_text('@0xbedead1234567890;\n' + schema + '\n')
    run([capnp, 'compile', '-o', plugin, path.name], reject=r'capnpc-swift:.*(unsupported|outside)')
    assert not Path(str(path) + '.swift').exists()
for data in [b'', b'garbage', b'\0' * 8, (work / 'message-1-None.bin').read_bytes()]:
    run([plugin], data=data, reject=r'capnpc-swift:')
print(f'PASS: {len(unsupported)} unsupported schemas and 4 invalid requests', flush=True)

# A large real compiler request must exercise multi-segment bootstrap decoding.
large = work / 'large.capnp'
large.write_text('@0xace0123456789012;\n' + '\n'.join(
    f'struct Item{i} {{ value @0 :UInt64; text @1 :Text; }}' for i in range(100)))
request = run([capnp, 'compile', '-o-', large.name])
segment_count = struct.unpack_from('<I', request)[0] + 1
assert segment_count > 1, 'bootstrap fixture no longer exercises far pointers'
run([plugin], data=request)
run([swiftc, *flags, '-I', host, '-typecheck', work / 'large.capnp.swift'])
print(f'PASS: bootstrap request with {segment_count} segments', flush=True)

# Names, imported references, and recursive references compile together.
(work / 'imported.capnp').write_text('@0xace0123456789013; struct Child { id @0 :UInt64; }')
(work / 'imports.capnp').write_text('@0xace0123456789014; using Other = import "imported.capnp"; '
    'struct Container { child @0 :Other.Child; next @1 :Container; class @2 :UInt32; '
    'self @3 :UInt32; init @4 :UInt32; union { rawValue @5 :Void; repeat @6 :Void; } }')
run([capnp, 'compile', '-o', plugin, 'imported.capnp', 'imports.capnp'])
run([swiftc, *flags, '-I', host, '-typecheck', work / 'imported.capnp.swift', work / 'imports.capnp.swift'])
print('PASS: imports, recursive references, Swift keywords', flush=True)


if not args.host_only:
    embedded = work / 'embedded'
    embedded.mkdir(exist_ok=True)
    ef = [*flags, '-enable-experimental-feature', 'Embedded', '-wmo', '-no-allocations', '-O']
    run([swiftc, *ef, '-parse-as-library', '-emit-module', '-emit-object',
         '-module-name', 'CapnpRuntime', '-emit-module-path', embedded / 'CapnpRuntime.swiftmodule',
         *sources, '-o', embedded / 'runtime.o'])
    # Import serialized Embedded runtime into a second compilation. The exported C
    # entry traverses generated scalars, lists, text/data, nested structs and unions.
    run([swiftc, *ef, '-I', embedded, '-parse-as-library', '-c', generated,
         fixture / 'verify.swift', '-o', embedded / 'readers.o'])
    for obj in [embedded / 'runtime.o', embedded / 'readers.o']:
        symbols = run(['nm', obj]).decode()
        assert not re.search(rf'\b_?({allocators})$', symbols, re.M), symbols
        print(f'PASS Embedded: {obj.name}, object bytes={obj.stat().st_size}', flush=True)
print('READERS CONFORMANCE: PASS', flush=True)
