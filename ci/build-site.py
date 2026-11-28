#!/usr/bin/env python3
"""Build the documentation site that release.yml publishes to GitHub Pages.

DocC builds the CapnpRuntime catalog for static hosting under /capnproto-swift/ (the Pages
path), with warnings as errors, so a broken symbol link fails the build. In that output every
page has its own index.html, and the root index.html is only DocC's generic shell, so it is
replaced by the hand-written landing page, site/index.html, with @VERSION@ filled in. Every
relative link on the landing page must resolve to a file in the output; a missing one fails.

Usage: ci/build-site.py --out DIR [--version X.Y.Z]   (the version defaults to "main")
Requires a Swift toolchain with the package's swift-docc-plugin dependency resolvable.
"""
import argparse
from html.parser import HTMLParser
from pathlib import Path
import shutil
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
parser.add_argument('--out', required=True, type=Path)
parser.add_argument('--version', default='main', help='shown on the landing page')
args = parser.parse_args()

root = Path(__file__).resolve().parent.parent
out = args.out.resolve()
landing = root / 'site/index.html'


class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []

    def handle_starttag(self, tag, attrs):
        for name, value in attrs:
            if name in ('href', 'src') and value:
                self.links.append(value)


def relative_targets(html):
    """The landing page's links into the site itself (not absolute URLs or fragments)."""
    links = Links()
    links.feed(html)
    return sorted({link.split('#')[0] for link in links.links
                   if not link.startswith(('http://', 'https://', 'mailto:', '#'))})


def resolves(link):
    target = out / link
    return (target / 'index.html').is_file() if link.endswith('/') or link == '' else target.is_file()


# 1. DocC, as Pages serves it.
if out.exists():
    shutil.rmtree(out)
out.parent.mkdir(parents=True, exist_ok=True)  # DocC fails if the output's parent is missing
subprocess.run(['swift', 'package', '--disable-sandbox', '--allow-writing-to-directory', str(out),
                'generate-documentation', '--target', 'CapnpRuntime', '--warnings-as-errors',
                '--transform-for-static-hosting', '--hosting-base-path', 'capnproto-swift',
                '--output-path', str(out)], cwd=root, check=True)
shell = out / 'index.html'
assert shell.is_file() and (out / 'documentation/capnpruntime/index.html').is_file(), \
    f'DocC did not write the expected static layout in {out}'

# 2. The landing page in place of DocC's root shell, then every link it makes must resolve.
html = landing.read_text(encoding='utf-8')
assert '@VERSION@' in html, 'site/index.html has no @VERSION@ placeholder'
shell.write_text(html.replace('@VERSION@', args.version), encoding='utf-8')
(out / '.nojekyll').write_text('')  # serve DocC's files as they are, with no Jekyll pass
broken = [link for link in relative_targets(html) if link and not resolves(link)]
if broken:
    print(f'FAIL: the landing page links to pages the site does not have: {broken}', file=sys.stderr)
    raise SystemExit(1)
pages = sum(1 for _ in out.rglob('index.html'))
print(f'SITE: PASS {out} ({pages} pages, landing page links all resolve, version {args.version})')
