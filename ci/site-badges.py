#!/usr/bin/env python3
"""Write the README's data badges into the documentation site, as shields.io endpoint files.

- badges/coverage.json: CapnpRuntime line coverage from `swift test --enable-code-coverage`
  (SwiftPM's coverage JSON, files under Sources/CapnpRuntime only, as the README states it).
- badges/capnp.json: the `capnp` version the run used, which check-readers tests against.

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

version = subprocess.run(['capnp', '--version'], check=True, capture_output=True, text=True).stdout
match = re.search(r'(\d+\.\d+(?:\.\d+)?)', version)
assert match, f'unexpected capnp --version output: {version!r}'

badges = args.out / 'badges'
badges.mkdir(parents=True, exist_ok=True)
color = 'brightgreen' if percent >= 95 else 'green' if percent >= 85 else 'yellow'
(badges / 'coverage.json').write_text(json.dumps(
    {'schemaVersion': 1, 'label': 'coverage', 'message': shown, 'color': color}) + '\n')
(badges / 'capnp.json').write_text(json.dumps(
    {'schemaVersion': 1, 'label': "Cap'n Proto", 'message': f'tested with {match.group(1)}',
     'color': 'blue'}) + '\n')
print(f'BADGES: PASS coverage {shown} ({covered}/{lines} lines), capnp {match.group(1)}')
