#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Call Caption.app"
DMG_NAME="Call-Caption.dmg"
STAGING_DIR="$DIR/.dmg_staging"
APP_ZIP="$DIR/.app_notarize.zip"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

cleanup() {
    rm -rf "$STAGING_DIR" "$APP_ZIP"
}
trap cleanup EXIT

if [ "$CODESIGN_IDENTITY" = "-" ] && [ "${ALLOW_ADHOC_DMG:-1}" = "0" ]; then
    echo "Refusing to create an ad-hoc DMG (ALLOW_ADHOC_DMG=0)." >&2
    exit 1
fi

"$DIR/build.sh"

codesign --verify --strict --verbose=2 "$DIR/$APP_NAME"

if [ -n "$NOTARY_PROFILE" ]; then
    rm -f "$APP_ZIP"
    ditto -c -k --keepParent "$DIR/$APP_NAME" "$APP_ZIP"
    xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    rm -f "$APP_ZIP"

    xcrun stapler staple "$DIR/$APP_NAME"
    spctl -a -t exec -vv "$DIR/$APP_NAME"
fi

rm -rf "$STAGING_DIR" "$DIR/$DMG_NAME"
mkdir -p "$STAGING_DIR"
cp -R "$DIR/$APP_NAME" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
    -volname "Call Caption" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DIR/$DMG_NAME"

rm -rf "$STAGING_DIR"

if [ "$CODESIGN_IDENTITY" != "-" ]; then
    codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DIR/$DMG_NAME"
fi

if [ -n "$NOTARY_PROFILE" ]; then
    xcrun notarytool submit "$DIR/$DMG_NAME" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DIR/$DMG_NAME"
    spctl -a -t open --context context:primary-signature -v "$DIR/$DMG_NAME"
fi

if [ "${KEEP_APP:-0}" != "1" ]; then
    rm -rf "$DIR/$APP_NAME" "$DIR/$APP_NAME.dSYM" "$DIR/.build"
fi

echo "Packaged installer: $DIR/$DMG_NAME"
