// elf-verify — declarative predicates over a projected tree.
//
// The producer-side gate of the modern.nix ELF suite: given a tree that
// CLAIMS to be a standalone cell, re-prove the claims over the bytes.
//
//   --policy=static   every ELF is genuinely static: no PT_INTERP, no
//                     DT_NEEDED (+ store scan, script scan, symlink checks)
//   --policy=floor    every bin/ ELF's PT_INTERP is the §12 floor loader,
//                     and the tree carries lib/ld-std-oci-toolchain.so + cas/
//                     (+ store scan, script scan, symlink checks)
//
// Individual predicates compose without a policy:
//   --require-static --interp=PATH --needed-closure --no-store-refs
//   --no-scripts-in-bin --check-symlinks
//   --allow GLOB      waive the script check for matching bin entries
//   --ignore SONAME   waive a DT_NEEDED in the closure check (host-provided
//                     at runtime, e.g. libcuda.so.1)
//
// Failure modes this exists for (the historical specimen ledger):
//   * a bash wrapper with an ELF's name (pkgsStatic.gzip's bin/gzip) — the
//     script scan catches what the filename hides;
//   * a PT_INTERP-bearing binary claimed static — --require-static reads the
//     program headers, not the label;
//   * a /nix/store reference smuggled in any byte of any file.
//
// Exit: 0 = all predicates hold; 1 = violations (each reported); 2 = usage.

#include <cstdio>
#include <cstring>
#include <set>
#include <string>
#include <vector>

#include "modern/elf.hpp"
#include "modern/tree.hpp"

namespace {

using modern::elf::Kind;
using modern::tree::Entry;
using modern::tree::EntryType;

constexpr const char* kFloorInterp = "/lib/ld-std-oci-toolchain.so";

// Tiny fnmatch: '*' matches any run (including '/'); everything else literal.
bool match_glob(const char* pat, const char* s) {
  if (*pat == '\0') return *s == '\0';
  if (*pat == '*') {
    for (const char* t = s;; ++t) {
      if (match_glob(pat + 1, t)) return true;
      if (*t == '\0') return false;
    }
  }
  return *pat == *s && match_glob(pat + 1, s + 1);
}

struct Options {
  bool require_static = false;
  bool no_store_refs = false;
  bool no_scripts_in_bin = false;
  bool check_symlinks = false;
  bool needed_closure = false;
  bool floor_layout = false;  // loader-at-/lib contract (set by --policy=floor)
  std::string interp;         // required PT_INTERP for bin ELFs, empty = unchecked
  std::vector<std::string> allow;
  std::set<std::string> ignore;
  std::string tree;
};

int usage() {
  std::fprintf(stderr,
               "usage: elf-verify [--policy=static|floor] [predicates...] TREE\n"
               "  predicates: --require-static --interp=PATH --needed-closure\n"
               "              --no-store-refs --no-scripts-in-bin --check-symlinks\n"
               "              --allow GLOB --ignore SONAME\n");
  return 2;
}

bool is_real_elf(Kind k) {
  return k == Kind::ElfExec || k == Kind::ElfDyn || k == Kind::ElfRel ||
         k == Kind::ElfOther || k == Kind::Elf32;
}

}  // namespace

int main(int argc, char** argv) {
  Options o;
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    auto next = [&]() -> const char* { return (i + 1 < argc) ? argv[++i] : nullptr; };
    if (a == "--policy=static") {
      o.require_static = o.no_store_refs = o.no_scripts_in_bin = o.check_symlinks = true;
    } else if (a == "--policy=floor") {
      o.interp = kFloorInterp;
      o.floor_layout = true;
      o.no_store_refs = o.no_scripts_in_bin = o.check_symlinks = true;
    } else if (a == "--require-static") {
      o.require_static = true;
    } else if (a.rfind("--interp=", 0) == 0) {
      o.interp = a.substr(9);
    } else if (a == "--needed-closure") {
      o.needed_closure = true;
    } else if (a == "--no-store-refs") {
      o.no_store_refs = true;
    } else if (a == "--no-scripts-in-bin") {
      o.no_scripts_in_bin = true;
    } else if (a == "--check-symlinks") {
      o.check_symlinks = true;
    } else if (a == "--allow") {
      if (const char* v = next()) o.allow.push_back(v); else return usage();
    } else if (a == "--ignore") {
      if (const char* v = next()) o.ignore.insert(v); else return usage();
    } else if (a.rfind("--", 0) == 0) {
      std::fprintf(stderr, "elf-verify: unknown flag %s\n", a.c_str());
      return usage();
    } else if (o.tree.empty()) {
      o.tree = a;
    } else {
      return usage();
    }
  }
  if (o.tree.empty()) return usage();

  auto wr = modern::tree::walk(o.tree);
  std::vector<std::string> violations;
  for (const auto& err : wr.errors) violations.push_back("(walk) " + err);

  // Basename index for the closure check (files and symlinks both provide).
  std::set<std::string> basenames;
  for (const auto& e : wr.entries) {
    if (e.type == EntryType::Dir) continue;
    auto slash = e.rel.rfind('/');
    basenames.insert(slash == std::string::npos ? e.rel : e.rel.substr(slash + 1));
  }

  bool floor_interp_seen = false;
  for (const auto& e : wr.entries) {
    switch (e.type) {
      case EntryType::Special:
        violations.push_back(e.rel + ": special file (not file/dir/symlink)");
        continue;
      case EntryType::Dir:
        continue;
      case EntryType::Symlink:
        if (o.check_symlinks) {
          if (e.link_absolute)
            violations.push_back(e.rel + ": absolute symlink -> " + e.link_target);
          else if (e.link_dangling)
            violations.push_back(e.rel + ": dangling symlink -> " + e.link_target);
        }
        continue;
      case EntryType::File:
        break;
    }

    if (e.kind == Kind::Malformed)
      violations.push_back(e.rel + ": malformed ELF: " + e.parse_error);

    if (o.no_store_refs && e.store_refs > 0)
      violations.push_back(e.rel + ": /nix/store literal (" + std::to_string(e.store_refs) +
                           " occurrence" + (e.store_refs == 1 ? "" : "s") + ")");

    if (o.no_scripts_in_bin && e.kind == Kind::Script && modern::tree::is_bin_entry(e.rel)) {
      bool waived = false;
      for (const auto& g : o.allow)
        if (match_glob(g.c_str(), e.rel.c_str())) { waived = true; break; }
      if (!waived)
        violations.push_back(e.rel +
                             ": script entrypoint under bin/ (dead on an empty host; "
                             "an ELF name proves nothing)");
    }

    if (o.require_static && is_real_elf(e.kind)) {
      if (e.kind == Kind::Elf32)
        violations.push_back(e.rel + ": 32-bit ELF (outside the static-cell population)");
      if (e.has_interp)
        violations.push_back(e.rel + ": PT_INTERP present (" + e.interp +
                             ") — binary claimed static is dynamic");
      if (!e.needed.empty())
        violations.push_back(e.rel + ": DT_NEEDED present (" + e.needed.front() +
                             (e.needed.size() > 1 ? ", ..." : "") +
                             ") — binary claimed static links dynamically");
      if (e.has_rpath || e.has_runpath)
        violations.push_back(e.rel + ": DT_RPATH/DT_RUNPATH present in a static cell");
    }

    if (!o.interp.empty() && e.has_interp && modern::tree::is_bin_entry(e.rel)) {
      if (e.interp == o.interp)
        floor_interp_seen = true;
      else
        violations.push_back(e.rel + ": PT_INTERP is " + e.interp + " (want " + o.interp + ")");
    }
    if (!o.interp.empty() && e.has_interp && e.interp == o.interp)
      floor_interp_seen = true;

    if (o.needed_closure && (e.kind == Kind::ElfExec || e.kind == Kind::ElfDyn)) {
      for (const auto& so : e.needed) {
        if (o.ignore.count(so)) continue;
        if (!basenames.count(so))
          violations.push_back(e.rel + ": DT_NEEDED " + so +
                               " resolves nowhere in the tree (dangling NEEDED)");
      }
    }
  }

  if (o.floor_layout && floor_interp_seen) {
    bool loader = basenames.count("ld-std-oci-toolchain.so") > 0;
    bool cas = false;
    for (const auto& e : wr.entries)
      if (e.type == EntryType::Dir && e.rel == "cas") cas = true;
    if (!loader)
      violations.push_back("lib/ld-std-oci-toolchain.so: floor interp seen but loader missing");
    if (!cas) violations.push_back("cas: floor interp seen but closure missing at cas/");
  }

  for (const auto& v : violations) std::printf("VIOLATION %s\n", v.c_str());
  if (!violations.empty()) {
    std::fprintf(stderr, "elf-verify: %zu violation(s) in %s\n", violations.size(),
                 o.tree.c_str());
    return 1;
  }
  std::fprintf(stderr, "elf-verify: %s clean\n", o.tree.c_str());
  return 0;
}
