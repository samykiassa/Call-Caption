#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Call Caption"
APP_BUNDLE="$DIR/$APP_NAME.app"
APP_BIN="$APP_BUNDLE/Contents/MacOS/CallCaption"

if pgrep -x "CallCaption" >/dev/null 2>&1; then
    osascript -e 'tell application id "com.callcaption.app" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        if ! pgrep -x "CallCaption" >/dev/null 2>&1; then
            break
        fi
        sleep 0.1
    done
    if pgrep -x "CallCaption" >/dev/null 2>&1; then
        pkill -x "CallCaption" 2>/dev/null || true
        for _ in $(seq 1 50); do
            if ! pgrep -x "CallCaption" >/dev/null 2>&1; then
                break
            fi
            sleep 0.1
        done
    fi
    if pgrep -x "CallCaption" >/dev/null 2>&1; then
        pkill -KILL -x "CallCaption" 2>/dev/null || true
        for _ in $(seq 1 30); do
            if ! pgrep -x "CallCaption" >/dev/null 2>&1; then
                break
            fi
            sleep 0.1
        done
    fi
fi

BUILD_ENV_STAMP="${DEPLOYMENT_TARGET:-arm64-apple-macos26.0}|${CODESIGN_IDENTITY:--}"
LAST_BUILD_ENV_FILE="$DIR/.build/last_build_env"

NEEDS_BUILD=0
if [ ! -x "$APP_BIN" ]; then
    NEEDS_BUILD=1
elif [ ! -f "$LAST_BUILD_ENV_FILE" ] || [ "$(cat "$LAST_BUILD_ENV_FILE" 2>/dev/null || true)" != "$BUILD_ENV_STAMP" ]; then
    NEEDS_BUILD=1
elif [ -n "$(find "$DIR/Sources" "$DIR/Resources" "$DIR/build.sh" "$DIR/PRIVACY.md" "$DIR/TERMS.md" "$DIR/LICENSE" \( -type f -newer "$APP_BIN" -o -type d -newer "$APP_BIN" \) -print -quit 2>/dev/null)" ]; then
    NEEDS_BUILD=1
fi

if [ "$NEEDS_BUILD" -eq 1 ]; then
    echo "App bundle missing or out of date. Building..."
    bash "$DIR/build.sh"
fi

echo "Launching Call Caption ($APP_NAME.app)..."
open "$APP_BUNDLE"
