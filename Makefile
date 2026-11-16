PREFIX ?= $(HOME)/.local
HERDR_MODS ?= $(HOME)/.config/herdr-app/mods
OMP_EXTENSIONS ?= $(HOME)/.omp/agent/extensions

.PHONY: build install herdr omp

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

# omp's `ask` mirrored as a card; new omp sessions load it.
omp:
	install -d $(OMP_EXTENSIONS)
	install -m 644 integrations/omp/devnotify-ask.ts $(OMP_EXTENSIONS)/devnotify-ask.ts
