# modern.nix

The dependency-free bootstrap layer of the sovereign build.

**The constraint (load-bearing):** this flake's inputs are `nixpkgs` and
nothing else, forever — enforced by `checks.bootstrap-seal`. modern.nix makes
the toolchain, which compiles libmodern-cpp; all of the bootstrap is like
that. It hosts its **own** tools, built from plain nixpkgs stdenv/GHC.
Downstream repos may re-export these tools as cells; modern.nix never learns
cells exist.

## The ELF suite (C++23, `packages.elf-suite`)

Our own mmap'd ELF64 reader/writer (`cpp/include/modern/elf.hpp`) — no
libbfd, no libelf, no vendored parser. Built with the plain nixpkgs stdenv
compiler (gcc).

- **`elf-verify`** — declarative predicates over a projected tree:
  `--policy=static` (no PT_INTERP, no DT_NEEDED, no scripts-in-bin, no
  `/nix/store` byte anywhere, symlink hygiene), `--policy=floor` (the §12
  loader contract), `--needed-closure` (every DT_NEEDED resolves within the
  tree), all composable as individual flags. Built for the historical
  specimen ledger: the bash wrapper wearing an ELF name (pkgsStatic.gzip),
  the PT_INTERP-bearing binary claimed static, the smuggled store reference.
- **`elf-graft`** — interp/rpath/needed surgery with checked pre- and
  postconditions. In-place and length-preserving: the file never grows
  (`§12` grafts always shrink); an over-long interp is a refused
  precondition, a silent misgraft is caught by re-parse. Retires patchelf.
- **`elf-census`** — the byte-level reference walk as data: one deterministic
  line per entry (kind, interp, NEEDED, soname, rpath, store-ref count).
  Census equivalence is the differential leg for cells whose compiler builds
  are not bit-reproducible.

## Tests

`nix flake check` runs the falsification harness (`cpp/test/run-tests.sh`):
every predicate is shown to **fail** on a broken specimen before its pass
counts, with readelf/patchelf as differential oracles (oracles only — never
dependencies). `checks.specimen-pkgsstatic-gzip` checks the suite against
the real historical specimen on the current pin.

## `modern project` (Haskell, `packages.modern`)

Typed projection: a JSON manifest (sources, copy/prune, strip, de-shell
symlinks, settings rewrites, the length-preserving Gate-F scrub) in, a §12
tree out, the gate enforced by calling the ELF suite. A poisoned manifest —
a smuggled store ref, a wrapper script under `bin/` — fails with a typed
error naming the file. Built from nixpkgs GHC + Shelly/aeson only; source
paths are injected by the caller (downstream repos own their cell manifests,
so no straylight path ever appears here).

Proven: the canonical `cxx-clang22-libstdcxx-musl` cell projected through
`modern project` reproduces its locked BLAKE3 REAPI root digest
(`9bad8764…:319`) bit-for-bit.

## `lib.mkTypedDerivation`

The Shelly builder pattern: `buildCommand = runghc <script> <args.json> $out`
— arguments are data (aeson), process work is Shelly, nothing is spliced
into a bash string. `checks.typed-derivation-demo` is the working model.
