{
  # modern.nix — the dependency-free bootstrap layer of the sovereign build.
  #
  # THE CONSTRAINT (load-bearing, guarded by checks.bootstrap-seal): the flake
  # inputs are nixpkgs ONLY, forever. modern.nix makes the toolchain, which
  # compiles libmodern-cpp — all of the bootstrap is like that. It hosts its
  # OWN tools (the C++23 ELF suite, the Haskell `modern` projector) built from
  # plain nixpkgs stdenv/GHC. Downstream repos may re-export these tools as
  # cells; modern.nix never learns cells exist. If an input other than nixpkgs
  # ever appears here, the recursion is re-forming: stop and restructure.
  description = "modern.nix — dependency-free bootstrap: the C++23 ELF suite and typed projection for content-addressed vendor blobs and standalone toolchain cells";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/ddb5e98374d1f16c86ecd70d9c4e2d6c6a5e8dbc";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f system (import nixpkgs { inherit system; }));
    in
    {
      packages = forAll (
        _system: pkgs: rec {
          # The C++23 ELF suite: elf-verify / elf-census / elf-graft.
          # Built with the plain nixpkgs stdenv compiler (gcc).
          elf-suite = pkgs.callPackage ./nix/elf-suite.nix { };
          # The static-musl build (pkgsStatic): genuinely static ELFs — no
          # PT_INTERP, no DT_NEEDED — so a DOWNSTREAM repo can project the
          # suite as a standalone cell (the re-export; modern.nix itself
          # never learns cells exist). Still nixpkgs-only.
          elf-suite-static = pkgs.pkgsStatic.callPackage ./nix/elf-suite.nix { };
          # The Haskell `modern` CLI (`modern project`): typed projection —
          # manifest in, §12 tree out, gate enforced by the ELF suite.
          modern = pkgs.callPackage ./nix/modern-cli.nix { inherit elf-suite; };
          default = elf-suite;
        }
      );

      checks = forAll (
        system: pkgs:
        import ./nix/checks.nix {
          inherit pkgs self;
          elf-suite = self.packages.${system}.elf-suite;
          modern = self.packages.${system}.modern;
        }
      );

      # System-independent library surface: every function takes pkgs.
      # mkTypedDerivation = the Shelly builder pattern (typed args, no bash).
      lib = import ./nix/lib.nix;

      # The modern overlay (mk-runpath / patch-elf / verify-closure /
      # extract / container-to-nix) — the vendor-blob charter, consumed by
      # straylight-nvidia-sdk in place of its own copy.
      overlays.default = import ./nix/overlay.nix;

      devShells = forAll (
        _system: pkgs: {
          default = pkgs.mkShell {
            packages = [
              pkgs.gnumake
              pkgs.patchelf # oracle for differential tests, never a dependency of the tools
            ];
          };
        }
      );
    };
}
