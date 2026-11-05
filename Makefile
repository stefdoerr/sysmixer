#!/usr/bin/make -f
# Top-level Makefile for a MOD Desktop / MOD Dwarf LV2 plugin.
# -----------------------------------------------------------
#
# This is the single source of truth for the plugin's identity in builds:
# change PLUGIN, BRAND, LABEL, and PLUGIN_URI_BASE below when you rename
# the plugin. Everything else (TTL patching, bundle naming, install paths,
# release tarball names) derives from these.
#
# Targets:
#   make                 - build the LV2 bundle into bin/<plugin>.lv2
#   make beta            - same, but builds the side-by-side beta variant
#                          (distinct URI/brand/unique-id; can coexist with
#                          the stable plugin in any LV2 host)
#   make install         - copy bin/<plugin>.lv2 into $(LV2_DIR)
#                          (default /usr/lib/lv2; sudo for system install)
#   make install-beta    - build beta + install via ./install.sh
#   make dwarf           - cross-compile + scp to a connected MOD Dwarf
#   make BETA=1 dwarf    - cross-compile + deploy the beta variant (distinct
#                          URI/name) alongside the stable plugin, for a
#                          side-by-side A/B on the Dwarf
#   make release version=x.y.z  - build, package, tag, push, gh release

# ---------------------------------------------------------------------------
# Plugin identity — change these when forking the template.
#
# PLUGIN     — lowercase identifier; the LV2 bundle becomes <PLUGIN>.lv2
#              and the cross-compiled .so is named <PLUGIN>.so.
# PLUGIN_DIR — path to the DPF inner-plugin source dir. The convention
#              is CamelCase under plugins/ to match DPF examples; rename
#              the directory when forking and update this var.
# BRAND      — modgui brand string shown on the pedal frame.
# LABEL      — modgui label string shown on the pedal frame.
# PLUGIN_URI_BASE — stable LV2 URI prefix (does NOT need to resolve over
#              HTTP — LV2 URIs are pure identifiers — but pick something
#              unique so plugins from different vendors never collide).
PLUGIN          := sysmixer
PLUGIN_DIR      := plugins/SysMixer
BRAND           := Stefan
LABEL           := System Mixer
PLUGIN_URI_BASE := http://stefan.local/plugins
# ---------------------------------------------------------------------------

# Set BETA=1 to produce a side-by-side beta build: distinct LV2 URI,
# bundle name, brand, and unique id. Same source, different identity —
# install with `make BETA=1 install` (or the `make beta` shortcut) and
# it'll coexist with the stable plugin in MOD Desktop. Used to A/B test
# a work-in-progress against the released plugin.
#
# The conditional `-D<PLUGIN_UPPER>_BETA=1` macro is propagated to the
# DPF sub-make via $(CXXFLAGS) (BUILD_CXX_FLAGS is hard-reset by DPF's
# Makefile.base.mk so user flags must travel via CXXFLAGS).
PLUGIN_UPPER := $(shell echo $(PLUGIN) | tr a-z A-Z)
ifeq ($(BETA),1)
export $(PLUGIN_UPPER)_BETA := 1
BUNDLE_NAME  := $(PLUGIN)-beta
BUNDLE_LABEL := $(LABEL) (Beta)
PLUGIN_URI   := $(PLUGIN_URI_BASE)/$(PLUGIN)-beta
else
BUNDLE_NAME  := $(PLUGIN)
BUNDLE_LABEL := $(LABEL)
PLUGIN_URI   := $(PLUGIN_URI_BASE)/$(PLUGIN)
endif
BUNDLE := bin/$(BUNDLE_NAME).lv2

.PHONY: all plugin ttl modgui features clean distclean

# Desktop CI (dpf-makefile-action) sets DESKTOP_ONLY=1 (via the workflow's
# `extraargs`) to build ONLY the self-describing desktop formats: VST3 + CLAP.
# It deliberately skips:
#   - lv2       — a desktop LV2 would need the top-level `ttl` step (the inner
#                 DPF build emits only the .so, not manifest.ttl), and the
#                 desktop-Linux LV2 is already shipped as the Patchstorage
#                 linux-amd64 release asset, so it'd be redundant here.
#   - ttl/modgui — MOD-specific and irrelevant to a desktop VST3/CLAP release;
#                 `ttl` also uses GNU-only `sed -i` that breaks on the macOS
#                 runner's BSD sed.
# Local `make` (DESKTOP_ONLY unset) still does the full MOD build.
ifeq ($(DESKTOP_ONLY),1)
PLUGIN_FORMATS := vst3 clap
all: plugin
else
all: plugin ttl modgui
endif

# dpf-makefile-action runs `make features` (to print DPF's detected build
# features) before building. Our top-level Makefile isn't a DPF Makefile, so
# delegate to the inner plugin Makefile — it includes dpf/Makefile.base.mk,
# where the real `features` target lives.
features:
	@$(MAKE) -C $(PLUGIN_DIR) features

# ---------------------------------------------------------------------------
# Build the plugin .so

# PLUGIN_FORMATS restricts which DPF formats get built (empty = the inner
# Makefile's full TARGETS list: lv2 vst3 clap). The Patchstorage/Dwarf
# cross-builds set PLUGIN_FORMATS=lv2 so they don't waste time building the
# desktop formats they never ship.
PLUGIN_FORMATS ?=
plugin:
	$(MAKE) -C $(PLUGIN_DIR) $(PLUGIN_FORMATS)

# ---------------------------------------------------------------------------
# Generate manifest.ttl and <plugin>.ttl via DPF's TTL generator.
# DPF dlopens the .so to introspect ports — this must run on the same
# architecture as the plugin (i.e., x86_64 host build, not the cross
# build).

ttl: plugin dpf/utils/lv2_ttl_generator
	@$(CURDIR)/dpf/utils/generate-ttl.sh

dpf/utils/lv2_ttl_generator:
	$(MAKE) -C dpf/utils/lv2-ttl-generator

# ---------------------------------------------------------------------------
# Copy modgui assets into the bundle and patch the modgui.ttl with the
# current build's URI / brand / label. The sed substitutions are no-ops
# in the stable build (identity transform) and only kick in for the beta.

modgui: ttl
	@mkdir -p $(BUNDLE)/modgui
	cp -f $(PLUGIN_DIR)/modgui/*.html $(BUNDLE)/modgui/
	cp -f $(PLUGIN_DIR)/modgui/*.css  $(BUNDLE)/modgui/
	cp -f $(PLUGIN_DIR)/modgui/*.js   $(BUNDLE)/modgui/
	@# PNGs are optional during early development (modgui still renders
	@# without a screenshot; only the knob sprite is essential).
	@if ls $(PLUGIN_DIR)/modgui/*.png >/dev/null 2>&1; then \
		cp -f $(PLUGIN_DIR)/modgui/*.png $(BUNDLE)/modgui/; \
	fi
	@if [ -d $(PLUGIN_DIR)/modgui/knobs ]; then \
		cp -rf $(PLUGIN_DIR)/modgui/knobs $(BUNDLE)/modgui/; \
	fi
	@# Beginner PDF manual -> "documentation" button in the plugin info
	@# dialog (referenced from modgui.ttl). Copied under a FIXED name so a
	@# plugin rename can't break the TTL reference.
	cp -f $(MANUAL_PDF) $(BUNDLE)/modgui/manual.pdf
	sed -e 's|$(PLUGIN_URI_BASE)/$(PLUGIN)|$(PLUGIN_URI)|g' \
	    -e 's|modgui:brand "$(BRAND)"|modgui:brand "$(BUNDLE_NAME)"|' \
	    -e 's|modgui:label "$(LABEL)"|modgui:label "$(BUNDLE_LABEL)"|' \
	    $(PLUGIN_DIR)/modgui.ttl > $(BUNDLE)/modgui.ttl
	@if ! grep -q 'modgui.ttl' $(BUNDLE)/manifest.ttl; then \
		printf '\n<%s>\n    rdfs:seeAlso <modgui.ttl> .\n' \
			"$(PLUGIN_URI)" >> $(BUNDLE)/manifest.ttl; \
	fi

# ---------------------------------------------------------------------------

clean:
	$(MAKE) clean -C $(PLUGIN_DIR)
	$(MAKE) clean -C dpf/utils/lv2-ttl-generator
	rm -rf bin build

distclean: clean
	rm -rf dpf/utils/lv2_ttl_generator dpf/utils/lv2_ttl_generator.exe

# ---------------------------------------------------------------------------
# install: copy the built bundle into $(LV2_DIR). Use PREFIX/LV2_DIR for
# system installs (sudo make install PREFIX=/usr/local); use ./install.sh
# for the MOD Desktop user-plugin dir.

PREFIX     ?= /usr
LV2_DIR    ?= $(DESTDIR)$(PREFIX)/lib/lv2

install: all
	@mkdir -p "$(LV2_DIR)"
	cp -rL "$(BUNDLE)" "$(LV2_DIR)/"

# ---------------------------------------------------------------------------
# manual: render the beginner PDF manual from its HTML source via headless
# Chrome. The PDF is generated output — edit the HTML, re-run this, and
# commit BOTH files (the release attaches the committed PDF). See "User
# manual (PDF)" in the mod-plugin-template's INSTRUCTIONS.md.

MANUAL_HTML := docs/manual/$(PLUGIN)-manual.html
MANUAL_PDF  := docs/manual/$(PLUGIN)-manual.pdf
CHROME      ?= google-chrome

manual:
	$(CHROME) --headless --disable-gpu --no-pdf-header-footer \
		--print-to-pdf=$(MANUAL_PDF) $(MANUAL_HTML)
	@echo "==> $(MANUAL_PDF)"

.PHONY: manual

# ---------------------------------------------------------------------------
# test: build + run every tests/test_*.cpp under AddressSanitizer. Each test
# is a plain main() compiled directly against the plugin source and DPF's
# core — no host, no test framework. See "Testing the DSP" in
# the mod-plugin-template's INSTRUCTIONS.md.

TEST_CXXFLAGS := -std=gnu++14 -g -O0 -fsanitize=address \
                 -I$(PLUGIN_DIR) -Idpf/distrho
TEST_SRCS     := $(wildcard $(PLUGIN_DIR)/*.cpp) dpf/distrho/src/DistrhoPlugin.cpp

test:
	@mkdir -p build/tests
	@set -e; for t in tests/test_*.cpp; do \
		bin=build/tests/$$(basename $$t .cpp); \
		echo "==> $$t"; \
		g++ $(TEST_CXXFLAGS) $$t $(TEST_SRCS) -o $$bin; \
		$$bin; \
	done
	@echo "==> all tests passed"

.PHONY: test

beta:
	$(MAKE) BETA=1

install-beta:
	$(MAKE) BETA=1
	BETA=1 ./install.sh

.PHONY: install beta install-beta

# ---------------------------------------------------------------------------
# MOD Dwarf cross-build — self-contained, no host workdir or external clones.
#
# Vendored Docker image (mod-build/Dockerfile) bakes in the
# mod-plugin-builder cross-toolchain (aarch64, glibc 2.27, gcc 9.4.0 —
# matching Dwarf firmware). The image holds NO plugin source (the plugin is
# mounted at build time), so it is plugin-INDEPENDENT: one shared image
# (moddwarf-cross) is reused by every plugin built from this template. First
# `make dwarf-image` is slow (~30-60 min, one-time per machine); after that
# `make dwarf-build` is ~10 s for any plugin. The shared name is deliberate —
# do NOT derive it from $(PLUGIN), or each plugin rebuilds the ~6 GB toolchain.
# (Override CROSS_IMAGE=... only if you really want a separate image.)

CROSS_IMAGE  ?= moddwarf-cross
DWARF_HOST   ?= 192.168.51.1
DWARF_USER   ?= root
DWARF_LV2DIR ?= /root/.lv2

DWARF_BUNDLE := build/dwarf/$(BUNDLE_NAME).lv2

dwarf-image:
	docker build -t $(CROSS_IMAGE) mod-build/

dwarf-build:
	@if ! docker image inspect $(CROSS_IMAGE) >/dev/null 2>&1; then \
		echo "==> $(CROSS_IMAGE) image not built yet — building (~30-60 min, one-time)"; \
		$(MAKE) dwarf-image; \
	fi
	@mkdir -p build/dwarf
	docker run --rm \
		-e HOST_UID=$$(id -u) -e HOST_GID=$$(id -g) \
		-e PLUGIN=$(PLUGIN) \
		-e BETA=$(BETA) \
		-v "$(CURDIR):/src:ro" \
		-v "$(CURDIR)/build/dwarf:/out" \
		$(CROSS_IMAGE) \
		bash /src/mod-build/build-plugin.sh

# Push the bundle to a connected Dwarf via scp. /root/.lv2/ is the per-
# user plugin dir and survives firmware updates.
#
# scp -O: Dwarf runs Dropbear, which has no SFTP subsystem. Modern OpenSSH
# scp (>= 9.0) defaults to SFTP and fails with "subsystem request failed
# on channel 0". -O forces the legacy scp protocol.
#
# After scp, we restart BOTH jack2 and mod-ui — they maintain independent
# lilv plugin caches. Restarting jack2 alone makes the plugin instantiable
# but mod-ui still shows the cached old port list ("No such symbol: ..."
# errors in the UI).
dwarf-deploy:
	@if [ ! -d "$(DWARF_BUNDLE)" ]; then \
		echo "error: no bundle at $(DWARF_BUNDLE) — run 'make dwarf-build' first."; \
		exit 1; \
	fi
	scp -O -r "$(DWARF_BUNDLE)" "$(DWARF_USER)@$(DWARF_HOST):$(DWARF_LV2DIR)/"
	@echo "==> Restarting jack2 + mod-ui so the new bundle is picked up"
	ssh "$(DWARF_USER)@$(DWARF_HOST)" 'systemctl restart jack2 mod-ui'
	@echo "==> After deploy, hard-refresh the MOD-UI browser tab (Ctrl-Shift-R)"
	@echo "    so its JS-side plugin metadata isn't served from the browser cache."

dwarf: dwarf-build dwarf-deploy

.PHONY: dwarf dwarf-build dwarf-image dwarf-deploy

# ---------------------------------------------------------------------------
# Patchstorage build — cross-compile for the three targets patchstorage.com's
# LV2-plugins platform supports, using Patchstorage's own prebuilt toolchain
# images (patchstorage/lv2_builder-<platform>:latest). Our build-target.sh runs
# the same two-phase build as the Dwarf cross-build, but pulls the toolchain
# from their image instead of building one. Output: build/patchstorage/<slug>/.

PS_TARGETS := linux-amd64 rpi-aarch64 patchbox-os-arm32
PS_DIR     := build/patchstorage
PYTHON     ?= python3

patchstorage-build:
	@set -e; for slug in $(PS_TARGETS); do \
	  case $$slug in \
	    linux-amd64) plat=x86_64; tuple=x86_64-mod-linux-gnu; \
	      flags="-msse -msse2 -mfpmath=sse"; arch="x86-64";; \
	    rpi-aarch64) plat=raspberrypi4_aarch64; tuple=aarch64-rpi4-linux-gnu; \
	      flags="-mcpu=cortex-a72"; arch="ARM aarch64";; \
	    patchbox-os-arm32) plat=raspberrypi3_armv8; tuple=armv8-rpi3-linux-gnueabihf; \
	      flags="-mcpu=cortex-a53 -mfpu=neon-fp-armv8 -mfloat-abi=hard"; arch="ARM, EABI5";; \
	    *) echo "unknown slug $$slug"; exit 1;; \
	  esac; \
	  echo "==> Building $(PLUGIN) for $$slug ($$plat)"; \
	  mkdir -p "$(PS_DIR)/$$slug"; \
	  docker run --rm --user root \
	    -e HOST_UID=$$(id -u) -e HOST_GID=$$(id -g) \
	    -e PLUGIN=$(PLUGIN) -e TARGET_SLUG=$$slug \
	    -e TUPLE=$$tuple -e CPUFLAGS="$$flags" -e EXPECT_ARCH="$$arch" \
	    -v "$(CURDIR):/src:ro" \
	    -v "$(CURDIR)/$(PS_DIR)/$$slug:/out" \
	    patchstorage/lv2_builder-$$plat:latest \
	    bash /src/patchstorage-build/build-target.sh; \
	done
	@echo "==> Patchstorage bundles built under $(PS_DIR)/"

.PHONY: patchstorage-build

# Assemble the uploader working tree and generate patchstorage.json + tarballs +
# artwork under build/ps-upload/dist/ for inspection. Assumes bundles are already
# built (run `make patchstorage-build` first). Hits the Patchstorage API.
patchstorage-prepare:
	PLUGIN=$(PLUGIN) PYTHON=$(PYTHON) bash patchstorage-build/prepare.sh

.PHONY: patchstorage-prepare

# Full publish: build the three bundles, prepare, and push to patchstorage.com.
# Provide your Patchstorage username; the uploader prompts for the password
# (nothing is stored). Idempotent: skips/updates per the uploader's own logic.
#
#   make patchstorage PS_USER=<patchstorage-username>
patchstorage: patchstorage-check-user patchstorage-build patchstorage-prepare
	cd build/ps-upload && $(PYTHON) uploader.py push all --username "$(PS_USER)"

# Fail fast if PS_USER is unset — BEFORE the expensive build/prepare prerequisites
# run (a bare `make patchstorage` must not do a full 3-target Docker build only to
# then complain about a missing username).
patchstorage-check-user:
	@if [ -z "$(PS_USER)" ]; then \
		echo "error: set PS_USER=<patchstorage-username>"; \
		echo "       usage: make patchstorage PS_USER=yourname"; \
		exit 1; \
	fi

.PHONY: patchstorage patchstorage-check-user

# ---------------------------------------------------------------------------
# release: build the MOD/Patchstorage LV2 bundles + Dwarf locally, package them,
# tag the current commit as v$(version), push, and create a GitHub release.
# The desktop VST3/CLAP (linux-x86_64, win64, macos-universal) are built by
# GitHub Actions (.github/workflows/desktop-release.yml) on the pushed tag and
# appended to the same release.
#
#   make release version=0.0.1
#
# Local build (instead of CI) because the cross-toolchain image takes
# ~30-60 min to assemble from scratch and is hard to cache reliably on a
# fresh GH Actions runner. Locally the image is already there and
# `make dwarf-build` is ~10 s.

DIST_DIR := dist
AMD64_TARBALL := $(PLUGIN)-v$(version)-linux-amd64.tar.gz
RPI_TARBALL   := $(PLUGIN)-v$(version)-rpi-aarch64.tar.gz
ARM32_TARBALL := $(PLUGIN)-v$(version)-patchbox-os-arm32.tar.gz
DWARF_TARBALL := $(PLUGIN)-v$(version)-dwarf-aarch64.tar.gz

# Requires the VERSION file to already say $(version) so the tarball name
# can't disagree with the version baked into the binaries — `make release`
# bumps the file automatically.
release-build:
	@if [ -z "$(version)" ]; then \
		echo "error: version is required."; \
		echo "       usage: make release-build version=x.y.z"; \
		exit 1; \
	fi
	@if [ "$$(cat VERSION)" != "$(version)" ]; then \
		echo "error: VERSION file says $$(cat VERSION), but version=$(version)."; \
		echo "       'make release version=$(version)' bumps it automatically,"; \
		echo "       or update the VERSION file first."; \
		exit 1; \
	fi
	@echo "==> Building Patchstorage bundles (linux-amd64, rpi-aarch64, patchbox-os-arm32)"
	$(MAKE) patchstorage-build
	@mkdir -p $(DIST_DIR)
	tar -C $(PS_DIR)/linux-amd64       -czf $(DIST_DIR)/$(AMD64_TARBALL) $(PLUGIN).lv2
	tar -C $(PS_DIR)/rpi-aarch64       -czf $(DIST_DIR)/$(RPI_TARBALL)   $(PLUGIN).lv2
	tar -C $(PS_DIR)/patchbox-os-arm32 -czf $(DIST_DIR)/$(ARM32_TARBALL) $(PLUGIN).lv2
	@echo "==> Building Dwarf bundle (aarch64)"
	$(MAKE) dwarf-build
	tar -C build/dwarf -czf $(DIST_DIR)/$(DWARF_TARBALL) $(PLUGIN).lv2
	@echo
	@echo "Built release artefacts in $(DIST_DIR)/:"
	@ls -lh $(DIST_DIR)/$(PLUGIN)-v$(version)-*.tar.gz

# The version flows from here into everything else: the VERSION file is
# bumped and committed BEFORE the build, so the binaries, the generated
# TTL (lv2:minorVersion / lv2:microVersion) and the tag all agree — no
# manual source edit needed per release.
release:
	@if [ -z "$(version)" ]; then \
		echo "error: version is required."; \
		echo "       usage: make release version=x.y.z"; \
		exit 1; \
	fi
	@if [ -n "$$(git status --porcelain)" ]; then \
		echo "error: working tree is dirty. Commit or stash first."; \
		git status --short; \
		exit 1; \
	fi
	@if git rev-parse -q --verify "refs/tags/v$(version)" >/dev/null 2>&1; then \
		echo "error: tag v$(version) already exists locally."; \
		exit 1; \
	fi
	@if [ "$$(cat VERSION)" != "$(version)" ]; then \
		echo "==> Bumping VERSION $$(cat VERSION) -> $(version)"; \
		printf '%s\n' "$(version)" > VERSION; \
		git add VERSION; \
		git commit -m "Bump version to $(version)"; \
	fi
	$(MAKE) release-build version=$(version)
	@echo "==> Pushing branch (so the tagged commit is reachable on origin)"
	git push
	@echo "==> Tagging v$(version)"
	git tag -a "v$(version)" -m "Release v$(version)"
	git push origin "v$(version)"
	@echo "==> Creating GitHub release v$(version) (MOD/Patchstorage LV2 + Dwarf + manual; desktop VST3/CLAP added by CI)"
	gh release create "v$(version)" \
		"$(DIST_DIR)/$(AMD64_TARBALL)" \
		"$(DIST_DIR)/$(RPI_TARBALL)" \
		"$(DIST_DIR)/$(ARM32_TARBALL)" \
		"$(DIST_DIR)/$(DWARF_TARBALL)" \
		"$(MANUAL_PDF)" \
		--title "v$(version)" \
		--generate-notes
	@echo
	@echo "Release published:"
	@echo "  https://github.com/$$(git config --get remote.origin.url | sed -E 's|.*[:/]([^:/]+/[^/]+?)(\.git)?$$|\1|')/releases/tag/v$(version)"

.PHONY: release release-build
