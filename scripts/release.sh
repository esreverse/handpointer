#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

# Releases are always signed with a Developer ID and notarized, so they open without a
# security warning. --skip-notarize is for trying the build only, never for publishing.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application}"
if [[ "$CODESIGN_IDENTITY" != Developer\ ID* ]] \
        || ! security find-identity -v -p codesigning | grep -q "$CODESIGN_IDENTITY"; then
    echo "error: no valid \"$CODESIGN_IDENTITY\" identity in the keychain; releases need a Developer ID." >&2
    exit 1
fi
IDENTITY="$CODESIGN_IDENTITY"
PROFILE="${NOTARY_PROFILE:-notarytool-profile}"
SKIP_NOTARIZE=false
[[ "${1:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=true

OUT="dist/release"
APP="$OUT/$APP_NAME.app"
DMG="$OUT/$APP_NAME-$VERSION.dmg"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

notarize() {
    if [[ -n "${APPLE_ID:-}" && -n "${APPLE_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
        xcrun notarytool submit "$1" --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" \
            --team-id "$APPLE_TEAM_ID" --wait --timeout 30m
    else
        xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --timeout 30m
    fi
    xcrun stapler staple "$2"
    xcrun stapler validate "$2"
}

echo "==> Building $APP_NAME $VERSION (universal)"
pick_sdk
swift build -c release --arch arm64 --arch x86_64 --scratch-path "$BUILD_DIR"
rm -rf "$OUT"
mkdir -p "$OUT"
# Universal builds land in apple/ with Xcode's build system and in out/ with SwiftPM's own.
PRODUCTS="$BUILD_DIR/apple/Products/Release"
[[ -x "$PRODUCTS/$APP_NAME" ]] || PRODUCTS="$BUILD_DIR/out/Products/Release"
make_bundle "$PRODUCTS/$APP_NAME" "$APP" "$BUILD_NUMBER"
lipo -info "$APP/Contents/MacOS/$APP_NAME"

echo "==> Signing with $IDENTITY"
sign_app "$APP" "$IDENTITY" --timestamp

if [[ "$SKIP_NOTARIZE" == false ]]; then
    echo "==> Notarizing the app"
    ditto -c -k --keepParent "$APP" "$OUT/$APP_NAME.zip"
    notarize "$OUT/$APP_NAME.zip" "$APP"
    rm "$OUT/$APP_NAME.zip"
fi

echo "==> Building the DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
if command -v create-dmg >/dev/null; then
create-dmg \
    --volname "$DISPLAY_NAME" \
    --volicon "assets/AppIcon.icns" \
    --window-pos 200 120 \
    --window-size 560 360 \
    --icon-size 112 \
    --icon "$APP_NAME.app" 150 170 \
    --hide-extension "$APP_NAME.app" \
    --app-drop-link 410 170 \
    --no-internet-enable \
    "$DMG" "$STAGE" >/dev/null
else
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
fi
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [[ "$SKIP_NOTARIZE" == false ]]; then
    echo "==> Notarizing the DMG"
    notarize "$DMG" "$DMG"
    echo "==> Gatekeeper check"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
    spctl --assess --type execute --verbose=2 "$APP"
fi

echo "==> Signing the update and writing appcast.xml"
TOOLS="$(sparkle_tools)"
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    ENCLOSURE="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$TOOLS/sign_update" --ed-key-file - "$DMG")"
else
    # The EdDSA key was created as "tinypointer" and stays under that keychain account.
    ENCLOSURE="$("$TOOLS/sign_update" --account tinypointer "$DMG")"
fi
# Release notes for the update dialog: RELEASE_NOTES if set, otherwise this version's section
# of CHANGELOG.md ("## <version>" up to the next "## ").
if [[ -z "${RELEASE_NOTES:-}" && -f CHANGELOG.md ]]; then
    RELEASE_NOTES="$(awk -v v="## $VERSION" '$0 == v {on = 1; next} on && /^## / {exit} on' CHANGELOG.md)"
fi
NOTES_HTML="$(printf '%s\n' "${RELEASE_NOTES:-$DISPLAY_NAME $VERSION}" \
    | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
    | awk 'BEGIN {list = 0}
           /^- / {if (!list) {print "<ul>"; list = 1} sub(/^- /, ""); print "<li>" $0 "</li>"; next}
           {if (list) {print "</ul>"; list = 0}}
           NF {print "<p>" $0 "</p>"}
           END {if (list) print "</ul>"}')"
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$DISPLAY_NAME</title>
    <item>
      <title>$DISPLAY_NAME $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <description><![CDATA[$NOTES_HTML]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/$APP_NAME-$VERSION.dmg"
                 type="application/octet-stream" $ENCLOSURE />
    </item>
  </channel>
</rss>
XML

(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
cp "$DMG" "$OUT/$APP_NAME.dmg"
echo
echo "Done: $DMG"
cat "$DMG.sha256"
