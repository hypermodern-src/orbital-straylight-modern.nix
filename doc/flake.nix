{
  description = "modern.nix — the bootstrap book";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems f;
    in
    {
      packages = forAll (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          # Narrowed src: only the book inputs enter the content address.
          book = pkgs.stdenvNoCC.mkDerivation {
            name = "modern-nix-book";
            src = nixpkgs.lib.fileset.toSource {
              root = ./.;
              fileset = nixpkgs.lib.fileset.unions [
                ./book.toml
                ./src
              ];
            };
            nativeBuildInputs = [ pkgs.mdbook ];
            buildPhase = "mdbook build";
            installPhase = "mv book $out";
          };
        in
        {
          default = book;
          book = book;
        }
      );
    };
}
