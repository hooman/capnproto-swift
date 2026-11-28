#!/usr/bin/env python3
"""Write the README's data badges into the documentation site, as shields.io endpoint files.

- badges/coverage.json: CapnpRuntime line coverage from `swift test --enable-code-coverage`
  (SwiftPM's coverage JSON, files under Sources/CapnpRuntime only, as the README states it).
- badges/capnp.json: the `capnp` versions the gates tested against: those given with
  --capnp-version (release.yml passes CI's Linux and macOS versions), else the local one.

release.yml runs this after building the site, so the badges describe the released tag. The
README draws them with https://img.shields.io/endpoint?url=<site>/badges/<name>.json.

Usage: ci/site-badges.py --out SITE_DIR [--skip-tests] (reuse the last coverage run)
"""
import argparse
import json
from pathlib import Path
import re
import subprocess

parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
parser.add_argument('--out', required=True, type=Path)
parser.add_argument('--skip-tests', action='store_true')
parser.add_argument('--capnp-version', action='append', default=[],
                    help='a tested capnp version; repeatable (default: `capnp --version`)')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent

if not args.skip_tests:
    subprocess.run(['swift', 'test', '--enable-code-coverage'], cwd=root, check=True)
path = Path(subprocess.run(['swift', 'test', '--show-codecov-path'], cwd=root, check=True,
                           capture_output=True, text=True).stdout.strip())
report = json.loads(path.read_text())
runtime = str(root / 'Sources/CapnpRuntime') + '/'
files = [f for f in report['data'][0]['files'] if f['filename'].startswith(runtime)]
assert files, f'no CapnpRuntime files in {path}'
lines = sum(f['summary']['lines']['count'] for f in files)
covered = sum(f['summary']['lines']['covered'] for f in files)
percent = 100 * covered / lines
# Rounded to a tenth, as llvm-cov reports it and the README quotes it.
shown = f'{percent:.1f}%'

versions = [v for v in args.capnp_version if v] or [
    subprocess.run(['capnp', '--version'], check=True, capture_output=True, text=True).stdout]
tested = []
for text in versions:
    match = re.search(r'(\d+\.\d+(?:\.\d+)?)', text)
    assert match, f'not a capnp version: {text!r}'
    tested.append(match.group(1))
tested = sorted(set(tested), key=lambda v: [int(x) for x in v.split('.')])

badges = args.out / 'badges'
badges.mkdir(parents=True, exist_ok=True)
color = 'brightgreen' if percent >= 95 else 'green' if percent >= 85 else 'yellow'
(badges / 'coverage.json').write_text(json.dumps(
    {'schemaVersion': 1, 'label': 'coverage', 'message': shown, 'color': color}) + '\n')
(badges / 'capnp.json').write_text(json.dumps(
    {'schemaVersion': 1, 'label': "Cap'n Proto", 'message': 'tested with ' + ', '.join(tested),
     'color': 'blue'}) + '\n')
print(f'BADGES: PASS coverage {shown} ({covered}/{lines} lines), capnp {", ".join(tested)}')
