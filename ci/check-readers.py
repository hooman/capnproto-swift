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


def make_code_generator_request(filenames):
    """Build a minimal framed CodeGeneratorRequest containing empty file nodes."""
    def struct_word(offset, data_words=0, ptr_words=0):
        return ((offset & 0x3fffffff) << 2) | (data_words << 32) | (ptr_words << 48)

    def list_word(offset, size_code, count):
        return ((offset & 0x3fffffff) << 2) | 1 | ((count << 3 | size_code) << 32)

    n = len(filenames)
    # Segment 0 layout:
    #   word 0: root struct pointer (data=0, ptrs=2) -> word 1
    #   word 1: ptr 0 (nodes inlineComposite list) -> word 3
    #   word 2: ptr 1 (requestedFiles inlineComposite list) -> word 3 + 1 + 2*n
    nodes_start = 3
    nodes_words = 1 + 2 * n
    req_start = nodes_start + nodes_words
    req_words = 1 + 2 * n
    words = [
        struct_word(0, 0, 2),
        list_word(nodes_start - 2, 7, 2 * n),
        list_word(req_start - 3, 7, 2 * n),
        struct_word(n, 2, 0),
    ]
    for i in range(n):
        words.extend([0x1001 + i, 0])  # id, kind=0 (file)
    words.append(struct_word(n, 1, 1))
    # Reserve requestedFiles entries, then append NUL-terminated UTF-8 filename blobs.
    blob_start = req_start + req_words
    blob_words = []
    for i, name in enumerate(filenames):
        raw = name.encode('utf-8') + b'\x00'
        padded = raw + b'\x00' * ((-len(raw)) % 8)
        ptr_slot = req_start + 1 + 2 * i + 1
        target_word = blob_start + len(blob_words)
        words.append(0x1001 + i)
        words.append(list_word(target_word - (ptr_slot + 1), 2, len(raw)))
        for off in range(0, len(padded), 8):
            blob_words.append(struct.unpack_from('<Q', padded, off)[0])
    words.extend(blob_words)
    header = struct.pack('<II', 0, len(words))
    return header + struct.pack(f'<{len(words)}Q', *words)


def run_in(directory, command, *, data=None, reject=None):
    result = subprocess.run([str(x) for x in command], input=data, capture_output=True, cwd=directory)
    if reject is not None:
        assert result.returncode != 0, f'Unexpected success: {command}'
        assert re.search(reject, result.stderr.decode(), re.I), result.stderr.decode()
    elif result.returncode:
        raise RuntimeError(f'{command}\n{result.stdout.decode()}\n{result.stderr.decode()}')
    return result.stdout


# Output-boundary hardening: lexical escapes, symlinked parent/leaf escapes, directory collisions,
# and rollback of newly created files on multi-file write failure.
out_box = work / 'output-hardening'
out_dir = out_box / 'out'
outside_dir = out_box / 'outside'
out_dir.mkdir(parents=True)
outside_dir.mkdir(parents=True)
(outside_dir / 'real.swift').write_text('sentinel\n')
(out_dir / 'sublink').symlink_to(outside_dir)
(out_dir / 'deadlink').symlink_to(outside_dir / 'missing')
(out_dir / 'existing.capnp.swift').symlink_to(outside_dir / 'real.swift')
(out_dir / 'dangling.capnp.swift').symlink_to(outside_dir / 'dangling.swift')
(out_dir / 'dircoll.capnp.swift').mkdir()
(out_dir / 'fileparent').write_text('not a dir\n')

for bad_name in ['../escape.capnp', 'a//b.capnp', 'trailing/', '/abs.capnp', 'a\x7fb.capnp']:
    run_in(out_dir, [plugin], data=make_code_generator_request([bad_name]),
           reject=r'capnpc-swift:.*unsafe output filename')

for escaped_name in [
    'sublink/new.capnp',
    'sublink/nested/new.capnp',
    'deadlink/new.capnp',
    'existing.capnp',
    'dangling.capnp',
    'dircoll.capnp',
    'fileparent/child.capnp',
]:
    run_in(out_dir, [plugin], data=make_code_generator_request([escaped_name]),
           reject=r'capnpc-swift:.*(escape|symbolic link|existing directory|not a directory)')

assert sorted(p.name for p in outside_dir.iterdir()) == ['real.swift']
assert (outside_dir / 'real.swift').read_text() == 'sentinel\n'

# Multi-file write failure: file #1 would be newly created, file #2 hits a read-only parent dir.
# File #1 must be rolled back so no partial newly created output remains.
ro_dir = out_dir / 'readonly'
ro_dir.mkdir()
ro_dir.chmod(0o555)
try:
    run_in(out_dir, [plugin],
           data=make_code_generator_request(['first.capnp', 'readonly/second.capnp']),
           reject=r'capnpc-swift:')
    assert not (out_dir / 'first.capnp.swift').exists(), 'partial newly-created file left behind'
    assert not (ro_dir / 'second.capnp.swift').exists()
finally:
    ro_dir.chmod(0o755)
print('PASS: output-boundary hardening (lexical, symlink parent/leaf, collision, rollback)', flush=True)

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
