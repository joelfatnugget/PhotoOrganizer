#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_NAME="PhotoOrganizer"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
ZIP_PATH="$BUILD_DIR/$APP_NAME.zip"
VERSION="${VERSION:-1.0.0}"
UNIVERSAL="${UNIVERSAL:-false}"

for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL="true" ;;
  esac
done

# Use full Xcode developer directory if active xcode-select points to CommandLineTools.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  CURRENT_DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
  if [[ "$CURRENT_DEV_DIR" != *".app/"* && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  fi
fi

echo "Building $APP_NAME ($VERSION)..."
cd "$ROOT_DIR"

if [[ "$UNIVERSAL" == "true" ]]; then
  xcrun swift build -c release --arch arm64 --arch x86_64
  BIN_PATH="$(xcrun swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$APP_NAME"App
else
  xcrun swift build -c release
  BIN_PATH="$(xcrun swift build -c release --show-bin-path)/${APP_NAME}App"
fi

if [[ ! -f "$BIN_PATH" ]]; then
  echo "Error: compiled binary not found at $BIN_PATH" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
printf "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.photoorganizer.macos</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

echo "Signing $APP_BUNDLE..."
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --verbose "$APP_BUNDLE"

echo "Creating archive..."
rm -f "$DMG_PATH" "$ZIP_PATH"
STAGING_DIR="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

if hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null 2>&1; then
  echo "Created DMG: $DMG_PATH"
  shasum -a 256 "$DMG_PATH"
else
  echo "hdiutil unavailable in this environment; creating ZIP fallback at $ZIP_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
  shasum -a 256 "$ZIP_PATH"
fi

rm -rf "$STAGING_DIR"
echo "Done: $APP_BUNDLE"
