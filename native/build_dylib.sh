#!/bin/bash
# Builds OfflineRating.dylib for iOS (arm64). Usage: build_dylib.sh <out.dylib>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?output path}"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=13.0 -isysroot "$SDK" \
  -dynamiclib -fobjc-arc -O2 -g -Wall -Wextra -Wno-unused-parameter \
  -install_name @rpath/OfflineRating.dylib \
  -framework Foundation -framework UIKit -framework CoreGraphics -framework QuartzCore -framework CoreImage -lsqlite3 \
  "$HERE/orp_main.m" "$HERE/orp_core.m" "$HERE/orp_ui.m" "$HERE/orp_charts.m" "$HERE/orp_index.m" \
  "$HERE/orp_engine.c" "$HERE/orp_store.c" "$HERE/orp_il2cpp.c" "$HERE/orp_hook.c" "$HERE/orp_hook.S" \
  -o "$OUT"
echo "built $OUT"
