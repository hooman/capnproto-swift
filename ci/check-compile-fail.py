#!/usr/bin/env python3
"""Compile-fail verification harness for CapnpRuntime and generated readers.

Proves compile-time invariants (nonescaping lifetimes, Arena noncopyability,
non-Sendable surface, strict memory safety) by compiling single-purpose Swift
fixtures to SIL (-emit-sil) and checking exit codes plus stderr diagnostics.
Also runs upstream watchlist tripwires (--mode tripwire / --mode all).
"""

import argparse
from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

CONTRACT_DIRS = ('controls', 'lifetimes', 'ownership', 'concurrency', 'safety')
TRIPWIRE_DIRS = ('tripwires',)
ALL_DIRS = CONTRACT_DIRS + TRIPWIRE_DIRS

STRICT_UPCOMING_SHARED = (
    'ExistentialAny',
    'MemberImportVisibility',
    'InferIsolatedConformances',
    'NonisolatedNonsendingByDefault',
    'ImmutableWeakCaptures',
)

DIRECTIVE_PREFIX_RE = re.compile(r'^//\s*(?:EXPECT\b|EXPECT[-_]|REQUIRES\b|FLAGS\b)')
EXPECT_PASS_RE = re.compile(r'^// EXPECT-PASS$')
EXPECT_ERROR_RE = re.compile(r'^// EXPECT-ERROR:\s*(.+)$')
REQUIRES_RE = re.compile(r'^// REQUIRES:\s*(\S+)$')
FLAGS_RE = re.compile(r'^// FLAGS:\s*(.+)$')


class DirectiveError(ValueError):
    pass


@dataclass
class FixtureSpec:
    path: Path
    rel_path: str
    category: str  # 'contract' or 'tripwire'
    expect_pass: bool = False
    expect_errors: list[tuple[str, re.Pattern[str]]] = field(default_factory=list)
    requires_generated: bool = False
    extra_flags: list[str] = field(default_factory=list)


@dataclass
class RunResult:
    ok: bool
    status: str  # 'pass', 'skip', 'unexpected-pass', 'unexpected-error', 'regex-mismatch'
    detail: str = ''
    command: list[str] = field(default_factory=list)
    stderr: str = ''


def parse_directives(text: str, *, path: Path, rel_path: str, category: str) -> FixtureSpec:
    spec = FixtureSpec(path=path, rel_path=rel_path, category=category)
    for lineno, raw_line in enumerate(text.splitlines(), start=1):
        line = raw_line.strip()
        if not line:
            continue
        if not line.startswith('//'):
            break
        if not DIRECTIVE_PREFIX_RE.match(line):
            continue

        if EXPECT_PASS_RE.match(line):
            if spec.expect_pass:
                raise DirectiveError(f'{rel_path}:{lineno}: duplicate EXPECT-PASS')
            spec.expect_pass = True
        elif m := EXPECT_ERROR_RE.match(line):
            pattern_text = m.group(1).strip()
            if not pattern_text:
                raise DirectiveError(f'{rel_path}:{lineno}: empty EXPECT-ERROR pattern')
            try:
                compiled = re.compile(pattern_text, re.I | re.M)
            except re.error as err:
                raise DirectiveError(f'{rel_path}:{lineno}: invalid regex {pattern_text!r}: {err}')
            spec.expect_errors.append((pattern_text, compiled))
        elif m := REQUIRES_RE.match(line):
            token = m.group(1)
            if token != 'generated':
                raise DirectiveError(f'{rel_path}:{lineno}: unknown REQUIRES token {token!r}')
            if spec.requires_generated:
                raise DirectiveError(f'{rel_path}:{lineno}: duplicate REQUIRES: generated')
            spec.requires_generated = True
        elif m := FLAGS_RE.match(line):
            spec.extra_flags.extend(shlex.split(m.group(1)))
        else:
            raise DirectiveError(f'{rel_path}:{lineno}: malformed directive {line!r}')

    if spec.expect_pass and spec.expect_errors:
        raise DirectiveError(f'{rel_path}: cannot declare both EXPECT-PASS and EXPECT-ERROR')
    if not spec.expect_pass and not spec.expect_errors:
        raise DirectiveError(f'{rel_path}: must declare EXPECT-PASS or at least one EXPECT-ERROR')
    return spec


def discover_fixtures(fixtures_dir: Path, mode: str) -> list[FixtureSpec]:
    if not fixtures_dir.is_dir():
        raise DirectiveError(f'Fixtures directory does not exist: {fixtures_dir}')

    specs: list[FixtureSpec] = []
    for file_path in sorted(fixtures_dir.rglob('*.swift')):
        rel = file_path.relative_to(fixtures_dir)
        parts = rel.parts
        if len(parts) != 2 or parts[0] not in ALL_DIRS:
            raise DirectiveError(
                f'Fixture {rel} must live directly inside one of {ALL_DIRS}')
        subdir = parts[0]
        category = 'tripwire' if subdir in TRIPWIRE_DIRS else 'contract'
        if mode == 'contract' and category != 'contract':
            continue
        if mode == 'tripwire' and category != 'tripwire':
            continue
        specs.append(
            parse_directives(
                file_path.read_text(encoding='utf-8'),
                path=file_path,
                rel_path=rel.as_posix(),
                category=category,
            )
        )
    return specs


def resolve_target_flags(swiftc: str, work: Path) -> list[str]:
    info_proc = subprocess.run([swiftc, '-print-target-info'], capture_output=True, text=True)
    if info_proc.returncode != 0:
        raise RuntimeError(f'swiftc -print-target-info failed:\n{info_proc.stderr}')
    triple = json.loads(info_proc.stdout)['target']['triple']
    if 'apple-macos' in triple:
        triple = triple.split('-apple-')[0] + '-apple-macos27'

    flags = [
        '-swift-version', '6',
        '-enable-experimental-feature', 'Lifetimes',
        '-strict-memory-safety',
        '-warnings-as-errors',
        '-module-cache-path', str(work / 'cache'),
        '-target', triple,
    ]
    for feature in STRICT_UPCOMING_SHARED:
        flags += ['-enable-upcoming-feature', feature]

    if 'apple-macos' in triple:
        sdk = os.environ.get('SDKROOT')
        if not sdk:
            sdk_proc = subprocess.run(
                ['xcrun', '--sdk', 'macosx', '--show-sdk-path'],
                capture_output=True,
                text=True,
                check=True,
            )
            sdk = sdk_proc.stdout.strip()
        flags += ['-sdk', sdk]
    return flags


def build_runtime_module(root: Path, swiftc: str, base_flags: list[str], work: Path) -> Path:
    runtime_dir = work / 'runtime'
    runtime_dir.mkdir(parents=True, exist_ok=True)
    sources = sorted(
        p for p in (root / 'Sources/CapnpRuntime').rglob('*.swift')
        if not any(part.endswith('.docc') for part in p.parts)
    )
    if not sources:
        raise RuntimeError('No CapnpRuntime sources found')
    cmd = [
        swiftc,
        *base_flags,
        '-enable-upcoming-feature', 'InternalImportsByDefault',
        '-O', '-wmo', '-parse-as-library',
        '-emit-module',
        '-module-name', 'CapnpRuntime',
        '-emit-module-path', str(runtime_dir / 'CapnpRuntime.swiftmodule'),
        *[str(s) for s in sources],
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f'Failed to build CapnpRuntime module:\n{proc.stdout}\n{proc.stderr}')
    return runtime_dir


def run_fixture(
    spec: FixtureSpec,
    *,
    swiftc: str,
    base_flags: list[str],
    runtime_dir: Path,
    generated: Path | None,
    sil_dir: Path,
    log_dir: Path,
) -> RunResult:
    if spec.requires_generated and generated is None:
        return RunResult(ok=True, status='skip', detail='no --generated')

    slug = re.sub(r'[^A-Za-z0-9._-]+', '_', spec.rel_path)
    cmd = [swiftc, *base_flags]
    # D4b: SwiftGenerator currently emits `import CapnpRuntime` rather than `public import`.
    # Keep InternalImportsByDefault active everywhere else; omit only when co-compiling generated code.
    if not spec.requires_generated:
        cmd += ['-enable-upcoming-feature', 'InternalImportsByDefault']
    if spec.requires_generated:
        cmd.append('-wmo')
    cmd += [
        *spec.extra_flags,
        '-I', str(runtime_dir),
        '-parse-as-library',
        '-emit-sil',
        '-o', str(sil_dir / f'{slug}.sil'),
    ]
    if spec.requires_generated:
        assert generated is not None
        cmd.append(str(generated))
    cmd.append(str(spec.path))

    proc = subprocess.run(cmd, capture_output=True, text=True)
    stderr = proc.stderr
    if stderr:
        (log_dir / f'{slug}.stderr').write_text(stderr, encoding='utf-8')

    if spec.expect_pass:
        if proc.returncode == 0:
            return RunResult(ok=True, status='pass', command=cmd, stderr=stderr)
        return RunResult(
            ok=False,
            status='unexpected-error',
            detail=f'expected pass, exited with code {proc.returncode}',
            command=cmd,
            stderr=stderr,
        )

    if proc.returncode == 0:
        expected = ', '.join(f'/{p}/' for p, _ in spec.expect_errors)
        if spec.category == 'tripwire':
            detail = (
                f'TRIPWIRE FIRED (unexpected pass; expected {expected}; '
                'review roadmap/swift-evolution-watch.md)'
            )
        else:
            detail = f'unexpected-pass (expected error matching {expected})'
        return RunResult(ok=False, status='unexpected-pass', detail=detail, command=cmd, stderr=stderr)

    diagnostic_text = '\n'.join(
        line for line in stderr.splitlines() if not re.match(r'^\s*\d*\s*\|', line)
    )
    for pattern_text, regex in spec.expect_errors:
        if not regex.search(diagnostic_text):
            return RunResult(
                ok=False,
                status='regex-mismatch',
                detail=f'expected diagnostic matching /{pattern_text}/',
                command=cmd,
                stderr=stderr,
            )
    return RunResult(ok=True, status='pass', command=cmd, stderr=stderr)


def run_self_test(swiftc: str, base_flags: list[str], runtime_dir: Path, work: Path) -> None:
    bad_inputs = [
        ('missing-expect.swift', 'private func f() -> Int { 1 }\n'),
        ('both-expect.swift', '// EXPECT-PASS\n// EXPECT-ERROR: foo\nprivate func f() {}\n'),
        ('empty-error.swift', '// EXPECT-ERROR:   \nprivate func f() {}\n'),
        ('typo-directive.swift', '// EXPECT_ERROR: foo\nprivate func f() {}\n'),
        ('bad-requires.swift', '// REQUIRES: bogus\n// EXPECT-PASS\nprivate func f() {}\n'),
    ]
    for name, content in bad_inputs:
        try:
            parse_directives(content, path=Path(name), rel_path=name, category='contract')
        except DirectiveError:
            continue
        raise RuntimeError(f'Self-test failed: parser accepted invalid fixture {name}')

    st_dir = work / 'self-test'
    st_sil = st_dir / 'sil'
    st_log = st_dir / 'logs'
    st_sil.mkdir(parents=True, exist_ok=True)
    st_log.mkdir(parents=True, exist_ok=True)

    cases = [
        (
            'st-unexpected-pass.swift',
            '// EXPECT-ERROR: anything\nprivate func ok() -> Int { 1 }\n',
            'unexpected-pass',
        ),
        (
            'st-regex-mismatch.swift',
            '// EXPECT-ERROR: __NEVER_MATCHES__\nprivate func bad() -> Int { "nope" }\n',
            'regex-mismatch',
        ),
        (
            'st-unexpected-error.swift',
            '// EXPECT-PASS\nprivate func bad() -> Int { "nope" }\n',
            'unexpected-error',
        ),
    ]
    for filename, source, expected_status in cases:
        file_path = st_dir / filename
        file_path.write_text(source, encoding='utf-8')
        spec = parse_directives(source, path=file_path, rel_path=f'self-test/{filename}', category='contract')
        result = run_fixture(
            spec,
            swiftc=swiftc,
            base_flags=base_flags,
            runtime_dir=runtime_dir,
            generated=None,
            sil_dir=st_sil,
            log_dir=st_log,
        )
        if result.ok or result.status != expected_status:
            raise RuntimeError(
                f'Self-test failed for {filename}: expected failure {expected_status!r}, '
                f'got ok={result.ok} status={result.status!r} stderr={result.stderr!r}'
            )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swiftc', default=os.environ.get('SWIFTC', 'swiftc'))
    parser.add_argument('--mode', choices=('contract', 'tripwire', 'all'), default='contract')
    parser.add_argument('--work', default=None)
    parser.add_argument('--runtime-module-dir', default=None)
    parser.add_argument('--generated', default=None)
    parser.add_argument('--fixtures', default=None)
    parser.add_argument('--filter', default=None)
    parser.add_argument('--no-self-test', action='store_true')
    parser.add_argument('--self-test-only', action='store_true')
    args = parser.parse_args()

    root = Path(__file__).resolve().parent.parent
    fixtures_dir = Path(args.fixtures).resolve() if args.fixtures else (root / 'ci/compile-fail')
    work = Path(args.work or tempfile.mkdtemp(prefix='capnp-compile-fail-')).resolve()
    sil_dir = work / 'sil'
    log_dir = work / 'logs'
    sil_dir.mkdir(parents=True, exist_ok=True)
    log_dir.mkdir(parents=True, exist_ok=True)

    swiftc = shutil.which(args.swiftc) or args.swiftc
    generated = Path(args.generated).resolve() if args.generated else None
    if generated is not None and not generated.is_file():
        print(f'ERROR: --generated file does not exist: {generated}', file=sys.stderr)
        return 2

    try:
        base_flags = resolve_target_flags(swiftc, work)
        if args.runtime_module_dir:
            runtime_dir = Path(args.runtime_module_dir).resolve()
            if not (runtime_dir / 'CapnpRuntime.swiftmodule').exists():
                print(
                    f'ERROR: CapnpRuntime.swiftmodule not found in {runtime_dir}',
                    file=sys.stderr,
                )
                return 2
        else:
            runtime_dir = build_runtime_module(root, swiftc, base_flags, work)

        self_test_label = 'SKIP'
        if args.self_test_only or (not args.no_self_test and not args.filter):
            run_self_test(swiftc, base_flags, runtime_dir, work)
            self_test_label = 'PASS'
            if args.self_test_only:
                print(f'COMPILE-FAIL SELF-TEST: PASS (artifacts: {work})', flush=True)
                return 0

        specs = discover_fixtures(fixtures_dir, args.mode)
    except DirectiveError as err:
        print(f'ERROR (fixture directive): {err}', file=sys.stderr)
        return 2
    except Exception as err:
        print(f'ERROR: {err}', file=sys.stderr)
        return 2

    if args.filter:
        specs = [s for s in specs if args.filter in s.rel_path]
    if not specs:
        print(f'ERROR: 0 fixtures selected (mode={args.mode}, filter={args.filter!r})', file=sys.stderr)
        return 2

    executed = 0
    passed = 0
    failed = 0
    skipped = 0
    for spec in specs:
        res = run_fixture(
            spec,
            swiftc=swiftc,
            base_flags=base_flags,
            runtime_dir=runtime_dir,
            generated=generated,
            sil_dir=sil_dir,
            log_dir=log_dir,
        )
        if res.status == 'skip':
            skipped += 1
            print(f'SKIP  [{spec.category}] {spec.rel_path} ({res.detail})', flush=True)
            continue
        executed += 1
        if res.ok:
            passed += 1
            print(f'PASS  [{spec.category}] {spec.rel_path}', flush=True)
        else:
            failed += 1
            print(f'FAIL  [{spec.category}] {spec.rel_path} — {res.detail}', flush=True)
            print('  cmd: ' + ' '.join(shlex.quote(c) for c in res.command), flush=True)
            if res.stderr:
                lines = res.stderr.splitlines()
                for line in lines[:40]:
                    print('  | ' + line, flush=True)
                if len(lines) > 40:
                    print(f'  | ... ({len(lines) - 40} more lines in {log_dir})', flush=True)

    if executed == 0:
        print('ERROR: all selected fixtures were skipped (executed=0)', file=sys.stderr)
        return 2
    if generated is not None and skipped != 0:
        print(f'ERROR: unexpected skipped={skipped} when --generated was provided', file=sys.stderr)
        return 2

    verdict = 'PASS' if failed == 0 else 'FAIL'
    print(
        f'COMPILE-FAIL ({args.mode}): {verdict} — '
        f'executed={executed} passed={passed} failed={failed} skipped={skipped} '
        f'(self-test: {self_test_label})',
        flush=True,
    )
    return 0 if failed == 0 else 1


if __name__ == '__main__':
    raise SystemExit(main())
