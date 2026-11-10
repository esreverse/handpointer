#!/bin/bash
# Build HandPointer for use on this Mac only (not notarized; see release.sh for that).
#
#   scripts/build-local.sh            build into ~/Library/Caches/handpointer-build/dist
#   scripts/build-local.sh --install  also replace /Applications/HandPointer.app and start it
#
# - Builds outside the repo (BUILD_DIR), because synced folders such as Google Drive
#   break SwiftPM's build database.
# - Without full Xcode, the newest Command Line Tools SDK may lack the SwiftUI macro
#   plugin; the script then falls back to the newest macOS 26 SDK. Override with SDKROOT.
# - Signs with the keychain's Developer ID Application identity, like the releases, so the
#   Accessibility permission survives rebuilds and switching to a release. Without one, it
#   uses "TinyHand Local Signing", then an ad hoc signature, which needs the permission
#   again after each build. Override with LOCAL_SIGN_IDENTITY (the full identity name).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

INSTALL=false
[[ "${1:-}" == "--install" ]] && INSTALL=true

pick_sdk
echo "==> Building $APP_NAME $VERSION${SDKROOT:+ with $(basename "$SDKROOT")}"
swift build -c release --scratch-path "$BUILD_DIR"

APP="$BUILD_DIR/dist/$APP_NAME.app"
mkdir -p "$BUILD_DIR/dist"
# A timestamp build number keeps a local build newer than the last release, so Sparkle
# does not replace it with that release.
make_bundle "$BUILD_DIR/release/$APP_NAME" "$APP" "$(date +%Y%m%d%H%M)"
DEVELOPER_ID="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
IDENTITY="${LOCAL_SIGN_IDENTITY:-${DEVELOPER_ID:-TinyHand Local Signing}}"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    sign_app "$APP" "$IDENTITY"
else
    echo "No \"$IDENTITY\" identity in the keychain; signing ad hoc."
    sign_app "$APP" "-"
fi
echo "Built $APP"

if [[ "$INSTALL" == true ]]; then
    quit_running_app
    rm -rf "/Applications/$APP_NAME.app"
    ditto "$APP" "/Applications/$APP_NAME.app"
    open "/Applications/$APP_NAME.app"
    echo "Installed and started /Applications/$APP_NAME.app"
fi
