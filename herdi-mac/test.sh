#!/bin/bash
# Regenerate the Xcode project, then run the test suite.
# The generate is load-bearing: a test file added or deleted without it
# leaves Herdi.xcodeproj referencing a file that moved, and xcodebuild
# fails on the stale file list (seen 2026-10-11: deleting a test file and
# running xcodebuild against the old project → "Build input file cannot
# be found").
# Runs signed builds, so launch it from a GUI session (Terminal.app); over
# SSH the codesign step fails on the keychain ACL.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen missing: brew install xcodegen" >&2
    exit 1
fi

echo "▸ Generating Xcode project..."
xcodegen generate

echo "▸ Testing (Debug)..."
xcodebuild \
    -project Herdi.xcodeproj \
    -scheme Herdi \
    -derivedDataPath .build/xcode-test \
    test \
    | tail -20
