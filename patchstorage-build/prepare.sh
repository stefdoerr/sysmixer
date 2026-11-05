#!/bin/bash
# Assemble a disposable uploader working tree and run `prepare`. Runs on the HOST.
# Requires: python3 + requests click rdflib; jq; network (Patchstorage API).
#
# Reads env: $PLUGIN. Keeps the vendored uploader copy pristine by copying into a
# scratch dir and generating a plugins.json containing only this plugin.
set -euo pipefail

PYTHON="${PYTHON:-python3}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="${PLUGIN:?PLUGIN not set}"
UPLOADER="$ROOT/patchstorage-build/uploader"
SRC_BUNDLES="$ROOT/build/patchstorage"
SCRATCH="$ROOT/build/ps-upload"
META="$ROOT/patchstorage.json"

[ -f "$UPLOADER/uploader.py" ] || { echo "vendored uploader missing at $UPLOADER"; exit 1; }
[ -f "$META" ] || { echo "missing $META"; exit 1; }
[ -d "$SRC_BUNDLES" ] || { echo "no bundles — run 'make patchstorage-build' first"; exit 1; }

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/plugins"
cp "$UPLOADER/uploader.py" "$UPLOADER/bundles.py" \
   "$UPLOADER/licenses.json" "$UPLOADER/categories.json" "$SCRATCH/"

# plugins.json keyed by the bundle folder name ("<plugin>.lv2"), from our metadata.
jq '{("'"$PLUGIN"'.lv2"): .}' "$META" > "$SCRATCH/plugins.json"

# Stage each built bundle into plugins/<slug>/<plugin>.lv2
found=0
for slug_dir in "$SRC_BUNDLES"/*/; do
  slug="$(basename "$slug_dir")"
  if [ -d "$slug_dir/$PLUGIN.lv2" ]; then
    mkdir -p "$SCRATCH/plugins/$slug"
    cp -rL "$slug_dir/$PLUGIN.lv2" "$SCRATCH/plugins/$slug/"
    found=$((found + 1))
  fi
done
[ "$found" -gt 0 ] || { echo "no <plugin>.lv2 bundles found under $SRC_BUNDLES"; exit 1; }
echo "==> Staged $found target bundle(s) for $PLUGIN"

cd "$SCRATCH"
"$PYTHON" uploader.py prepare all

OUT="$SCRATCH/dist/$PLUGIN.lv2/patchstorage.json"
if [ ! -f "$OUT" ]; then
  echo "prepare.sh: FAILED — $OUT was not generated." >&2
  echo "  The uploader exits 0 even on errors (e.g. a transient Patchstorage API failure);" >&2
  echo "  check the output above and re-run 'make patchstorage-prepare'." >&2
  exit 1
fi

echo "==> Prepared. Inspect: $SCRATCH/dist/$PLUGIN.lv2/patchstorage.json"
