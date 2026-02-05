PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin

.PHONY: all build release install uninstall clean

all: build

build:
	zig build

release:
	zig build -Doptimize=ReleaseFast

install: release
	install -d $(DESTDIR)$(BINDIR)
	install -m 755 zig-out/bin/lifetch $(DESTDIR)$(BINDIR)/lifetch

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/lifetch

clean:
	rm -rf zig-out .zig-cache
