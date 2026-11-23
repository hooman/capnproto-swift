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
# Output for an existing schema stays byte-identical to the committed golden file. Regenerate
# it deliberately, in the same commit as the generator change that alters it.
# (`.expected`, not `.swift`: generated code is not held to swift-format.)
assert first == (fixture / 'golden/readers.capnp.swift.expected').read_bytes(), 'golden output changed'

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
    'interface-field': 'interface Service {} struct Box { value @0 :Service; }',
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

# Multi-file write failure: file #1 is newly created, then writing file #2 fails. File #1 must be
# rolled back so no partial newly created output remains. The failure must also happen as root
# (GitHub container jobs run as root and ignore directory permission bits), so file #2's leaf
# name exceeds NAME_MAX (255 bytes): the write rejects it as an invalid file name for every user.
# Preflight does not check name length, so the failure comes from the write itself.
long_name = 'x' * 250 + '.capnp'
assert len((long_name + '.swift').encode()) > 255
before = sorted(os.listdir(out_dir))
result = subprocess.run([plugin], input=make_code_generator_request(['first.capnp', long_name]),
                        capture_output=True, cwd=out_dir)
stderr = result.stderr.decode()
assert result.returncode != 0, 'Unexpected success: over-long output name was written'
assert re.search(r'capnpc-swift:', stderr), stderr
assert not re.search(r'unsafe output filename|duplicate output path|escape|symbolic link|'
                     r'existing directory|not a directory', stderr, re.I), \
    f'failed in preflight, not while writing: {stderr}'
# Listing the directory avoids stat on the over-long name; it also catches stray temp files.
assert sorted(os.listdir(out_dir)) == before, \
    f'partial output left behind: {sorted(set(os.listdir(out_dir)) - set(before))}'
print('PASS: output-boundary hardening (lexical, symlink parent/leaf, collision, rollback)',
      flush=True)

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

# D-17 item 0: annotation uses are skipped and annotation declarations generate nothing.
# Output must equal the committed golden files, which came from an unannotated twin with the
# same node IDs, and the readers must decode a C++-encoded message.
annotated = work / 'annotated'
annotated.mkdir(exist_ok=True)
run([capnp, 'compile', '-o', f'{plugin}:{annotated}', f'--src-prefix={fixture}',
     fixture / 'annotated-import.capnp', fixture / 'annotated.capnp'])
for name in ['annotated-import.capnp.swift', 'annotated.capnp.swift']:
    assert (annotated / name).read_bytes() == (fixture / 'golden' / f'{name}.expected').read_bytes(), name
message = run([capnp, 'encode', fixture / 'annotated.capnp', 'Box'],
              data=b'(value = 9, thing = (id = 42), choice = (count = 3), extra = (flag = true))')
(annotated / 'box.bin').write_bytes(message)
run([swiftc, *flags, *link_flags, '-O', '-parse-as-library', '-I', host,
     annotated / 'annotated-import.capnp.swift',
     annotated / 'annotated.capnp.swift', fixture / 'annotated-verify.swift', host / 'runtime.o',
     '-o', annotated / 'verify'])
print(run([annotated / 'verify', annotated / 'box.bin']).decode().strip(), flush=True)
# The real upstream import, as in most real-world schemas.
(work / 'cxx.capnp').write_text('@0xa11071a7ed000003; using Cxx = import "/capnp/c++.capnp"; '
    '$Cxx.namespace("demo"); struct Point $Cxx.name("Pt") { x @0 :Int32 $Cxx.name("ex"); }')
run([capnp, 'compile', '-o', plugin, 'cxx.capnp'])
run([swiftc, *flags, '-I', host, '-typecheck', work / 'cxx.capnp.swift'])
# Fields that use the schemas upstream installs. capnp only puts an import's nodes in the
# request when something uses it, so an unused import would prove nothing. These files hold
# annotations, interfaces, generics, enums, constants and implicit method structs.
# (persistent.capnp offers only generic types, which a field cannot reference yet.)
(work / 'upstream.capnp').write_text('''@0xa11071a7ed000009;
using Cxx = import "/capnp/c++.capnp";
using Schema = import "/capnp/schema.capnp";
using Rpc = import "/capnp/rpc.capnp";
using TwoParty = import "/capnp/rpc-twoparty.capnp";
using Stream = import "/capnp/stream.capnp";
using Json = import "/capnp/compat/json.capnp";
$Cxx.namespace("probe");
struct Uses {
  node @0 :Schema.Node;
  message @1 :Rpc.Message;
  vat @2 :TwoParty.VatId;
  stream @3 :Stream.StreamResult;
  json @4 :Json.Value;
}
''')
request = run([capnp, 'compile', '-o-', 'upstream.capnp'])
assert len(request) > 64 * 1024, 'upstream imports no longer reach the request'
upstream_run = subprocess.run([plugin], input=request, capture_output=True, cwd=work)
assert upstream_run.returncode == 0, upstream_run.stderr.decode()
# Upstream files document their enums and interfaces too; no rendered struct may warn.
assert not upstream_run.stderr, upstream_run.stderr.decode()
# Not typechecked: it names readers for upstream files that cannot be generated yet (enums).
assert (work / 'upstream.capnp.swift').is_file()
# An unused interface in an imported file does not block generation; a field that uses one does.
(work / 'service.capnp').write_text('@0xa11071a7ed000004; interface Service {} '
    'annotation note(*) :Void; struct Plain { id @0 :UInt64; }')
(work / 'uses-plain.capnp').write_text('@0xa11071a7ed000005; using S = import "service.capnp"; '
    'struct Box $S.note { plain @0 :S.Plain $S.note; }')
run([capnp, 'compile', '-o', plugin, 'uses-plain.capnp'])
(work / 'uses-service.capnp').write_text('@0xa11071a7ed000006; using S = import "service.capnp"; '
    'struct Box { service @0 :S.Service; }')
run([capnp, 'compile', '-o', plugin, 'uses-service.capnp'], reject=r'capnpc-swift:.*unsupported')
assert not (work / 'uses-service.capnp.swift').exists()
# A non-empty list default whose element type is unsupported (an enum's two-byte list) is
# diagnosed, not misread as a pointer list (which failed with typeMismatch).
(work / 'color.capnp').write_text('@0xa11071a7ed000007; enum Color { red @0; green @1; }')
(work / 'enum-list-default.capnp').write_text('@0xa11071a7ed000008; using C = import "color.capnp"; '
    'struct Box { colors @0 :List(C.Color) = [red, green]; }')
run([capnp, 'compile', '-o', plugin, 'enum-list-default.capnp'],
    reject=r'capnpc-swift:.*unsupported non-empty pointer default')
print('PASS: annotations tolerated, golden output, upstream imports, interface diagnostics', flush=True)

# Doc comments (D-17 item 1). capnp copies comment bytes verbatim, so a hostile schema can put
# line breaks, bidi controls, other control characters and invalid UTF-8 into sourceInfo. All of
# it must stay inside `///` lines. The goldens were written by hand: main's output plus the
# expected doc lines.
docs = work / 'docs'
docs_out = docs / 'out'
docs_out.mkdir(parents=True)
(docs / 'docs-hostile.capnp').write_bytes(
    b'@0xd0c5000000000002;\n'
    b'struct Hostile @0xd0c5000000000021 {\r\n'
    b'  # CRLF line one.\r\n'
    b'  # CRLF line two.\r\n'
    b'  a @0 :Int32;  # cr:\rpublic var injected: Int { 0 }\n'
    b'  b @1 :Int32;  # bidi:\xe2\x80\xaeevil\xe2\x81\xa6x\xe2\x81\xa9 ctl:\x01\x7f\xc2\x85 tab:\tend   \n'
    b'  c @2 :Int32;  # bad utf8:\xff\xfe!\n'
    b'  d @3 :Int32;  # */ /* and } code(); \n'
    b'  e @4 :Int32;  #    \n'
    b'  f @5 :Int32;  # \x1b[31mansi\n'
    b'}\n')
run([capnp, 'compile', '-o', f'{plugin}:{docs_out}', f'--src-prefix={fixture}', fixture / 'docs.capnp'])
run([capnp, 'compile', '-o', f'{plugin}:{docs_out}', f'--src-prefix={docs}', docs / 'docs-hostile.capnp'])
for name in ['docs.capnp.swift', 'docs-hostile.capnp.swift']:
    assert (docs_out / name).read_bytes() == (fixture / 'golden' / f'{name}.expected').read_bytes(), \
        f'golden output changed: {name}'
for line in (docs_out / 'docs-hostile.capnp.swift').read_text(encoding='utf-8').splitlines():
    if 'injected' in line or 'code()' in line:
        assert line.lstrip().startswith('/// '), f'doc text escaped its comment: {line!r}'
run([swiftc, *flags, '-I', host, '-typecheck', docs_out / 'docs.capnp.swift',
     docs_out / 'docs-hostile.capnp.swift'])

# Hand-edited requests: sourceInfo may be missing entries, or missing entirely, and member lists
# may not match. Doc comments are cosmetic, so each case still generates.
capnp_prefix = Path(capnp).resolve().parent.parent
schema_capnp = next((p for p in [capnp_prefix / 'include/capnp/schema.capnp',
                                 Path('/usr/include/capnp/schema.capnp'),
                                 Path('/usr/local/include/capnp/schema.capnp')] if p.is_file()), None)
assert schema_capnp, f'schema.capnp not found near {capnp}'
docs_text = run([capnp, 'convert', 'binary:text', schema_capnp, 'CodeGeneratorRequest'],
                data=run([capnp, 'compile', '-o-', f'--src-prefix={fixture}', fixture / 'docs.capnp'])).decode()

source_info = docs_text.rindex(',', 0, docs_text.index('sourceInfo = ['))

def edited_docs(name, pattern):
    # Edit only the sourceInfo section: node IDs also appear in the nodes list.
    tail, count = re.subn(pattern, '', docs_text[source_info:], flags=re.S)
    assert count == 1, f'{name}: edit matched {count} times'
    text = docs_text[:source_info] + tail
    request = run([capnp, 'convert', 'text:binary', schema_capnp, 'CodeGeneratorRequest'], data=text.encode())
    out = docs / name
    out.mkdir()
    result = subprocess.run([plugin], input=request, capture_output=True, cwd=out)
    assert result.returncode == 0, f'{name}: {result.stderr.decode()}'
    return (out / 'docs.capnp.swift').read_text(encoding='utf-8'), result.stderr.decode()

point_id = 0xd0c5000000000011
# Point's own entry is gone: no doc for Point or its fields, the rest unchanged, no warning.
output, stderr = edited_docs('missing-entry', rf'\(\s*id = {point_id},.*?endByte = \d+ \),\s*')
assert not stderr, stderr
assert 'A point in the plane' not in output and 'Horizontal position' not in output, output
assert '/// File doc' in output and '/// A bare dot.' in output and '/// Draw heavier.' in output, output
# Point lists one member too few: a warning, Point's own doc kept, all its member docs dropped.
output, stderr = edited_docs('member-mismatch', r'\(\s*docComment = "Horizontal position\.\\n"\s*\),\s*')
assert re.fullmatch(rf'capnpc-swift: warning: .*{point_id:x}.*\n', stderr), stderr
assert '/// A point in the plane.' in output, output
assert 'Horizontal position' not in output and 'Vertical position' not in output, output
assert '/// A bare dot.' in output and '/// Draw heavier.' in output, output
# No sourceInfo at all (older capnp): no doc lines; the only `///` is the generator's own.
output, stderr = edited_docs('no-source-info', r',\s*sourceInfo = \[.*\]\s*(?=\)\s*$)')
assert not stderr, stderr
assert {line.strip() for line in output.splitlines() if '///' in line} == \
    {'/// Active union tag, or nil for a tag unknown to this schema version.'}, output
print('PASS: doc comments (golden, hostile text, missing and mismatched sourceInfo)', flush=True)


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
