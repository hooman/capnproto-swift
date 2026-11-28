#!/usr/bin/env python3
"""Run CapnpRuntime on a real ESP32-C6 (RISC-V rv32imac) board, the hardware stage of the
32-bit qualification after Wasm and QEMU.

Builds the same Embedded, -no-allocations Swift objects as ci/check-qemu.py's riscv32 image
(the runtime, generated fixture readers, the shared fixtures and the shared driver), links them
into a minimal ESP-IDF app (ci/esp32c6) with a table of every QEMU input, flashes it, and reads
UART0 through the DevKitC-1's USB-UART bridge. It requires:

- every QEMU input's PASS line, in order, with the host driver's checksums
- the heap unchanged by the run: free and lowest-ever free bytes equal before and after
- the negative control (QEMU's "defaults checked as populated") to trap, which the panic
  handler reports before halting

It reports flash size, the main task's peak stack and each input's time in microseconds.
Requires ESP-IDF v5.x in the environment (`. $IDF_PATH/export.sh`, which also supplies
pyserial), a Swift.org toolchain, the --readers-work directory of ci/check-readers.py, and a
board on --port. Local only: CI has no board.
"""
import argparse
import glob
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
parser.add_argument('--swiftc', required=True)
parser.add_argument('--readers-work', required=True, help='work directory of check-readers.py')
parser.add_argument('--port', help='serial port (default: the only /dev/cu.usbserial-* or ttyUSB*)')
parser.add_argument('--work', default=None)
parser.add_argument('--build-only', action='store_true', help='build the firmware; no flashing')
args = parser.parse_args()

assert os.environ.get('IDF_PATH') and shutil.which('idf.py'), 'run inside ESP-IDF: . $IDF_PATH/export.sh'
root = Path(__file__).resolve().parent.parent
readers = Path(args.readers_work).resolve()
work = Path(args.work or tempfile.mkdtemp(prefix='capnp-esp32c6-')).resolve()
# ESP-IDF writes these paths into generated CMake unquoted, so parentheses break the build.
assert not set('()') & set(str(work)), f'--work must not contain parentheses: {work}'
generated = work / 'generated'
generated.mkdir(parents=True, exist_ok=True)
swiftc = shutil.which(args.swiftc) or args.swiftc
print(f'Artifacts: {work}', flush=True)


def run(command, **kwargs):
    result = subprocess.run([str(x) for x in command], capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f'{command}\n{result.stdout}\n{result.stderr}')
    return result.stdout


# 1. The Swift objects, with ci/check-qemu.py's riscv32 flags.
sources = sorted((root / 'Sources/CapnpRuntime').glob('*.swift'))
swift = [swiftc, '-swift-version', '6', '-enable-experimental-feature', 'Embedded',
         '-enable-experimental-feature', 'Lifetimes', '-enable-experimental-feature', 'Extern',
         '-wmo', '-Osize', '-Xfrontend', '-function-sections', '-no-allocations',
         '-target', 'riscv32-none-none-eabi', '-Xcc', '-march=rv32imac', '-Xcc', '-mabi=ilp32',
         '-module-cache-path', work / 'cache',
         # The one difference from the QEMU image. Swift's stack protector reads
         # __stack_chk_guard through the GOT, and ESP-IDF's linker script discards .got.plt.
         # It is hardening, not behaviour under test.
         '-Xfrontend', '-disable-stack-protector']
run([*swift, '-strict-memory-safety', '-parse-as-library', '-emit-module', '-module-name', 'CapnpRuntime',
     '-emit-module-path', generated / 'CapnpRuntime.swiftmodule', *sources, '-c', '-o', generated / 'runtime.o'])
run([*swift, '-parse-as-library', '-I', generated, '-module-name', 'image', '-c', readers / 'readers.capnp.swift',
     root / 'ci/fixtures/verify.swift', root / 'ci/fixtures/edges32.swift', root / 'ci/fixtures/build32.swift',
     root / 'ci/fixtures/genbuild32.swift', root / 'ci/fixtures/embedded-driver.swift',
     root / 'ci/esp32c6/driver.swift', '-o', generated / 'image.o'])

# Nothing reads .swift_modhash at run time, and ESP-IDF's linker script has no place for it:
# left in, the orphan lands between .flash.rodata and .flash.init_array, which breaks the image.
objcopy = Path(swiftc).resolve().parent / 'llvm-objcopy'
for name in ('runtime.o', 'image.o'):
    run([objcopy, '--remove-section=.swift_modhash', generated / name])

# 2. The inputs, in ci/check-qemu.py's order, with the line each must print.
messages = sorted(readers.glob('message-*.bin'))
assert len(messages) == 9, f'expected 9 messages in {readers}, found {len(messages)}'
expected_sum = {m: re.search(r'checksum=(\d+)', run([readers / 'host/verify', m, m.name.split('-')[1]])).group(1)
                for m in messages}
inputs = []  # (bytes, expected line)


def add(mode, pattern, *, shift=0, packed=False, message=b''):
    data = bytes([mode, shift, 1 if packed else 0, 0]) + len(message).to_bytes(4, 'little')
    inputs.append((data + bytes(shift) + message, pattern))


for m in messages:
    mode, total = int(m.name.split('-')[1]), expected_sum[m]
    add(mode, f'PASS mode={mode} shift=0 checksum={total}', message=m.read_bytes())
    packed = (root / 'ci/fixtures/packed' / m.name.replace('.bin', '.packed')).read_bytes()
    add(mode, f'PASS packed mode={mode} shift=0 checksum={total}', packed=True, message=packed)
populated = [m for m in messages if m.name.startswith('message-1-')][0]
for shift in (1, 3):
    add(1, f'PASS mode=1 shift={shift} checksum={expected_sum[populated]}', shift=shift,
        message=populated.read_bytes())
for mode, checks in ((99, 8), (98, 5), (97, 8), (96, 3)):
    add(mode, f'PASS mode={mode} checks={checks}')
defaults = [m for m in messages if m.name.startswith('message-0-')][0]
negative = bytes([1, 0, 0, 0]) + len(defaults.read_bytes()).to_bytes(4, 'little') + defaults.read_bytes()


def c_array(name, data):
    body = ', '.join(str(b) for b in data)
    # In RAM, aligned to a word, as QEMU's loader places its input; the shift unaligns it.
    return f'static uint8_t {name}[{len(data)}] __attribute__((aligned(8))) = {{{body}}};\n'


source = '#include <stdint.h>\n'
source += ''.join(c_array(f'input{i}', data) for i, (data, _) in enumerate(inputs))
source += c_array('negative', negative)
source += f'static const void *const inputs[{len(inputs)}] = {{{", ".join(f"input{i}" for i in range(len(inputs)))}}};\n'
source += f'int32_t capnp_input_count(void) {{ return {len(inputs)}; }}\n'
source += 'const void *capnp_input_at(int32_t index) { return inputs[index]; }\n'
source += 'const void *capnp_negative_input(void) { return negative; }\n'
(generated / 'inputs.c').write_text(source)

# 3. The firmware.
project = work / 'project'
shutil.rmtree(project, ignore_errors=True)
shutil.copytree(root / 'ci/esp32c6', project, ignore=shutil.ignore_patterns('driver.swift'))
idf = ['idf.py', '-C', project, '-B', work / 'build']
env = dict(os.environ, IDF_TARGET='esp32c6', CAPNP_GENERATED=str(generated))
run([*idf, 'build'], env=env)
app = work / 'build/capnp_esp32c6.bin'
size = run([*idf, 'size'], env=env)
flash_used = re.search(r'Total image size:\s*([\d,]+) bytes', size)
print(f'BUILD: PASS {app.name} {app.stat().st_size} B'
      + (f', total image {flash_used.group(1)} B' if flash_used else ''), flush=True)
if args.build_only:
    raise SystemExit(0)

# 4. Flash, reset, and read the run.
ports = [args.port] if args.port else glob.glob('/dev/cu.usbserial-*') + glob.glob('/dev/ttyUSB*')
assert len(ports) == 1, f'expected one board, found {ports}; pass --port'
port = ports[0]
run([*idf, '-p', port, 'flash'], env=env)

import serial  # noqa: E402  (pyserial, from the ESP-IDF environment)

lines = []
with serial.Serial(port, 115200, timeout=0.5) as uart:
    uart.dtr = False  # EN low, then high: a clean boot into the app, not the ROM loader
    uart.rts = True
    time.sleep(0.1)
    uart.rts = False
    deadline = time.monotonic() + 60
    buffer = b''
    while time.monotonic() < deadline:
        buffer += uart.read(4096)
        text = buffer.decode('utf-8', errors='replace')
        if 'CAPNP BEGIN' in text and ('Guru Meditation' in text or 'DID NOT TRAP' in text):
            time.sleep(1)  # the panic report continues for a moment
            buffer += uart.read(65536)
            break
    text = buffer.decode('utf-8', errors='replace')
(work / 'uart.log').write_text(text)
assert 'CAPNP BEGIN' in text, f'no CAPNP BEGIN on {port}; see {work / "uart.log"}'
lines = text[text.index('CAPNP BEGIN'):].splitlines()
results = [line.strip() for line in lines if line.startswith('PASS ')]
times = [int(t) for t in re.findall(r'^time us=(\d+)', '\n'.join(lines), re.M)]
for index, ((_, pattern), got) in enumerate(zip(inputs, results + [''] * len(inputs))):
    assert got == pattern, f'input {index}: expected {pattern!r}, got {got!r}; see {work / "uart.log"}'
assert len(results) == len(inputs) and len(times) == len(inputs), f'{len(results)} PASS lines for {len(inputs)} inputs'
heap = re.search(r'^heap free_before=(\d+) free_after=(\d+) low_before=(\d+) low_after=(\d+)', text, re.M)
assert heap and heap.group(1) == heap.group(2) and heap.group(3) == heap.group(4), \
    f'the run changed the heap: {heap and heap.group(0)}'
stack = re.search(r'^stack size=(\d+) unused=(\d+)', text, re.M)
assert stack, 'no stack report'
peak = int(stack.group(1)) - int(stack.group(2))
after = text[text.index('CAPNP NEGATIVE CONTROL'):]
assert 'Guru Meditation' in after and 'DID NOT TRAP' not in after, 'the negative control did not trap'
print(f'PASS esp32c6 on {port}: {len(messages)} aligned + 2 unaligned oracle messages, {len(messages)} packed, '
      f'8 32-bit edge checks, 5 packed, 8 builder and 3 generated-builder; heap unchanged '
      f'({heap.group(1)} B free); main-task stack peak {peak} B (of {stack.group(1)}); '
      f'negative control traps; slowest input {max(times)} us, all {sum(times)} us', flush=True)
for (_, pattern), us in zip(inputs, times):
    print(f'  {us:>7} us  {pattern}')
print('ESP32-C6 CHECK: PASS', flush=True)
