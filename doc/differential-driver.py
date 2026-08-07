#!/usr/bin/env python3
# Gate C driver: project every canonical cell through `modern project` and
# compare BLAKE3 REAPI root digests against the locked cells/BUCK values.
import json, os, subprocess, sys

MODERN = "/nix/store/dil2byv715vzvbnxqmd7qnkk1aysmqgc-modern-cli/bin/modern"
STRAYLIGHT = "/nix/store/kc0d2s5ps25m9w2ggh70nyjgq1ival05-straylight-cli-0.1.0/bin/straylight"
STRIP = "/nix/store/z4zcd87nx2hrsdayd0vl2mx5ncj3ikd8-binutils-wrapper-2.46/bin/strip"

SYSM = "/nix/store/g2xrkpwwyjsxirn4qxfzvwys3ynnxa3m-straylight-sysroot-libstdcxx-musl-x86_64"
SYSG = "/nix/store/w17acllm26viyahy5mdasw1yzhs9864h-straylight-sysroot-libstdcxx-glibc-x86_64"
SHIM = "/nix/store/cxkgkarrv3b6ysj88463n3x3ffk1rd5l-rust-glibc-shim"
RUSTSC = "/nix/store/jhr1xv4lsm5d85v2pjlsn9y8v51zr4wn-rust-rustc1.95-libstdcxx-glibc-selfcontained"
GHCSC = "/nix/store/yincpbfqn264rm96w74pbdk4kvpsxnpi-haskell-ghc912-libstdcxx-glibc-selfcontained"
GHCDS = "/nix/store/kj5lihyq8amymzvq3mgkpry7pj7y38dq-haskell-ghc912-libstdcxx-glibc-deshelled"
CCDS = "/nix/store/in77k68jly3d22kwd5ff3a6g8fwa6fws-cc-clang22-libstdcxx-glibc-deshelled"
RTS = "/nix/store/f8dvhs3nqyidmx9zw89ly4lwvxpd1cvb-ghc-rts-extra-libs"
LEANSC = "/nix/store/liff8xj7yj9ksqvkfh8ndxda2n9y84fb-lean-lean4.30-libstdcxx-glibc-selfcontained"
LEANDS = "/nix/store/zsffkjp49mx9skcphql3psqsnk9i3fh6-lean-lean4.30-libstdcxx-glibc-deshelled"
NVSC = "/nix/store/nf55y5bdr5awi1ks32q7zca516p3349k-nv-cuda13-libstdcxx-glibc-selfcontained"
NVDS = "/nix/store/62mhx89qwrdjbrdk0l7cszy9hf5z1pja-nv-cuda13-libstdcxx-glibc-deshelled"
PTSC = "/nix/store/9jcavafwq3816pn2dngpq98li59xk8zc-prelude-tools-ghc912-libstdcxx-glibc-selfcontained"
PYSC = "/nix/store/p8qq2i2p9zadl933rnpxbxp9asnhdfz4-python-3.13-libstdcxx-glibc-selfcontained"
SZ = "/nix/store/2w31bfl4cqrr7vsbvx6k2kfciscdmsh2-stringzilla-static-x86_64-unknown-linux-musl-4.6.2"
ZL = "/nix/store/wnv30hqn9jl3jbr8s5v6qhwwbrri7wkb-zlib-static-x86_64-unknown-linux-musl-1.3.1"
LM_MANIFEST = "/nix/store/hmk0r16p4hx4iyil614vh8va3px8gagn-libmodern-manifest.json"
SJ = "/nix/store/lwd5i03r2mg6d39n6y1pz70pzb8d26ix-simdjson-static-x86_64-unknown-linux-musl-4.2.4"
SJ_MANIFEST = "/nix/store/3iyxqsxf3ajb5plich95vfnjxmwvajbl-simdjson-manifest.json"

LOCKED = {
    "cc": "a86ec9efabe7cbba98ffe45d707c2aaca9c9e2d6fb1798bb2d4d3bff604f7b3f/319",
    "cxx": "9bad876480dc022d8725bcf6e58eb4a3774f31cc4cdd9a63d83ef1f2667fe53a/319",
    "rust": "580e01383d8805689ef3bb4d3e383879bf7f4fdb9f740eb1342f01bd1c5fc297/477",
    "ghc": "61c5829a4b00afa12303d3064898ec448a2173df061508dc7093482f47915a7c/476",
    "lean": "d663df9af4277b3ff43b473d1cff01616d94bdb4fe4f1565904ed2f076f1b28c/471",
    "prelude-tools": "f4a7b7fa3a916293b8ccb3752e7ea3c410e6968e4148abe38bcbe34cd4c61784/233",
    "nv": "8af45100f6474ec04c6e04a2c1bfd08c52a30c7da1e3f26018a374b3dff2e05d/556",
    "python": "9001ee63c60ed48ff919cafc7523629012bfcb1eec8b97898fe44c801bafb376/480",
    "libmodern": "4059d79f86376438366898ca284d1f25d02f776283c9d0c798eae43c75bbf0af/248",
    "simdjson": "cef025d006236e06c321a94bb442672ed37dd3fc3c5bd525b0d0f37b93fa90c5/246",
}

def reshape_ops(src="cell"):
    return [
        {"op": "copyPath", "from": src, "path": "toolchain/.", "to": "."},
        {"op": "mkdir", "dir": "lib"},
        {"op": "copyPath", "from": src, "path": "lib/ld-std-oci-toolchain.so", "to": "lib"},
        {"op": "copyPath", "from": src, "path": "cas", "to": "."},
    ]

GHC_BIN_LINKS = {
    "ghc": "../lib/ghc-9.12.3/bin/ghc-9.12.3",
    "ghc-9.12.3": "../lib/ghc-9.12.3/bin/ghc-9.12.3",
    "ghc-pkg": "../lib/ghc-9.12.3/bin/ghc-pkg-9.12.3",
    "ghc-pkg-9.12.3": "../lib/ghc-9.12.3/bin/ghc-pkg-9.12.3",
    "haddock": "../lib/ghc-9.12.3/bin/haddock-ghc-9.12.3",
    "haddock-ghc-9.12.3": "../lib/ghc-9.12.3/bin/haddock-ghc-9.12.3",
    "hp2ps": "../lib/ghc-9.12.3/bin/hp2ps-ghc-9.12.3",
    "hp2ps-ghc-9.12.3": "../lib/ghc-9.12.3/bin/hp2ps-ghc-9.12.3",
    "hpc": "../lib/ghc-9.12.3/bin/hpc-ghc-9.12.3",
    "hpc-ghc-9.12.3": "../lib/ghc-9.12.3/bin/hpc-ghc-9.12.3",
    "hsc2hs": "../lib/ghc-9.12.3/bin/hsc2hs-ghc-9.12.3",
    "hsc2hs-ghc-9.12.3": "../lib/ghc-9.12.3/bin/hsc2hs-ghc-9.12.3",
    "runghc": "../lib/ghc-9.12.3/bin/runghc-9.12.3",
    "runghc-9.12.3": "../lib/ghc-9.12.3/bin/runghc-9.12.3",
}
GHC_BIN_DEAD = ["ghci", "ghci-9.12.3", "runhaskell", "runhaskell-9.12.3"]

ZEROS = "/" + "0" * 42 + "-"
GHC_SETTINGS = "toolchain/lib/ghc-9.12.3/lib/settings"
CC_STRIP = ["bin/clang", "bin/ld.lld", "bin/llvm-ar", "bin/llvm-dwarfdump",
            "bin/llvm-nm", "bin/llvm-objcopy", "bin/llvm-objdump",
            "bin/llvm-readelf", "bin/llvm-strip"]

def floor_gate(allow=None):
    return {"policy": "floor", "allow": allow or []}

MANIFESTS = {
    # ── cc: strip + cc symlink + rust shim graft, from the glibc sysroot ──
    "cc": {
        "name": "cc-clang22-libstdcxx-glibc",
        "sources": {"sysroot": SYSG, "shim": SHIM},
        "ops": [
            {"op": "copy", "from": "sysroot"},
            {"op": "strip", "tool": STRIP, "paths": CC_STRIP, "optional": True},
            {"op": "symlink", "at": "bin/cc", "target": "clang", "ifMissing": True},
            {"op": "copyPath", "from": "shim", "path": "libutil.so", "to": "sysroot/lib", "deref": True},
            {"op": "copyPath", "from": "shim", "path": "libgcc.a", "to": "sysroot/lib", "deref": True},
        ],
        "gate": floor_gate(),
    },
    "cxx": {
        "name": "cxx-clang22-libstdcxx-musl",
        "sources": {"sysroot": SYSM},
        "ops": [
            {"op": "copy", "from": "sysroot"},
            {"op": "strip", "tool": STRIP, "optional": True,
             "paths": ["bin/clang", "bin/clang++", "bin/ld", "bin/ld.lld", "bin/llvm-objcopy"]},
        ],
        "gate": {"policy": "static"},
    },
    "rust": {
        "name": "rust-rustc1.95-libstdcxx-glibc",
        "sources": {"cell": RUSTSC},
        "ops": reshape_ops(),
        "gate": floor_gate(["bin/rust-gdb", "bin/rust-gdbgui", "bin/rust-lldb"]),
    },
    # ── ghc: two stages — de-shell+graft, then the floor reshape ──
    "ghc-deshell": {
        "name": "haskell-ghc912-libstdcxx-glibc-deshelled",
        "sources": {"cell": GHCSC, "cc": CCDS, "rts": RTS},
        "ops": [
            {"op": "copy", "from": "cell"},
            {"op": "remove", "globs": ["toolchain/bin/" + n for n in list(GHC_BIN_LINKS) + GHC_BIN_DEAD]},
        ] + [
            {"op": "symlink", "at": "toolchain/bin/" + n, "target": t}
            for n, t in GHC_BIN_LINKS.items()
        ] + [
            {"op": "copyPath", "from": "cc", "path": ".", "to": "toolchain/cc"},
            {"op": "copyPath", "from": "rts", "path": "lib/.", "to": "toolchain/cc/sysroot/lib"},
            {"op": "rewrite", "file": GHC_SETTINGS, "replace": [
                {"from": ZEROS + "ghc-sov-clang/bin/", "to": "$topdir/../../../cc/bin/"},
                {"from": ZEROS + "straylight-sysroot-libstdcxx-glibc-x86_64/bin/", "to": "$topdir/../../../cc/bin/"},
            ]},
        ],
    },
    "ghc": {  # sources filled in after ghc-deshell projects
        "name": "haskell-ghc912-libstdcxx-glibc",
        "sources": {"cell": None},
        "ops": reshape_ops(),
        "gate": floor_gate(),
    },
    "lean-deshell": {
        "name": "lean-lean4.30-libstdcxx-glibc-deshelled",
        "sources": {"cell": LEANSC},
        "ops": [
            {"op": "copy", "from": "cell"},
            {"op": "symlink", "at": "toolchain/bin/lean", "target": ".lean-wrapped"},
        ],
    },
    "lean": {
        "name": "lean-lean4.30-libstdcxx-glibc",
        "sources": {"cell": None},
        "ops": reshape_ops(),
        "gate": floor_gate(["bin/leanmake"]),
    },
    "nv-deshell": {
        "name": "nv-cuda13-libstdcxx-glibc-deshelled",
        "sources": {"cell": NVSC},
        "ops": [
            {"op": "copy", "from": "cell"},
            {"op": "symlink", "at": "toolchain/bin/fatbinary", "target": ".fatbinary-real"},
        ],
    },
    "nv": {
        "name": "nv-cuda13-libstdcxx-glibc",
        "sources": {"cell": None},
        "ops": reshape_ops(),
        "gate": floor_gate(),
    },
    "prelude-tools": {
        "name": "prelude-tools-ghc912-libstdcxx-glibc",
        "sources": {"cell": PTSC},
        "ops": reshape_ops(),
        "gate": floor_gate(),
    },
    "python": {
        "name": "python-3.13-libstdcxx-glibc",
        "sources": {"cell": PYSC},
        "ops": reshape_ops(),
        "gate": floor_gate(["bin/pip*", "bin/idle*", "bin/pydoc*", "bin/2to3*", "bin/python*-config"]),
    },
    "libmodern": {
        "name": "libmodern",
        "sources": {"stringzilla": SZ, "zlib": ZL, "manifest": LM_MANIFEST},
        "ops": [
            {"op": "mkdir", "dir": "include"}, {"op": "mkdir", "dir": "lib"},
            {"op": "copyPath", "from": "stringzilla", "path": "include/.", "to": "include", "deref": True},
            {"op": "copyPath", "from": "stringzilla", "path": "lib/libstringzilla.a", "to": "lib"},
            {"op": "copyPath", "from": "zlib", "path": "include/.", "to": "include", "deref": True},
            {"op": "copyPath", "from": "zlib", "path": "lib/libz.a", "to": "lib"},
            {"op": "copyPath", "from": "manifest", "path": "", "to": ".", "rename": "manifest.json"},
        ],
        "gate": {"policy": "static"},
    },
    "simdjson": {
        "name": "simdjson",
        "sources": {"simdjson": SJ, "manifest": SJ_MANIFEST},
        "ops": [
            {"op": "mkdir", "dir": "include"}, {"op": "mkdir", "dir": "lib"},
            {"op": "copyPath", "from": "simdjson", "path": "include/.", "to": "include", "deref": True},
            {"op": "copyPath", "from": "simdjson", "path": "lib/libsimdjson.a", "to": "lib"},
            {"op": "copyPath", "from": "manifest", "path": "", "to": ".", "rename": "manifest.json"},
        ],
        "gate": {"policy": "static"},
    },
}

REFS = {"ghc-deshell": GHCDS, "lean-deshell": LEANDS, "nv-deshell": NVDS}

ORDER = ["cxx", "cc", "rust", "ghc-deshell", "ghc", "lean-deshell", "lean",
         "nv-deshell", "nv", "prelude-tools", "python", "libmodern", "simdjson"]

def digest(tree):
    return subprocess.run([STRAYLIGHT, "reapi", "digest", tree, "--root"],
                          capture_output=True, text=True, check=True).stdout.strip()

def main():
    base = os.path.dirname(os.path.abspath(__file__))
    results = []
    outs = {}
    only = sys.argv[1:] or ORDER
    for cell in only:
        m = dict(MANIFESTS[cell])
        if cell in ("ghc", "lean", "nv"):
            m = json.loads(json.dumps(m))
            m["sources"]["cell"] = outs[cell + "-deshell"]
        mpath = os.path.join(base, cell + ".manifest.json")
        out = os.path.join(base, "out-" + cell)
        json.dump(m, open(mpath, "w"), indent=2)
        subprocess.run(["rm", "-rf", out], check=True)
        r = subprocess.run([MODERN, "project", mpath, "--out", out],
                           capture_output=True, text=True)
        if r.returncode != 0:
            results.append((cell, "PROJECT-FAILED", r.stderr.strip().splitlines()[-3:]))
            continue
        outs[cell] = out
        got = digest(out)
        if cell in REFS:
            want = digest(REFS[cell])
            tag = "stage"
        else:
            want = LOCKED[cell]
            tag = "locked"
        ok = "IDENTICAL" if got == want else "MISMATCH"
        results.append((cell, ok, f"{tag} got={got} want={want}"))
        print(f"{cell:16s} {ok:10s} {want}", flush=True)
    print()
    for c, s, d in results:
        if s != "IDENTICAL":
            print("DETAIL", c, s, d)

main()
