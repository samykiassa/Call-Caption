#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
APP_BUNDLE="$DIR/CallCaption.app"
BIN="$APP_BUNDLE/Contents/MacOS/CallCaption"

# Ensure Dictation is enabled in macOS so SFSpeechRecognizer operates cleanly
defaults write com.apple.assistant.support "Dictation Enabled" -bool true 2>/dev/null || true
defaults write com.apple.speech.recognition.AppleSpeechRecognition.prefs DictationIMStatus -bool true 2>/dev/null || true
defaults write com.apple.speech.recognition.AppleSpeechRecognition.prefs VisibleNetworkSRLocaleIdentifiers -dict-add "es_ES" 1 "es_US" 1 "en_US" 1 2>/dev/null || true

# Kill stale tunnels or previous instances
pkill -f "CallCaption" 2>/dev/null || true
pkill -f "nokey@localhost.run" 2>/dev/null || true
sleep 0.5

if [ ! -d "$APP_BUNDLE" ]; then
    echo "App bundle not found. Building first..."
    bash "$DIR/build.sh"
fi

echo "Launching Live Call Caption (CallCaption.app)..."
open "$APP_BUNDLE"
