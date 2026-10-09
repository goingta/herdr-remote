#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Herdi"
APP_DIR="$SCRIPT_DIR/dist/$APP_NAME.app"

# The widget is an .appex app extension: swift build cannot produce or embed one,
# so the whole build goes through XcodeGen + xcodebuild. Nested signing is xcodebuild's
# job — the widget must be signed before the app that embeds it, and hand-rolled
# codesign after the fact would break that order.
cd "$SCRIPT_DIR"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen missing: brew install xcodegen" >&2
    exit 1
fi

echo "▸ Generating Xcode project..."
xcodegen generate

echo "▸ Building (Release)..."
xcodebuild \
    -project Herdi.xcodeproj \
    -scheme Herdi \
    -configuration Release \
    -derivedDataPath .build/xcode \
    build \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=YES \
    | tail -20

BUILT_APP=".build/xcode/Build/Products/Release/$APP_NAME.app"
if [ ! -d "$BUILT_APP" ]; then
    echo "Build product missing: $BUILT_APP" >&2
    exit 1
fi

echo "▸ Staging .app bundle..."
rm -rf "$APP_DIR"
mkdir -p dist
cp -R "$BUILT_APP" "$APP_DIR"

# Icon, if present (XcodeGen picks up Assets.xcassets; this covers the bare .icns)
if [ -f "$SCRIPT_DIR/Sources/Assets/AppIcon.icns" ] && [ ! -d "$SCRIPT_DIR/Sources/Assets.xcassets" ]; then
    cp "$SCRIPT_DIR/Sources/Assets/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

echo "✓ Built: $APP_DIR"
echo "  To install: cp -R $APP_DIR /Applications/"
