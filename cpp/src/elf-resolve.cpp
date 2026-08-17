// elf-resolve — deterministic dynamic-loader resolution planner.
//
// This is deliberately a planner, not a patcher.  Given an extracted rootfs,
// it records the provider selected for every DT_NEEDED edge using the
// consumer's own DT_RPATH/DT_RUNPATH and an explicitly declared default path.
// Absolute paths are interpreted inside ROOT; a symlink or $ORIGIN expansion
// that escapes ROOT is rejected.  The sorted, line-oriented plan is both a
// human audit surface and stable input to the projection layer.

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <optional>
#include <set>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>
#include <deque>
#include <fnmatch.h>

#include "modern/tree.hpp"

namespace fs = std::filesystem;
using modern::elf::Kind;

namespace {

struct Options {
  fs::path root;
  std::vector<std::string> library_path;
  std::vector<std::string> defaults{"/lib64", "/lib", "/usr/lib64", "/usr/lib",
                                    "/usr/local/lib"};
  std::set<std::string> host;
  std::map<std::string, std::string> cache;
  std::vector<std::string> entries;
  std::vector<std::string> entry_prefixes;
  std::vector<std::string> entry_globs;
};

struct Edge {
  std::string root;
  std::string consumer;
  std::string needed;
  std::string provider;
  std::string source;
};

auto split_colon(const std::string& value) -> std::vector<std::string> {
  std::vector<std::string> out;
  std::stringstream stream(value);
  std::string item;
  while (std::getline(stream, item, ':')) {
    if (!item.empty()) out.push_back(item);
  }
  return out;
}

auto replace_all(std::string value, std::string_view needle, const std::string& replacement)
    -> std::string {
  for (std::size_t at = 0; (at = value.find(needle, at)) != std::string::npos;) {
    value.replace(at, needle.size(), replacement);
    at += replacement.size();
  }
  return value;
}

auto under(const fs::path& root, const fs::path& path) -> bool {
  auto r = root.lexically_normal();
  auto p = path.lexically_normal();
  auto ri = r.begin();
  auto pi = p.begin();
  for (; ri != r.end(); ++ri, ++pi) {
    if (pi == p.end() || *ri != *pi) return false;
  }
  return true;
}

auto root_path(const fs::path& root, const fs::path& origin, std::string raw)
    -> std::optional<fs::path> {
  const auto origin_in_root = fs::relative(origin, root).generic_string();
  raw = replace_all(std::move(raw), "${ORIGIN}", "/" + origin_in_root);
  raw = replace_all(std::move(raw), "$ORIGIN", "/" + origin_in_root);
  // Other dynamic string tokens are target/platform facts.  Guessing them is
  // forbidden; callers must supply their expanded directories explicitly.
  if (raw.find('$') != std::string::npos) return std::nullopt;
  fs::path candidate = raw.starts_with('/') ? root / raw.substr(1) : origin / raw;
  return candidate.lexically_normal();
}

auto canonical_inside(const fs::path& root, const fs::path& candidate)
    -> std::optional<fs::path> {
  // std::filesystem::canonical follows an absolute symlink against the HOST
  // root. OCI/rootfs semantics require `/x` to mean ROOT/x. Walk components
  // ourselves so both relative and absolute links remain in the declared tree.
  auto normalized = candidate.lexically_normal();
  if (!under(root, normalized)) return std::nullopt;
  std::deque<fs::path> todo;
  for (const auto& part : normalized.lexically_relative(root)) todo.push_back(part);
  fs::path current = root;
  unsigned links = 0;
  while (!todo.empty()) {
    auto part = std::move(todo.front());
    todo.pop_front();
    if (part == "." || part.empty()) continue;
    if (part == "..") {
      if (current == root) return std::nullopt;
      current = current.parent_path();
      continue;
    }
    auto next = current / part;
    std::error_code ec;
    auto status = fs::symlink_status(next, ec);
    if (ec || status.type() == fs::file_type::not_found) return std::nullopt;
    if (status.type() != fs::file_type::symlink) {
      current = std::move(next);
      continue;
    }
    if (++links > 40) return std::nullopt;
    auto target = fs::read_symlink(next, ec);
    if (ec) return std::nullopt;
    if (target.is_absolute()) current = root;
    std::vector<fs::path> parts;
    for (const auto& target_part : target.relative_path()) parts.push_back(target_part);
    for (auto it = parts.rbegin(); it != parts.rend(); ++it) todo.push_front(*it);
  }
  if (!under(root, current)) return std::nullopt;
  std::error_code ec;
  if (!fs::exists(current, ec) || ec) return std::nullopt;
  return current.lexically_normal();
}

auto rel(const fs::path& root, const fs::path& path) -> std::string {
  return fs::relative(path, root).generic_string();
}

auto resolve(const Options& o, const fs::path& consumer, const modern::tree::Entry& entry,
             const std::vector<std::string>& inherited_rpath, const std::string& needed)
    -> std::optional<Edge> {
  const fs::path origin = consumer.parent_path();
  if (needed.find('/') != std::string::npos) {
    auto p = root_path(o.root, origin, needed);
    if (!p) return std::nullopt;
    auto selected = canonical_inside(o.root, *p);
    if (!selected) return std::nullopt;
    return Edge{"", entry.rel, needed, rel(o.root, *selected), "needed-path"};
  }

  std::vector<std::pair<std::string, std::string>> search;
  // glibc: DT_RPATH is used only when DT_RUNPATH is absent.  An explicit
  // library path then precedes DT_RUNPATH; defaults are last.  We intentionally
  // do not read ambient LD_LIBRARY_PATH.
  if (!entry.has_runpath && entry.has_rpath)
    for (const auto& p : split_colon(entry.rpath)) search.emplace_back(p, "rpath");
  for (const auto& p : inherited_rpath) search.emplace_back(p, "inherited-rpath");
  for (const auto& p : o.library_path) search.emplace_back(p, "library-path");
  if (entry.has_runpath)
    for (const auto& p : split_colon(entry.runpath)) search.emplace_back(p, "runpath");
  for (const auto& [directory, source] : search) {
    auto d = root_path(o.root, origin, directory);
    if (!d) continue;
    auto selected = canonical_inside(o.root, *d / needed);
    if (selected) return Edge{"", entry.rel, needed, rel(o.root, *selected), source};
  }
  if (auto it = o.cache.find(needed); it != o.cache.end()) {
    auto p = root_path(o.root, origin, it->second);
    if (!p) return std::nullopt;
    auto selected = canonical_inside(o.root, *p);
    if (!selected) return std::nullopt;
    return Edge{"", entry.rel, needed, rel(o.root, *selected), "cache"};
  }
  for (const auto& directory : o.defaults) {
    auto d = root_path(o.root, origin, directory);
    if (!d) continue;
    auto selected = canonical_inside(o.root, *d / needed);
    if (selected) return Edge{"", entry.rel, needed, rel(o.root, *selected), "default"};
  }
  return std::nullopt;
}

auto read_cache_plan(const fs::path& file, std::map<std::string, std::string>& cache)
    -> bool {
  std::ifstream input(file);
  if (!input) return false;
  std::string line;
  while (std::getline(input, line)) {
    if (line.empty() || line.starts_with('#')) continue;
    std::istringstream fields(line);
    std::string soname;
    std::string path;
    std::string residue;
    if (!(fields >> soname >> path) || (fields >> residue) || !path.starts_with('/')) return false;
    // First entry wins. A normalized plan generated from `ldconfig -p`
    // preserves the cache's preference order without consulting ambient state.
    cache.try_emplace(std::move(soname), std::move(path));
  }
  return true;
}

auto usage() -> int {
  std::cerr << "usage: elf-resolve ROOT [--library-path PATH] [--default PATH] "
               "[--no-defaults] [--host SONAME] [--cache-plan FILE] [--entry PATH] "
               "[--entry-prefix PATH]\n"
               "       elf-resolve ROOT --entry-glob GLOB ...\n"
               "cache plan format: one 'SONAME ROOT-ABSOLUTE-PATH' per line\n";
  return 2;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) return usage();
  Options o;
  o.root = fs::absolute(argv[1]).lexically_normal();
  for (int i = 2; i < argc; ++i) {
    const std::string arg = argv[i];
    if (arg == "--no-defaults") {
      o.defaults.clear();
    } else if ((arg == "--library-path" || arg == "--default" || arg == "--host" ||
                arg == "--cache-plan" || arg == "--entry" || arg == "--entry-prefix" ||
                arg == "--entry-glob") &&
               i + 1 < argc) {
      const std::string value = argv[++i];
      if (arg == "--library-path") o.library_path.push_back(value);
      if (arg == "--default") o.defaults.push_back(value);
      if (arg == "--host") o.host.insert(value);
      if (arg == "--entry") o.entries.push_back(value);
      if (arg == "--entry-prefix") o.entry_prefixes.push_back(value);
      if (arg == "--entry-glob") o.entry_globs.push_back(value);
      if (arg == "--cache-plan" && !read_cache_plan(value, o.cache)) {
        std::cerr << "elf-resolve: malformed cache plan: " << value << '\n';
        return 2;
      }
    } else {
      return usage();
    }
  }

  std::error_code ec;
  o.root = fs::canonical(o.root, ec);
  if (ec || !fs::is_directory(o.root)) {
    std::cerr << "elf-resolve: invalid root\n";
    return 2;
  }

  auto walked = modern::tree::walk(o.root);
  bool failed = false;
  for (const auto& error : walked.errors) {
    std::cerr << "ERROR " << error << '\n';
    failed = true;
  }

  std::map<std::string, const modern::tree::Entry*> elf_entries;
  for (const auto& entry : walked.entries)
    if (entry.kind == Kind::ElfExec || entry.kind == Kind::ElfDyn)
      elf_entries.emplace(entry.rel, &entry);

  struct Work {
    std::string path;
    std::string root;
    std::vector<std::string> inherited_rpath;
  };
  std::deque<Work> pending;
  auto enqueue_root = [&](const std::string& path) { pending.push_back({path, path, {}}); };
  if (o.entries.empty() && o.entry_prefixes.empty() && o.entry_globs.empty()) {
    for (const auto& [path, _] : elf_entries) enqueue_root(path);
  } else {
    for (const auto& raw : o.entries) {
      auto requested = root_path(o.root, o.root, raw);
      auto selected = requested ? canonical_inside(o.root, *requested) : std::nullopt;
      if (!selected) {
        std::cerr << "INVALID_ENTRY path=" << raw << '\n';
        failed = true;
        continue;
      }
      enqueue_root(rel(o.root, *selected));
    }
    for (const auto& raw : o.entry_prefixes) {
      auto requested = root_path(o.root, o.root, raw);
      auto selected = requested ? canonical_inside(o.root, *requested) : std::nullopt;
      if (!selected || !fs::is_directory(*selected)) {
        std::cerr << "INVALID_ENTRY_PREFIX path=" << raw << '\n';
        failed = true;
        continue;
      }
      const auto prefix = rel(o.root, *selected);
      for (const auto& [path, _] : elf_entries)
        if (path == prefix || path.starts_with(prefix + "/")) enqueue_root(path);
    }
    for (const auto& pattern : o.entry_globs) {
      bool matched = false;
      for (const auto& [path, _] : elf_entries) {
        // No FNM_PATHNAME: '*' intentionally crosses directories, making the
        // pattern independent of Python package nesting depth.
        if (fnmatch(pattern.c_str(), path.c_str(), 0) == 0) {
          enqueue_root(path);
          matched = true;
        }
      }
      if (!matched) {
        std::cerr << "EMPTY_ENTRY_GLOB pattern=" << pattern << '\n';
        failed = true;
      }
    }
  }

  std::set<std::string> visited;
  std::vector<Edge> edges;
  while (!pending.empty()) {
    auto work = std::move(pending.front());
    pending.pop_front();
    std::string visit_key = work.root + "\n" + work.path;
    for (const auto& p : work.inherited_rpath) visit_key += "\n" + p;
    if (!visited.insert(visit_key).second) continue;
    auto found = elf_entries.find(work.path);
    if (found == elf_entries.end()) {
      std::cerr << "NOT_ELF path=" << work.path << '\n';
      failed = true;
      continue;
    }
    const auto& entry = *found->second;
    const auto consumer = o.root / entry.rel;
    for (const auto& needed : entry.needed) {
      if (o.host.contains(needed)) {
        edges.push_back({work.root, entry.rel, needed, "@host", "host"});
        continue;
      }
      auto edge = resolve(o, consumer, entry, work.inherited_rpath, needed);
      if (!edge) {
        std::cerr << "UNRESOLVED root=" << work.root << " consumer=" << entry.rel
                  << " needed=" << needed << '\n';
        failed = true;
      } else {
        edge->root = work.root;
        if (edge->provider != "@host") {
          auto inherited = work.inherited_rpath;
          if (!entry.has_runpath && entry.has_rpath) {
            std::vector<std::string> own;
            for (const auto& raw : split_colon(entry.rpath)) {
              auto expanded = root_path(o.root, consumer.parent_path(), raw);
              if (expanded && under(o.root, *expanded))
                own.push_back("/" + expanded->lexically_relative(o.root).generic_string());
            }
            own.insert(own.end(), inherited.begin(), inherited.end());
            inherited = std::move(own);
          }
          pending.push_back({edge->provider, work.root, std::move(inherited)});
        }
        edges.push_back(std::move(*edge));
      }
    }
  }
  std::ranges::sort(edges, {}, [](const Edge& e) { return std::tie(e.root, e.consumer, e.needed); });
  for (const auto& e : edges)
    std::cout << "EDGE root=" << e.root << " consumer=" << e.consumer << " needed=" << e.needed
              << " provider=" << e.provider << " source=" << e.source << '\n';
  return failed ? 1 : 0;
}
