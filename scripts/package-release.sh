#!/bin/bash
# Default: local preview ZIP. Public signing/notarization requires explicitly
# supplied Developer ID identity and an existing notarytool keychain profile.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${WATTSON_VERSION:-0.1.2}"
PROFILE="${WATTSON_NOTARY_PROFILE:-}"
if [[ -n "$PROFILE" && "${WATTSON_SIGNING_IDENTITY:--}" == - ]]; then
    echo "Notarization requires WATTSON_SIGNING_IDENTITY (Developer ID Application)." >&2
    exit 1
fi
./scripts/build-app.sh
APP="dist/Wattson.app"
SUFFIX="-preview"
if [[ -n "$PROFILE" ]]; then
    SUBMISSION="dist/Wattson-notarization.zip"
    ditto -c -k --keepParent "$APP" "$SUBMISSION"
    xcrun notarytool submit "$SUBMISSION" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
    rm "$SUBMISSION"
    SUFFIX=""
fi
ARCHIVE="dist/Wattson-$VERSION-arm64$SUFFIX.zip"
ditto -c -k --keepParent "$APP" "$ARCHIVE"
if [[ -z "$PROFILE" ]]; then
    zip -q -j "$ARCHIVE" docs/INSTALL_PREVIEW.zh-CN.md LICENSE
else
    zip -q -j "$ARCHIVE" LICENSE
fi
(
    cd dist
    shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256"
)
echo "Created $ARCHIVE"
if [[ -z "$PROFILE" ]]; then
    echo "Preview only: not notarized. Gatekeeper may block downloads."
fi
