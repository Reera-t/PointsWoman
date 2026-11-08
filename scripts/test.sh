#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${POINTSWOMAN_BUILD_DIR:-$ROOT/.build}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$BUILD/clang-cache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-$BUILD/swift-cache}"
swift build --build-system native --disable-sandbox --cache-path "$BUILD/cache" --config-path "$BUILD/config" --security-path "$BUILD/security" --package-path "$ROOT" --scratch-path "$BUILD"
BIN="$(swift build --build-system native --disable-sandbox --cache-path "$BUILD/cache" --config-path "$BUILD/config" --security-path "$BUILD/security" --package-path "$ROOT" --scratch-path "$BUILD" --show-bin-path)"
"$BIN/PointsWomanChecks"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/scripts/integration_test.py" "$BIN/pointswomanctl"
