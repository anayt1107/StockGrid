#!/bin/bash
# Installs (or reinstalls) the latest StockGrid release into /Applications.
set -euo pipefail
REPO="${STOCKGRID_REPO:-anayt1107/StockGrid}"

echo "Finding the latest StockGrid release…"
URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | cut -d'"' -f4)"
[ -n "$URL" ] || { echo "No release download found at https://github.com/$REPO/releases"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo "Downloading $URL"
curl -fL --progress-bar "$URL" -o "$TMP/StockGrid.zip"
ditto -x -k "$TMP/StockGrid.zip" "$TMP"

DEST=/Applications
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
pkill -x StockGrid 2>/dev/null || true
rm -rf "$DEST/StockGrid.app"
mv "$TMP/StockGrid.app" "$DEST/"
xattr -dr com.apple.quarantine "$DEST/StockGrid.app" 2>/dev/null || true
echo "Installed $DEST/StockGrid.app"
open "$DEST/StockGrid.app"
