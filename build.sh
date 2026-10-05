#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
APP_NAME="CallCaption"
APP_BUNDLE="$DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

echo "=========================================="
echo "  Building $APP_NAME for macOS"
echo "=========================================="

# 1. Clean previous build
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# 2. Compile Swift sources
echo "-> Compiling Swift sources..."
mkdir -p /tmp/clang-cache

swiftc -O \
  -module-cache-path /tmp/clang-cache \
  -framework AppKit \
  -framework AVFoundation \
  -framework ScreenCaptureKit \
  -framework Speech \
  -framework Translation \
  -framework CoreMedia \
  -framework Accelerate \
  "$DIR"/Sources/*.swift \
  -o "$MACOS_DIR/$APP_NAME"

# 3. Copy Resources & Info.plist
echo "-> Setting up application bundle..."
cp "$DIR/Resources/Info.plist" "$CONTENTS/Info.plist"
if [ -f "$DIR/Resources/AppIcon.icns" ]; then
  cp "$DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi
if [ -f "$DIR/Resources/tunnel_key" ]; then
  cp "$DIR/Resources/tunnel_key"* "$RESOURCES_DIR/"
  chmod 600 "$RESOURCES_DIR/tunnel_key"
fi

# 4. Create PkgInfo
echo -n "APPL????" > "$CONTENTS/PkgInfo"

# 5. Ad-hoc code sign with stable designated requirement for macOS TCC
codesign -s - --force --deep --entitlements "$DIR/Resources/CallCaption.entitlements" -r="designated => identifier \"com.samy.CallCaption\"" "$APP_BUNDLE"

echo "=========================================="
echo "✅ Build completed successfully!"
echo "App location: $APP_BUNDLE"
echo "Launch with:  open $APP_BUNDLE"
echo "=========================================="
