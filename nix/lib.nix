# modern.nix library surface (system-independent; every function takes pkgs).
#
# mkTypedDerivation — the Shelly builder pattern: a derivation whose
# buildCommand is `runghc <script> <args.json> $out`. The script is a typed
# Haskell program (Shelly for process work, aeson for its arguments); nothing
# from the argument set is ever spliced into a shell string. This is the
# replacement idiom for the ad-hoc `runCommand "..." '' ...bash... ''`
# projection stratum: paths go in as DATA, the program is compiled-checked
# (well, runghc-checked) code under version control.
{
  # mkTypedDerivation ::
  #   { pkgs, name, script, args ? {}, runtimeInputs ? [], ghcPackages ? ...,
  #     allowedReferences ? null }
  #   -> derivation
  #
  # `script` receives argv[1] = a JSON file of `args` (decode with aeson),
  # argv[2] = $out. Tool paths belong in `args`; PATH additions (cp, chmod
  # ...) in `runtimeInputs`.
  mkTypedDerivation =
    {
      pkgs,
      name,
      script,
      args ? { },
      runtimeInputs ? [ ],
      ghcPackages ? (p: [
        p.shelly
        p.aeson
      ]),
      allowedReferences ? null,
    }:
    let
      ghc = pkgs.haskellPackages.ghcWithPackages ghcPackages;
      argsJson = pkgs.writeText "${name}-args.json" (builtins.toJSON args);
    in
    pkgs.runCommand name
      (
        {
          nativeBuildInputs = [ ghc ] ++ runtimeInputs;
          passthru = { inherit argsJson script; };
        }
        // (if allowedReferences == null then { } else { inherit allowedReferences; })
      )
      ''
        runghc ${script} ${argsJson} "$out"
      '';

  # ── vendor-blob content-addressing (the original modern.nix charter) ──────
  #
  # Vendor blobs (NVIDIA SDK tarballs, wheels, OCI-exported filesystems) are
  # first-class content-addressed inputs: admission is (1) the blob's own
  # content hash, checked IN the builder (independent of any fetcher's
  # promise — a tampered blob is rejected before a byte is unpacked), and
  # (2) verify-closure — every ELF's DT_NEEDED must resolve within the
  # unpacked tree ∪ declared system floor ∪ the ignore list (MODE 2, dangling
  # NEEDED), enforced by elf-verify. No ad-hoc fetch trust.
  #
  # vendorBlob ::
  #   { pkgs, elf-suite, name, blob, sha256, unpack ? auto,
  #     ignore ? [], gate ? true } -> derivation
  vendorBlob =
    {
      pkgs,
      elf-suite,
      name,
      blob, # a path (store or fetched) to the vendor archive
      sha256, # the blob's content address, verified in-builder
      unpack ? null, # shell fragment; default: tar -xf into $out
      ignore ? [ ], # sonames provided by the host at runtime (libcuda.so.1 ...)
      gate ? true,
    }:
    pkgs.runCommand name
      {
        nativeBuildInputs = [
          pkgs.gnutar
          pkgs.xz
          pkgs.gzip
          pkgs.zstd
          elf-suite
        ];
        inherit blob sha256;
      }
      ''
        # (1) content admission: the bytes must BE the declared identity
        echo "$sha256  $blob" | sha256sum -c - || {
          echo "vendorBlob: content-address mismatch — blob rejected" >&2
          exit 1
        }
        mkdir -p $out
        ${if unpack == null then ''tar -xf "$blob" -C $out'' else unpack}
        # (2) structural admission: no dangling NEEDED (verify-closure MODE 2)
        ${
          if gate then
            ''
              elf-verify --needed-closure ${
                pkgs.lib.concatMapStringsSep " " (i: "--ignore ${i}") ignore
              } $out
            ''
          else
            ""
        }
      '';

  # container-to-nix — pull a vendor OCI image's filesystem as a
  # fixed-output derivation (the charter's FOD extractor, absorbed from
  # straylight-nvidia-sdk nix/modern.nix).
  containerToNix =
    {
      pkgs,
      name,
      imageRef,
      hash,
    }:
    let
      platform = if pkgs.stdenv.hostPlatform.isAarch64 then "linux/arm64" else "linux/amd64";
    in
    pkgs.stdenvNoCC.mkDerivation {
      inherit name;
      nativeBuildInputs = [
        pkgs.crane
        pkgs.gnutar
        pkgs.gzip
      ];
      outputHashAlgo = "sha256";
      outputHashMode = "recursive";
      outputHash = hash;
      SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      buildCommand = ''
        mkdir -p $out
        crane export --platform ${platform} ${imageRef} - | tar -xf - -C $out
      '';
    };
}
