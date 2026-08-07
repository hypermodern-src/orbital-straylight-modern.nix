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
}
