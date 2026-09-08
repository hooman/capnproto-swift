#!/usr/bin/env python3
"""Check concrete runtime and generated-reader paths across an Embedded module boundary.
Compile with -no-allocations, audit allocator symbols, and reject an allocating control.
This checks target compilation only; it does not link firmware or execute on hardware.
"""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--swiftc', required=True)
p.add_argument('--target', required=True)
p.add_argument('--generated', required=True)
p.add_argument('--stdlib', help='matching toolchain Embedded modules, for cross-OS builds')
p.add_argument('--work')
a = p.parse_args()
root = Path(__file__).resolve().parent.parent
work = Path(a.work or tempfile.mkdtemp(prefix='capnp-cross-')).resolve()
work.mkdir(parents=True, exist_ok=True)
flags = [a.swiftc, '-swift-version', '6', '-enable-experimental-feature', 'Embedded',
         '-enable-experimental-feature', 'Lifetimes', '-wmo', '-no-allocations',
         '-target', a.target, '-module-cache-path', str(work / 'cache'), '-parse-as-library']
if a.stdlib:
    flags += ['-I', a.stdlib]
sources = sorted((root / 'Sources/CapnpRuntime').glob('*.swift'))
subprocess.run([*flags, '-emit-module', '-emit-module-path', str(work / 'CapnpRuntime.swiftmodule'),
                '-module-name', 'CapnpRuntime', *map(str, sources)], check=True)
subprocess.run([*flags, '-c', *map(str, sources), str(root / 'ci/runtime-entry.swift'),
                '-o', str(work / 'runtime.o')], check=True)
subprocess.run([*flags, '-I', str(work), '-c', str(Path(a.generated).resolve()),
                str(root / 'ci/fixtures/verify.swift'), '-o', str(work / 'readers.o')], check=True)
# Apple nm cannot read every ELF object; llvm-nm is accepted through NM.
import os
nm = os.environ.get('NM', 'nm')
for name in ['runtime.o', 'readers.o']:
    result = subprocess.run([nm, str(work / name)], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f'{nm} cannot inspect {a.target}; set NM to llvm-nm: {result.stderr}')
    assert not re.search(r'\b_?(free|malloc|posix_memalign|swift_allocObject|swift_slowAlloc|swift_coroFrameAlloc)$',
                         result.stdout, re.M), result.stdout
negative = subprocess.run([*flags, '-c', str(root / 'ci/negative-control.swift'),
                           '-o', str(work / 'negative.o')], capture_output=True, text=True)
assert negative.returncode != 0 and 'alloc' in negative.stderr.lower(), negative.stderr
print(f'CROSS EMBEDDED: PASS {a.target}; artifacts: {work}')
