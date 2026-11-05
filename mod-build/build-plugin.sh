#!/bin/bash
# Self-contained cross-build, run *inside* the cross-toolchain image.
#
# Invoked by `make dwarf-build`. The host passes us:
#   /src   — the source tree, mounted read-only
#   /out   — host-side output dir; we drop <bundle>.lv2 here
#   $PLUGIN — plugin name (matches the PLUGIN var in the top-level Makefile)
#   $BETA   — "1" to build the side-by-side beta variant (optional)
#
# Pipeline:
#   1. Stage the source into a writable scratch dir (rsync from /src).
#   2. Native (x86_64) build to produce the LV2 .ttl metadata + modgui
#      bundle layout. DPF's lv2_ttl_generator dlopen()s the plugin .so
#      to introspect ports, so it has to run against an x86_64 build —
#      it can't introspect an aarch64 .so on an x86_64 host.
#   3. Cross-compile the .so against the moddwarf-new toolchain baked
#      into the image, overwriting the x86_64 .so in the bundle.
#   4. Sanity-check that the resulting bundle has an aarch64 .so, then
#      copy it to /out.

set -euo pipefail

if [ ! -d /src ]; then
    echo "build-plugin.sh: /src not mounted. Run via 'make dwarf-build'." >&2
    exit 1
fi
if [ ! -d /out ]; then
    echo "build-plugin.sh: /out not mounted." >&2
    exit 1
fi
if [ -z "${PLUGIN:-}" ]; then
    echo "build-plugin.sh: \$PLUGIN not set. Run via 'make dwarf-build' (which sets it)." >&2
    exit 1
fi

# BETA=1 (passed through from the top-level Makefile) builds the side-by-side
# beta variant: distinct bundle name / URI / unique-id, same source. Lets you A/B
# a work-in-progress against the stable plugin on the same device. The bundle and
# .so are named <plugin>-beta; passing BETA=1 to make propagates the
# <PLUGIN>_BETA macro and renames the build (see the inner plugin Makefile).
if [ "${BETA:-}" = "1" ]; then
    BUNDLE="${PLUGIN}-beta"
    MAKE_BETA="BETA=1"
else
    BUNDLE="${PLUGIN}"
    MAKE_BETA=""
fi

TOOLCHAIN_BIN=/root/mod-workdir/moddwarf-new/host/usr/bin
TOOL_PREFIX=aarch64-modaudio-linux-gnu

if [ ! -x "$TOOLCHAIN_BIN/${TOOL_PREFIX}-gcc" ]; then
    echo "build-plugin.sh: cross-toolchain missing at $TOOLCHAIN_BIN." >&2
    echo "                 Re-build the docker image: 'make dwarf-image'." >&2
    exit 1
fi

WORK=/work/$BUNDLE
rm -rf "$WORK"
mkdir -p "$WORK"
# rsync gives us a writable copy without touching the read-only mount.
# Exclude build artefacts so the staging dir is clean.
rsync -a --exclude bin --exclude build --exclude '.git' /src/ "$WORK/"
cd "$WORK"

# Find the inner DPF plugin dir (the only one under plugins/ that has a
# Makefile). Lets the template work without hardcoding the capitalised
# plugin directory name.
PLUGIN_DIR="$(find plugins -mindepth 2 -maxdepth 2 -name Makefile -printf '%h\n' | head -n1)"
if [ -z "$PLUGIN_DIR" ]; then
    echo "build-plugin.sh: no plugin Makefile found under plugins/*/" >&2
    exit 1
fi

echo "==> [1/3] Native build (for .ttl metadata + modgui assets)"
make -s all ${MAKE_BETA} PLUGIN_FORMATS=lv2
# Stash the populated bundle (.ttl + modgui assets). DPF's clean between
# the native and cross builds wipes bin/, so we have to set this aside.
BUNDLE_STASH=/tmp/${BUNDLE}-bundle-stash
rm -rf "$BUNDLE_STASH"
cp -rL "bin/${BUNDLE}.lv2" "$BUNDLE_STASH"

echo "==> [2/3] Cross-compiling ${BUNDLE}.so for aarch64"
make -s -C "$PLUGIN_DIR" clean ${MAKE_BETA}
make -s -C "$PLUGIN_DIR" lv2 ${MAKE_BETA} \
    CC="$TOOLCHAIN_BIN/${TOOL_PREFIX}-gcc" \
    CXX="$TOOLCHAIN_BIN/${TOOL_PREFIX}-g++" \
    AR="$TOOLCHAIN_BIN/${TOOL_PREFIX}-ar" \
    LD="$TOOLCHAIN_BIN/${TOOL_PREFIX}-ld" \
    STRIP="$TOOLCHAIN_BIN/${TOOL_PREFIX}-strip" \
    NOOPT=false
"$TOOLCHAIN_BIN/${TOOL_PREFIX}-strip" "bin/${BUNDLE}.lv2/${BUNDLE}.so"

if ! file "bin/${BUNDLE}.lv2/${BUNDLE}.so" | grep -q 'ARM aarch64'; then
    echo "build-plugin.sh: cross-compile did not produce an aarch64 binary." >&2
    file "bin/${BUNDLE}.lv2/${BUNDLE}.so" >&2
    exit 1
fi

echo "==> [3/3] Publishing bundle to /out/${BUNDLE}.lv2"
# Use the stashed bundle (has the .ttl + modgui) and overlay the aarch64 .so
cp -f "bin/${BUNDLE}.lv2/${BUNDLE}.so" "$BUNDLE_STASH/${BUNDLE}.so"
rm -rf "/out/${BUNDLE}.lv2"
cp -rL "$BUNDLE_STASH" "/out/${BUNDLE}.lv2"

# Container runs as root; chown the output back to the host user so it's
# editable / deletable from outside Docker.
if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ]; then
    chown -R "$HOST_UID:$HOST_GID" /out
fi

echo "==> Done. $(file -b /out/${BUNDLE}.lv2/${BUNDLE}.so)"
