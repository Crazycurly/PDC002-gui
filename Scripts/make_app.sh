#!/bin/bash
# Assemble PDC002.app from the release build and ad-hoc sign it.
set -euo pipefail

cd "$(dirname "$0")/.."

# XCTest (used by the test target) needs the full Xcode toolchain, and the
# app links SwiftUI; prefer Xcode if it is installed.
if [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi

swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"
APP=PDC002.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/PDC002" "$APP/Contents/MacOS/PDC002"
cp -R "$BIN_DIR/PDC002_PDC002Kit.bundle" "$APP/Contents/Resources/"

# App icon — regenerate from the vector generator only when it has changed.
if [ ! -f AppIcon.icns ] || [ Scripts/make_icon.swift -nt AppIcon.icns ]; then
    swift Scripts/make_icon.swift AppIcon.iconset
    iconutil -c icns AppIcon.iconset -o AppIcon.icns
fi
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>PDC002</string>
    <key>CFBundleIdentifier</key>
    <string>local.pdc002-flasher</string>
    <key>CFBundleName</key>
    <string>PDC002 Flasher</string>
    <key>CFBundleDisplayName</key>
    <string>PDC002 Flasher</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Protocol reverse engineering: see reference/PDC002.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
