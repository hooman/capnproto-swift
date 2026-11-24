# Vendored upstream corpus

These files are copied unmodified from [Cap'n Proto](https://github.com/capnproto/capnproto)
at tag `v1.0.1` (commit `c7f810a76ca88ff28613fa165927e0269255aab0`), path `c++/src/capnp/`.
They are MIT licensed, copyright Sandstorm Development Group, Inc. and contributors; the
license notice is kept in `test.capnp`.

- `test.capnp`: upstream's own schema test corpus.
- `testdata/packed`, `testdata/short.txt`, `testdata/binary`: files that `test.capnp` embeds
  (`embed "testdata/..."`), needed for it to compile.

`ci/check-readers.py` copies them into its work directory and rewrites one line,
`using Cxx = import "c++.capnp";`, to `import "/capnp/c++.capnp"`, so the installed
standard schemas resolve without a duplicate-ID error. It then records the generator's
accept/reject verdict for each top-level declaration in
`../golden/test-capnp-verdicts.expected`.

`v1.0.1` matches the `capnp` that Ubuntu ships to the Linux CI job; a newer `test.capnp`
may use syntax that `capnp` cannot compile.
