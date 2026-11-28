#!/usr/bin/env bash
# Release preconditions that release.yml's validate job runs before anything is tagged, kept
# here so they run locally too (RELEASING.md):
#
# 1. `capnpc-swift --version` prints the version being released (Sources/capnpc-swift/main.swift).
# 2. Docs before release: README.md, CHANGELOG.md and the DocC catalog have each changed since
#    the previous tag. A release that truly needs no README or DocC change says so with a line
#    `Docs: unchanged` (and why) in its CHANGELOG entry; the CHANGELOG itself must change.
#
# Usage: VERSION=X.Y.Z ci/check-release.sh [PREVIOUS_TAG]   (default: the latest tag before HEAD)
set -euo pipefail
cd "$(dirname "$0")/.."
: "${VERSION:?set VERSION=X.Y.Z}"
previous="${1:-$(git describe --tags --abbrev=0 HEAD 2>/dev/null || true)}"
fail=0

if ! grep -qF "print(\"capnpc-swift $VERSION\")" Sources/capnpc-swift/main.swift; then
    echo "::error::capnpc-swift --version does not print $VERSION (Sources/capnpc-swift/main.swift)"
    fail=1
fi

if [ -n "$previous" ]; then
    entry="$(awk -v v="$VERSION" '$0 ~ "^## \\[" v "\\]" { on = 1; next } on && /^## \[/ { exit } on { print }' CHANGELOG.md)"
    unchanged=()
    for path in CHANGELOG.md README.md Sources/CapnpRuntime/CapnpRuntime.docc; do
        git diff --quiet "$previous" HEAD -- "$path" && unchanged+=("$path")
    done
    for path in "${unchanged[@]+"${unchanged[@]}"}"; do
        if [ "$path" != CHANGELOG.md ] && grep -q '^Docs: unchanged' <<<"$entry"; then
            echo "note: $path unchanged since $previous, as the CHANGELOG entry says"
        else
            echo "::error::$path has not changed since $previous: update the docs before releasing (RELEASING.md)"
            fail=1
        fi
    done
fi

[ "$fail" -eq 0 ] && echo "RELEASE CHECK: PASS $VERSION (docs checked against ${previous:-no earlier tag})"
exit "$fail"
