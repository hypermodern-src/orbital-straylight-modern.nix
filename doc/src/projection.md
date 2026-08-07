# Typed projection

`modern project MANIFEST --out DIR` interprets a declarative manifest into
a §12 tree and enforces its gate by calling `elf-verify`. This replaced the
ad-hoc projection stratum in straylight-toolchain (the de-shell/graft/
reshape/prune `runCommand` bash) in the MODERN-d flip.

## The manifest

JSON: a `name`, a `sources` map (symbolic name → tree path; store paths are
injected by the *caller* — downstream repos own their manifests, so no
straylight path ever appears in modern.nix), an `ops` list, and an optional
`gate`.

| op | semantics |
| --- | --- |
| `copy` | whole source tree, `cp -r`: symlinks preserved, exec bits preserved, **hardlinks split** (a REAPI Directory has no hardlink concept); `deref` for `cp -rL` |
| `copyPath` | one path out of a source (the keep-list prune pattern); `optional`, `deref`, `rename` |
| `remove` | delete entries matching root-relative globs |
| `strip` | run a manifest-declared `strip` tool over enumerated paths |
| `symlink` | create/replace a symlink — the de-shell primitive |
| `rewrite` | literal string replacements in one file (GHC settings repointing) |
| `scrub` | the Gate-F de-nix: store literals → zeros, closure hashes → placeholder, volatile build dirs zeroed — all length-preserving |
| `mkdir` | ensure a directory |

A poisoned manifest — a smuggled store ref, a wrapper script under `bin/` —
fails with a **typed error naming the file** (human line + JSON object).

## The differential

Before the flip, every canonical cell was re-projected through
`modern project` and compared against its locked BLAKE3 REAPI root digest
(`straylight reapi digest` as oracle): **13/13 legs bit-for-bit
identical** — 8 toolchain cells, 2 libmodern cells, and the 3 intermediate
de-shell stages. The full table and driver live in `doc/differential.md`.
Three fidelity bugs were found *by* the differential (hardlink aliasing,
top-level symlink deref, an incomplete de-shell table) — two of them caught
by the gate before the digest comparison could even run.

## mkTypedDerivation

`lib.mkTypedDerivation`: a derivation whose `buildCommand` is
`runghc <script> <args.json> $out` — arguments are data (aeson), process
work is Shelly, nothing is spliced into a bash string.
`checks.typed-derivation-demo` is the working model.

`lib.project` is the nix face of `modern project` itself: manifest attrset
in, projected tree out, `allowedReferences = []` by default (the
floor-cells-standalone principle rides the derivation).
