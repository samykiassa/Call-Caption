#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
APP_NAME="Call Caption"
APP_BUNDLE="$DIR/$APP_NAME.app"

pkill -x "CallCaption" 2>/dev/null || true
sleep 0.5

if [ ! -d "$APP_BUNDLE" ]; then
    echo "App bundle not found. Building first..."
    bash "$DIR/build.sh"
fi

echo "Launching Call Caption ($APP_NAME.app)..."
open "$APP_BUNDLE"
