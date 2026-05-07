PREFIX  ?= /usr/local
BINDIR  := $(PREFIX)/bin
BIN     := playlist-convert
BUILT   := .build/release/PlaylistConvert

.PHONY: help build sign install uninstall clean test

help:
	@echo "Targets:"
	@echo "  make build      Build a release binary at $(BUILT)"
	@echo "  make install    Build, ad-hoc sign, and symlink into $(BINDIR)/$(BIN)"
	@echo "  make uninstall  Remove the symlink at $(BINDIR)/$(BIN)"
	@echo "  make test       Run the XCTest suite"
	@echo "  make clean      Remove build artifacts"
	@echo ""
	@echo "Override the install location with PREFIX=... (default: /usr/local)"

build:
	swift build -c release

sign: build
	codesign --force --sign - $(BUILT)

install: sign
	@mkdir -p "$(BINDIR)" 2>/dev/null || sudo mkdir -p "$(BINDIR)"
	@if [ -w "$(BINDIR)" ]; then \
		ln -sf "$(CURDIR)/$(BUILT)" "$(BINDIR)/$(BIN)"; \
	else \
		echo "Need sudo to write to $(BINDIR)"; \
		sudo ln -sf "$(CURDIR)/$(BUILT)" "$(BINDIR)/$(BIN)"; \
	fi
	@echo ""
	@echo "✓ Installed: $(BINDIR)/$(BIN) -> $(CURDIR)/$(BUILT)"
	@echo "  First run: $(BIN)   (it'll walk you through setup)"

uninstall:
	@if [ -L "$(BINDIR)/$(BIN)" ] || [ -f "$(BINDIR)/$(BIN)" ]; then \
		if [ -w "$(BINDIR)" ]; then rm -f "$(BINDIR)/$(BIN)"; else sudo rm -f "$(BINDIR)/$(BIN)"; fi; \
		echo "✓ Removed $(BINDIR)/$(BIN)"; \
	else \
		echo "Nothing to remove at $(BINDIR)/$(BIN)"; \
	fi

test:
	swift test

clean:
	swift package clean
	rm -rf .build
