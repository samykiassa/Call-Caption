#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP_NAME="Call Caption.app"
APP_BUNDLE="$DIR/$APP_NAME"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE_NAME="CallCaption"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-arm64-apple-macos26.0}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
WORK_DIR=""

if [ "${1:-}" = "clean" ]; then
    rm -rf "$APP_BUNDLE" "$DIR/$APP_NAME.dSYM" "$DIR/.build" "$DIR/.dmg_staging" "$DIR"/.DS_Store "$DIR/AudioTapHelper.o" "$DIR/CallCaptionSwift.o" "$DIR/main"
    exit 0
fi

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$DIR/.build/clang-module-cache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-$DIR/.build/swift-module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULECACHE_PATH"

cleanup() {
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

echo "Building Call Caption..."

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/callcaption-build.XXXXXX")"
rm -rf "$APP_BUNDLE" "$DIR/$APP_NAME.dSYM"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
if command -v git >/dev/null 2>&1 && git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    BUILD_NUM="$(git -C "$DIR" rev-list --count HEAD 2>/dev/null || echo "1")"
    if [[ "$BUILD_NUM" =~ ^[0-9]+$ ]] && [ "$BUILD_NUM" -ge 1 ]; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" "$CONTENTS_DIR/Info.plist"
    fi
fi

if [ -f "$DIR/Resources/AppIcon.icns" ]; then
    cp "$DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi
for lproj in "$DIR"/Resources/*.lproj; do
    if [ -d "$lproj" ]; then
        cp -R "$lproj" "$RESOURCES_DIR/"
    fi
done
for doc in PRIVACY.md TERMS.md LICENSE; do
    if [ -f "$DIR/$doc" ]; then
        cp "$DIR/$doc" "$RESOURCES_DIR/$doc"
    fi
done
if [ -f "$DIR/Resources/PrivacyInfo.xcprivacy" ]; then
    cp "$DIR/Resources/PrivacyInfo.xcprivacy" "$RESOURCES_DIR/PrivacyInfo.xcprivacy"
fi

OBJ_HELPER="$WORK_DIR/AudioTapHelper.o"
clang -Wall -Wextra -Werror -fobjc-arc -O3 -g \
    -target "$DEPLOYMENT_TARGET" \
    "-fdebug-prefix-map=$DIR/Sources=Sources" \
    -c "$DIR/Sources/AudioTapHelper.m" \
    -o "$OBJ_HELPER"

SWIFT_OBJ="$WORK_DIR/CallCaptionSwift.o"
swiftc \
    -warnings-as-errors \
    -O -whole-module-optimization -g \
    -swift-version 6 \
    -target "$DEPLOYMENT_TARGET" \
    -file-prefix-map "$DIR/Sources=Sources" \
    -import-objc-header "$DIR/Sources/AudioTapHelper.h" \
    -c \
    "$DIR"/Sources/*.swift \
    -o "$SWIFT_OBJ"

swiftc \
    -warnings-as-errors \
    -target "$DEPLOYMENT_TARGET" \
    "$OBJ_HELPER" "$SWIFT_OBJ" \
    -framework Cocoa \
    -framework SwiftUI \
    -framework AVFoundation \
    -framework Speech \
    -framework CoreAudio \
    -framework AudioToolbox \
    -framework Translation \
    -framework Network \
    -framework Security \
    -framework CryptoKit \
    -Xlinker -dead_strip \
    -o "$MACOS_DIR/$EXECUTABLE_NAME"

dsymutil "$MACOS_DIR/$EXECUTABLE_NAME" -o "$DIR/$APP_NAME.dSYM"
rm -f "$OBJ_HELPER" "$SWIFT_OBJ"

strip -Sx "$MACOS_DIR/$EXECUTABLE_NAME"

chmod -R u=rwX,go=rX "$APP_BUNDLE"
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

if [ "$CODESIGN_IDENTITY" = "-" ]; then
    codesign --force --options runtime --sign - \
        --entitlements "$DIR/Resources/CallCaption.entitlements" \
        "$APP_BUNDLE"
else
    codesign --force --options runtime --timestamp \
        --sign "$CODESIGN_IDENTITY" \
        --entitlements "$DIR/Resources/CallCaption.entitlements" \
        "$APP_BUNDLE"
fi

printf '%s\n' "${DEPLOYMENT_TARGET}|${CODESIGN_IDENTITY}" > "$DIR/.build/last_build_env"

echo "Successfully built: $APP_BUNDLE"
