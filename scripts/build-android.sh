#!/bin/bash
set -euo pipefail
MACROID_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
cd "$MACROID_ROOT/android"
./gradlew :app:assembleDebug "$@"
mkdir -p "$MACROID_ROOT/artifacts"
cp app/build/outputs/apk/debug/app-debug.apk "$MACROID_ROOT/artifacts/Macroid.apk"
echo "Built Macroid.apk (development signature)"
