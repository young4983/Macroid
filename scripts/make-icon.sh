#!/bin/bash
set -euo pipefail
MACROID_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MACROID_ICONSET="$MACROID_ROOT/macos/build/Macroid.iconset"
mkdir -p "$MACROID_ICONSET" "$MACROID_ROOT/macos/Resources"
swift "$MACROID_ROOT/scripts/make-icon.swift" "$MACROID_ICONSET/icon_512x512@2x.png"
for MACROID_SIZE in 16 32 128 256 512; do
    sips -z "$MACROID_SIZE" "$MACROID_SIZE" "$MACROID_ICONSET/icon_512x512@2x.png" --out "$MACROID_ICONSET/icon_${MACROID_SIZE}x${MACROID_SIZE}.png" >/dev/null
    MACROID_DOUBLE=$((MACROID_SIZE * 2))
    if [[ "$MACROID_SIZE" -lt 512 ]]; then
        sips -z "$MACROID_DOUBLE" "$MACROID_DOUBLE" "$MACROID_ICONSET/icon_512x512@2x.png" --out "$MACROID_ICONSET/icon_${MACROID_SIZE}x${MACROID_SIZE}@2x.png" >/dev/null
    fi
done
iconutil -c icns "$MACROID_ICONSET" -o "$MACROID_ROOT/macos/Resources/Macroid.icns"
