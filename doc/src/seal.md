# The seal and the re-export

## The seal

`checks.bootstrap-seal` asserts, at eval time, that the flake's input
closure is exactly `[nixpkgs]` — every check carries the assertion, so a
straylight input anywhere in the lock fails the whole suite. Two layers:

1. the strict `outputs = { self, nixpkgs }:` signature rejects an
   undeclared input argument outright;
2. with that loosened, the lock-based seal throws, printing the poisoned
   closure — which, in the falsification run, visibly contained
   `modern-nix` itself: the bootstrap recursion, literally re-forming.

Both legs were executed on a scratch branch and the green leg re-proven on
main. If you ever feel the pull to import something straylight into
modern.nix, that is the recursion re-forming — stop and restructure.

## The re-export

The ELF suite ships as a cell — released **downstream**, from
straylight-toolchain, which consumes modern.nix and projects
`packages.elf-suite-static` (pkgsStatic: genuinely static, no interp, no
NEEDED) through a manifest: copy + the Gate-F scrub +
`elf-verify --policy=static` as the projection gate. The suite gates its
own release twice — once at projection (`modern project`'s gate), once in
the `straylight cell release` §12 gate — and rides the normal producer
cycle: build → gate → push → `oci://self` verify → machine lock.

The released cell: `elf_suite_cas` in straylight-toolchain `cells/BUCK`,
digest `a221c3661f3bdea429a3697a4af71125b2b1e0ece991a38808e17a24e4070eec:78`.

modern.nix never learns any of this happened. That is the point.
