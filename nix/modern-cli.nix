# The `modern` CLI — Haskell, built from plain nixpkgs GHC only (the same
# dependency-free discipline as the ELF suite; Shelly and aeson come from the
# nixpkgs haskellPackages set at the pinned rev). The wrapper bakes the ELF
# suite path so `modern project` gates without ceremony; --elf-suite still
# overrides.
{
  haskell,
  haskellPackages,
  makeWrapper,
  runCommandLocal,
  elf-suite,
}:
let
  raw = haskell.lib.justStaticExecutables (haskellPackages.callCabal2nix "modern" ../hs { });
in
runCommandLocal "modern-cli"
  {
    nativeBuildInputs = [ makeWrapper ];
    passthru = { inherit raw; };
    meta.mainProgram = "modern";
  }
  ''
    mkdir -p $out/bin
    makeWrapper ${raw}/bin/modern $out/bin/modern \
      --set-default MODERN_ELF_SUITE ${elf-suite}
  ''
