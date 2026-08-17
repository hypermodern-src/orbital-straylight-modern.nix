# Vendor blobs

The original modern.nix charter, absorbed from straylight-nvidia-sdk:
vendor blobs (the NVIDIA SDK tarballs, wheels, OCI-exported filesystems)
are first-class **content-addressed** inputs instead of things rebuilt from
source or trusted from a fetcher.

## Admission

`lib.vendorBlob` admits a blob through two gates:

1. **content address** — the blob's sha256 is checked *in the builder*,
   independent of any fetcher's promise; a one-byte tamper is rejected
   before a byte is unpacked;
2. **verify-closure** — `elf-verify --needed-closure` over the unpacked
   tree: every ELF's `DT_NEEDED` must resolve within the tree ∪ the ignore
   list (host-provided sonames like `libcuda.so.1`); a dangling NEEDED is a
   rejected blob, not a runtime crash on target hardware.

`checks.vendor-blob-admission` proves all four legs: clean blob admitted,
tampered blob rejected, dangling-NEEDED rejected, closed variant admitted.

For OCI rootfs imports, admission additionally uses `elf-resolve`: products
declare their executable and plugin/extension roots, the image's loader cache is
normalized into inert SONAME→path data, and the complete reachable edge plan
must resolve. Dead payload is outside the product closure; a hand-maintained
"optional missing library" list is not a substitute for reachability.

## The overlay

`overlays.default` carries the charter primitives consumed by
straylight-nvidia-sdk in place of its own former copy: `mk-runpath`,
`patch-elf`, `verify-closure` (the two-mode structural gate: dangling
NEEDED and ABI shadow), `extract`, and `container-to-nix` (a vendor OCI
image's filesystem as a fixed-output derivation). `lib.containerToNix`
exposes the same extractor to non-overlay consumers.
