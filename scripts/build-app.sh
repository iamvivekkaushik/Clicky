#!/bin/bash
# Builds build/Clicky.app (release, ad-hoc signed). Usage: scripts/build-app.sh [--universal] [--install]
#   --universal  Apple silicon + Intel in one binary (slower; used for sharing)
#   --install    copy to /Applications, quitting the running copy first
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHS=()
INSTALL=false
for arg in "$@"; do
  case "$arg" in
    --universal) ARCHS=(--arch arm64 --arch x86_64) ;;
    --install) INSTALL=true ;;
    *) echo "unknown option $arg" >&2; exit 1 ;;
  esac
done

[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift .

swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/Clicky"
APP=build/Clicky.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Clicky"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Clicky"))"

if $INSTALL; then
  pkill -x Clicky 2>/dev/null || true
  rm -rf /Applications/Clicky.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Clicky.app"
fi
