// modern/elf.hpp — the ELF core of the modern.nix bootstrap suite.
//
// A single-header ELF64 reader/writer over mmap'd bytes. C++23, no
// dependencies beyond the C library and POSIX mmap. This is deliberately NOT
// libbfd/libelf: the §12 producer population is ELF64 little-endian
// (x86_64/aarch64) and the three tools built on this header (elf-verify,
// elf-census, elf-graft) need exactly:
//
//   - classification: real ELF vs script vs data (the pkgsStatic.gzip
//     bash-wrapper specimen taught us a file's NAME proves nothing);
//   - the program-header walk: PT_INTERP (offset, capacity, string);
//   - the dynamic section via PT_DYNAMIC + PT_LOAD vaddr mapping (robust when
//     the section table is stripped): DT_NEEDED / DT_SONAME / DT_RPATH /
//     DT_RUNPATH resolved against DT_STRTAB;
//   - byte scans (the /nix/store reference walk);
//   - in-place, length-preserving surgery (graft): PT_INTERP rewrite within
//     the existing slot, DT_RPATH/DT_RUNPATH/DT_NEEDED removal by compacting
//     the fixed-size dynamic array. The file NEVER grows or moves sections —
//     every §12 graft shrinks (store interp -> /lib/ld-std-oci-toolchain.so).
//
// Everything parses defensively: a malformed table is a reported condition,
// never UB. All multi-byte reads are little-endian from unaligned bytes.

#pragma once

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <expected>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

namespace modern::elf {

// ── constants ───────────────────────────────────────────────────────────────
inline constexpr uint32_t PT_LOAD = 1;
inline constexpr uint32_t PT_DYNAMIC = 2;
inline constexpr uint32_t PT_INTERP = 3;

inline constexpr int64_t DT_NULL = 0;
inline constexpr int64_t DT_NEEDED = 1;
inline constexpr int64_t DT_STRTAB = 5;
inline constexpr int64_t DT_SONAME = 14;
inline constexpr int64_t DT_RPATH = 15;
inline constexpr int64_t DT_RUNPATH = 29;

inline constexpr uint16_t ET_EXEC = 2;
inline constexpr uint16_t ET_DYN = 3;
inline constexpr uint16_t ET_REL = 1;

// ── little-endian unaligned reads/writes ────────────────────────────────────
template <typename T>
inline T load_le(const uint8_t* p) {
  T v{};
  std::memcpy(&v, p, sizeof(T));
  return v;  // x86_64/aarch64 hosts are little-endian; the format is too.
}
template <typename T>
inline void store_le(uint8_t* p, T v) {
  std::memcpy(p, &v, sizeof(T));
}

// ── file kinds ──────────────────────────────────────────────────────────────
enum class Kind {
  Data,        // regular bytes, no recognized magic
  Script,      // leading "#!"
  Elf32,       // ELFCLASS32 — recognized, not parsed (outside the §12 population)
  ElfExec,     // ELF64 ET_EXEC
  ElfDyn,      // ELF64 ET_DYN (PIE or shared object)
  ElfRel,      // ELF64 ET_REL (relocatable object)
  ElfOther,    // ELF64, other e_type
  ElfBadEndian,
  Malformed,   // ELF magic but tables are broken — reason in Parsed::error
};

struct DynInfo {
  std::vector<std::string> needed;
  std::optional<std::string> soname;
  std::optional<std::string> rpath;    // DT_RPATH
  std::optional<std::string> runpath;  // DT_RUNPATH
  bool strtab_resolved = false;        // false => names above may be absent
};

struct InterpInfo {
  uint64_t offset;    // file offset of the PT_INTERP segment
  uint64_t capacity;  // p_filesz — the slot's byte capacity (incl. NUL)
  std::string value;  // NUL-stripped interpreter string
};

struct Phdr {
  uint32_t p_type, p_flags;
  uint64_t p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align;
};

struct Parsed {
  Kind kind = Kind::Data;
  std::string error;  // set when kind == Malformed
  uint16_t machine = 0;
  std::vector<Phdr> phdrs;
  std::optional<InterpInfo> interp;
  std::optional<DynInfo> dyn;  // present iff PT_DYNAMIC exists and parsed
  // location of the dynamic array in the FILE, for surgery:
  uint64_t dyn_offset = 0, dyn_filesz = 0;
};

// ── the mapped file ─────────────────────────────────────────────────────────
class Image {
 public:
  Image() = default;
  Image(const Image&) = delete;
  Image& operator=(const Image&) = delete;
  Image(Image&& o) noexcept { *this = std::move(o); }
  Image& operator=(Image&& o) noexcept {
    close();
    data_ = o.data_; size_ = o.size_; fd_ = o.fd_; writable_ = o.writable_;
    o.data_ = nullptr; o.size_ = 0; o.fd_ = -1;
    return *this;
  }
  ~Image() { close(); }

  static std::expected<Image, std::string> open(const std::string& path, bool writable) {
    Image im;
    im.writable_ = writable;
    im.fd_ = ::open(path.c_str(), writable ? O_RDWR : O_RDONLY);
    if (im.fd_ < 0) return std::unexpected("open failed: " + path);
    struct stat st{};
    if (fstat(im.fd_, &st) != 0) return std::unexpected("fstat failed: " + path);
    im.size_ = static_cast<size_t>(st.st_size);
    if (im.size_ == 0) return im;  // empty file: Kind::Data
    void* m = mmap(nullptr, im.size_, writable ? (PROT_READ | PROT_WRITE) : PROT_READ,
                   writable ? MAP_SHARED : MAP_PRIVATE, im.fd_, 0);
    if (m == MAP_FAILED) return std::unexpected("mmap failed: " + path);
    im.data_ = static_cast<uint8_t*>(m);
    return im;
  }

  std::span<const uint8_t> bytes() const { return {data_, size_}; }
  std::span<uint8_t> mutable_bytes() {
    return writable_ ? std::span<uint8_t>{data_, size_} : std::span<uint8_t>{};
  }
  size_t size() const { return size_; }
  bool valid() const { return data_ != nullptr || size_ == 0; }

  void sync() {
    if (data_ && writable_) msync(data_, size_, MS_SYNC);
  }

 private:
  void close() {
    if (data_) munmap(data_, size_);
    if (fd_ >= 0) ::close(fd_);
    data_ = nullptr; size_ = 0; fd_ = -1;
  }
  uint8_t* data_ = nullptr;
  size_t size_ = 0;
  int fd_ = -1;
  bool writable_ = false;
};

// ── parsing ─────────────────────────────────────────────────────────────────
inline bool has_elf_magic(std::span<const uint8_t> b) {
  return b.size() >= 4 && b[0] == 0x7f && b[1] == 'E' && b[2] == 'L' && b[3] == 'F';
}

inline std::optional<uint64_t> vaddr_to_offset(const std::vector<Phdr>& phdrs, uint64_t v) {
  for (const auto& p : phdrs)
    if (p.p_type == PT_LOAD && v >= p.p_vaddr && v < p.p_vaddr + p.p_filesz)
      return v - p.p_vaddr + p.p_offset;
  return std::nullopt;
}

// Read a NUL-terminated string at file offset `off`, bounded by the file.
inline std::optional<std::string> cstr_at(std::span<const uint8_t> b, uint64_t off) {
  if (off >= b.size()) return std::nullopt;
  const uint8_t* s = b.data() + off;
  const uint8_t* e = static_cast<const uint8_t*>(std::memchr(s, 0, b.size() - off));
  if (!e) return std::nullopt;
  return std::string(reinterpret_cast<const char*>(s), static_cast<size_t>(e - s));
}

inline Parsed parse(std::span<const uint8_t> b) {
  Parsed out;
  if (b.size() >= 2 && b[0] == '#' && b[1] == '!') {
    out.kind = Kind::Script;
    return out;
  }
  if (!has_elf_magic(b)) return out;  // Data
  if (b.size() < 0x40) {
    out.kind = Kind::Malformed;
    out.error = "truncated ELF header";
    return out;
  }
  const uint8_t cls = b[4], endian = b[5];
  if (cls == 1) { out.kind = Kind::Elf32; return out; }
  if (cls != 2) { out.kind = Kind::Malformed; out.error = "bad ELF class"; return out; }
  if (endian != 1) { out.kind = Kind::ElfBadEndian; return out; }

  const uint16_t e_type = load_le<uint16_t>(b.data() + 0x10);
  out.machine = load_le<uint16_t>(b.data() + 0x12);
  const uint64_t phoff = load_le<uint64_t>(b.data() + 0x20);
  const uint16_t phentsize = load_le<uint16_t>(b.data() + 0x36);
  const uint16_t phnum = load_le<uint16_t>(b.data() + 0x38);

  switch (e_type) {
    case ET_EXEC: out.kind = Kind::ElfExec; break;
    case ET_DYN: out.kind = Kind::ElfDyn; break;
    case ET_REL: out.kind = Kind::ElfRel; break;
    default: out.kind = Kind::ElfOther; break;
  }
  if (out.kind == Kind::ElfRel || phnum == 0) return out;  // no phdrs to walk

  if (phentsize < 56) {
    out.kind = Kind::Malformed; out.error = "bad e_phentsize"; return out;
  }
  if (phnum == 0xffff) {  // PN_XNUM: real count in sh_info of shdr 0 — out of scope
    out.kind = Kind::Malformed; out.error = "PN_XNUM program-header count unsupported"; return out;
  }
  if (phoff + uint64_t(phentsize) * phnum > b.size()) {
    out.kind = Kind::Malformed; out.error = "program-header table outside file"; return out;
  }

  for (uint16_t i = 0; i < phnum; ++i) {
    const uint8_t* p = b.data() + phoff + uint64_t(i) * phentsize;
    Phdr h{};
    h.p_type = load_le<uint32_t>(p + 0x00);
    h.p_flags = load_le<uint32_t>(p + 0x04);
    h.p_offset = load_le<uint64_t>(p + 0x08);
    h.p_vaddr = load_le<uint64_t>(p + 0x10);
    h.p_paddr = load_le<uint64_t>(p + 0x18);
    h.p_filesz = load_le<uint64_t>(p + 0x20);
    h.p_memsz = load_le<uint64_t>(p + 0x28);
    h.p_align = load_le<uint64_t>(p + 0x30);
    out.phdrs.push_back(h);
  }

  for (const auto& h : out.phdrs) {
    if (h.p_type == PT_INTERP) {
      if (h.p_offset + h.p_filesz > b.size() || h.p_filesz == 0) {
        out.kind = Kind::Malformed; out.error = "PT_INTERP outside file"; return out;
      }
      InterpInfo ii;
      ii.offset = h.p_offset;
      ii.capacity = h.p_filesz;
      const char* s = reinterpret_cast<const char*>(b.data() + h.p_offset);
      size_t n = strnlen(s, h.p_filesz);
      ii.value.assign(s, n);
      out.interp = std::move(ii);
    }
    if (h.p_type == PT_DYNAMIC) {
      out.dyn_offset = h.p_offset;
      out.dyn_filesz = h.p_filesz;
    }
  }

  if (out.dyn_filesz != 0) {
    if (out.dyn_offset + out.dyn_filesz > b.size()) {
      out.kind = Kind::Malformed; out.error = "PT_DYNAMIC outside file"; return out;
    }
    DynInfo di;
    // First pass: find DT_STRTAB.
    std::optional<uint64_t> strtab_off;
    const size_t n_dyn = out.dyn_filesz / 16;
    for (size_t i = 0; i < n_dyn; ++i) {
      const uint8_t* d = b.data() + out.dyn_offset + i * 16;
      const int64_t tag = static_cast<int64_t>(load_le<uint64_t>(d));
      const uint64_t val = load_le<uint64_t>(d + 8);
      if (tag == DT_NULL) break;
      if (tag == DT_STRTAB) strtab_off = vaddr_to_offset(out.phdrs, val);
    }
    di.strtab_resolved = strtab_off.has_value();
    auto name_of = [&](uint64_t val) -> std::optional<std::string> {
      if (!strtab_off) return std::nullopt;
      return cstr_at(b, *strtab_off + val);
    };
    for (size_t i = 0; i < n_dyn; ++i) {
      const uint8_t* d = b.data() + out.dyn_offset + i * 16;
      const int64_t tag = static_cast<int64_t>(load_le<uint64_t>(d));
      const uint64_t val = load_le<uint64_t>(d + 8);
      if (tag == DT_NULL) break;
      switch (tag) {
        case DT_NEEDED:
          if (auto s = name_of(val)) di.needed.push_back(*s);
          break;
        case DT_SONAME:
          if (auto s = name_of(val)) di.soname = *s;
          break;
        case DT_RPATH:
          if (auto s = name_of(val)) di.rpath = *s;
          else di.rpath = "";  // present but unresolvable — still counts as present
          break;
        case DT_RUNPATH:
          if (auto s = name_of(val)) di.runpath = *s;
          else di.runpath = "";
          break;
        default: break;
      }
    }
    out.dyn = std::move(di);
  }
  return out;
}

// ── byte scan ───────────────────────────────────────────────────────────────
inline size_t count_occurrences(std::span<const uint8_t> b, std::string_view needle) {
  if (needle.empty() || b.size() < needle.size()) return 0;
  size_t count = 0;
  const uint8_t* cur = b.data();
  const uint8_t* end = b.data() + b.size();
  while (cur < end) {
    const void* hit = memmem(cur, static_cast<size_t>(end - cur), needle.data(), needle.size());
    if (!hit) break;
    ++count;
    cur = static_cast<const uint8_t*>(hit) + 1;
  }
  return count;
}

// ── surgery (in-place, length-preserving at the file level) ────────────────
struct GraftError {
  int exit_code;  // 2 = precondition, 3 = postcondition
  std::string message;
};

// Rewrite PT_INTERP to `new_interp` within the existing slot. The file never
// grows: precondition is strlen(new)+1 <= capacity. The slot is zero-padded
// and p_filesz/p_memsz shrink to strlen(new)+1 so the kernel (which reads
// exactly p_filesz bytes and requires NUL-termination) sees a clean string.
inline std::expected<void, GraftError> set_interp(Image& im, const std::string& new_interp) {
  auto b = im.mutable_bytes();
  if (b.empty()) return std::unexpected(GraftError{2, "file not writable"});
  Parsed p = parse(im.bytes());
  if (p.kind != Kind::ElfExec && p.kind != Kind::ElfDyn)
    return std::unexpected(GraftError{2, "not an ELF executable/shared object"});
  if (!p.interp)
    return std::unexpected(GraftError{2, "no PT_INTERP segment (static binary?)"});
  const uint64_t need = new_interp.size() + 1;
  if (need > p.interp->capacity)
    return std::unexpected(GraftError{
        2, "new interpreter (" + std::to_string(need) + " bytes) does not fit PT_INTERP slot (" +
               std::to_string(p.interp->capacity) + " bytes) — in-place graft only shrinks"});

  // Rewrite the slot: string + NUL, zero-fill the remainder of the old slot.
  std::memset(b.data() + p.interp->offset, 0, p.interp->capacity);
  std::memcpy(b.data() + p.interp->offset, new_interp.data(), new_interp.size());

  // Shrink p_filesz/p_memsz of the PT_INTERP phdr.
  const uint64_t phoff = load_le<uint64_t>(b.data() + 0x20);
  const uint16_t phentsize = load_le<uint16_t>(b.data() + 0x36);
  const uint16_t phnum = load_le<uint16_t>(b.data() + 0x38);
  for (uint16_t i = 0; i < phnum; ++i) {
    uint8_t* ph = b.data() + phoff + uint64_t(i) * phentsize;
    if (load_le<uint32_t>(ph) == PT_INTERP) {
      store_le<uint64_t>(ph + 0x20, need);  // p_filesz
      store_le<uint64_t>(ph + 0x28, need);  // p_memsz
    }
  }

  // Keep the .interp SECTION header honest too (readelf and section-walkers
  // read it; the kernel does not). Best-effort: find a section whose
  // sh_offset matches the interp slot and shrink sh_size.
  const uint64_t shoff = load_le<uint64_t>(b.data() + 0x28);
  const uint16_t shentsize = load_le<uint16_t>(b.data() + 0x3a);
  const uint16_t shnum = load_le<uint16_t>(b.data() + 0x3c);
  if (shoff != 0 && shentsize >= 64 && shoff + uint64_t(shentsize) * shnum <= b.size()) {
    for (uint16_t i = 0; i < shnum; ++i) {
      uint8_t* sh = b.data() + shoff + uint64_t(i) * shentsize;
      const uint64_t sh_offset = load_le<uint64_t>(sh + 0x18);
      const uint64_t sh_size = load_le<uint64_t>(sh + 0x20);
      if (sh_offset == p.interp->offset && sh_size == p.interp->capacity)
        store_le<uint64_t>(sh + 0x20, need);
    }
  }
  im.sync();
  return {};
}

// Compact the dynamic array, dropping entries selected by `drop`. The array
// is fixed-size in the file; removed entries are compacted out and the tail
// is DT_NULL-filled. Returns the number of entries dropped.
template <typename Pred>
inline std::expected<size_t, GraftError> drop_dyn_entries(Image& im, Pred drop) {
  auto b = im.mutable_bytes();
  if (b.empty()) return std::unexpected(GraftError{2, "file not writable"});
  Parsed p = parse(im.bytes());
  if (p.kind != Kind::ElfExec && p.kind != Kind::ElfDyn)
    return std::unexpected(GraftError{2, "not an ELF executable/shared object"});
  if (p.dyn_filesz == 0)
    return std::unexpected(GraftError{2, "no PT_DYNAMIC segment"});

  const size_t n_dyn = p.dyn_filesz / 16;
  uint8_t* base = b.data() + p.dyn_offset;
  std::vector<std::pair<uint64_t, uint64_t>> kept;
  size_t dropped = 0;
  bool past_null = false;
  for (size_t i = 0; i < n_dyn; ++i) {
    const uint64_t tag_raw = load_le<uint64_t>(base + i * 16);
    const uint64_t val = load_le<uint64_t>(base + i * 16 + 8);
    const int64_t tag = static_cast<int64_t>(tag_raw);
    if (past_null || tag == DT_NULL) { past_null = true; continue; }
    if (drop(tag, val)) { ++dropped; continue; }
    kept.emplace_back(tag_raw, val);
  }
  for (size_t i = 0; i < n_dyn; ++i) {
    if (i < kept.size()) {
      store_le<uint64_t>(base + i * 16, kept[i].first);
      store_le<uint64_t>(base + i * 16 + 8, kept[i].second);
    } else {
      store_le<uint64_t>(base + i * 16, 0);
      store_le<uint64_t>(base + i * 16 + 8, 0);
    }
  }
  im.sync();
  return dropped;
}

inline const char* kind_name(Kind k) {
  switch (k) {
    case Kind::Data: return "data";
    case Kind::Script: return "script";
    case Kind::Elf32: return "elf32";
    case Kind::ElfExec: return "elf-exec";
    case Kind::ElfDyn: return "elf-dyn";
    case Kind::ElfRel: return "elf-rel";
    case Kind::ElfOther: return "elf-other";
    case Kind::ElfBadEndian: return "elf-bigendian";
    case Kind::Malformed: return "elf-malformed";
  }
  return "unknown";
}

}  // namespace modern::elf
