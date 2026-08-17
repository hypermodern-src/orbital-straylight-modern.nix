#!/usr/bin/env bash
# run-tests.sh — the ELF-suite property/differential/falsification harness.
#
# Every falsification runs BOTH legs: the predicate must FAIL on the broken
# specimen before its pass on the clean one counts (the monotone rule). The
# oracles are readelf and patchelf — used only to CHECK the suite, never as
# dependencies of it.
#
# Environment: VERIFY CENSUS GRAFT RESOLVE (tool paths), CC (a working C compiler),
# READELF, PATCHELF. Run from a writable scratch directory.
set -ueo pipefail

: "${VERIFY:?}" "${CENSUS:?}" "${GRAFT:?}" "${RESOLVE:?}" "${CC:?}" "${READELF:?}" "${PATCHELF:?}"

pass=0
fail=0
ok() { echo "ok: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# expect_exit <code> <name> <cmd...>
expect_exit() {
  local want="$1" name="$2"
  shift 2
  local got=0
  "$@" > /dev/null 2>&1 || got=$?
  if [ "$got" = "$want" ]; then ok "$name (exit $got)"; else bad "$name: exit $got, want $want"; fi
}

# expect_report <pattern> <name> <cmd...> — the command may fail; its combined
# output must name the violation class.
expect_report() {
  local pat="$1" name="$2"
  shift 2
  "$@" > report.txt 2>&1 || true
  if grep -q "$pat" report.txt; then ok "$name"; else bad "$name (no '$pat' in report)"; fi
}

# scrub <tree> — kill /nix/store literals length-preservingly (finalize
# semantics: real projected cells are de-nixed the same way).
scrub() {
  python3 - "$1" << 'EOF'
import os, re, sys
pat = re.compile(rb"/nix/store")
for dp, _, fs in os.walk(sys.argv[1]):
    for f in fs:
        p = os.path.join(dp, f)
        if os.path.islink(p):
            continue
        data = open(p, "rb").read()
        new = pat.sub(b"/nix/st0re", data)
        if new != data:
            assert len(new) == len(data)
            open(p, "wb").write(new)
EOF
}

# ── corpus ──────────────────────────────────────────────────────────────────
mkdir -p corpus
cat > corpus/hello.c << 'EOF'
#include <stdio.h>
int main(void) { puts("hello from the corpus"); return 0; }
EOF
cat > corpus/foo.c << 'EOF'
int foo(void) { return 42; }
EOF
cat > corpus/usefoo.c << 'EOF'
extern int foo(void);
#include <stdio.h>
int main(void) { printf("%d\n", foo()); return 0; }
EOF

# STATIC_LIBC_DIR (optional): where libc.a lives when the ambient compiler
# doesn't ship one (nix stdenv). Passed per-invocation so the DYNAMIC corpus
# binaries never see it (a global -L would fold static libc.a into them).
$CC corpus/hello.c -o corpus/hello-dyn
$CC -static ${STATIC_LIBC_DIR:+-L"$STATIC_LIBC_DIR"} corpus/hello.c -o corpus/hello-static
$CC -shared -fPIC -Wl,-soname,libfoo.so.1 corpus/foo.c -o corpus/libfoo.so.1
ln -sf libfoo.so.1 corpus/libfoo.so
$CC corpus/usefoo.c -Lcorpus -lfoo -o corpus/usefoo
$CC corpus/hello.c -Wl,--disable-new-dtags,-rpath,/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-phantom/lib -o corpus/hello-rpath
$CC corpus/hello.c -Wl,--enable-new-dtags,-rpath,/opt/phantom/lib -o corpus/hello-runpath
printf '#!/bin/sh\nexec true\n' > corpus/script.sh
chmod +x corpus/script.sh
printf 'just bytes\n' > corpus/data.txt

# ── differential: census facts vs readelf ground truth ──────────────────────
oracle_interp() { $READELF -lW "$1" | sed -n 's/.*interpreter: \(.*\)]/\1/p'; }
oracle_needed() { $READELF -dW "$1" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | paste -sd, -; }
oracle_soname() { $READELF -dW "$1" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p'; }
oracle_rpath() { $READELF -dW "$1" | sed -n 's/.*(RPATH).*\[\(.*\)\]/\1/p'; }
oracle_runpath() { $READELF -dW "$1" | sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p'; }

census_field() { # census_field <tree> <rel> <field>
  $CENSUS "$1" | awk -F'|' -v rel="$2" '$1 == rel' | tr '|' '\n' | sed -n "s/^$3=//p"
}

mkdir -p difftree/bin difftree/lib
cp corpus/hello-dyn corpus/hello-static corpus/hello-rpath corpus/hello-runpath corpus/usefoo difftree/bin/
cp corpus/libfoo.so.1 difftree/lib/

for b in hello-dyn hello-rpath hello-runpath usefoo; do
  want_interp=$(oracle_interp "difftree/bin/$b")
  got_interp=$(census_field difftree "bin/$b" interp)
  [ "$want_interp" = "$got_interp" ] && ok "differential interp $b" || bad "differential interp $b: '$got_interp' vs '$want_interp'"
  want_needed=$(oracle_needed "difftree/bin/$b")
  got_needed=$(census_field difftree "bin/$b" needed)
  [ "$want_needed" = "$got_needed" ] && ok "differential needed $b" || bad "differential needed $b: '$got_needed' vs '$want_needed'"
done
[ "$(oracle_soname difftree/lib/libfoo.so.1)" = "$(census_field difftree lib/libfoo.so.1 soname)" ] \
  && ok "differential soname libfoo" || bad "differential soname libfoo"
[ "$(oracle_rpath difftree/bin/hello-rpath)" = "$(census_field difftree bin/hello-rpath rpath)" ] \
  && ok "differential rpath" || bad "differential rpath"
[ "$(oracle_runpath difftree/bin/hello-runpath)" = "$(census_field difftree bin/hello-runpath runpath)" ] \
  && ok "differential runpath" || bad "differential runpath"

# census determinism: two runs, byte-identical
$CENSUS difftree > census.1
$CENSUS difftree > census.2
cmp -s census.1 census.2 && ok "census deterministic" || bad "census not deterministic"

# ── elf-verify: the specimen falsifications (the historical ledger) ─────────
# (a) a bash wrapper with an ELF's name — the pkgsStatic.gzip specimen.
mkdir -p spec-a/bin
printf '#!/nix/store/00000000000000000000000000000000-bash/bin/bash\nexec gzip "$@"\n' > spec-a/bin/gzip
chmod +x spec-a/bin/gzip
expect_exit 1 "falsify(a): bash wrapper with ELF name fails static policy" \
  $VERIFY --policy=static spec-a
expect_report "script entrypoint" "falsify(a): violation names the script" \
  $VERIFY --policy=static spec-a

# (b) a PT_INTERP-bearing binary claimed static.
mkdir -p spec-b/bin
cp corpus/hello-dyn spec-b/bin/hello
expect_exit 1 "falsify(b): dynamic binary fails static policy" $VERIFY --policy=static spec-b
expect_report "PT_INTERP present" "falsify(b): violation names PT_INTERP" \
  $VERIFY --policy=static spec-b

# (c) a tree with an embedded /nix/store reference.
mkdir -p spec-c/bin spec-c/share
cp corpus/hello-static spec-c/bin/hello
scrub spec-c # the compiled binary itself carries store literals; isolate the planted one
printf 'see /nix/store/abcdefghijklmnopqrstuvwxyz012345-leak/lib\n' > spec-c/share/doc.txt
expect_exit 1 "falsify(c): store-ref-leaking tree fails" $VERIFY --policy=static spec-c
expect_report "/nix/store literal" "falsify(c): violation names the literal" \
  $VERIFY --policy=static spec-c

# pass leg: a genuinely static, clean (de-nixed) tree.
mkdir -p clean/bin
cp corpus/hello-static clean/bin/hello
scrub clean
if $VERIFY --policy=static clean; then ok "pass leg: static tree clean"; else bad "pass leg: static tree"; fi

# absolute + dangling symlinks
mkdir -p spec-sym/bin
cp corpus/hello-static spec-sym/bin/hello
scrub spec-sym
ln -s /nix/store/00000000000000000000000000000000-x/bin/x spec-sym/bin/absolute
expect_exit 1 "falsify: absolute symlink fails" $VERIFY --policy=static spec-sym
rm spec-sym/bin/absolute
ln -s ../nowhere spec-sym/bin/dangling
expect_exit 1 "falsify: dangling symlink fails" $VERIFY --policy=static spec-sym
rm spec-sym/bin/dangling
ln -s hello spec-sym/bin/also-hello
if $VERIFY --policy=static spec-sym; then ok "pass leg: relative symlink ok"; else bad "pass leg: relative symlink"; fi

# needed-closure: dangling NEEDED vs closed tree (MODE 2 of verify-closure)
mkdir -p spec-nc/bin spec-nc/lib
cp corpus/usefoo spec-nc/bin/
expect_exit 1 "falsify: dangling DT_NEEDED fails --needed-closure" \
  $VERIFY --needed-closure --ignore libc.so.6 --ignore libgcc_s.so.1 spec-nc
cp corpus/libfoo.so.1 spec-nc/lib/
if $VERIFY --needed-closure --ignore libc.so.6 --ignore libgcc_s.so.1 spec-nc; then
  ok "pass leg: closed NEEDED tree"
else
  bad "pass leg: closed NEEDED tree"
fi
expect_exit 1 "falsify: --ignore withdrawn reintroduces the libc dangle" \
  $VERIFY --needed-closure spec-nc

# ── elf-resolve: preserve each consumer's loader context ───────────────────
# Historical NGC failure: two ABI-incompatible providers shared a SONAME and
# flatten+cp-an selected one by find order. The plan must instead follow the
# consumer's own $ORIGIN RUNPATH.
mkdir -p resolve/bin resolve/good resolve/bad
printf 'int foo(void) { return 7; }\n' > foo-good.c
printf 'int foo(void) { return 99; }\n' > foo-bad.c
printf 'extern int foo(void); int main(void) { return foo() == 7 ? 0 : 1; }\n' > use-foo.c
$CC -shared -fPIC -Wl,-soname,libfoo.so.1 foo-good.c -o resolve/good/libfoo.so.1
$CC -shared -fPIC -Wl,-soname,libfoo.so.1 foo-bad.c -o resolve/bad/libfoo.so.1
$CC use-foo.c -Lresolve/good -Wl,-rpath,'$ORIGIN/../good' \
  -Wl,--no-as-needed -l:libfoo.so.1 -o resolve/bin/use-foo
$RESOLVE resolve --host libc.so.6 > resolve.plan
grep -q 'consumer=bin/use-foo needed=libfoo.so.1 provider=good/libfoo.so.1 source=runpath' resolve.plan \
  && ok "resolve: consumer RUNPATH selects ABI-matched provider" \
  || bad "resolve: wrong duplicate-SONAME provider selected"

# A loader-cache decision is explicit data. RUNPATH precedes it; without a
# RUNPATH the exact cached provider is selected (never rediscovered by find).
printf 'libfoo.so.1 /bad/libfoo.so.1\n' > resolve.cache
$RESOLVE resolve --host libc.so.6 --cache-plan resolve.cache > resolve.cache-plan
grep -q 'consumer=bin/use-foo needed=libfoo.so.1 provider=good/libfoo.so.1 source=runpath' resolve.cache-plan \
  && ok "resolve: RUNPATH precedes loader cache" \
  || bad "resolve: cache incorrectly overrode RUNPATH"
$CC use-foo.c -Lresolve/bad -Wl,--no-as-needed -l:libfoo.so.1 -o resolve/bin/use-cache
$RESOLVE resolve --host libc.so.6 --cache-plan resolve.cache > resolve.cache-plan.2
grep -q 'consumer=bin/use-cache needed=libfoo.so.1 provider=bad/libfoo.so.1 source=cache' resolve.cache-plan.2 \
  && ok "resolve: explicit loader-cache provider selected" \
  || bad "resolve: cache provider not selected"
mkdir resolve/absolute
ln -s /good/libfoo.so.1 resolve/absolute/libfoo.so.1
printf 'libfoo.so.1 /absolute/libfoo.so.1\n' > resolve.absolute.cache
$RESOLVE resolve --host libc.so.6 --cache-plan resolve.absolute.cache --entry /bin/use-cache > resolve.absolute.plan
grep -q 'provider=good/libfoo.so.1 source=cache' resolve.absolute.plan \
  && ok "resolve: absolute container symlink is root-relative" \
  || bad "resolve: absolute container symlink escaped to host"
printf 'not-a-valid-cache-row\n' > malformed.cache
expect_exit 2 "falsify: malformed cache plan rejected" \
  $RESOLVE resolve --cache-plan malformed.cache
rm resolve/bin/use-cache

before=$(sha256sum resolve.plan | cut -d' ' -f1)
touch resolve/bad/created-later
$RESOLVE resolve --host libc.so.6 > resolve.plan.2
after=$(sha256sum resolve.plan.2 | cut -d' ' -f1)
[ "$before" = "$after" ] && ok "resolve: plan independent of traversal order" \
  || bad "resolve: plan changed with irrelevant tree entry"

mv resolve/good/libfoo.so.1 resolve/good/libfoo.hidden
expect_exit 1 "falsify: unresolved consumer edge rejected" \
  $RESOLVE resolve --host libc.so.6
ln -s /etc/passwd resolve/good/libfoo.so.1
expect_exit 1 "falsify: provider symlink escaping root rejected" \
  $RESOLVE resolve --host libc.so.6
rm resolve/good/libfoo.so.1
mv resolve/good/libfoo.hidden resolve/good/libfoo.so.1

# DT_RPATH is inherited, and its $ORIGIN belongs to the declaring object.
printf 'extern int foo(void); int mid(void) { return foo(); }\n' > mid.c
printf 'extern int mid(void); int main(void) { return mid() == 7 ? 0 : 1; }\n' > root.c
$CC -shared -fPIC mid.c -Lresolve/good -Wl,-soname,libmid.so.1 \
  -Wl,--no-as-needed -l:libfoo.so.1 -o resolve/good/libmid.so.1
$CC root.c -Lresolve/good -Wl,--disable-new-dtags,-rpath,'$ORIGIN/../good' \
  -Wl,--no-as-needed -l:libmid.so.1 -o resolve/bin/rpath-root
$RESOLVE resolve --host libc.so.6 --entry /bin/rpath-root > resolve.inherited
grep -q 'consumer=good/libmid.so.1 needed=libfoo.so.1 provider=good/libfoo.so.1 source=inherited-rpath' resolve.inherited \
  && ok "resolve: inherited RPATH keeps declaring ORIGIN" \
  || bad "resolve: inherited RPATH expanded against child"
rm resolve/good/libmid.so.1 resolve/bin/rpath-root

# Reachability is the prune law: an unreachable optional plugin with a missing
# dependency does not poison the declared product closure, but scanning the
# whole tree still exposes it.
cp corpus/usefoo resolve/bad/dead-plugin
expect_exit 1 "falsify: all-ELF scan sees unreachable broken plugin" \
  $RESOLVE resolve --host libc.so.6
$RESOLVE resolve --host libc.so.6 --entry /bin/use-foo > resolve.reachable
grep -q 'consumer=bin/use-foo needed=libfoo.so.1 provider=good/libfoo.so.1' resolve.reachable \
  && ok "resolve: entrypoint closure excludes unreachable plugin" \
  || bad "resolve: entrypoint closure missing selected provider"
expect_exit 1 "falsify: nonexistent entrypoint rejected" \
  $RESOLVE resolve --host libc.so.6 --entry /bin/not-there
printf 'extern int foo(void); int bar(void) { return foo(); }\n' > bar.c
$CC -shared -fPIC bar.c -Lresolve/good -Wl,-rpath,'$ORIGIN' \
  -Wl,--no-as-needed -l:libfoo.so.1 -o resolve/good/libbar.so.1
$RESOLVE resolve --host libc.so.6 --entry-prefix /good > resolve.prefix
grep -q 'consumer=good/libbar.so.1 needed=libfoo.so.1 provider=good/libfoo.so.1 source=runpath' resolve.prefix \
  && ok "resolve: entry-prefix roots loadable shared objects" \
  || bad "resolve: entry-prefix omitted shared object"
expect_exit 1 "falsify: nonexistent entry-prefix rejected" \
  $RESOLVE resolve --host libc.so.6 --entry-prefix /not-there

# ── elf-graft: surgery + checked pre/postconditions ─────────────────────────
LDSO=$(oracle_interp corpus/hello-dyn)

# runtime proof: graft the interp to a NEW absolute path and let the KERNEL
# load it (not ld.so-as-program, not a wrapper). RUNPATH is kept on this
# specimen so provider resolution stays with the binary's own closure.
mkdir -p graftrun
cp corpus/hello-dyn graftrun/hello
cp "$LDSO" graftrun/ld.so
$GRAFT graftrun/hello --set-interp "$PWD/graftrun/ld.so" \
  && ok "graft: set-interp" || bad "graft: surgery failed"
out=$(./graftrun/hello)
[ "$out" = "hello from the corpus" ] && ok "graft: kernel executes via grafted PT_INTERP" \
  || bad "graft: runtime exec ('$out')"
[ "$($PATCHELF --print-interpreter graftrun/hello)" = "$PWD/graftrun/ld.so" ] \
  && ok "graft: patchelf reads back the new interp" || bad "graft: patchelf read-back"

# rpath surgery on a separate specimen, with both oracles reading back
cp corpus/hello-rpath graftrun/rpathless
$GRAFT graftrun/rpathless --remove-rpath \
  && ok "graft: remove-rpath" || bad "graft: remove-rpath failed"
[ -z "$($PATCHELF --print-rpath graftrun/rpathless)" ] \
  && ok "graft: patchelf sees no rpath" || bad "graft: rpath survived per patchelf"
[ -z "$(oracle_runpath graftrun/rpathless)$(oracle_rpath graftrun/rpathless)" ] \
  && ok "graft: readelf sees no rpath/runpath" || bad "graft: rpath survived per readelf"

# remove-needed, with readelf as oracle
cp corpus/usefoo graftrun/usefoo
$GRAFT graftrun/usefoo --remove-needed libfoo.so.1 \
  && ok "graft: remove-needed" || bad "graft: remove-needed failed"
oracle_needed graftrun/usefoo | grep -q libfoo && bad "graft: NEEDED survived per readelf" \
  || ok "graft: readelf confirms NEEDED removal"

# precondition: an interp longer than the slot must be refused (exit 2), file untouched
cp corpus/hello-dyn graftrun/pre
long="/$(printf 'x%.0s' $(seq 1 300))/ld.so"
before=$(sha256sum graftrun/pre | cut -d' ' -f1)
expect_exit 2 "falsify: over-long interp refused (precondition)" \
  $GRAFT graftrun/pre --set-interp "$long"
after=$(sha256sum graftrun/pre | cut -d' ' -f1)
[ "$before" = "$after" ] && ok "graft: refused graft left no bytes behind" \
  || bad "graft: precondition failure mutated the file"

# precondition: grafting a static binary
cp corpus/hello-static graftrun/static
expect_exit 2 "falsify: set-interp on a static binary refused" \
  $GRAFT graftrun/static --set-interp /lib/x

# postcondition: the deliberately bad graft — surgery skipped, check must bite
cp corpus/hello-dyn graftrun/post
expect_exit 3 "falsify: bad graft caught by postcondition" \
  $GRAFT graftrun/post --set-interp /lib/ld-std-oci-toolchain.so --test-skip-surgery

# ── the floor policy over a grafted mini-cell ───────────────────────────────
mkdir -p floor/bin floor/lib floor/cas
cp corpus/hello-dyn floor/bin/app
$GRAFT floor/bin/app --set-interp /lib/ld-std-oci-toolchain.so --remove-rpath
cp "$LDSO" floor/lib/ld-std-oci-toolchain.so
chmod +w floor/lib/ld-std-oci-toolchain.so
touch floor/cas/placeholder
# scrub residual store literals (finalize semantics, length-preserving)
python3 - << 'EOF'
import os, re
pat = re.compile(rb"/nix/store")
for dp, _, fs in os.walk("floor"):
    for f in fs:
        p = os.path.join(dp, f)
        data = open(p, "rb").read()
        new = pat.sub(b"/nix/st0re", data)
        if new != data:
            assert len(new) == len(data)
            open(p, "wb").write(new)
EOF
if $VERIFY --policy=floor floor; then ok "pass leg: floor mini-cell clean"; else bad "pass leg: floor mini-cell"; fi
# falsify the loader-at-/lib contract
rm floor/lib/ld-std-oci-toolchain.so
expect_exit 1 "falsify: floor interp without loader at lib/ fails" $VERIFY --policy=floor floor
# falsify: wrong interp under floor policy
mkdir -p floor2/bin
cp corpus/hello-dyn floor2/bin/app
python3 - << 'EOF'
import re
p = "floor2/bin/app"
data = open(p, "rb").read()
open(p, "wb").write(re.sub(rb"/nix/store", b"/nix/st0re", data))
EOF
expect_exit 1 "falsify: non-floor interp under floor policy fails" $VERIFY --policy=floor floor2

echo
echo "== $pass ok, $fail failed =="
[ "$fail" = 0 ]
