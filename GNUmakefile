# GNUmakefile for gershwin-system
# Installs the bundled `Library` directory into /System/Library (or $(DESTDIR)/System/Library)

DESTDIR ?=
SYS_LIB_DIR := $(DESTDIR)/System/Library
LIBSRC := Library

.PHONY: all install uninstall clean

all:
	@echo "Nothing to build for gershwin-system"

install:
	@echo "Installing '$(LIBSRC)' into '$(SYS_LIB_DIR)/$(LIBSRC)'"
	@mkdir -p "$(SYS_LIB_DIR)"
	@rm -rf "$(SYS_LIB_DIR)/$(LIBSRC)"
	@cp -a "$(LIBSRC)" "$(SYS_LIB_DIR)/"
	@echo "Install complete."

uninstall:
	@echo "Removing '$(SYS_LIB_DIR)/$(LIBSRC)'"
	@if [ -e "$(SYS_LIB_DIR)/$(LIBSRC)" ]; then rm -rf "$(SYS_LIB_DIR)/$(LIBSRC)"; echo "Removed."; else echo "Nothing to remove."; fi

clean:
	@echo "Nothing to clean."
