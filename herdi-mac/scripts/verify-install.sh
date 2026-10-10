#!/bin/bash
# Verify that the app installed in /Applications is exactly the dist build —
# same binary bytes, same Info.plist version. Three incidents (2026-10-10) shipped
# a stale or wrong-version binary into /Applications from this exact gap.
# Run on the mac: herdi-mac/scripts/verify-install.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_APP="$SCRIPT_DIR/../dist/Herdi.app"
INSTALLED_APP="/Applications/Herdi.app"

fail() { echo "FAIL: $1"; exit 1; }

for app in "$DIST_APP" "$INSTALLED_APP"; do
    [ -d "$app" ] || fail "missing app bundle: $app"
done

bin() { printf '%s/Contents/MacOS/Herdi' "$1"; }
ver() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist"; }

DIST_MD5="$(md5 -q "$(bin "$DIST_APP")")"
INST_MD5="$(md5 -q "$(bin "$INSTALLED_APP")")"
DIST_VER="$(ver "$DIST_APP")"
INST_VER="$(ver "$INSTALLED_APP")"

echo "dist:       $DIST_VER  $DIST_MD5"
echo "installed:  $INST_VER  $INST_MD5"

[ "$DIST_MD5" = "$INST_MD5" ] || fail "installed binary differs from dist"
[ "$DIST_VER" = "$INST_VER" ] || fail "installed version differs from dist"

if codesign --verify --deep --strict "$INSTALLED_APP" 2>/dev/null; then
    echo "signature:  ok"
else
    fail "installed app fails codesign verification"
fi

echo "PASS: /Applications matches dist ($DIST_VER)"
