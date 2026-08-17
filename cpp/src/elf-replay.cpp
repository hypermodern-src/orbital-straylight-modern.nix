// elf-replay — independent verifier for an elf-resolve edge plan.
//
// This intentionally does not resolve libraries.  It treats the plan as an
// artifact and replays its claims against the rootfs bytes: strict grammar,
// root-confined paths, real ELF consumers/providers, exact DT_NEEDED coverage,
// host-boundary consistency, and provider-closure coverage.  A planner bug or
// a stale/tampered plan must therefore fail in a second executable.

#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <tuple>
#include <vector>

#include "modern/elf.hpp"

namespace fs = std::filesystem;
using modern::elf::Kind;

namespace {

struct Edge {
  std::string root;
  std::string consumer;
  std::string needed;
  std::string provider;
  std::string source;
  std::string context;
};

auto field(const std::string& token, const std::string& key, std::string& out) -> bool {
  const auto prefix = key + "=";
  if (!token.starts_with(prefix) || token.size() == prefix.size()) return false;
  out = token.substr(prefix.size());
  return true;
}

auto safe_relative(const std::string& raw) -> bool {
  if (raw.empty() || raw.starts_with('/')) return false;
  const fs::path path(raw);
  if (path.lexically_normal().generic_string() != raw) return false;
  for (const auto& part : path)
    if (part == ".." || part == "." || part.empty()) return false;
  return true;
}

auto parse_edge(const std::string& line, Edge& edge) -> bool {
  std::istringstream input(line);
  std::string tag, root, consumer, needed, provider, source, context, residue;
  if (!(input >> tag >> root >> consumer >> needed >> provider >> source >> context) ||
      input >> residue)
    return false;
  return tag == "EDGE" && field(root, "root", edge.root) &&
         field(consumer, "consumer", edge.consumer) && field(needed, "needed", edge.needed) &&
         field(provider, "provider", edge.provider) && field(source, "source", edge.source) &&
         field(context, "context", edge.context);
}

auto read_elf(const fs::path& path) -> std::optional<modern::elf::Parsed> {
  auto image = modern::elf::Image::open(path.string(), false);
  if (!image) return std::nullopt;
  auto parsed = modern::elf::parse(image->bytes());
  if (parsed.kind != Kind::ElfExec && parsed.kind != Kind::ElfDyn) return std::nullopt;
  return parsed;
}

auto usage() -> int {
  std::cerr << "usage: elf-replay ROOT PLAN\n";
  return 2;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 3) return usage();
  std::error_code ec;
  const auto rootfs = fs::canonical(fs::absolute(argv[1]), ec);
  if (ec || !fs::is_directory(rootfs)) return usage();
  std::ifstream plan(argv[2]);
  if (!plan) return usage();

  bool failed = false;
  std::vector<Edge> edges;
  std::string line;
  unsigned line_number = 0;
  while (std::getline(plan, line)) {
    ++line_number;
    if (line.empty()) continue;
    Edge edge;
    if (!parse_edge(line, edge)) {
      std::cerr << "MALFORMED line=" << line_number << '\n';
      failed = true;
      continue;
    }
    edges.push_back(std::move(edge));
  }

  using Context = std::tuple<std::string, std::string, std::string>;
  std::map<Context, std::multiset<std::string>> planned;
  std::map<Context, std::multiset<std::string>> actual;
  using Provider = std::pair<std::string, std::string>;
  std::set<Provider> providers;
  std::map<std::string, modern::elf::Parsed> parsed;

  auto load = [&](const std::string& rel) -> std::optional<modern::elf::Parsed> {
    if (auto found = parsed.find(rel); found != parsed.end()) return found->second;
    if (!safe_relative(rel)) return std::nullopt;
    std::error_code path_ec;
    const auto resolved = fs::canonical(rootfs / rel, path_ec);
    if (path_ec) return std::nullopt;
    const auto confined = resolved.lexically_relative(rootfs);
    if (confined.empty() || confined.is_absolute() || *confined.begin() == "..")
      return std::nullopt;
    auto value = read_elf(resolved);
    if (value) parsed.emplace(rel, *value);
    return value;
  };

  static const std::set<std::string> sources = {
      "needed-path", "rpath", "inherited-rpath", "library-path", "runpath", "cache",
      "default", "host"};

  if (edges.empty()) {
    std::cerr << "EMPTY_PLAN\n";
    failed = true;
  }

  for (const auto& edge : edges) {
    if (!safe_relative(edge.root) || !safe_relative(edge.consumer) || edge.needed.empty() ||
        edge.needed.find('/') != std::string::npos || edge.context.empty() ||
        !sources.contains(edge.source)) {
      std::cerr << "INVALID_EDGE consumer=" << edge.consumer << " needed=" << edge.needed << '\n';
      failed = true;
      continue;
    }
    if (!load(edge.root)) {
      std::cerr << "INVALID_ROOT root=" << edge.root << '\n';
      failed = true;
    }
    const auto consumer = load(edge.consumer);
    if (!consumer || !consumer->dyn) {
      std::cerr << "NOT_ELF consumer=" << edge.consumer << '\n';
      failed = true;
      continue;
    }
    const Context context{edge.root, edge.consumer, edge.context};
    planned[context].insert(edge.needed);
    if (!actual.contains(context))
      actual[context].insert(consumer->dyn->needed.begin(), consumer->dyn->needed.end());

    if (edge.provider == "@host") {
      if (edge.source != "host") {
        std::cerr << "HOST_SOURCE consumer=" << edge.consumer << " needed=" << edge.needed << '\n';
        failed = true;
      }
    } else {
      if (edge.source == "host" || !safe_relative(edge.provider) || !load(edge.provider)) {
        std::cerr << "INVALID_PROVIDER consumer=" << edge.consumer << " provider=" << edge.provider
                  << '\n';
        failed = true;
      } else {
        providers.emplace(edge.root, edge.provider);
      }
    }
  }

  for (const auto& [context, needs] : actual) {
    if (planned[context] != needs) {
      std::cerr << "COVERAGE root=" << std::get<0>(context)
                << " consumer=" << std::get<1>(context)
                << " context=" << std::get<2>(context) << '\n';
      failed = true;
    }
  }
  for (const auto& context : providers) {
    const auto provider = load(context.second);
    bool covered = false;
    for (const auto& [candidate, _] : actual)
      if (std::get<0>(candidate) == context.first && std::get<1>(candidate) == context.second)
        covered = true;
    if (provider && provider->dyn && !provider->dyn->needed.empty() && !covered) {
      std::cerr << "UNCLOSED root=" << context.first << " provider=" << context.second << '\n';
      failed = true;
    }
  }

  if (!failed)
    std::cout << "REPLAY edges=" << edges.size() << " contexts=" << actual.size() << "\n";
  return failed ? 1 : 0;
}
