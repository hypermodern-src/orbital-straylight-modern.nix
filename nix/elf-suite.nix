# The C++23 ELF suite, built with the plain nixpkgs stdenv (gcc).
#
# Compiler choice, recorded: nixpkgs' default stdenv (gcc 15.x at the current
# pin). Rationale: the suite is the BOTTOM of the bootstrap — it must build
# with whatever plain nixpkgs provides, with zero straylight inputs; gcc is
# the stdenv default and C++23 support is complete. The library core is our
# own mmap'd ELF64 reader/writer (cpp/include/modern/elf.hpp) — no libbfd, no
# libelf, no vendored third-party parser.
{ stdenv }:

stdenv.mkDerivation {
  pname = "modern-elf-suite";
  version = "0.1.0";

  src = ../cpp;

  makeFlags = [ "PREFIX=${placeholder "out"}" ];
  enableParallelBuilding = true;

  meta = {
    description = "elf-verify / elf-census / elf-graft / elf-resolve — the modern.nix ELF suite";
    mainProgram = "elf-verify";
  };
}
