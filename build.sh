#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
swift build -c release
SIDELOAD_BIN_DIR="$(swift build -c release --show-bin-path)"
SIDELOAD_APP="$PWD/build/Local Sideload.app"
mkdir -p "$SIDELOAD_APP/Contents/MacOS" "$SIDELOAD_APP/Contents/Resources"
cp "$SIDELOAD_BIN_DIR/LocalSideload" "$SIDELOAD_APP/Contents/MacOS/LocalSideload"
cp Info.plist "$SIDELOAD_APP/Contents/Info.plist"
swift scripts/make-icon.swift "$PWD/build/AppIcon.iconset"
iconutil --convert icns "$PWD/build/AppIcon.iconset" --output "$SIDELOAD_APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$SIDELOAD_APP"
codesign --verify --strict "$SIDELOAD_APP"
echo "Built: $SIDELOAD_APP"
