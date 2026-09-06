#!/bin/bash
# Builds Wattson.app. No Xcode required — SwiftPM produces the binary and the
# bundle is assembled by hand.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Wattson.app"
VERSION="0.1.0"

echo "==> building"
swift build -c release

echo "==> assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/wattson "$APP/Contents/MacOS/Wattson"

echo "==> icon"
rm -rf dist/Wattson.iconset && mkdir -p dist/Wattson.iconset
swift scripts/make-icon.swift dist/Wattson.iconset >/dev/null
iconutil -c icns dist/Wattson.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf dist/Wattson.iconset

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Wattson</string>
    <key>CFBundleDisplayName</key><string>Wattson</string>
    <key>CFBundleIdentifier</key><string>com.wattson.app</string>
    <key>CFBundleExecutable</key><string>Wattson</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <!-- Menu bar only: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so Gatekeeper treats it as a stable identity across launches.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "==> done: $APP"
