# Releasing

A release is one run of the `release` workflow from `main`. It validates, reruns every CI gate
on that commit, creates the tag and GitHub Release with an attested source archive, and then
publishes that commit's documentation to <https://hooman.github.io/capnproto-swift/>. Tags are
immutable: a bad release is fixed forward with a new version, never retagged.

Only the maintainer starts a release. An agent prepares it, through the PRs below, and checks
it afterwards.

## 1. Docs before the release

Update and merge the docs first, in a PR like any other change:

- `CHANGELOG.md`: everything since the last tag, under `## [Unreleased]`.
- `README.md`: the release row, the dependency pin (`.upToNextMinor(from: "X.Y.0")`), and
  every figure the gates produce. Regenerate them; don't edit numbers by hand.
- The DocC catalog (`Sources/CapnpRuntime/CapnpRuntime.docc`): new API, articles, and the
  tutorial's dependency pin.
- `Sources/capnpc-swift/main.swift`: `--version` prints the new version.

The release refuses to start unless `capnpc-swift --version` names the version, and README,
CHANGELOG and the DocC catalog each changed since the previous tag (`ci/check-release.sh`).
If a release really needs no README or DocC change, its CHANGELOG entry says so on a line
starting `Docs: unchanged`, with the reason.

## 2. The release PR

One small PR renames `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`, with the day you will
run the release, and opens a new, empty `## [Unreleased]` above it. Before merging it, run
the release check locally:

```sh
VERSION=X.Y.Z ci/check-release.sh
```

## 3. Run it

```sh
gh workflow run release.yml -R hooman/capnproto-swift -f version=X.Y.Z
gh run watch -R hooman/capnproto-swift "$(gh run list -R hooman/capnproto-swift --workflow release.yml -L 1 --json databaseId --jq '.[0].databaseId')"
```

The jobs run in order: `validate`, `ci` (the whole `embedded-clean` workflow), `publish`
(the tag, the release and its attestation) and `site` (GitHub Pages). If `site` fails, the
release already exists: fix the cause on `main` if needed, then rerun only that job.

## 4. Check it

```sh
gh release view X.Y.Z -R hooman/capnproto-swift
gh release download X.Y.Z -R hooman/capnproto-swift -p 'capnproto-swift-X.Y.Z.tar.gz*'
shasum -a 256 -c capnproto-swift-X.Y.Z.tar.gz.sha256
gh attestation verify capnproto-swift-X.Y.Z.tar.gz -R hooman/capnproto-swift
curl -fsS https://hooman.github.io/capnproto-swift/ | grep -c 'Version X.Y.Z'
curl -fsS https://hooman.github.io/capnproto-swift/badges/coverage.json
```

Then open the site: the landing page, the API reference, both articles and the tutorial.
Swift Package Index picks up the new tag by itself.

## One-time setup

As of 2026-11-28, the tag ruleset is in place; the other three are still to do.

- Tag ruleset `release-tags`: tags can be created, never moved or deleted.
- GitHub Pages with source **GitHub Actions** (`gh api -X POST repos/hooman/capnproto-swift/pages -f build_type=workflow`),
  and the repository's homepage set to the site.
- The package listed on the Swift Package Index (for the Swift-version and platform badges).
