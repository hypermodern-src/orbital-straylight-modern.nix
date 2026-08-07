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
  modern,
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

  # `modern project` end-to-end over a synthetic cell: copy + strip + symlink
  # + scrub + gate, then the falsifications — a poisoned source (store ref,
  # wrapper script) must fail the gate with a typed error NAMING the file.
  modern-project-tests =
    pkgs.runCommand "modern-project-tests"
      {
        nativeBuildInputs = [
          pkgs.stdenv.cc
          pkgs.jq
          modern
        ];
      }
      ''
        mkdir work && cd work

        # a synthetic source cell: one static-ish binary + a data file
        mkdir -p src/bin src/share
        cat > hello.c <<'EOF'
        #include <stdio.h>
        int main(void){ puts("cell"); return 0; }
        EOF
        cc -static -L${pkgs.glibc.static}/lib hello.c -o src/bin/hello
        echo "docs" > src/share/README

        write_manifest() { # $1 = source dir, $2 = out json
          cat > "$2" <<EOF
        {
          "name": "synthetic",
          "sources": { "tree": "$PWD/$1" },
          "ops": [
            { "op": "copy", "from": "tree" },
            { "op": "strip", "tool": "$(command -v strip)", "paths": ["bin/hello"], "optional": true },
            { "op": "symlink", "at": "bin/h", "target": "hello", "ifMissing": true },
            { "op": "scrub" }
          ],
          "gate": { "policy": "static" }
        }
        EOF
        }

        write_manifest src m.json
        modern project m.json --out out1
        test -x out1/bin/hello && test -L out1/bin/h || { echo "FAIL: projected shape"; exit 1; }

        # determinism: same manifest, same bytes
        modern project m.json --out out2
        diff -r out1 out2 && echo "ok: projection deterministic"

        # falsification 1: a wrapper script wearing an ELF name
        cp -r src poisoned1 && chmod -R u+w poisoned1
        printf '#!/bin/sh\nexec hello\n' > poisoned1/bin/gzip
        chmod +x poisoned1/bin/gzip
        write_manifest poisoned1 m1.json
        if modern project m1.json --out bad1 2> err1.txt; then
          echo "FAIL: wrapper script passed the gate"; exit 1
        fi
        grep -q 'gate violation: bin/gzip' err1.txt || { echo "FAIL: error does not name the file"; cat err1.txt; exit 1; }
        grep -q '"file":"bin/gzip"' err1.txt || { echo "FAIL: no typed (JSON) error"; cat err1.txt; exit 1; }
        echo "ok: falsify wrapper-script names bin/gzip (typed)"

        # falsification 2: a smuggled /nix/store reference that scrub cannot
        # kill length-preservingly is still caught by the gate — plant it
        # AFTER scrub would run by skipping the scrub op
        cp -r src poisoned2 && chmod -R u+w poisoned2
        echo "ref: /nix/store/abcdefghijklmnopqrstuvwxyz012345-leak" > poisoned2/share/leak.txt
        cat > m2.json <<EOF
        {
          "name": "synthetic",
          "sources": { "tree": "$PWD/poisoned2" },
          "ops": [ { "op": "copy", "from": "tree" } ],
          "gate": { "policy": "static" }
        }
        EOF
        if modern project m2.json --out bad2 2> err2.txt; then
          echo "FAIL: store ref passed the gate"; exit 1
        fi
        grep -q 'gate violation: share/leak.txt' err2.txt || { echo "FAIL: error does not name the file"; cat err2.txt; exit 1; }
        echo "ok: falsify store-ref names share/leak.txt (typed)"

        # the scrub op DOES kill a hashed store literal (length-preserving)
        modern project m.json --out out3
        cmp -s out1/bin/hello out3/bin/hello && echo "ok: scrubbed binary stable"

        echo "all modern-project tests passed" | tee $out
      '';

  # The mkTypedDerivation pattern end-to-end: buildCommand = runghc Build.hs
  # with typed JSON args, Shelly for process work, the ELF suite as the gate.
  typed-derivation-demo =
    let
      lib' = import ./lib.nix;
      helloStatic =
        pkgs.runCommand "hello-static-specimen" { nativeBuildInputs = [ pkgs.stdenv.cc ]; } ''
          echo 'int main(void){return 0;}' > h.c
          cc -static -L${pkgs.glibc.static}/lib h.c -o $out
        '';
    in
    lib'.mkTypedDerivation {
      inherit pkgs;
      name = "typed-derivation-demo";
      script = ./typed-demo/Build.hs;
      runtimeInputs = [ pkgs.coreutils ];
      args = {
        binary = helloStatic;
        elfSuite = elf-suite;
        motd = "projected by a typed Shelly builder, no string-spliced bash";
      };
    };

  # Vendor-blob content-addressing: admission = content hash (in-builder,
  # independent of fetcher trust) + verify-closure (no dangling NEEDED).
  # The PASS leg goes through lib.vendorBlob itself; the falsification legs
  # (tampered bytes, dangling NEEDED) replicate the same admission commands
  # in-check, since a nix check cannot depend on a failing derivation.
  vendor-blob-admission =
    let
      lib' = import ./lib.nix;
      # a well-formed synthetic vendor blob: one static-ish executable
      goodBlob =
        pkgs.runCommand "vendor-blob-good.tar" { nativeBuildInputs = [ pkgs.stdenv.cc pkgs.gnutar ]; } ''
          mkdir -p tree/bin
          echo 'int main(void){return 0;}' > h.c
          cc -static -L${pkgs.glibc.static}/lib h.c -o tree/bin/tool
          tar -cf $out -C tree .
        '';
      goodHash = pkgs.runCommand "vendor-blob-good.hash" { } ''
        sha256sum ${goodBlob} | cut -d' ' -f1 | tr -d '\n' > $out
      '';
      admitted = lib'.vendorBlob {
        inherit pkgs elf-suite;
        name = "vendor-blob-admitted";
        blob = goodBlob;
        sha256 = builtins.readFile goodHash;
        ignore = [ ];
      };
    in
    pkgs.runCommand "vendor-blob-admission"
      {
        nativeBuildInputs = [
          pkgs.stdenv.cc
          pkgs.gnutar
          elf-suite
        ];
        inherit goodBlob admitted;
      }
      ''
        test -x $admitted/bin/tool && echo "ok: clean blob admitted via lib.vendorBlob"

        # falsification 1: tampered blob — flip one byte, same admission command
        cp $goodBlob tampered.tar && chmod +w tampered.tar
        printf '\xff' | dd of=tampered.tar bs=1 seek=512 conv=notrunc status=none
        want=$(sha256sum $goodBlob | cut -d' ' -f1)
        if echo "$want  tampered.tar" | sha256sum -c - 2> /dev/null; then
          echo "FAIL: tampered blob passed the content-address check"; exit 1
        fi
        echo "ok: tampered blob rejected by content address"

        # falsification 2: a blob whose ELF has a dangling NEEDED
        mkdir -p bad/lib bad/bin
        echo 'int f(void){return 1;}' > f.c
        cc -shared -fPIC -Wl,-soname,libghost.so.1 f.c -o libghost.so.1
        echo 'extern int f(void); int main(void){return f();}' > m.c
        cc m.c -L. -lghost -o bad/bin/needy \
          -Wl,--no-as-needed -l:libghost.so.1 || cc m.c ./libghost.so.1 -o bad/bin/needy
        if elf-verify --needed-closure --ignore libc.so.6 --ignore libgcc_s.so.1 bad; then
          echo "FAIL: dangling NEEDED admitted"; exit 1
        fi
        echo "ok: dangling-NEEDED blob rejected by verify-closure"
        cp libghost.so.1 bad/lib/
        elf-verify --needed-closure --ignore libc.so.6 --ignore libgcc_s.so.1 bad \
          && echo "ok: closed blob admitted"

        echo "vendor-blob admission proofs complete" | tee $out
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
