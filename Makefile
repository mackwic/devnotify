PREFIX ?= $(HOME)/.local
HERDR_MODS ?= $(HOME)/.config/herdr-app/mods

.PHONY: build install herdr

build:
	swift build -c release

install: build
	install -d $(PREFIX)/bin
	install .build/release/devnotify $(PREFIX)/bin/devnotify
	install integrations/herdr/devnotify-herdr-until $(PREFIX)/bin/devnotify-herdr-until

# Herdr's toast mod, as `my-toast` (the layout names it in its "toast").
herdr: install
	install -d $(HERDR_MODS)/my-toast
	install -m 644 integrations/herdr/my-toast/main.js integrations/herdr/my-toast/mod.json $(HERDR_MODS)/my-toast/
