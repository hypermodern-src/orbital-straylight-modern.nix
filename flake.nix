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
          default = elf-suite;
        }
      );

      checks = forAll (
        system: pkgs:
        import ./nix/checks.nix {
          inherit pkgs self;
          elf-suite = self.packages.${system}.elf-suite;
        }
      );

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
