# The Gate C differential — every canonical cell through `modern project`

2026-08-06. Every canonical cell re-projected through `modern project`
(declarative manifests over the same store inputs the ad-hoc stratum used)
and digested with `straylight reapi digest --root` (the PROD-4 oracle;
`straylight cell lock --check` FRESH 8/8 before and after).

**Result: 13/13 legs bit-for-bit IDENTICAL — including the three
intermediate de-shell stages. No census-equivalence fallback was needed:
the projection stratum is fully deterministic given its stage inputs.**
(The known non-determinism lives in the *compiler builds* underneath the
`*-selfcontained` stage inputs, which this differential holds fixed; rust
and ghc digests moved in PROD-4 for exactly that reason.)

| cell            | leg                                  | digest (BLAKE3 REAPI root)  | vs        | result |
|-----------------|--------------------------------------|-----------------------------|-----------|--------|
| cxx             | copy+strip from musl sysroot         | `9bad8764…:319`             | locked    | IDENTICAL |
| cc              | copy+strip+cc-symlink+shim-graft     | `a86ec9ef…:319`             | locked    | IDENTICAL |
| rust            | floor reshape from selfcontained     | `580e0138…:477`             | locked    | IDENTICAL |
| ghc (stage 1)   | de-shell+cc-graft+rts+settings       | `ee3e29c2…:239`             | stage ref | IDENTICAL |
| ghc (stage 2)   | floor reshape from OWN stage 1       | `61c5829a…:476`             | locked    | IDENTICAL |
| lean (stage 1)  | de-shell (bin/lean → .lean-wrapped)  | `e657579a…:239`             | stage ref | IDENTICAL |
| lean (stage 2)  | floor reshape from OWN stage 1       | `d663df9a…:471`             | locked    | IDENTICAL |
| nv (stage 1)    | de-shell (fatbinary → .fatbinary-real)| `ec2df1ff…:239`            | stage ref | IDENTICAL |
| nv (stage 2)    | floor reshape from OWN stage 1       | `8af45100…:556`             | locked    | IDENTICAL |
| prelude-tools   | floor reshape from selfcontained     | `f4a7b7fa…:233`             | locked    | IDENTICAL |
| python          | floor reshape from selfcontained     | `9001ee63…:480`             | locked    | IDENTICAL |
| libmodern       | library-cell projection (hdrs+.a+manifest) | `4059d79f…:248`       | locked    | IDENTICAL |
| simdjson        | library-cell projection              | `cef025d0…:246`             | locked    | IDENTICAL |

Bugs found BY the differential (each a fidelity lesson, fixed with its test):

1. **hardlink aliasing** (`cp -a` → `cp -r`): `bin/llvm-strip`/`bin/llvm-objcopy`
   share an inode; preserving hardlinks made stripping one strip both. A
   REAPI Directory has no hardlink concept — the copy fidelity must match
   the digest's view.
2. **top-level symlink deref**: the reference pipeline's bare `cp` of
   `libutil.so` dereferences; `cp -r` copies the link. The gate itself
   caught the resulting absolute symlink before the digest could.
3. **incomplete de-shell table**: `ghci`/`ghci-9.12.3` are deleted (dead
   scripts, no ELF counterpart), not symlinked — again caught by the gate
   ("script entrypoint under bin/") before the digest comparison ran.

Vendor-blob content-addressing (`lib.vendorBlob` / `lib.containerToNix`):
admission = in-builder content hash + verify-closure (dangling-NEEDED).
`checks.vendor-blob-admission`: clean blob admitted through the lib; a
one-byte tamper rejected by content address; a dangling-NEEDED blob
rejected by `elf-verify --needed-closure`; the closed variant admitted.
