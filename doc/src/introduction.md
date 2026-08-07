# modern.nix

modern.nix is the **bottom of the sovereign build stack**: the layer that
makes the toolchain, which compiles everything else. All of the bootstrap is
like that — which is why this flake's inputs are `nixpkgs` and *nothing
else*, forever.

The constraint is not a style preference; it is what prevents the bootstrap
recursion from re-forming. modern.nix hosts its **own** tools, built from
plain nixpkgs stdenv and GHC:

- the **C++23 ELF suite** — `elf-verify`, `elf-graft`, `elf-census`
  ([The ELF suite](elf-suite.md));
- the **`modern` CLI** — `modern project`, the typed projection interpreter,
  plus `lib.mkTypedDerivation`, the Shelly builder pattern
  ([Typed projection](projection.md));
- the **vendor-blob primitives** — content-addressed admission for the blobs
  nobody rebuilds from source ([Vendor blobs](vendor-blobs.md)).

Downstream repositories (straylight-toolchain, straylight-nvidia-sdk,
libmodern-cpp) consume these as a flake input and express their cell
projections as **manifests** instead of ad-hoc bash. The suite itself ships
as a cell — but that release happens *downstream*, as a re-export; modern.nix
never learns cells exist ([The seal and the re-export](seal.md)).

The whole layer is guarded by `checks.bootstrap-seal`: an eval-time
assertion that the flake's input closure is exactly `[nixpkgs]`. It has been
falsified — a deliberately added straylight input fails every check, and the
poisoned closure visibly contains `modern-nix` itself: the recursion,
literally re-forming.
