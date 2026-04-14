#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Chronoframe"
BUILD_DIR="${SCRIPT_DIR}/build"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/release"
APP_DIR="${EXPORT_DIR}/${APP_NAME}.app"
ZIP_PATH="${BUILD_DIR}/${APP_NAME}-release.zip"
PROJECT_PATH="${SCRIPT_DIR}/Chronoframe.xcodeproj"
SCHEME_NAME="Chronoframe"
PACKAGING_DIR="${SCRIPT_DIR}/Packaging"
DERIVED_DATA_DIR="${BUILD_DIR}/ArchiveDerivedData"
ENTITLEMENTS_PATH="${PACKAGING_DIR}/Chronoframe.entitlements"
VALIDATOR_PATH="${PACKAGING_DIR}/validate_app_bundle.py"
TMP_DIR="${TMPDIR:-/tmp}/chronoframe-ui-archive"
MODULE_CACHE_DIR="${TMP_DIR}/module-cache"

mkdir -p "$BUILD_DIR" "$EXPORT_DIR" "$MODULE_CACHE_DIR"
rm -rf "$ARCHIVE_PATH"
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

echo "📦 Archiving Release build..."
XCODEBUILD_ARGS=(
  xcodebuild
  -project "$PROJECT_PATH"
  -scheme "$SCHEME_NAME"
  -configuration Release
  -derivedDataPath "$DERIVED_DATA_DIR"
  -archivePath "$ARCHIVE_PATH"
  -destination "generic/platform=macOS"
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
  SWIFT_MODULECACHE_PATH="$MODULE_CACHE_DIR"
)

if [ -n "${CHRONOFRAME_CODESIGN_IDENTITY:-}" ]; then
  XCODEBUILD_ARGS+=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="${CHRONOFRAME_CODESIGN_IDENTITY}"
  )
  if [ -n "${CHRONOFRAME_DEVELOPMENT_TEAM:-}" ]; then
    XCODEBUILD_ARGS+=(
      DEVELOPMENT_TEAM="${CHRONOFRAME_DEVELOPMENT_TEAM}"
    )
  fi
else
  XCODEBUILD_ARGS+=(
    CODE_SIGNING_ALLOWED=NO
  )
fi

"${XCODEBUILD_ARGS[@]}" archive >/dev/null

ARCHIVED_APP_PATH="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"
if [ ! -d "$ARCHIVED_APP_PATH" ]; then
  echo "error: expected archived app at $ARCHIVED_APP_PATH" >&2
  exit 1
fi

echo "🧾 Staging archived app..."
ditto "$ARCHIVED_APP_PATH" "$APP_DIR"

VALIDATOR_ARGS=()
if [ -n "${CHRONOFRAME_CODESIGN_IDENTITY:-}" ]; then
  echo "🔐 Verifying Developer ID signature..."
  codesign --verify --deep --strict "$APP_DIR"
  VALIDATOR_ARGS+=(--require-distribution-signing)
else
  echo "🔏 Applying ad hoc signature for local archive validation..."
  codesign --force --deep --sign - "$APP_DIR"
fi

if [ "${#VALIDATOR_ARGS[@]}" -gt 0 ]; then
  python3 "$VALIDATOR_PATH" "${VALIDATOR_ARGS[@]}" "$APP_DIR"
else
  python3 "$VALIDATOR_PATH" "$APP_DIR"
fi

echo "🗜️ Creating release zip archive..."
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

echo "✅ Archive complete!"
echo "➡️  Archive bundle: ${ARCHIVE_PATH}"
echo "➡️  Staged app: ${APP_DIR}"
echo "➡️  Zip archive: ${ZIP_PATH}"
