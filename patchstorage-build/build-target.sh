#!/bin/bash
# Cross-build one Patchstorage target, run INSIDE a patchstorage/lv2_builder-<platform> image.
#
# Invoked by `make patchstorage-build` via `docker run`. The host passes:
#   /src         — source tree, mounted read-only
#   /out         — host output dir (build/patchstorage/<slug>); we drop <plugin>.lv2 here
#   $PLUGIN      — plugin name (bundle is <plugin>.lv2, shared object is <plugin>.so)
#   $TARGET_SLUG — patchstorage target slug (linux-amd64 | rpi-aarch64 | patchbox-os-arm32)
#   $TUPLE       — cross toolchain prefix (e.g. aarch64-rpi4-linux-gnu)
#   $CPUFLAGS    — CPU/opt flags matching patchstorage's defconfig
#   $EXPECT_ARCH — substring `file` must report for the built .so
#   $HOST_UID/$HOST_GID — chown output back to the host user
#
# Two-phase build, mirroring the proven mod-build/build-plugin.sh (Dwarf) pattern:
#   1. Native x86_64 build -> .ttl + modgui bundle (DPF's ttl generator dlopens a native .so).
#   2. Cross-compile the .so with the image's toolchain + CPUFLAGS; overlay onto the stash.
set -euo pipefail

for v in PLUGIN TARGET_SLUG TUPLE CPUFLAGS EXPECT_ARCH; do
  if [ -z "${!v:-}" ]; then echo "build-target.sh: \$$v not set" >&2; exit 1; fi
done
[ -d /src ] || { echo "build-target.sh: /src not mounted" >&2; exit 1; }
[ -d /out ] || { echo "build-target.sh: /out not mounted" >&2; exit 1; }

# Locate the cross toolchain inside the image (auto-discover; fail loudly if the
# image layout ever changes). Expected path is the crosstool-ng prefix dir.
GCC="$(ls /home/builder/lv2-workdir/*/toolchain/bin/${TUPLE}-gcc 2>/dev/null | head -n1 || true)"
if [ -z "$GCC" ]; then
  GCC="$(find / -name "${TUPLE}-gcc" -type f 2>/dev/null | head -n1 || true)"
fi
if [ -z "$GCC" ]; then
  echo "build-target.sh: toolchain '${TUPLE}-gcc' not found in image." >&2
  echo "Toolchains present:" >&2
  ls /home/builder/lv2-workdir/*/toolchain/bin/*-gcc 2>/dev/null >&2 || echo "  (none at expected path)" >&2
  exit 1
fi
BIN_DIR="$(dirname "$GCC")"
echo "==> Toolchain: $BIN_DIR/${TUPLE}-{gcc,g++}"

WORK=/tmp/psbuild/$PLUGIN
rm -rf "$WORK"; mkdir -p "$WORK"
rsync -a --exclude bin --exclude build --exclude '.git' /src/ "$WORK/"
cd "$WORK"

PLUGIN_DIR="$(find plugins -mindepth 2 -maxdepth 2 -name Makefile -printf '%h\n' | head -n1)"
[ -n "$PLUGIN_DIR" ] || { echo "build-target.sh: no plugin Makefile under plugins/*/" >&2; exit 1; }

echo "==> [1/3] Native build (.ttl + modgui assets)"
make -s all PLUGIN_FORMATS=lv2
STASH=/tmp/${PLUGIN}-bundle-stash
rm -rf "$STASH"
cp -rL "bin/${PLUGIN}.lv2" "$STASH"

echo "==> [2/3] Cross-compiling ${PLUGIN}.so for ${TARGET_SLUG} (${TUPLE})"
make -s -C "$PLUGIN_DIR" clean
make -s -C "$PLUGIN_DIR" lv2 \
  CC="$BIN_DIR/${TUPLE}-gcc" \
  CXX="$BIN_DIR/${TUPLE}-g++" \
  AR="$BIN_DIR/${TUPLE}-ar" \
  STRIP="$BIN_DIR/${TUPLE}-strip" \
  EXTRA_CFLAGS="$CPUFLAGS" \
  EXTRA_CXXFLAGS="$CPUFLAGS" \
  NOOPT=false
"$BIN_DIR/${TUPLE}-strip" "bin/${PLUGIN}.lv2/${PLUGIN}.so"

if ! file "bin/${PLUGIN}.lv2/${PLUGIN}.so" | grep -q "$EXPECT_ARCH"; then
  echo "build-target.sh: unexpected arch for ${TARGET_SLUG} (want '$EXPECT_ARCH')" >&2
  file "bin/${PLUGIN}.lv2/${PLUGIN}.so" >&2
  exit 1
fi

echo "==> [3/3] Publishing bundle to /out/${PLUGIN}.lv2"
cp -f "bin/${PLUGIN}.lv2/${PLUGIN}.so" "$STASH/${PLUGIN}.so"
rm -rf "/out/${PLUGIN}.lv2"
cp -rL "$STASH" "/out/${PLUGIN}.lv2"

if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ]; then
  chown -R "$HOST_UID:$HOST_GID" /out
fi
echo "==> Done: $(file -b /out/${PLUGIN}.lv2/${PLUGIN}.so)"
