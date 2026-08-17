# The ELF suite

Five C++23 tools over one mmap'd ELF64 reader/writer
(`cpp/include/modern/elf.hpp`) — no libbfd, no libelf, no vendored parser.
Built with the plain nixpkgs stdenv compiler (gcc).

## elf-verify

Declarative predicates over a projected tree. Two named policies:

- `--policy=static` — every ELF is genuinely static (no `PT_INTERP`, no
  `DT_NEEDED`, no `DT_RPATH`), no script wearing an executable's name under
  `bin/`, no `/nix/store` byte anywhere, symlink hygiene (no absolute, no
  dangling).
- `--policy=floor` — every `bin/` ELF's `PT_INTERP` is exactly
  `/lib/ld-std-oci-toolchain.so`, and if any is, the tree carries the
  loader at `lib/` and its closure at `cas/` (the §12 loader-at-/lib
  contract).

Individual predicates compose without a policy: `--require-static`,
`--interp=PATH`, `--needed-closure` (every `DT_NEEDED` resolves within the
tree; `--ignore` for host-provided sonames), `--no-store-refs`,
`--no-scripts-in-bin`, `--check-symlinks`, `--allow GLOB`.

The predicates encode the historical specimen ledger: the pkgsStatic.gzip
bash wrapper wearing an ELF name, the `PT_INTERP`-bearing binary claimed
static, the smuggled store reference. Each is a mandatory falsification in
`cpp/test/run-tests.sh` — the predicate must *fail* on the broken specimen
before its pass counts — and `checks.specimen-pkgsstatic-gzip` re-checks
the real specimen on every pin.

## elf-graft

Interp/rpath/needed surgery with checked pre- and postconditions; patchelf
retired for the graft operations the projection performs. Every operation
is **in-place and the file never grows**: a §12 graft always shrinks (a
store ld.so path is longer than the floor loader path). An over-long
interp is a refused precondition (exit 2, zero bytes mutated); after
surgery the file is re-opened, re-parsed, and the requested state asserted
(exit 3 on failure — demonstrable via the `--test-skip-surgery`
falsification hook). The test suite's runtime leg has the *kernel* execute
a grafted binary via its new `PT_INTERP`; readelf and patchelf serve as
read-back oracles (oracles only, never dependencies).

## elf-census

The byte-level reference walk as data: one deterministic line per entry —
kind, exec bit, interp, `DT_NEEDED`, soname, rpath/runpath, store-ref
count. Census equivalence (byte-identical outputs) is the differential leg
for trees whose producing compilers are not bit-reproducible; `--sizes`
adds sizes for the strict form.

## elf-resolve

`elf-resolve` is the non-mutating dynamic-loader planner for imported rootfs
trees. It begins from declared executable paths, directory surfaces, or globbed
plugin/extension roots and records every reachable `DT_NEEDED` edge together
with the provider selected by the consumer's actual loader context.

The modeled precedence is `DT_RPATH` (when no `DT_RUNPATH`) → inherited RPATH →
declared library path → `DT_RUNPATH` → an explicit normalized `ld.so.cache`
plan → declared default directories. `$ORIGIN` is expanded against the ELF that
declared it; inherited RPATH carries that already-expanded directory into child
resolution. Absolute symlinks are interpreted inside the imported rootfs, never
against the build host. Host-provided SONAMEs such as `libcuda.so.1` must be
declared individually.

The falsification ledger includes duplicate incompatible SONAME providers,
traversal-order changes, malformed cache plans, root-escaping symlinks,
unreachable broken plugins, missing entrypoints, and inherited `$ORIGIN`.
Against the CUDA 13.1 / Triton 26.06 TRT-LLM image, the declared Triton + Python
surface (565 extension modules) resolves 11,775 edges with zero unresolved:
10,156 cache, 1,251 RUNPATH, 190 RPATH, 163 inherited-RPATH, 11 host, and four
declared library-path edges. This plan replaces flatten-and-`autoPatchelf`:
vendor loader topology is preserved and independently replayable.

## elf-replay

`elf-replay ROOT PLAN` is the independent acceptance side of the resolver
contract. It does not search for libraries or share resolution policy with
`elf-resolve`; it parses the emitted claims, re-opens every consumer and
provider, and checks that each root/consumer context has the exact multiset of
`DT_NEEDED` edges present in the ELF. Providers must be root-confined ELF
files, host edges must have no provider, source labels must be known, and every
non-leaf provider must itself appear as a consumer context.

This separation makes the plan falsifiable rather than self-attesting. The
ledger rejects malformed records, invented or omitted dependencies, non-ELF
providers, root escapes, and forged host boundaries before accepting a real
resolver plan.

## The scanner must not carry its needle

Found by the suite's own release: the `/nix/store` search pattern (and the
violation message that names it) lived in `.rodata`, so the suite's static
binaries could never pass their own `--no-store-refs` predicate — a bare
literal is unscrubabble, since the §12 scrub is length-preserving and only
rewrites *hashed* store paths. The needle is byte-shifted (+1) in the
binary and decoded at runtime — the same discipline as nix's own reference
scanner, which stores hashes, not paths.
