#!/usr/bin/env python3
"""Build and run the DocC tutorial's code against this checkout.

No other gate compiles the tutorial: DocC shows its files as text, and every other check skips
`*.docc`. This script makes the tutorial's final Package.swift (03-Package.swift) depend on
this checkout by path, adds its schema (02-Person.capnp), and for each main.swift step builds
and runs the package. Its output must equal the step's shown output, except the `$ swift run`
prompt line and trailing spaces, which editors strip.

Usage: ci/check-tutorial.py [--work DIR]. Requires a Swift toolchain and `capnp` (the
package's build-tool plugin runs it).
"""
import argparse
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
parser.add_argument('--work', type=Path)
args = parser.parse_args()

root = Path(__file__).resolve().parent.parent
resources = root / 'Sources/CapnpRuntime/CapnpRuntime.docc/Tutorials/GettingStartedWithCapnProto/Resources'
tutorial = resources.parent / 'GettingStarted.tutorial'
work = (args.work or Path(tempfile.mkdtemp(prefix='capnp-tutorial-'))).resolve()
package = work / 'GettingStarted'
shutil.rmtree(package, ignore_errors=True)
(package / 'Sources/GettingStarted').mkdir(parents=True)

# The step pairs, as the tutorial shows them: each main.swift step, then its output.
shown = re.findall(r'@Code\(name: "([^"]+)", file: "([^"]+)"\)', tutorial.read_text())
steps = [(code, output) for (name, code), (oname, output) in zip(shown, shown[1:])
         if name == 'main.swift' and oname == 'Output']
assert len(steps) == 3, f'expected 3 main.swift steps with output, found {steps}'

manifest = (resources / '03-Package.swift').read_text()
dependency = re.compile(r'\.package\(url: "https://github\.com/hooman/capnproto-swift", [^)]*\)\)')
assert dependency.search(manifest), '03-Package.swift no longer depends on capnproto-swift by URL'
(package / 'Package.swift').write_text(
    dependency.sub(f'.package(name: "capnproto-swift", path: "{root}")', manifest))
shutil.copy(resources / '02-Person.capnp', package / 'Sources/GettingStarted/Person.capnp')


def lines(text):
    return [line.rstrip() for line in text.strip().splitlines() if not line.startswith('$ ')]


failed = False
for code, output in steps:
    shutil.copy(resources / code, package / 'Sources/GettingStarted/main.swift')
    result = subprocess.run(['swift', 'run', '-q', 'GettingStarted'], cwd=package,
                            capture_output=True, text=True)
    expected = lines((resources / output).read_text())
    got = lines(result.stdout)
    if result.returncode or got != expected:
        failed = True
        print(f'FAIL {code}: exit {result.returncode}\n  expected {expected}\n  got      {got}\n'
              f'{result.stderr[-2000:]}', file=sys.stderr)
    else:
        print(f'PASS {code} -> {output} ({len(got)} lines)')
if failed:
    raise SystemExit(1)
print(f'TUTORIAL CHECK: PASS ({len(steps)} steps)')
