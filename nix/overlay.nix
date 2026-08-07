# The modern overlay — content-addressed vendor-blob primitives, absorbed
# from straylight-nvidia-sdk's nix/modern.nix (the original charter module,
# now hosted at the bottom of the stack where it belongs; the SDK consumes
# this via the modern.nix flake input instead of carrying its own copy).
#
# Provides:
#   - mk-runpath: construct LD runpath from dependencies
#   - patch-elf: fix interpreter and runpath for all ELFs
#   - extract: unpack tarball/archive, patch rpaths
#   - container-to-nix: extract container filesystem (FOD)
#   - verify-closure: fail the build if any ELF has a lurking linkage bomb
#
# ──────────────────────────────────────────────────────────────────────────────
# Closure policy (why verify-closure exists)
# ──────────────────────────────────────────────────────────────────────────────
# Our vendor-blob packages (nvidia-sdk, tritonserver, ngc-python) ship their own
# ABI-matched shared libraries — a full Qt6, CUDA userspace, HPC-X, TRT-LLM, etc.
# The ONLY correct linkage policy is: the vendor's bundled libs win, and nixpkgs
# supplies just the irreducible system floor. Two failure modes hide otherwise,
# and only surface when the binary is actually executed on target hardware:
#
#   MODE 1 (ABI shadow): an ELF resolves a soname to a NIXPKGS copy when the SAME
#     soname also exists in the vendor bundle → two incompatible builds of one
#     library load into the process → GLIBC_PRIVATE / Qt_6_PRIVATE_API crashes.
#
#   MODE 2 (dangling NEEDED): an ELF NEEDs a soname that resolves nowhere on its
#     RPATH → "cannot open shared object file" at startup.
#
# `verify-closure` walks every ELF in $out at build time and fails the build on
# either mode, so a package cannot even be produced with a hidden linkage bomb.
# This replaces the reactive "run it on the GB10 and see what breaks" loop with a
# structural guarantee shared by every vendor-blob package.

final: _prev:
let
  inherit (final) lib;

  # ════════════════════════════════════════════════════════════════════════════
  # mk-runpath — construct ld runpath from dependencies
  # ════════════════════════════════════════════════════════════════════════════

  mk-runpath =
    deps:
    lib.concatStringsSep ":" (
      lib.concatMap (
        dep:
        let
          d = dep.lib or dep.out or dep;
        in
        [
          "${d}/lib"
          "${d}/lib64"
        ]
      ) deps
    );

  # ════════════════════════════════════════════════════════════════════════════
  # patch-elf — fix interpreter and runpath for all ELFs
  # ════════════════════════════════════════════════════════════════════════════

  patch-elf = { runpath, out }: ''
    find ${out} -type f \( -executable -o -name "*.so*" \) 2>/dev/null | while read -r f; do
      if file "$f" | grep -q ELF; then
        if file "$f" | grep -q "executable"; then
          patchelf --set-interpreter "$(cat ${final.stdenv.cc}/nix-support/dynamic-linker)" "$f" 2>/dev/null || true
        fi
        existing=$(patchelf --print-rpath "$f" 2>/dev/null || echo "")
        new_rpath="${runpath}:${out}/lib:${out}/lib64''${existing:+:$existing}"
        patchelf --set-rpath "$new_rpath" "$f" 2>/dev/null || true
      fi
    done
  '';

  # ════════════════════════════════════════════════════════════════════════════
  # verify-closure — structural gate against the two linkage failure modes
  # ════════════════════════════════════════════════════════════════════════════
  #
  #   verify-closure {
  #     out        = "$out";
  #     bundleDirs = [ "$out/nsight-.../host-linux-x64" ... ];  # vendor's own libs
  #     systemFloor = [ "${glibc}/lib" ... ];                    # nixpkgs floor
  #     ignore     = [ "libcuda.so.1" "libnvidia-ml.so.1" ];     # host-provided at runtime
  #   }
  #
  # For every ELF under `out`, resolve each DT_NEEDED against the union of the
  # ELF's own dir, bundleDirs, systemFloor, and its recorded RUNPATH/RPATH:
  #   - MODE 2: any NEEDED (not in `ignore`) that resolves nowhere → fail.
  #   - MODE 1: any NEEDED whose soname ALSO exists in a bundleDir but resolved to
  #     a non-bundle (nixpkgs) path first → fail (ABI shadow).
  # verify-closure — structural gate against the two ELF linkage failure modes.
  # Implemented in nix/scripts/verify-closure.sh (testable in isolation, not
  # wrestled through Nix indented-string escaping). Emits a shell snippet for
  # a postFixup/postInstall that fails the build on MODE1 (ABI shadow) or
  # MODE2 (dangling NEEDED). See the script header for the algorithm.
  verify-closure =
    {
      out,
      bundleDirs ? [ ],
      systemFloor ? [ ],
      ignore ? [ ],
      outIsBundle ? false,
    }:
    let
      script = ./scripts/verify-closure.sh;
      bundleArg = lib.concatStringsSep ":" bundleDirs;
      floorArg = lib.concatStringsSep ":" systemFloor;
      ignoreArg = lib.concatStringsSep " " ignore;
      outIsBundleArg = if outIsBundle then "1" else "0";
    in
    ''
      ${final.bash}/bin/bash ${script} \
        "${out}" \
        "${bundleArg}" \
        "${floorArg}" \
        "${ignoreArg}" \
        "${outIsBundleArg}"
    '';

in
{
  modern = {
    inherit mk-runpath patch-elf verify-closure;

    # ══════════════════════════════════════════════════════════════════════════
    # extract — unpack tarball/archive, patch rpaths
    # ══════════════════════════════════════════════════════════════════════════

    extract =
      {
        pname,
        version,
        src,
        runtime-inputs ? [ ],
        install ? "cp -a . $out/",
        post-install ? "",
        meta ? { },
        ...
      }:
      let
        runpath = mk-runpath runtime-inputs;
      in
      final.stdenv.mkDerivation {
        inherit
          pname
          version
          src
          meta
          ;

        nativeBuildInputs = [
          final.patchelf
          final.file
          final.findutils
          final.gnugrep
          final.gnutar
          final.gzip
          final.xz
          final.unzip
        ];

        dontConfigure = true;
        dontBuild = true;
        dontUnpack = true;

        installPhase = ''
          runHook preInstall
          mkdir -p $out
          ${install}
          ${post-install}
          runHook postInstall
        '';

        fixupPhase = ''
          runHook preFixup
          ${patch-elf {
            inherit runpath;
            out = "$out";
          }}
          runHook postFixup
        '';
      };

    # ══════════════════════════════════════════════════════════════════════════
    # container-to-nix — extract container filesystem (FOD)
    # ══════════════════════════════════════════════════════════════════════════

    container-to-nix =
      {
        name,
        imageRef,
        hash,
      }:
      let
        # Map Nix system to OCI platform
        platform = if final.stdenv.hostPlatform.isAarch64 then "linux/arm64" else "linux/amd64";
      in
      final.stdenvNoCC.mkDerivation {
        inherit name;

        nativeBuildInputs = [
          final.crane
          final.gnutar
          final.gzip
        ];

        outputHashAlgo = "sha256";
        outputHashMode = "recursive";
        outputHash = hash;

        SSL_CERT_FILE = "${final.cacert}/etc/ssl/certs/ca-bundle.crt";

        buildCommand = ''
          mkdir -p $out
          crane export --platform ${platform} ${imageRef} - | tar -xf - -C $out
        '';
      };
  };
}
