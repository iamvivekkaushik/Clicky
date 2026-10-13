#!/bin/bash
# Builds dist/Clicky-<version>.dmg to share: universal app, Applications shortcut and first-launch notes.
# The app is ad-hoc signed, not notarized (that needs an Apple Developer ID), so macOS asks people to
# approve it once; scripts/dmg-readme.txt explains how.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh --universal
codesign --verify --strict build/Clicky.app

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R build/Clicky.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp scripts/dmg-readme.txt "$STAGE/Read Me First.txt"

mkdir -p dist
DMG="dist/Clicky-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Clicky $VERSION" -srcfolder "$STAGE" -format UDZO "$DMG" >/dev/null
echo "Built $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
