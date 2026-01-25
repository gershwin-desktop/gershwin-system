# GNUmakefile for gershwin-system
# Installs the contents of the repository `Library` directory into /System/Library
# (or $(DESTDIR)/System/Library when DESTDIR is set).

DESTDIR ?=
SYS_LIB_DIR := $(DESTDIR)/System/Library
LIBSRC := Library

STAMP := $(DESTDIR)/System/Library/Receipts/System.stamp
STAMP_DIR := $(dir $(STAMP))

.PHONY: all install uninstall clean

all:
	@echo "Nothing to build for gershwin-system"

install:
	@echo "Installing contents of '$(LIBSRC)' into '$(SYS_LIB_DIR)' (stamp: $(STAMP))"
	@if [ ! -d "$(LIBSRC)" ]; then echo "Source directory '$(LIBSRC)' not found"; exit 1; fi
	@mkdir -p "$(SYS_LIB_DIR)"
	@mkdir -p "$(STAMP_DIR)"
	@rm -f "$(STAMP)"
	@# Use tar to preserve attributes and symlinks, then write a stamp file listing installed paths
	@cd "$(LIBSRC)" && tar cf - . | (cd "$(SYS_LIB_DIR)" && tar xpf -)
	@cd "$(LIBSRC)" && find . -mindepth 1 -print | sed 's|^|$(SYS_LIB_DIR)/|' > "$(STAMP)"
	@echo "Install complete. Recorded installed items in '$(STAMP)'"

uninstall:
	@echo "Removing items recorded in stamp '$(STAMP)' from '$(SYS_LIB_DIR)'"
	@if [ ! -f "$(STAMP)" ]; then echo "Stamp file '$(STAMP)' not found; nothing to remove"; exit 0; fi
	@# Remove entries in stamp (safe: only removes paths we recorded)
	@sort -r "$(STAMP)" | while read -r f; do \
		if [ -e "$$f" ]; then rm -rf "$$f" && echo "Removed $$f"; fi; \
	done
	@rm -f "$(STAMP)"
	@echo "Uninstall complete."

clean:
	@echo "Nothing to clean."
