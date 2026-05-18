#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Chronoframe"
BUILD_DIR="${SCRIPT_DIR}/build"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/release"
APP_DIR="${EXPORT_DIR}/${APP_NAME}.app"
ZIP_PATH="${BUILD_DIR}/${APP_NAME}-release.zip"
LOG_PATH="${BUILD_DIR}/archive-xcodebuild.log"
PROJECT_PATH="${SCRIPT_DIR}/Chronoframe.xcodeproj"
SCHEME_NAME="Chronoframe"
PACKAGING_DIR="${SCRIPT_DIR}/Packaging"
DERIVED_DATA_DIR="${BUILD_DIR}/ArchiveDerivedData"
ENTITLEMENTS_PATH="${PACKAGING_DIR}/Chronoframe.entitlements"
# Phase 1 finding (P1): `${TMPDIR:-/tmp}` only fills in when TMPDIR
# is unset; an EMPTY TMPDIR yields `/chronoframe-ui-archive` rooted
# at /, polluting shared machines. Normalize first.
if [ -z "${TMPDIR:-}" ]; then TMPDIR=/tmp; fi
TMP_DIR="${TMPDIR%/}/chronoframe-ui-archive"
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

mkdir -p "$BUILD_DIR" "$EXPORT_DIR" "$MODULE_CACHE_DIR" "$SWIFT_CACHE_DIR"
rm -rf "$ARCHIVE_PATH"
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

if [ "$LOCAL_ARCHIVE" -eq 0 ]; then
  missing=()
  [ -n "${CHRONOFRAME_CODESIGN_IDENTITY:-}" ] || missing+=("CHRONOFRAME_CODESIGN_IDENTITY")
  [ -n "${CHRONOFRAME_DEVELOPMENT_TEAM:-}" ] || missing+=("CHRONOFRAME_DEVELOPMENT_TEAM")
  if [ -z "${CHRONOFRAME_NOTARY_PROFILE:-}" ]; then
    [ -n "${CHRONOFRAME_NOTARY_APPLE_ID:-}" ] || missing+=("CHRONOFRAME_NOTARY_PROFILE or CHRONOFRAME_NOTARY_APPLE_ID")
    [ -n "${CHRONOFRAME_NOTARY_PASSWORD:-}" ] || missing+=("CHRONOFRAME_NOTARY_PROFILE or CHRONOFRAME_NOTARY_PASSWORD")
  fi
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "error: distribution archives require Developer ID signing and notarization settings." >&2
    printf 'missing: %s\n' "${missing[@]}" >&2
    echo "For local ad hoc validation only, rerun with: ./archive.sh --local" >&2
    exit 2
  fi
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
  ENABLE_HARDENED_RUNTIME=YES
)

if [ "$LOCAL_ARCHIVE" -eq 0 ]; then
  XCODEBUILD_ARGS+=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="${CHRONOFRAME_CODESIGN_IDENTITY}"
    DEVELOPMENT_TEAM="${CHRONOFRAME_DEVELOPMENT_TEAM}"
  )
else
  XCODEBUILD_ARGS+=(
    CODE_SIGNING_ALLOWED=NO
  )
fi

if ! "${XCODEBUILD_ARGS[@]}" archive >"$LOG_PATH" 2>&1; then
  echo "error: xcodebuild failed while archiving ${APP_NAME}." >&2
  echo "log: ${LOG_PATH}" >&2
  echo "---- last 80 xcodebuild log lines ----" >&2
  tail -n 80 "$LOG_PATH" >&2 || true
  exit 1
fi

ARCHIVED_APP_PATH="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"
if [ ! -d "$ARCHIVED_APP_PATH" ]; then
  echo "error: expected archived app at $ARCHIVED_APP_PATH" >&2
  exit 1
fi

echo "🧾 Staging archived app..."
ditto "$ARCHIVED_APP_PATH" "$APP_DIR"

VALIDATOR_ARGS=()
if [ "$LOCAL_ARCHIVE" -eq 0 ]; then
  echo "🔐 Verifying Developer ID signature..."
  codesign --verify --deep --strict "$APP_DIR"
  VALIDATOR_ARGS+=(--require-distribution-signing)
else
  echo "🔏 Applying ad hoc signature for local archive validation..."
  codesign --force --deep --sign - "$APP_DIR"
fi

if [ "${#VALIDATOR_ARGS[@]}" -gt 0 ]; then
  "${VALIDATOR_COMMAND[@]}" "${VALIDATOR_ARGS[@]}" "$APP_DIR"
else
  "${VALIDATOR_COMMAND[@]}" "$APP_DIR"
fi

echo "🗜️ Creating release zip archive..."
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

if [ "$LOCAL_ARCHIVE" -eq 0 ]; then
  echo "📨 Submitting zip for notarization..."
  # Phase 1 finding (P1): require a keychain profile so the
  # app-specific password is never passed on argv. The previous
  # fallback exposed `--password "$CHRONOFRAME_NOTARY_PASSWORD"`
  # to `ps -ef` for the duration of the notarytool submit (and to
  # `bash -x` traces if any future caller enabled them).
  if [ -z "${CHRONOFRAME_NOTARY_PROFILE:-}" ]; then
    echo "❌ CHRONOFRAME_NOTARY_PROFILE is required for release notarization." >&2
    echo "   Store the credential with: xcrun notarytool store-credentials --apple-id ... --team-id ..." >&2
    echo "   and set CHRONOFRAME_NOTARY_PROFILE to the profile name." >&2
    exit 1
  fi
  NOTARY_ARGS=(xcrun notarytool submit "$ZIP_PATH" --wait --keychain-profile "$CHRONOFRAME_NOTARY_PROFILE")
  "${NOTARY_ARGS[@]}"

  echo "📎 Stapling notarization ticket..."
  xcrun stapler staple "$APP_DIR"
  xcrun stapler validate "$APP_DIR"
  spctl -a -vv "$APP_DIR"

  echo "🗜️ Recreating zip with stapled app..."
  rm -f "$ZIP_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
fi

echo "✅ Archive complete!"
echo "➡️  Archive bundle: ${ARCHIVE_PATH}"
echo "➡️  Staged app: ${APP_DIR}"
echo "➡️  Zip archive: ${ZIP_PATH}"
echo "➡️  Xcode archive log: ${LOG_PATH}"
