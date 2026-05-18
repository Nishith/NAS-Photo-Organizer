#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_NAME="Chronoframe"
BUILD_DIR="${SCRIPT_DIR}/build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
ZIP_PATH="${BUILD_DIR}/${APP_NAME}.zip"
LOG_PATH="${BUILD_DIR}/xcodebuild.log"
PROJECT_PATH="${SCRIPT_DIR}/Chronoframe.xcodeproj"
SCHEME_NAME="Chronoframe"
PACKAGING_DIR="${SCRIPT_DIR}/Packaging"
DERIVED_DATA_DIR="${BUILD_DIR}/DerivedData"
ENTITLEMENTS_PATH="${PACKAGING_DIR}/Chronoframe.entitlements"
if [ -z "${TMPDIR:-}" ]; then TMPDIR=/tmp; fi
TMP_DIR="${TMPDIR%/}/chronoframe-ui-build"
MODULE_CACHE_DIR="${TMP_DIR}/module-cache"
SWIFT_HOME_DIR="${TMP_DIR}/home"
SWIFT_CACHE_DIR="${SWIFT_HOME_DIR}/Library/Caches"
VALIDATOR_COMMAND=(
  env
  HOME="$SWIFT_HOME_DIR"
  XDG_CACHE_HOME="$SWIFT_CACHE_DIR"
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
  SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIR"
  swift run --disable-sandbox --package-path "$SCRIPT_DIR" ChronoframePackagingTool
)

mkdir -p "$BUILD_DIR" "$MODULE_CACHE_DIR" "$SWIFT_CACHE_DIR"
rm -rf "$APP_DIR"
rm -rf "$DERIVED_DATA_DIR"
rm -f "$ZIP_PATH"
: >"$LOG_PATH"

if [ ! -d "$PROJECT_PATH" ]; then
  echo "error: expected Xcode project at $PROJECT_PATH" >&2
  exit 1
fi

if [ ! -f "$ENTITLEMENTS_PATH" ]; then
  echo "error: expected entitlements file at $ENTITLEMENTS_PATH" >&2
  exit 1
fi

echo "🔨 Building Xcode project from ${SCRIPT_DIR}..."
if ! xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGNING_ALLOWED=NO \
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" \
  SWIFT_MODULECACHE_PATH="$MODULE_CACHE_DIR" \
  build >"$LOG_PATH" 2>&1; then
  echo "error: xcodebuild failed while building ${APP_NAME}." >&2
  echo "log: ${LOG_PATH}" >&2
  echo "---- last 80 xcodebuild log lines ----" >&2
  tail -n 80 "$LOG_PATH" >&2 || true
  exit 1
fi

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

"${VALIDATOR_COMMAND[@]}" "$APP_DIR"

echo "🗜️ Creating zip archive..."
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

echo "✅ Build complete!"
echo "➡️  You can run it with: open \"${APP_DIR}\""
echo "➡️  Archive ready at: ${ZIP_PATH}"
echo "➡️  Xcode build log: ${LOG_PATH}"
