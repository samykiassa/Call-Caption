#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
APP_NAME="CallCaption"
DMG_NAME="CallCaption-Installer.dmg"
STAGE_DIR="/tmp/CallCaption_DMG_Stage"

echo "=========================================="
echo "  Packaging $APP_NAME Release DMG"
echo "=========================================="

# 1. Build app bundle
bash "$DIR/build.sh"

# 2. Prepare staging directory
rm -rf "$STAGE_DIR"
rm -f "$DIR/$DMG_NAME"
mkdir -p "$STAGE_DIR"

echo "-> Copying $APP_NAME.app to DMG staging..."
cp -R "$DIR/$APP_NAME.app" "$STAGE_DIR/"

# 3. Create Applications symlink for drag-and-drop install
ln -s /Applications "$STAGE_DIR/Applications"

# 4. Generate compressed read-only DMG
echo "-> Creating DMG..."
hdiutil create -volname "CallCaption" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DIR/$DMG_NAME"

# 5. Clean up staging
rm -rf "$STAGE_DIR"

echo "=========================================="
echo "✅ Production DMG created successfully!"
echo "Location: $DIR/$DMG_NAME"
echo "Size: $(du -h "$DIR/$DMG_NAME" | cut -f1)"
echo "=========================================="
