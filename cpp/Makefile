# The modern.nix ELF suite — plain make, plain compiler, no dependencies.
# The flake wraps this with nixpkgs stdenv; local dev is `make -C cpp`.

CXX ?= g++
CXXFLAGS ?= -std=c++23 -O2 -Wall -Wextra -Werror -Iinclude
PREFIX ?= /usr/local

TOOLS := elf-verify elf-census elf-graft elf-resolve elf-replay
HDRS := include/modern/elf.hpp include/modern/tree.hpp

all: $(TOOLS)

elf-%: src/elf-%.cpp $(HDRS)
	$(CXX) $(CXXFLAGS) -o $@ $<

install: $(TOOLS)
	install -D -t $(DESTDIR)$(PREFIX)/bin $(TOOLS)

clean:
	rm -f $(TOOLS)

.PHONY: all install clean
