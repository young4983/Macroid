#!/bin/bash
set -euo pipefail
MACROID_SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
"$MACROID_SCRIPTS/build-android.sh" "$@"
"$MACROID_SCRIPTS/build-macos.sh"
