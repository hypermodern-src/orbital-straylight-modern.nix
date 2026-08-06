// modern/tree.hpp — the tree walk shared by elf-verify and elf-census.
//
// Walks a projected cell tree WITHOUT following symlinks, classifying every
// entry: regular files get the full ELF parse + the /nix/store byte scan,
// symlinks get target inspection (absolute targets and danglers are the two
// symlink failure classes a §12 tree can carry). Entries come back sorted by
// relative path so every consumer's output is deterministic.

#pragma once

#include <filesystem>
#include <string>
#include <vector>

#include <sys/stat.h>
#include <unistd.h>

#include "modern/elf.hpp"

namespace modern::tree {

namespace fs = std::filesystem;

inline constexpr std::string_view kStoreNeedle = "/nix/store";

enum class EntryType { File, Symlink, Dir, Special };

struct Entry {
  std::string rel;  // path relative to the tree root, '/'-separated
  EntryType type = EntryType::File;

  // symlink facts
  std::string link_target;
  bool link_absolute = false;
  bool link_dangling = false;

  // regular-file facts
  bool executable = false;
  uintmax_t size = 0;
  elf::Kind kind = elf::Kind::Data;
  std::string parse_error;
  std::string interp;
  bool has_interp = false;
  std::vector<std::string> needed;
  std::string soname;
  std::string rpath;    // DT_RPATH if present
  std::string runpath;  // DT_RUNPATH if present
  bool has_rpath = false;
  bool has_runpath = false;
  size_t store_refs = 0;  // occurrences of "/nix/store" in the bytes
};

// Is this rel path a direct entry of some bin/ directory? ("bin/x", "a/bin/x")
inline bool is_bin_entry(const std::string& rel) {
  auto slash = rel.rfind('/');
  if (slash == std::string::npos) return false;
  std::string dir = rel.substr(0, slash);
  return dir == "bin" || (dir.size() >= 4 && dir.compare(dir.size() - 4, 4, "/bin") == 0);
}

struct WalkResult {
  std::vector<Entry> entries;
  std::vector<std::string> errors;  // I/O errors, unreadable files
};

inline WalkResult walk(const fs::path& root) {
  WalkResult out;
  std::error_code ec;
  auto it = fs::recursive_directory_iterator(
      root, fs::directory_options::none, ec);
  if (ec) {
    out.errors.push_back("cannot open tree root: " + root.string() + ": " + ec.message());
    return out;
  }
  for (auto end = fs::recursive_directory_iterator(); it != end; it.increment(ec)) {
    if (ec) {
      out.errors.push_back("walk error: " + ec.message());
      break;
    }
    const fs::path& p = it->path();
    Entry e;
    e.rel = fs::relative(p, root).generic_string();

    struct stat st{};
    if (lstat(p.c_str(), &st) != 0) {
      out.errors.push_back("lstat failed: " + e.rel);
      continue;
    }
    if (S_ISLNK(st.st_mode)) {
      it.disable_recursion_pending();
      e.type = EntryType::Symlink;
      std::error_code lec;
      fs::path target = fs::read_symlink(p, lec);
      if (lec) {
        out.errors.push_back("readlink failed: " + e.rel);
        continue;
      }
      e.link_target = target.string();
      e.link_absolute = target.is_absolute();
      if (!e.link_absolute) {
        // lstat suffices: an intermediate symlink counts as present.
        fs::path resolved = p.parent_path() / target;
        struct stat ts{};
        e.link_dangling = (lstat(resolved.c_str(), &ts) != 0);
      } else {
        struct stat ts{};
        e.link_dangling = (lstat(target.c_str(), &ts) != 0);
      }
      out.entries.push_back(std::move(e));
      continue;
    }
    if (S_ISDIR(st.st_mode)) {
      e.type = EntryType::Dir;
      out.entries.push_back(std::move(e));
      continue;
    }
    if (!S_ISREG(st.st_mode)) {
      e.type = EntryType::Special;
      out.entries.push_back(std::move(e));
      continue;
    }

    e.type = EntryType::File;
    e.executable = (st.st_mode & S_IXUSR) != 0;
    e.size = static_cast<uintmax_t>(st.st_size);

    auto im = elf::Image::open(p.string(), /*writable=*/false);
    if (!im) {
      out.errors.push_back(im.error());
      continue;
    }
    auto bytes = im->bytes();
    elf::Parsed parsed = elf::parse(bytes);
    e.kind = parsed.kind;
    e.parse_error = parsed.error;
    if (parsed.interp) {
      e.has_interp = true;
      e.interp = parsed.interp->value;
    }
    if (parsed.dyn) {
      e.needed = parsed.dyn->needed;
      if (parsed.dyn->soname) e.soname = *parsed.dyn->soname;
      if (parsed.dyn->rpath) { e.has_rpath = true; e.rpath = *parsed.dyn->rpath; }
      if (parsed.dyn->runpath) { e.has_runpath = true; e.runpath = *parsed.dyn->runpath; }
    }
    e.store_refs = elf::count_occurrences(bytes, kStoreNeedle);
    out.entries.push_back(std::move(e));
  }
  std::sort(out.entries.begin(), out.entries.end(),
            [](const Entry& a, const Entry& b) { return a.rel < b.rel; });
  return out;
}

}  // namespace modern::tree
