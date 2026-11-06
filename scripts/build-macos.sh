#!/bin/bash
set -euo pipefail
MACROID_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MACROID_SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
if [[ ! -f "$MACROID_ROOT/artifacts/Macroid.apk" ]]; then "$MACROID_ROOT/scripts/build-android.sh"; fi
mkdir -p "$MACROID_ROOT/macos/Resources"
cp "$MACROID_ROOT/artifacts/Macroid.apk" "$MACROID_ROOT/macos/Resources/Macroid.apk"
cp "$MACROID_SDK/platform-tools/adb" "$MACROID_ROOT/macos/Resources/adb"
cp "$MACROID_SDK/platform-tools/NOTICE.txt" "$MACROID_ROOT/macos/Resources/adb-NOTICE.txt"
chmod +x "$MACROID_ROOT/macos/Resources/adb"
python3 "$MACROID_ROOT/scripts/generate-xcode-project.py"
if [[ ! -f "$MACROID_ROOT/macos/Resources/Macroid.icns" ]]; then "$MACROID_ROOT/scripts/make-icon.sh"; fi
xcodebuild -quiet -project "$MACROID_ROOT/macos/Macroid.xcodeproj" -scheme Macroid -configuration Release \
    -derivedDataPath "$MACROID_ROOT/macos/build" ARCHS="x86_64 arm64" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
ditto "$MACROID_ROOT/macos/build/Build/Products/Release/Macroid.app" "$MACROID_ROOT/artifacts/Macroid.app"
codesign --force --sign - "$MACROID_ROOT/artifacts/Macroid.app/Contents/Resources/adb"
codesign --force --sign - "$MACROID_ROOT/artifacts/Macroid.app"
lipo -info "$MACROID_ROOT/artifacts/Macroid.app/Contents/MacOS/Macroid"
lipo -info "$MACROID_ROOT/artifacts/Macroid.app/Contents/Resources/adb"
echo "Built Macroid.app (Universal 2, local ad-hoc signature)"
