#!/bin/bash
set -e

APP_NAME="NAS Organizer UI"
BUILD_DIR="build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RESOURCES_DIR="${APP_DIR}/Contents/Resources"
ICONSET_DIR="${BUILD_DIR}/AppIcon.iconset"
ICON_FILE="${RESOURCES_DIR}/AppIcon.icns"

echo "🧹 Cleaning up..."
rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"
mkdir -p "$ICONSET_DIR"

echo "🎨 Generating app icon..."
swift Tools/IconGenerator.swift "$ICONSET_DIR"
if command -v iconutil >/dev/null 2>&1; then
  iconutil -c icns "$ICONSET_DIR" -o "$ICON_FILE"
fi

echo "🔨 Compiling Swift sources..."
swiftc \
  Sources/BackendRunner.swift \
  Sources/ContentView.swift \
  Sources/NASOrganizerApp.swift \
  -o "$MACOS_DIR/$APP_NAME" \
  -target x86_64-apple-macosx13.0 \
  -target arm64-apple-macosx13.0 \
  -framework AppKit \
  -framework SwiftUI \
  -framework Combine

echo "📝 Generating Info.plist..."
cat <<EOF > "${APP_DIR}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.nishith.nasorganizerui</string>
    <key>CFBundleDisplayName</key>
    <string>NAS Organizer</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>3.0</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "✅ Build complete!"
echo "➡️  You can run it with: open \"${APP_DIR}\""
