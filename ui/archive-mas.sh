#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Chronoframe"
BUILD_DIR="${SCRIPT_DIR}/build"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}-MAS.xcarchive"
EXPORT_DIR="${BUILD_DIR}/mas-export"
PKG_PATH="${BUILD_DIR}/${APP_NAME}-MAS.pkg"
PROJECT_PATH="${SCRIPT_DIR}/Chronoframe.xcodeproj"
SCHEME_NAME="Chronoframe"
PACKAGING_DIR="${SCRIPT_DIR}/Packaging"
DERIVED_DATA_DIR="${BUILD_DIR}/MASArchiveDerivedData"
EXPORT_OPTIONS_PLIST="${PACKAGING_DIR}/ExportOptions-MAS.plist"
VALIDATOR_PATH="${PACKAGING_DIR}/validate_app_bundle.py"
TMP_DIR="${TMPDIR:-/tmp}/chronoframe-ui-mas-archive"
MODULE_CACHE_DIR="${TMP_DIR}/module-cache"
LOCAL_ARCHIVE=0

for arg in "$@"; do
  case "$arg" in
    --local)
      LOCAL_ARCHIVE=1
      ;;
    *)
      echo "error: unknown argument: $arg" >&2
      echo "usage: $0 [--local]" >&2
      exit 64
      ;;
  esac
done

mkdir -p "$BUILD_DIR" "$EXPORT_DIR" "$MODULE_CACHE_DIR"
rm -rf "$ARCHIVE_PATH"
rm -rf "$EXPORT_DIR"
rm -rf "$DERIVED_DATA_DIR"
rm -f "$PKG_PATH"

if [ ! -d "$PROJECT_PATH" ]; then
  echo "error: expected Xcode project at $PROJECT_PATH" >&2
  exit 1
fi

if [ ! -f "$EXPORT_OPTIONS_PLIST" ]; then
  echo "error: expected export options at $EXPORT_OPTIONS_PLIST" >&2
  exit 1
fi

if [ ! -f "$VALIDATOR_PATH" ]; then
  echo "error: expected validator script at $VALIDATOR_PATH" >&2
  exit 1
fi

echo "📦 Archiving Mac App Store build..."
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
  ENABLE_HARDENED_RUNTIME=YES
  CHRONOFRAME_SKIP_PYTHON_BACKEND=YES
  "SWIFT_ACTIVE_COMPILATION_CONDITIONS=MAS_BUILD"
)

if [ "$LOCAL_ARCHIVE" -eq 0 ]; then
  XCODEBUILD_ARGS+=(
    CODE_SIGN_STYLE=Automatic
  )
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

BACKEND_DIR="${ARCHIVED_APP_PATH}/Contents/Resources/Backend"
if [ -d "$BACKEND_DIR" ]; then
  echo "error: Python backend was included in the MAS build — this will be rejected" >&2
  exit 1
fi

if [ "$LOCAL_ARCHIVE" -eq 0 ]; then
  echo "📤 Exporting for App Store upload..."
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
    >/dev/null

  echo "🧾 Validating exported app..."
  EXPORTED_APP="${EXPORT_DIR}/${APP_NAME}.app"
  if [ -d "$EXPORTED_APP" ]; then
    python3 "$VALIDATOR_PATH" --app-store "$EXPORTED_APP"
  fi

  PKG_FILE=$(find "$EXPORT_DIR" -name "*.pkg" -maxdepth 1 | head -1)
  if [ -n "$PKG_FILE" ]; then
    cp "$PKG_FILE" "$PKG_PATH"
    echo "✅ Mac App Store archive complete!"
    echo "➡️  Archive bundle: ${ARCHIVE_PATH}"
    echo "➡️  Upload package: ${PKG_PATH}"
    echo ""
    echo "Upload with: xcrun altool --upload-app -f '${PKG_PATH}' -t macos --apiKey YOUR_KEY --apiIssuer YOUR_ISSUER"
    echo "Or use Xcode > Window > Organizer to upload the archive."
  else
    echo "✅ Mac App Store archive complete!"
    echo "➡️  Archive bundle: ${ARCHIVE_PATH}"
    echo "➡️  Export directory: ${EXPORT_DIR}"
    echo ""
    echo "Use Xcode > Window > Organizer to upload the archive."
  fi
else
  echo "🔏 Local MAS archive (unsigned) — validating bundle structure..."
  python3 "$VALIDATOR_PATH" --app-store "$ARCHIVED_APP_PATH"
  echo "✅ Local Mac App Store archive complete!"
  echo "➡️  Archive bundle: ${ARCHIVE_PATH}"
fi
