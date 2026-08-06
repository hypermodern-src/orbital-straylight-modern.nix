# modern.nix flake checks — the falsification harness IS the test suite.
#
#   elf-suite-tests        property/differential tests + the specimen ledger
#                          (bash-wrapper-as-ELF, PT_INTERP-claimed-static,
#                          store-ref leak, bad graft) — every predicate is
#                          shown to FAIL on broken input before its pass
#                          counts.
#   specimen-pkgsstatic-gzip
#                          the REAL historical specimen: pkgsStatic.gzip's
#                          bin/gzip was a bash wrapper wearing an ELF name.
#                          Differential: elf-verify's verdict must agree with
#                          shell-computed ground truth over the actual bytes,
#                          whichever way this nixpkgs pin ships it.
#   bootstrap-seal         the input closure is nixpkgs-only (eval-time; any
#                          added flake input fails every check).
{
  pkgs,
  self,
  elf-suite,
}:
let
  lock = builtins.fromJSON (builtins.readFile (self + "/flake.lock"));
  inputNodes = builtins.filter (n: n != lock.root) (builtins.attrNames lock.nodes);
  # THE SEAL: modern.nix depends on nixpkgs and NOTHING else — it makes the
  # toolchain, which compiles libmodern-cpp; a straylight input here is the
  # bootstrap recursion re-forming. Evaluated eagerly so every check carries it.
  sealed =
    if inputNodes == [ "nixpkgs" ] then
      true
    else
      throw ("bootstrap seal violated: flake inputs must be exactly [nixpkgs], got " + builtins.toJSON inputNodes);
in
assert sealed;
{
  bootstrap-seal =
    pkgs.runCommand "bootstrap-seal"
      {
        passthru.inputs = inputNodes;
      }
      ''
        echo "input closure: ${builtins.toJSON inputNodes} (nixpkgs only)" | tee $out
      '';

  elf-suite-tests =
    pkgs.runCommand "elf-suite-tests"
      {
        nativeBuildInputs = [
          pkgs.stdenv.cc # builds the corpus
          pkgs.binutils # readelf: the differential oracle
          pkgs.patchelf # read-back oracle for grafts (never a tool dependency)
          pkgs.python3 # the length-preserving scrub in the floor leg
          elf-suite
        ];
      }
      ''
        mkdir work && cd work
        STATIC_LIBC_DIR=${pkgs.glibc.static}/lib \
        VERIFY=${elf-suite}/bin/elf-verify \
        CENSUS=${elf-suite}/bin/elf-census \
        GRAFT=${elf-suite}/bin/elf-graft \
        CC=cc READELF=readelf PATCHELF=patchelf \
          bash ${../cpp/test/run-tests.sh} | tee $out
      '';

  specimen-pkgsstatic-gzip =
    pkgs.runCommand "specimen-pkgsstatic-gzip"
      {
        nativeBuildInputs = [ elf-suite ];
        gzipTree = pkgs.pkgsStatic.gzip;
      }
      ''
        # Ground truth over the bytes, computed with nothing but the shell:
        # does any bin/ entry hide a script behind an executable name, or does
        # any file carry a /nix/store reference?
        dirty=0
        for f in "$gzipTree"/bin/*; do
          [ -f "$f" ] && [ ! -L "$f" ] || continue
          [ "$(head -c2 "$f")" = "#!" ] && dirty=1
        done
        grep -rq /nix/store "$gzipTree" && dirty=1

        if elf-verify --policy=static "$gzipTree" > verdict.txt 2>&1; then clean=1; else clean=0; fi
        cat verdict.txt

        if [ "$dirty" = 1 ] && [ "$clean" = 1 ]; then
          echo "FAIL: the specimen is dirty but elf-verify passed it (the pkgsStatic.gzip trap)"
          exit 1
        fi
        if [ "$dirty" = 0 ] && [ "$clean" = 0 ]; then
          # verify may still be stricter than the shell oracle (symlinks, rpath);
          # only a script/store-ref miss is the historical failure class.
          if grep -qE "script entrypoint|/nix/store literal" verdict.txt; then
            echo "FAIL: verify reports script/store-ref the shell oracle disproves"
            exit 1
          fi
        fi
        echo "specimen agreement: dirty=$dirty verify-clean=$clean" | tee $out
      '';
}
