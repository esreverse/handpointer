#!/bin/bash
# Build TinyPointer for use on this Mac only, without a Developer ID certificate.
#
#   scripts/build-local.sh            build into ~/Library/Caches/tinypointer-build/dist
#   scripts/build-local.sh --install  also replace /Applications/TinyPointer.app and start it
#
# - Builds outside the repo (BUILD_DIR), because synced folders such as Google Drive
#   break SwiftPM's build database.
# - Without full Xcode, the newest Command Line Tools SDK may lack the SwiftUI macro
#   plugin; the script then falls back to the newest macOS 26 SDK. Override with SDKROOT.
# - Signs with the keychain identity "TinyHand Local Signing" (override with
#   LOCAL_SIGN_IDENTITY) so the Accessibility permission survives rebuilds.
#   Falls back to an ad hoc signature, which needs the permission again after each build.
# - No hardened runtime. The app has no auto-update.
# - macOS asks for Accessibility again after each new build.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

export BUILD_DIR="${BUILD_DIR:-$HOME/Library/Caches/tinypointer-build}"
INSTALL=false
[[ "${1:-}" == "--install" ]] && INSTALL=true

if [[ -z "${SDKROOT:-}" && "$(xcode-select -p)" == *CommandLineTools* ]]; then
    sdk="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1 || true)"
    if [[ -n "$sdk" ]]; then
        export SDKROOT="$sdk"
    fi
fi
echo "==> Building $APP_NAME $VERSION${SDKROOT:+ with $(basename "$SDKROOT")}"
swift build -c release --scratch-path "$BUILD_DIR"

APP="$BUILD_DIR/dist/$APP_NAME.app"
mkdir -p "$BUILD_DIR/dist"
make_bundle "$BUILD_DIR/release/$APP_NAME" "$APP" "0"
IDENTITY="${LOCAL_SIGN_IDENTITY:-TinyHand Local Signing}"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "No \"$IDENTITY\" identity in the keychain; signing ad hoc."
    codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "Built $APP"

if [[ "$INSTALL" == true ]]; then
    quit_running_app
    rm -rf "/Applications/$APP_NAME.app"
    ditto "$APP" "/Applications/$APP_NAME.app"
    open "/Applications/$APP_NAME.app"
    echo "Installed and started /Applications/$APP_NAME.app"
fi
