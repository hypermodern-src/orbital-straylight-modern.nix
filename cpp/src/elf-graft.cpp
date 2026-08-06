// elf-graft — interp/rpath/needed surgery with checked pre/postconditions.
//
// The §12 producer's scalpel, retiring patchelf for the graft operations the
// projection actually performs. Every operation is IN-PLACE and the file
// never changes size:
//
//   --set-interp PATH    rewrite PT_INTERP within its existing slot (the §12
//                        graft always shrinks: a /nix/store ld.so path is
//                        longer than /lib/ld-std-oci-toolchain.so). Growing
//                        is a PRECONDITION failure, not a silent relayout.
//   --remove-rpath       drop every DT_RPATH/DT_RUNPATH entry (compact the
//                        dynamic array, DT_NULL-fill the tail)
//   --remove-needed SO   drop a DT_NEEDED entry by name
//   --print              report interp/needed/rpath/runpath and exit
//
// Contract: preconditions are checked before any byte is written (exit 2);
// after surgery the file is re-opened and re-parsed and the requested state
// is asserted (exit 3 on failure). --test-skip-surgery is the falsification
// hook: it runs the full postcondition check WITHOUT performing the surgery,
// so the postcondition leg can be demonstrated to actually bite.
//
// Exit: 0 ok; 1 --print parse trouble; 2 precondition; 3 postcondition.

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include <sys/stat.h>

#include "modern/elf.hpp"

namespace {

using namespace modern::elf;

int usage() {
  std::fprintf(stderr,
               "usage: elf-graft FILE (--print | [--set-interp PATH] [--remove-rpath]"
               " [--remove-needed SONAME]... [--test-skip-surgery])\n");
  return 2;
}

int print_facts(const std::string& file) {
  auto im = Image::open(file, false);
  if (!im) { std::fprintf(stderr, "elf-graft: %s\n", im.error().c_str()); return 1; }
  Parsed p = parse(im->bytes());
  std::printf("kind: %s\n", kind_name(p.kind));
  if (p.kind == Kind::Malformed) std::printf("error: %s\n", p.error.c_str());
  if (p.interp)
    std::printf("interp: %s (slot %llu bytes)\n", p.interp->value.c_str(),
                static_cast<unsigned long long>(p.interp->capacity));
  if (p.dyn) {
    for (const auto& n : p.dyn->needed) std::printf("needed: %s\n", n.c_str());
    if (p.dyn->soname) std::printf("soname: %s\n", p.dyn->soname->c_str());
    if (p.dyn->rpath) std::printf("rpath: %s\n", p.dyn->rpath->c_str());
    if (p.dyn->runpath) std::printf("runpath: %s\n", p.dyn->runpath->c_str());
  }
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  std::string file, new_interp;
  bool remove_rpath = false, do_print = false, test_skip = false;
  std::vector<std::string> remove_needed;

  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    auto next = [&]() -> const char* { return (i + 1 < argc) ? argv[++i] : nullptr; };
    if (a == "--print") do_print = true;
    else if (a == "--set-interp") {
      if (const char* v = next()) new_interp = v; else return usage();
    } else if (a == "--remove-rpath") remove_rpath = true;
    else if (a == "--remove-needed") {
      if (const char* v = next()) remove_needed.push_back(v); else return usage();
    } else if (a == "--test-skip-surgery") test_skip = true;
    else if (a.rfind("--", 0) == 0) return usage();
    else if (file.empty()) file = a;
    else return usage();
  }
  if (file.empty()) return usage();
  if (do_print) return print_facts(file);
  if (new_interp.empty() && !remove_rpath && remove_needed.empty()) return usage();

  struct stat before{};
  if (stat(file.c_str(), &before) != 0) {
    std::fprintf(stderr, "elf-graft: cannot stat %s\n", file.c_str());
    return 2;
  }

  if (!test_skip) {
    auto im = Image::open(file, true);
    if (!im) { std::fprintf(stderr, "elf-graft: %s\n", im.error().c_str()); return 2; }

    if (!new_interp.empty()) {
      auto r = set_interp(*im, new_interp);
      if (!r) {
        std::fprintf(stderr, "elf-graft: precondition: %s\n", r.error().message.c_str());
        return r.error().exit_code;
      }
    }
    if (remove_rpath) {
      auto r = drop_dyn_entries(*im, [](int64_t tag, uint64_t) {
        return tag == DT_RPATH || tag == DT_RUNPATH;
      });
      if (!r) {
        std::fprintf(stderr, "elf-graft: precondition: %s\n", r.error().message.c_str());
        return r.error().exit_code;
      }
    }
    if (!remove_needed.empty()) {
      // Need the strtab to compare names: parse once read-only for names.
      auto snapshot = parse(im->bytes());
      if (!snapshot.dyn || !snapshot.dyn->strtab_resolved) {
        std::fprintf(stderr, "elf-graft: precondition: no resolvable DT_STRTAB\n");
        return 2;
      }
      // Re-derive strtab offset for name lookups during the drop.
      std::optional<uint64_t> strtab_off;
      {
        auto b = im->bytes();
        const size_t n_dyn = snapshot.dyn_filesz / 16;
        for (size_t i = 0; i < n_dyn; ++i) {
          const uint8_t* d = b.data() + snapshot.dyn_offset + i * 16;
          if (static_cast<int64_t>(load_le<uint64_t>(d)) == DT_STRTAB)
            strtab_off = vaddr_to_offset(snapshot.phdrs, load_le<uint64_t>(d + 8));
        }
      }
      auto r = drop_dyn_entries(*im, [&](int64_t tag, uint64_t val) {
        if (tag != DT_NEEDED || !strtab_off) return false;
        auto name = cstr_at(im->bytes(), *strtab_off + val);
        if (!name) return false;
        for (const auto& want : remove_needed)
          if (*name == want) return true;
        return false;
      });
      if (!r) {
        std::fprintf(stderr, "elf-graft: precondition: %s\n", r.error().message.c_str());
        return r.error().exit_code;
      }
    }
  }

  // ── postconditions: re-open, re-parse, assert the requested state ────────
  std::vector<std::string> post;
  struct stat after{};
  if (stat(file.c_str(), &after) != 0) {
    post.push_back("file vanished after surgery");
  } else if (after.st_size != before.st_size) {
    post.push_back("file size changed (" + std::to_string(before.st_size) + " -> " +
                   std::to_string(after.st_size) + ") — grafts must be in-place");
  }
  {
    auto im = Image::open(file, false);
    if (!im) {
      post.push_back("cannot re-open for verification");
    } else {
      Parsed p = parse(im->bytes());
      if (p.kind == Kind::Malformed)
        post.push_back("post-graft parse failed: " + p.error);
      if (!new_interp.empty()) {
        if (!p.interp)
          post.push_back("PT_INTERP missing after --set-interp");
        else if (p.interp->value != new_interp)
          post.push_back("PT_INTERP is '" + p.interp->value + "', wanted '" + new_interp + "'");
      }
      if (remove_rpath && p.dyn && (p.dyn->rpath || p.dyn->runpath))
        post.push_back("DT_RPATH/DT_RUNPATH still present after --remove-rpath");
      if (!remove_needed.empty() && p.dyn)
        for (const auto& want : remove_needed)
          for (const auto& n : p.dyn->needed)
            if (n == want) post.push_back("DT_NEEDED " + want + " still present");
    }
  }

  if (!post.empty()) {
    for (const auto& m : post)
      std::fprintf(stderr, "elf-graft: postcondition FAILED: %s\n", m.c_str());
    return 3;
  }
  std::fprintf(stderr, "elf-graft: %s ok\n", file.c_str());
  return 0;
}
