#!/usr/bin/env python3
"""Run CapnpRuntime and generated readers on emulated 32-bit bare metal under QEMU.

Builds one Embedded, -no-allocations image per target: the runtime, the generated fixture
readers, the shared assertions (ci/fixtures/verify.swift) and 32-bit suites
(ci/fixtures/edges32.swift) and builder suite (ci/fixtures/build32.swift), and the bare-metal driver and startup in ci/qemu. Each image
links against ci/qemu/start.c only (no libc, no compiler-rt, no allocator) and is audited
for allocator symbols. Then it is booted once per input, with the same inputs and expected
results as ci/check-wasm.py:

- the 9 C++ oracle messages, with the host driver's checksum
- the populated multi-segment message again at +1 and +3 byte offsets
- the same 9 messages packed by capnp (ci/fixtures/packed)
- the 32-bit edge suite (8 checks), the 32-bit packed suite (5 checks) and the 32-bit
  builder suite (7 checks: layouts, the out-of-space sweep with guard bytes, limits)

Each boot must exit 0 and print its PASS line. Two negative controls must fail through the
fault handler (FAULT, non-zero exit): a message with a corrupted segment table, and a
message checked against the wrong mode's expectations.

Targets:
- armv7em: Cortex-M4 (Thumb-2) on qemu-system-arm -M mps2-an386
- riscv32: rv32imac on qemu-system-riscv32 -M virt -bios none

Requires a Swift.org toolchain, qemu-system-arm and qemu-system-riscv32, and the --work
directory produced by ci/check-readers.py (generated readers, messages, host driver).
"""
import argparse
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--swiftc', required=True)
parser.add_argument('--readers-work', required=True, help='work directory of check-readers.py')
parser.add_argument('--target', action='append', choices=['armv7em', 'riscv32'],
                    help='target to run (repeatable; default: both)')
parser.add_argument('--work', default=None)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
work = Path(args.work or tempfile.mkdtemp(prefix='capnp-qemu-')).resolve()
work.mkdir(parents=True, exist_ok=True)
readers = Path(args.readers_work).resolve()
swiftc = shutil.which(args.swiftc) or args.swiftc  # not resolved: swiftc is a symlink to swift-driver
bin_dir = Path(swiftc).resolve().parent
tool = {name: shutil.which(name, path=str(bin_dir)) or shutil.which(name)
        for name in ('clang', 'ld.lld', 'llvm-nm', 'llvm-objdump')}
print(f'Artifacts: {work}', flush=True)

TARGETS = {
    'armv7em': {
        'triple': 'armv7em-none-none-eabi',
        'swift': [],
        'clang': ['-mthumb', '-mfloat-abi=soft'],
        'script': 'mps2-an386.ld',
        'qemu': ['qemu-system-arm', '-M', 'mps2-an386'],
        'input': 0x2030_0000,
    },
    'riscv32': {
        'triple': 'riscv32-none-none-eabi',
        'swift': ['-Xcc', '-march=rv32imac', '-Xcc', '-mabi=ilp32'],
        # -mno-relax: the semihosting sequence's .balign must survive linker relaxation.
        'clang': ['-march=rv32imac', '-mabi=ilp32', '-mno-relax'],
        'script': 'riscv32-virt.ld',
        'qemu': ['qemu-system-riscv32', '-M', 'virt', '-bios', 'none'],
        'input': 0x8040_0000,
    },
}

allocators = '|'.join(line.strip() for line in (root / 'ci/allocator-symbols.txt').read_text().splitlines()
                      if line.strip() and not line.startswith('#'))
allocator = re.compile(rf'^_?({allocators})$')
sources = sorted((root / 'Sources/CapnpRuntime').glob('*.swift'))  # not the DocC tutorial sources


def run(command, *, check=True):
    result = subprocess.run([str(x) for x in command], capture_output=True, text=True)
    if check and result.returncode:
        raise RuntimeError(f'{command}\n{result.stdout}\n{result.stderr}')
    return result.stdout


def build(name, target):
    out = work / name
    out.mkdir(exist_ok=True)
    swift = [swiftc, '-swift-version', '6', '-enable-experimental-feature', 'Embedded',
             '-enable-experimental-feature', 'Lifetimes', '-enable-experimental-feature', 'Extern',
             '-wmo', '-Osize', '-Xfrontend', '-function-sections', '-no-allocations',
             '-target', target['triple'], *target['swift'], '-module-cache-path', work / 'cache']
    run([*swift, '-strict-memory-safety', '-parse-as-library', '-emit-module', '-module-name', 'CapnpRuntime',
         '-emit-module-path', out / 'CapnpRuntime.swiftmodule', *sources, '-c', '-o', out / 'runtime.o'])
    run([*swift, '-I', out, '-module-name', 'image', '-c', readers / 'readers.capnp.swift',
         root / 'ci/fixtures/verify.swift', root / 'ci/fixtures/edges32.swift', root / 'ci/fixtures/build32.swift', root / 'ci/fixtures/genbuild32.swift',
         root / 'ci/qemu/main.swift',
         '-o', out / 'image.o'])
    run([tool['clang'], '-target', target['triple'], *target['clang'], '-ffreestanding', '-fno-builtin', '-Os',
         '-c', root / 'ci/qemu/start.c', '-o', out / 'start.o'])
    elf = out / 'image.elf'
    run([tool['ld.lld'], '-T', root / 'ci/qemu' / target['script'], '--gc-sections',
         out / 'image.o', out / 'runtime.o', out / 'start.o', '-o', elf])
    found = [line.split()[-1] for line in run([tool['llvm-nm'], elf]).splitlines()
             if allocator.match(line.split()[-1])]
    assert not found, f'{name}: allocator symbols in the image: {found}'
    sections = {}
    for line in run([tool['llvm-objdump'], '-h', elf]).splitlines():
        m = re.match(r'\s*\d+\s+(\.\S+)\s+([0-9a-fA-F]+)\s+', line)
        if m:
            sections[m.group(1)] = int(m.group(2), 16)
    flash = sum(sections.get(s, 0) for s in ('.text', '.rodata', '.ARM.exidx', '.data'))
    return elf, flash


def boot(name, target, elf, mode, *, shift=0, packed=False, message=b''):
    """Boot the image on one input; returns (exit status, output)."""
    data = bytes([mode, shift, 1 if packed else 0, 0]) + len(message).to_bytes(4, 'little')
    data += bytes(shift) + message
    path = work / name / 'input.bin'
    path.write_bytes(data)
    command = [*target['qemu'], '-nographic', '-monitor', 'none', '-serial', 'none',
               '-semihosting-config', 'enable=on,target=native', '-kernel', elf,
               '-device', f'loader,file={path},addr={target["input"]:#x},force-raw=on']
    try:
        result = subprocess.run([str(x) for x in command], capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        raise AssertionError(f'{name}: QEMU timed out on mode={mode} shift={shift} packed={packed}')
    return result.returncode, result.stdout + result.stderr


messages = sorted(readers.glob('message-*.bin'))
assert len(messages) == 9, f'expected 9 messages in {readers}, found {len(messages)}'
expected = {}
for message in messages:
    host = run([readers / 'host/verify', message, message.name.split('-')[1]])
    expected[message] = re.search(r'checksum=(\d+)', host).group(1)

for name in args.target or list(TARGETS):
    target = TARGETS[name]
    assert shutil.which(target['qemu'][0]), f'{target["qemu"][0]} not found'
    elf, flash = build(name, target)
    stack = 0

    def passes(mode, pattern, **kwargs):
        global stack
        status, output = boot(name, target, elf, mode, **kwargs)
        assert status == 0 and re.search(pattern, output, re.M), \
            f'{name}: mode={mode} shift={kwargs.get("shift", 0)} packed={kwargs.get("packed", False)}: ' \
            f'exit {status}: {output!r}'
        used = re.search(r'^stack=(\d+)$', output, re.M)
        assert used, f'{name}: no stack report: {output!r}'
        stack = max(stack, int(used.group(1)))

    for message in messages:
        mode, sum_ = int(message.name.split('-')[1]), expected[message]
        passes(mode, rf'^PASS mode={mode} shift=0 checksum={sum_}$', message=message.read_bytes())
        packed = (root / 'ci/fixtures/packed' / message.name.replace('.bin', '.packed')).read_bytes()
        passes(mode, rf'^PASS packed mode={mode} shift=0 checksum={sum_}$', packed=True, message=packed)
    populated = [m for m in messages if m.name.startswith('message-1-')][0]
    for shift in (1, 3):
        passes(1, rf'^PASS mode=1 shift={shift} checksum={expected[populated]}$',
               shift=shift, message=populated.read_bytes())
    passes(99, r'^PASS mode=99 checks=8$')
    passes(98, r'^PASS mode=98 checks=5$')
    passes(97, r'^PASS mode=97 checks=9$')
    passes(96, r'^PASS mode=96 checks=3$')

    # Negative controls: each must trap into the fault handler and exit non-zero.
    corrupted = bytearray(populated.read_bytes())
    corrupted[0:4] = (0xFFFF_FFFF).to_bytes(4, 'little')  # segment count 2^32: invalid frame
    defaults = [m for m in messages if m.name.startswith('message-0-')][0]
    for label, mode, message in [('corrupted segment table', 1, bytes(corrupted)),
                                 ('defaults checked as populated', 1, defaults.read_bytes())]:
        status, output = boot(name, target, elf, mode, message=message)
        assert status != 0 and 'FAULT' in output and 'PASS' not in output, \
            f'{name}: negative control "{label}" did not fail: exit {status}: {output!r}'
    print(f'PASS qemu {name} ({" ".join(target["qemu"][:3])}): {len(messages)} aligned + 2 unaligned '
          f'oracle messages, {len(messages)} packed, 8 32-bit edge checks, 5 packed, 9 builder and 3 generated-builder; '
          f'2 negative controls fault; flash={flash} B, max stack={stack} B', flush=True)
print('QEMU CHECK: PASS', flush=True)
