#!/bin/bash
# Builds StockGrid.app next to this script. Re-run after editing index.html or app/main.swift.
set -euo pipefail
cd "$(dirname "$0")"

APP=StockGrid.app
BUILD=.build
rm -rf "$APP" "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD/AppIcon.iconset"

echo "Compiling…"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.3" app/main.swift -o "$APP/Contents/MacOS/StockGrid" -framework Cocoa -framework WebKit

echo "Drawing icon…"
swiftc -swift-version 5 -target "$(uname -m)-apple-macos13.3" app/make_icon.swift -o "$BUILD/make_icon" -framework Cocoa
"$BUILD/make_icon" "$BUILD/icon.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$BUILD/icon.png" --out "$BUILD/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$BUILD/icon.png" --out "$BUILD/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cp app/Info.plist "$APP/Contents/Info.plist"
# Version comes from the VERSION file (or $VERSION); the update repo from $STOCKGRID_REPO or the git remote.
VERSION="${VERSION:-$(cat VERSION)}"
REPO="${STOCKGRID_REPO:-$(git remote get-url origin 2>/dev/null | sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##' || true)}"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace StockGridUpdateRepo -string "$REPO" "$APP/Contents/Info.plist"
echo "Version $VERSION, updates from ${REPO:-(none)}"
cp index.html "$APP/Contents/Resources/index.html"
codesign --force --deep --sign - "$APP"
rm -rf "$BUILD"
echo "Built $(pwd)/$APP"
if [ "${ZIP:-}" = "1" ]; then
  ditto -c -k --keepParent "$APP" "StockGrid-$VERSION.zip"
  echo "Zipped StockGrid-$VERSION.zip"
fi
