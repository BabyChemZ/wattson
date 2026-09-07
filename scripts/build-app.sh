#!/bin/bash
# Builds Wattson.app. No Xcode required — SwiftPM produces the binary and the
# bundle is assembled by hand.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Wattson.app"
VERSION="${WATTSON_VERSION:-0.1.1}"
SIGNING_IDENTITY="${WATTSON_SIGNING_IDENTITY:--}"
ARCH="${WATTSON_ARCH:-arm64}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$ARCH" != arm64 ]]; then
    echo "Use a numeric x.y.z version; this preview supports arm64 only." >&2
    exit 1
fi

echo "==> building"
swift build -c release --arch "$ARCH"
BIN_DIR="$(swift build -c release --arch "$ARCH" --show-bin-path)"

echo "==> assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/wattson" "$APP/Contents/MacOS/Wattson"
cp LICENSE "$APP/Contents/Resources/LICENSE"

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

# Ad-hoc builds are local previews, not Gatekeeper-approved public releases.
if [[ "$SIGNING_IDENTITY" == - ]]; then
    codesign --force --sign - "$APP"
else
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"

echo "==> done: $APP"
