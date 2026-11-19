#!/bin/bash
# Builds the simulator host that renders orp_ui.m with sample data.  Usage: build_ui_host.sh <outdir>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; N="$HERE/../.."
OUT="${1:?out dir}"; APP="$OUT/UIHost.app"
mkdir -p "$APP"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun --sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=13.0 -isysroot "$SDK" -fobjc-arc -O1 -g \
  -framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore -framework CoreImage \
  "$HERE/main.m" "$HERE/fake_core.m" "$N/orp_ui.m" -o "$APP/UIHost"
cp "$HERE/Info.plist" "$APP/Info.plist"
codesign -f -s - "$APP"
echo "$APP"
