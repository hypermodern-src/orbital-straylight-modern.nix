#!/usr/bin/env bash
# verify-closure.sh — structural gate against the two ELF linkage failure modes.
#
# Usage:
#   verify-closure.sh <out> <bundle-dirs-colon> <floor-dirs-colon> <ignore-space>
#
# For every native 64-bit ELF under <out>, resolve each DT_NEEDED against the
# ELF's own dir, its RUNPATH/RPATH, and an index of sonames provided by the
# bundle dirs and the system floor:
#
#   MODE 2 (dangling): a NEEDED (not ignored, not glibc-core) resolves nowhere.
#   MODE 1 (ABI shadow): a NEEDED the vendor bundle provides resolved to a
#           concrete NON-bundle (nixpkgs/floor) path instead.
#
# Design note: soname indexes are built ONCE (a couple of `find`s), and each ELF
# is read with a single `readelf -dh`. On ~1k ELFs this is ~1s, versus the naive
# per-edge `patchelf` approach which is minutes on a full container tree.

set -uo pipefail

out="$1"
IFS=':' read -r -a bundle_dirs <<<"${2:-}"
IFS=':' read -r -a floor_dirs <<<"${3:-}"
read -r -a ignore_globs <<<"${4:-}"
# When "1", treat EVERY soname anywhere under $out as bundle-provided. Correct
# for self-contained vendor trees (Triton/torch/cupy ship their own libs in
# per-package dirs; extensions resolve them from the already-loaded process at
# runtime, so they look statically dangling but are fine). Avoids enumerating
# every python package lib dir as a bundleDir.
out_is_bundle="${5:-0}"

echo "verify-closure: auditing ELF linkage under $out ..."

# ── Index sonames provided by bundle / floor (built once) ─────────────────────
declare -A bundle_has=() avail=()
index_dirs() {
  local kind="$1"
  shift
  local d f b
  for d in "$@"; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    while IFS= read -r f; do
      b="${f##*/}"
      avail["$b"]=1
      [ "$kind" = bundle ] && bundle_has["$b"]=1
    done < <(find "$d" -maxdepth 1 -name "*.so*" 2>/dev/null || true)
  done
}
index_dirs bundle "${bundle_dirs[@]:-}"
index_dirs floor "${floor_dirs[@]:-}"

if [ "$out_is_bundle" = "1" ]; then
  while IFS= read -r f; do
    b="${f##*/}"
    avail["$b"]=1
    bundle_has["$b"]=1
  done < <(find "$out" -name "*.so*" 2>/dev/null || true)
fi

is_ignored() {
  local n="$1" g
  for g in "${ignore_globs[@]:-}"; do
    # shellcheck disable=SC2254
    case "$n" in $g) return 0 ;; esac
  done
  return 1
}

# glibc core + loader are the ambient ABI floor every process gets.
is_core() {
  case "$1" in
  libc.so.6 | libm.so.6 | libpthread.so.0 | librt.so.1 | libdl.so.2 | \
    libutil.so.1 | libresolv.so.2 | libnsl.so.* | ld-linux*.so.*) return 0 ;;
  esac
  return 1
}

fail=0
while IFS= read -r elf; do
  [ -L "$elf" ] && continue
  hdr="$(readelf -dh "$elf" 2>/dev/null)" || continue
  case "$hdr" in *ELF64*) ;; *) continue ;; esac # native 64-bit only
  owndir="${elf%/*}"

  # RUNPATH/RPATH (first match), expand $ORIGIN to the ELF's own dir.
  rpath="$(printf '%s\n' "$hdr" | sed -n -E 's/.*\((RUNPATH|RPATH)\).*\[(.*)\]/\2/p' | head -1)"
  rpath="${rpath//\$ORIGIN/$owndir}"
  rpath="${rpath//'${ORIGIN}'/$owndir}"

  while IFS= read -r need; do
    [ -z "$need" ] && continue
    is_ignored "$need" && continue
    is_core "$need" && continue

    resolved_dir=""
    if [ -e "$owndir/$need" ]; then
      resolved_dir="$owndir"
    else
      saved_ifs="$IFS"
      IFS=':'
      for d in $rpath; do
        [ -n "$d" ] && [ -e "$d/$need" ] && {
          resolved_dir="$d"
          break
        }
      done
      IFS="$saved_ifs"
    fi
    if [ -z "$resolved_dir" ] && [ -n "${avail[$need]:-}" ]; then
      resolved_dir="__indexed__"
    fi

    if [ -z "$resolved_dir" ]; then
      echo "verify-closure: MODE2 dangling: $elf needs $need (resolves nowhere)" >&2
      fail=1
      continue
    fi

    # MODE1: bundle-provided soname resolved to a concrete non-bundle path.
    # own dir, any in-$out path, or the (bundle-first) index are all fine.
    if [ -n "${bundle_has[$need]:-}" ]; then
      case "$resolved_dir" in
      __indexed__) : ;;
      "$out"/*) : ;;
      *)
        echo "verify-closure: MODE1 ABI-shadow: $elf resolved $need via non-bundle $resolved_dir (bundle provides this soname)" >&2
        fail=1
        ;;
      esac
    fi
  done < <(printf '%s\n' "$hdr" | sed -n -E 's/.*\(NEEDED\).*Shared library: \[(.*)\]/\1/p')
done < <(find "$out" -type f \( -executable -o -name "*.so*" \) 2>/dev/null || true)

if [ "$fail" -ne 0 ]; then
  echo "verify-closure: FAILED — lurking linkage issues above. Fix RPATH/bundle ordering or the system floor." >&2
  exit 1
fi
echo "verify-closure: OK — no ABI-shadow or dangling NEEDED under $out."
