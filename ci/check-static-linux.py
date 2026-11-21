#!/usr/bin/env python3
"""Check CapnpRuntime on Static Linux (musl) for aarch64 and x86_64.

1. Build & static-link audit. Compile CapnpRuntime with strict memory safety and
   link the shared fixture assertions (ci/fixtures/verify.swift) plus generated
   readers into statically linked musl ELF executables (-static-executable
   -static-stdlib). Inspect each ELF with llvm-objdump and require the expected
   machine format with NO PT_INTERP, PT_DYNAMIC, or DT_NEEDED entries.
   Note: full-Swift static Linux binaries link libswiftCore and musl (which
   allocate and use threads); static linking is distinct from INVARIANT 2
   (-no-allocations).
2. Execution. Run all 9 C++-encoded oracle messages from a check-readers.py work
   directory directly on matching native Linux or inside a minimal FROM scratch
   Docker container (with --init and a bounded timeout), requiring host-identical
   checksums plus nonzero exit on a wrong-mode negative control.
3. Optional --check-swiftpm. Also verify `swift build --swift-sdk <triple>
   --product CapnpRuntime` for each selected architecture.

Requires a Swift.org toolchain, its matching Static Linux SDK bundle (explicitly
named via --static-linux-sdk or --sdk-id), and the --readers-work directory from
ci/check-readers.py.
"""
import argparse
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

ARCH_SPECS = {
    'aarch64': {
        'triple': 'aarch64-swift-linux-musl',
        'elf_format': 'elf64-littleaarch64',
        'docker_platform': 'linux/arm64',
        'native_machines': ('aarch64', 'arm64'),
    },
    'x86_64': {
        'triple': 'x86_64-swift-linux-musl',
        'elf_format': 'elf64-x86-64',
        'docker_platform': 'linux/amd64',
        'native_machines': ('x86_64', 'amd64'),
    },
}


def run(command, *, data=None, timeout=None):
    result = subprocess.run(
        [str(x) for x in command],
        input=data,
        capture_output=True,
        timeout=timeout,
    )
    if result.returncode:
        raise RuntimeError(f'{command}\n{result.stdout.decode()}\n{result.stderr.decode()}')
    return result.stdout.decode()


def resolve_arch_sdk(swift_bin: Path, static_linux_sdk: Path | None, sdk_id: str | None, arch: str, triple: str) -> Path:
    if static_linux_sdk is not None:
        candidate = static_linux_sdk / arch
        if not candidate.is_dir():
            raise RuntimeError(f'Static Linux SDK arch directory missing: {candidate}')
        return candidate
    assert sdk_id is not None
    out = run([swift_bin, 'sdk', 'configure', '--show-configuration', sdk_id, triple])
    match = re.search(r'^sdkRootPath:\s*(.+)$', out, re.M)
    if not match:
        raise RuntimeError(f'Could not resolve sdkRootPath for {sdk_id} / {triple}:\n{out}')
    sdk_dir = Path(match.group(1).strip())
    if not sdk_dir.is_dir():
        raise RuntimeError(f'Resolved sdkRootPath does not exist: {sdk_dir}')
    return sdk_dir


def audit_static_elf(objdump: str, exe: Path, expected_format: str) -> None:
    od_out = run([objdump, '-f', '-p', exe])
    if f'file format {expected_format}' not in od_out:
        raise RuntimeError(f'{exe}: expected ELF format {expected_format!r}, got:\n{od_out[:600]}')
    forbidden = re.findall(r'\b(INTERP|DYNAMIC|NEEDED)\b', od_out)
    if forbidden:
        raise RuntimeError(f'{exe}: not purely statically linked (found {sorted(set(forbidden))}):\n{od_out}')


def execute_native(exe: Path, messages: list[Path], expected: dict[Path, str], timeout: int) -> tuple[int, str]:
    for message in messages:
        mode = int(message.name.split('-')[1])
        payload = bytes([mode]) + bytes(7) + message.read_bytes()
        output = run([exe], data=payload, timeout=timeout)
        got = re.search(r'checksum=(\d+)', output)
        assert got and got.group(1) == expected[message], f'native/{message.name}: {output!r}'
    bad_msg = messages[0]
    wrong_mode = 1 if int(bad_msg.name.split('-')[1]) == 0 else 0
    neg = subprocess.run(
        [str(exe)],
        input=bytes([wrong_mode]) + bytes(7) + bad_msg.read_bytes(),
        capture_output=True,
        timeout=timeout,
    )
    assert neg.returncode != 0, f'negative control unexpectedly exited 0 for {exe}'
    return neg.returncode, f'native-{platform.system().lower()}-{platform.machine()}'


def execute_docker_scratch(
    docker: str,
    build_dir: Path,
    arch: str,
    docker_platform: str,
    messages: list[Path],
    expected: dict[Path, str],
    timeout: int,
) -> tuple[int, str]:
    (build_dir / 'Dockerfile').write_text('FROM scratch\nCOPY verify /verify\nENTRYPOINT ["/verify"]\n', encoding='utf-8')
    tag = f'capnp-static-linux-{arch}:{uuid.uuid4().hex[:8]}'
    run([docker, 'build', '--quiet', '--platform', docker_platform, '-t', tag, build_dir], timeout=max(timeout * 4, 60))

    def run_once(payload: bytes) -> subprocess.CompletedProcess[bytes]:
        cname = f'capnp-musl-{arch}-{uuid.uuid4().hex[:8]}'
        # --init prevents PID 1 in FROM scratch from ignoring unhandled SIGILL/SIGTRAP traps.
        cmd = [docker, 'run', '--rm', '--init', '-i', '--name', cname, '--platform', docker_platform, tag]
        try:
            return subprocess.run(cmd, input=payload, capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            subprocess.run([docker, 'rm', '-f', cname], capture_output=True)
            raise

    try:
        for message in messages:
            mode = int(message.name.split('-')[1])
            payload = bytes([mode]) + bytes(7) + message.read_bytes()
            res = run_once(payload)
            if res.returncode != 0:
                raise RuntimeError(
                    f'docker/{arch}/{message.name} exited {res.returncode}: '
                    f'{res.stdout.decode()!r} {res.stderr.decode()!r}'
                )
            output = res.stdout.decode()
            got = re.search(r'checksum=(\d+)', output)
            assert got and got.group(1) == expected[message], f'docker/{arch}/{message.name}: {output!r}'
        bad_msg = messages[0]
        wrong_mode = 1 if int(bad_msg.name.split('-')[1]) == 0 else 0
        neg = run_once(bytes([wrong_mode]) + bytes(7) + bad_msg.read_bytes())
        assert neg.returncode != 0, f'negative control unexpectedly exited 0 for {arch}'
        host_arch = platform.machine()
        emulated = host_arch not in ARCH_SPECS[arch]['native_machines']
        venue = f'docker FROM scratch ({docker_platform} on {platform.system()} {host_arch}' + (', emulated)' if emulated else ')')
        return neg.returncode, venue
    finally:
        subprocess.run([docker, 'rmi', '-f', tag], capture_output=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swiftc', default=os.environ.get('SWIFTC', 'swiftc'))
    sdk_group = parser.add_mutually_exclusive_group(required=True)
    sdk_group.add_argument(
        '--static-linux-sdk',
        help='Directory containing per-arch musl SDKs (…/swift-linux-musl/musl-1.2.5.sdk)',
    )
    sdk_group.add_argument(
        '--sdk-id',
        help='Explicit Swift SDK ID (e.g. swift-6.4.2-RELEASE_static-linux-0.1.0), resolved via swift sdk configure',
    )
    parser.add_argument('--readers-work', required=True, help='work directory of check-readers.py')
    parser.add_argument('--archs', default='aarch64,x86_64', help='comma-separated architectures (aarch64,x86_64)')
    parser.add_argument('--work', default=None)
    parser.add_argument('--no-execute', action='store_true', help='compile, link and ELF-audit only')
    parser.add_argument('--check-swiftpm', action='store_true', help='also run swift build --swift-sdk for CapnpRuntime')
    parser.add_argument('--timeout', type=int, default=15, help='per-message execution timeout in seconds')
    args = parser.parse_args()

    archs = [a.strip() for a in args.archs.split(',') if a.strip()]
    for arch in archs:
        if arch not in ARCH_SPECS:
            print(f'ERROR: unsupported arch {arch!r}; choose from {sorted(ARCH_SPECS)}', file=sys.stderr)
            return 2

    root = Path(__file__).resolve().parent.parent
    work = Path(args.work or tempfile.mkdtemp(prefix='capnp-static-linux-')).resolve()
    work.mkdir(parents=True, exist_ok=True)
    readers = Path(args.readers_work).resolve()
    swiftc = shutil.which(args.swiftc) or args.swiftc
    bin_dir = Path(swiftc).resolve().parent
    swift_bin = bin_dir / 'swift'
    objdump = shutil.which('llvm-objdump', path=str(bin_dir)) or shutil.which('llvm-objdump')
    assert objdump, 'llvm-objdump not found (ships with Swift.org toolchains)'
    static_linux_sdk = Path(args.static_linux_sdk).resolve() if args.static_linux_sdk else None

    compiler_line = run([swiftc, '--version']).splitlines()[0].strip()
    print(f'Artifacts: {work}', flush=True)
    print(f'Toolchain: {compiler_line}', flush=True)
    print(f'Host:      {platform.system()} {platform.machine()}', flush=True)
    print(f'SDK:       {args.sdk_id or static_linux_sdk}', flush=True)

    sources = sorted(
        p for p in (root / 'Sources/CapnpRuntime').rglob('*.swift')
        if not any(part.endswith('.docc') for part in p.parts)
    )
    generated = readers / 'readers.capnp.swift'
    assert generated.is_file(), f'missing {generated}; run ci/check-readers.py first'
    messages = sorted(readers.glob('message-*.bin'))
    assert len(messages) == 9, f'expected 9 messages in {readers}, found {len(messages)}'

    expected: dict[Path, str] = {}
    if not args.no_execute:
        for message in messages:
            mode = message.name.split('-')[1]
            host_out = run([readers / 'host/verify', message, mode])
            match = re.search(r'checksum=(\d+)', host_out)
            assert match, f'unexpected host output for {message.name}: {host_out!r}'
            expected[message] = match.group(1)

    docker = shutil.which('docker')
    host_is_linux = platform.system() == 'Linux'
    host_machine = platform.machine()

    for arch in archs:
        spec = ARCH_SPECS[arch]
        triple = spec['triple']
        sdk = resolve_arch_sdk(swift_bin, static_linux_sdk, args.sdk_id, arch, triple)
        out = work / arch
        out.mkdir(exist_ok=True)
        resource_dir = sdk / 'usr/lib/swift_static'
        common = [
            swiftc, '-swift-version', '6', '-enable-experimental-feature', 'Lifetimes',
            '-target', triple, '-sdk', str(sdk),
            '-resource-dir', str(resource_dir),
            '-static-stdlib', '-wmo', '-O',
            '-module-cache-path', str(work / 'cache'),
        ]
        run([
            *common, '-strict-memory-safety', '-warnings-as-errors',
            '-parse-as-library', '-emit-module', '-emit-object',
            '-module-name', 'CapnpRuntime',
            '-emit-module-path', out / 'CapnpRuntime.swiftmodule',
            *sources, '-o', out / 'runtime.o',
        ])
        exe = out / 'verify'
        clang_resources = ['-Xclang-linker', '-resource-dir', '-Xclang-linker', str(resource_dir / 'clang')]
        run([
            *common, '-static-executable', *clang_resources,
            '-I', out, generated, root / 'ci/fixtures/verify.swift',
            root / 'ci/fixtures/musl/main.swift', out / 'runtime.o',
            '-o', exe,
        ])
        audit_static_elf(objdump, exe, spec['elf_format'])
        size = exe.stat().st_size
        print(
            f'PASS static-linux ELF ({triple}): {size} bytes, {spec["elf_format"]}, '
            'no INTERP/DYNAMIC/NEEDED',
            flush=True,
        )

        if not args.no_execute:
            if host_is_linux and host_machine in spec['native_machines']:
                neg_rc, venue = execute_native(exe, messages, expected, args.timeout)
            elif docker:
                neg_rc, venue = execute_docker_scratch(
                    docker, out, arch, spec['docker_platform'], messages, expected, args.timeout
                )
            else:
                raise RuntimeError(
                    f'No execution runner for {triple} on {platform.system()} {host_machine} '
                    '(install Docker/OrbStack or pass --no-execute)'
                )
            print(
                f'PASS static-linux exec ({triple}, {venue}): '
                f'{len(messages)}/{len(messages)} messages match host; wrong-mode exits {neg_rc}',
                flush=True,
            )

        if args.check_swiftpm:
            spm_scratch = work / f'spm-{arch}'
            run([
                swift_bin, 'build',
                '--package-path', root,
                '--scratch-path', spm_scratch,
                '--swift-sdk', triple,
                '--product', 'CapnpRuntime',
            ])
            print(f'PASS static-linux SwiftPM ({triple}): CapnpRuntime built', flush=True)

    print('STATIC LINUX CHECK: PASS', flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
