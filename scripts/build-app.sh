#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/swift-env.sh"
swift build "${SWIFT_OPTIONS[@]}" --configuration release
BIN_DIR="$(swift build "${SWIFT_OPTIONS[@]}" --configuration release --show-bin-path)"
APP="$PROJECT_ROOT/dist/Earbar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Earbar" "$APP/Contents/MacOS/Earbar"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --strict "$APP"
echo "Built $APP"
