#!/usr/bin/env bash
#
# Install the built plugin .lv2 bundle into MOD Desktop's plugin directory.
# Default destination is the user-plugin path ($XDG_DOCUMENTS/MOD Desktop/lv2),
# which is the official location for user-installed plugins on Linux and
# survives MOD Desktop reinstalls.
#
# Override with:
#   MOD_DESKTOP_PLUGINS=/path/to/mod-desktop/plugins ./install.sh
#
# Set BETA=1 to install the side-by-side beta variant (<plugin>-beta.lv2)
# instead of the stable bundle. Build first with `make BETA=1` or use
# `make install-beta`.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# Derive the plugin name from the top-level Makefile so install.sh stays
# in sync if the plugin is renamed via that single variable.
PLUGIN="$(awk -F':=' '/^PLUGIN[[:space:]]*:=/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$REPO_DIR/Makefile")"
if [[ -z "$PLUGIN" ]]; then
    echo "error: could not parse PLUGIN from Makefile" >&2
    exit 1
fi

BUNDLE_NAME="$PLUGIN"
if [[ -n "${BETA:-}" && "$BETA" != "0" ]]; then
    BUNDLE_NAME="${PLUGIN}-beta"
fi
BUNDLE_SRC="$REPO_DIR/bin/${BUNDLE_NAME}.lv2"
DEST="${MOD_DESKTOP_PLUGINS:-$HOME/Documents/MOD Desktop/lv2}"

if [[ ! -d "$BUNDLE_SRC" ]]; then
    echo "error: $BUNDLE_SRC not found." >&2
    echo "       Build the plugin first:  make" >&2
    exit 1
fi

if [[ ! -d "$DEST" ]]; then
    echo "error: destination directory does not exist: $DEST" >&2
    echo "       Either create it, or override the location with MOD_DESKTOP_PLUGINS=..." >&2
    exit 1
fi

DEST_BUNDLE="$DEST/${BUNDLE_NAME}.lv2"

# Remove the previous install so stale TTL or modgui files from older
# builds don't linger alongside fresh ones.
if [[ -e "$DEST_BUNDLE" ]]; then
    echo "Removing previous install: $DEST_BUNDLE"
    rm -rf "$DEST_BUNDLE"
fi

echo "Installing $BUNDLE_SRC"
echo "        -> $DEST_BUNDLE"
cp -r "$BUNDLE_SRC" "$DEST_BUNDLE"

echo
echo "Done. Restart MOD Desktop so it rescans plugins."
