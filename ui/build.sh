#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_NAME="Chronoframe"
BUILD_DIR="${SCRIPT_DIR}/build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
ZIP_PATH="${BUILD_DIR}/${APP_NAME}.zip"
PROJECT_PATH="${SCRIPT_DIR}/Chronoframe.xcodeproj"
SCHEME_NAME="Chronoframe"
PACKAGING_DIR="${SCRIPT_DIR}/Packaging"
DERIVED_DATA_DIR="${BUILD_DIR}/DerivedData"
ENTITLEMENTS_PATH="${PACKAGING_DIR}/Chronoframe.entitlements"
VALIDATOR_PATH="${PACKAGING_DIR}/validate_app_bundle.py"
TMP_DIR="${TMPDIR:-/tmp}/chronoframe-ui-build"
MODULE_CACHE_DIR="${TMP_DIR}/module-cache"

mkdir -p "$BUILD_DIR" "$MODULE_CACHE_DIR"
rm -rf "$APP_DIR"
rm -rf "$DERIVED_DATA_DIR"
rm -f "$ZIP_PATH"

if [ ! -d "$PROJECT_PATH" ]; then
  echo "error: expected Xcode project at $PROJECT_PATH" >&2
  exit 1
fi

if [ ! -f "$ENTITLEMENTS_PATH" ]; then
  echo "error: expected entitlements file at $ENTITLEMENTS_PATH" >&2
  exit 1
fi

if [ ! -f "$VALIDATOR_PATH" ]; then
  echo "error: expected validator script at $VALIDATOR_PATH" >&2
  exit 1
fi

echo "🔨 Building Xcode project from ${SCRIPT_DIR}..."
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGNING_ALLOWED=NO \
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" \
  SWIFT_MODULECACHE_PATH="$MODULE_CACHE_DIR" \
  build >/dev/null

BUILT_APP_PATH="${DERIVED_DATA_DIR}/Build/Products/Debug/${APP_NAME}.app"
if [ ! -d "$BUILT_APP_PATH" ]; then
  echo "error: expected built app at $BUILT_APP_PATH" >&2
  exit 1
fi

echo "📦 Staging app bundle..."
ditto "$BUILT_APP_PATH" "$APP_DIR"

if [ -n "${CHRONOFRAME_CODESIGN_IDENTITY:-}" ]; then
  echo "🔐 Codesigning app bundle with hardened runtime..."
  codesign --force --deep --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS_PATH" \
    --sign "${CHRONOFRAME_CODESIGN_IDENTITY}" \
    "$APP_DIR"
else
  echo "🔏 Applying ad hoc signature for local validation..."
  codesign --force --deep --sign - "$APP_DIR"
fi

python3 "$VALIDATOR_PATH" "$APP_DIR"

echo "🗜️ Creating zip archive..."
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

echo "✅ Build complete!"
echo "➡️  You can run it with: open \"${APP_DIR}\""
echo "➡️  Archive ready at: ${ZIP_PATH}"
