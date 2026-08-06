// elf-census — the byte-level reference walk, as data.
//
// Emits one deterministic line per tree entry (sorted by path): kind, exec
// bit, PT_INTERP, DT_NEEDED, DT_SONAME, DT_RPATH/RUNPATH presence, and the
// count of /nix/store byte occurrences. Two trees are census-equivalent iff
// their outputs are byte-identical — the differential leg used where a cell's
// compiler build is known non-deterministic (bit-identity is impossible, but
// the ELF *shape* must still agree).
//
// By default sizes are OMITTED (they wobble across non-deterministic
// rebuilds); --sizes adds them for the strict form.

#include <cstdio>
#include <string>

#include "modern/tree.hpp"

int main(int argc, char** argv) {
  bool sizes = false;
  std::string root;
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    if (a == "--sizes") sizes = true;
    else if (a.rfind("--", 0) == 0) {
      std::fprintf(stderr, "usage: elf-census [--sizes] TREE\n");
      return 2;
    } else if (root.empty()) root = a;
    else {
      std::fprintf(stderr, "usage: elf-census [--sizes] TREE\n");
      return 2;
    }
  }
  if (root.empty()) {
    std::fprintf(stderr, "usage: elf-census [--sizes] TREE\n");
    return 2;
  }

  auto wr = modern::tree::walk(root);
  if (!wr.errors.empty()) {
    for (const auto& e : wr.errors) std::fprintf(stderr, "elf-census: %s\n", e.c_str());
    return 1;
  }

  for (const auto& e : wr.entries) {
    using modern::tree::EntryType;
    std::string line = e.rel;
    switch (e.type) {
      case EntryType::Dir:
        line += "|dir";
        break;
      case EntryType::Symlink:
        line += "|symlink|->" + e.link_target;
        if (e.link_absolute) line += "|absolute";
        if (e.link_dangling) line += "|dangling";
        break;
      case EntryType::Special:
        line += "|special";
        break;
      case EntryType::File: {
        line += std::string("|") + modern::elf::kind_name(e.kind);
        if (e.executable) line += "|x";
        if (sizes) line += "|size=" + std::to_string(e.size);
        if (e.has_interp) line += "|interp=" + e.interp;
        if (!e.needed.empty()) {
          line += "|needed=";
          for (size_t i = 0; i < e.needed.size(); ++i) {
            if (i) line += ",";
            line += e.needed[i];
          }
        }
        if (!e.soname.empty()) line += "|soname=" + e.soname;
        if (e.has_rpath) line += "|rpath=" + e.rpath;
        if (e.has_runpath) line += "|runpath=" + e.runpath;
        if (e.store_refs > 0) line += "|storerefs=" + std::to_string(e.store_refs);
        if (!e.parse_error.empty()) line += "|error=" + e.parse_error;
        break;
      }
    }
    std::printf("%s\n", line.c_str());
  }
  return 0;
}
