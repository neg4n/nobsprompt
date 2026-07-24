PREFIX ?= $(HOME)/.local
BUILD_DIR ?= build-install
MESON ?= meson

.PHONY: all configure build test install benchmark memory-check

all: build

configure:
	@if test -f "$(BUILD_DIR)/build.ninja"; then \
		$(MESON) setup --reconfigure "$(BUILD_DIR)" \
			--buildtype=release -Doptimization=3 -Db_lto=true \
			--prefix="$(PREFIX)"; \
	else \
		$(MESON) setup "$(BUILD_DIR)" \
			--buildtype=release -Doptimization=3 -Db_lto=true \
			--prefix="$(PREFIX)"; \
	fi

build: configure
	$(MESON) compile -C "$(BUILD_DIR)"

test: build
	$(MESON) test -C "$(BUILD_DIR)" --print-errorlogs

install: build
	$(MESON) install -C "$(BUILD_DIR)" $(if $(DESTDIR),--destdir "$(DESTDIR)",)

benchmark: build
	zsh bench/benchmark.zsh "./$(BUILD_DIR)/nbsp"

memory-check:
	sh tests/run_memory_checks.sh

