PREFIX ?= $(HOME)/.local

.PHONY: build install

build:
	swift build -c release

install: build
	install -d $(PREFIX)/bin
	install .build/release/devnotify $(PREFIX)/bin/devnotify
