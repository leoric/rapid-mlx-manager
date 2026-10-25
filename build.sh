#!/usr/bin/env bash
# Builds build/rapid-manager.app using only the Swift CLI (no Xcode project needed).
set -euo pipefail
cd "$(dirname "$0")"

# If the .swift files ended up next to Package.swift (flattened download),
# put them where SwiftPM expects them.
if [ ! -d Sources/RapidManager ]; then
  mkdir -p Sources/RapidManager
  shopt -s nullglob
  files=(*.swift)
  for f in "${files[@]}"; do
    [ "$f" = "Package.swift" ] || mv "$f" Sources/RapidManager/
  done
fi

swift build -c release
APP="build/rapid-manager.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/rapid-manager "$APP/Contents/MacOS/rapid-manager"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
echo "Run:  open $APP"
