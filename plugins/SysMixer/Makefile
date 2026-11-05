#!/usr/bin/make -f
# DPF inner Makefile for SysMixer
# -------------------------------

# Set BETA=1 (or SYSMIXER_BETA=1) on the make command line for the
# side-by-side beta variant: distinct LV2 URI, bundle name, brand and
# unique id. The top-level Makefile wraps this in `make beta`.
ifeq ($(BETA),1)
SYSMIXER_BETA = 1
endif
ifeq ($(SYSMIXER_BETA),1)
NAME = sysmixer-beta
# DPF's Makefile.base.mk hard-resets BUILD_CXX_FLAGS but APPENDS
# $(CXXFLAGS) at the end, so user-visible flags must travel through
# CXXFLAGS to actually reach the compiler. Putting -DSYSMIXER_BETA=1
# in BUILD_CXX_FLAGS silently fails.
CXXFLAGS += -DSYSMIXER_BETA=1
else
NAME = sysmixer
endif

# Plugin version — the top-level VERSION file is the single source of
# truth (`make release` bumps and commits it to match the release tag).
# Injected as preprocessor defines so getVersion() and the generated LV2
# TTL (lv2:minorVersion / lv2:microVersion) always report the released
# version. Travels through CXXFLAGS for the same reason as the BETA
# macro above. The macro names are deliberately NOT plugin-prefixed so
# forks don't need to rename them.
PLUGIN_VERSION := $(strip $(shell cat ../../VERSION 2>/dev/null))
ifeq ($(PLUGIN_VERSION),)
$(error VERSION file not found at ../../VERSION)
endif
PLUGIN_VERSION_PARTS := $(subst ., ,$(PLUGIN_VERSION))
CXXFLAGS += -DPLUGIN_VERSION_MAJOR=$(word 1,$(PLUGIN_VERSION_PARTS)) \
            -DPLUGIN_VERSION_MINOR=$(word 2,$(PLUGIN_VERSION_PARTS)) \
            -DPLUGIN_VERSION_MICRO=$(word 3,$(PLUGIN_VERSION_PARTS))

# Extra flags injected by the Patchstorage cross-build (CPU/opt flags matching
# patchstorage's defconfig). Kept in a separate variable so passing them on the
# make command line doesn't clobber the version defines above — a command-line
# CXXFLAGS=... would override the makefile's `CXXFLAGS +=` lines entirely.
CFLAGS   += $(EXTRA_CFLAGS)
CXXFLAGS += $(EXTRA_CXXFLAGS)

# Source files (DPF's makefile expects FILES_DSP for DSP-only plugins,
# FILES_UI when there's a native UI — but we use modgui for the MOD GUI,
# so DSP-only here).
FILES_DSP = \
	SysMixerPlugin.cpp

# Pull in DPF's shared build rules
include ../../dpf/Makefile.plugins.mk

# Targets — LV2 only (MOD Desktop / MOD Dwarf both consume LV2).
# Add `vst2`, `vst3`, `clap`, etc. here if you want extra formats; each
# adds DPF code with potentially different licensing — see
# `dpf/LICENSING.md`.
# Formats DPF builds from this one source: lv2 is the MOD/Patchstorage format;
# vst3 + clap are the desktop-DAW formats. Plain `make` builds all three. The
# Patchstorage/Dwarf cross-builds pass PLUGIN_FORMATS=lv2 (see the top-level
# `plugin` target) so they don't spend time on desktop formats they don't ship;
# releases build vst3/clap portably via `make desktop-build`.
TARGETS += lv2 vst3 clap

all: $(TARGETS)
