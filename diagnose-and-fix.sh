#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

echo "=========================================================="
echo "  💬 CallCaption: Diagnostics & Permissions"
echo "=========================================================="
echo ""

# 1. Check macOS Version
echo "1. System Information:"
sw_vers
echo ""

# 2. Check Permissions via Swift probe
echo "2. Checking macOS Permissions for CallCaption..."
swift -module-cache-path /tmp/clang-cache -e '
import Foundation
import Speech
import AVFoundation
import ScreenCaptureKit

let speechStatus = SFSpeechRecognizer.authorizationStatus()
let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
var screenAccess = false
if #available(macOS 14.0, *) {
    screenAccess = CGPreflightScreenCaptureAccess()
}

print("   • Speech Recognition Status: \(speechStatus.rawValue) (3 = Authorized, 2 = Denied, 0 = Not Determined)")
print("   • Microphone Access Status:   \(micStatus.rawValue) (3 = Authorized, 2 = Denied, 0 = Not Determined)")
print("   • Screen/Call Audio Access:   \(screenAccess ? "✅ Granted" : "⚠️ Not Granted")")

if speechStatus.rawValue != 3 {
    print("   👉 ACTION REQUIRED: Speech Recognition is not authorized!")
}
if micStatus.rawValue != 3 {
    print("   👉 ACTION REQUIRED: Microphone is not authorized!")
}
if !screenAccess {
    print("   👉 ACTION REQUIRED: Screen Recording is needed to capture incoming caller audio!")
}
'

echo ""
echo "3. Testing macOS TranslationKit (Apple Neural Engine)..."
swift -module-cache-path /tmp/clang-cache -e '
import Foundation
import Translation

_ = Task {
    if #available(macOS 15.0, iOS 18.0, *) {
        let es = Locale.Language(identifier: "es")
        let en = Locale.Language(identifier: "en")
        
        let s1 = TranslationSession(installedSource: es, target: en)
        if let r1 = try? await s1.translate("Hola, me alegro de hablar contigo en WhatsApp.") {
            print("   ✅ ES ➔ EN: \(r1.targetText)")
        }
        
        let s2 = TranslationSession(installedSource: en, target: es)
        if let r2 = try? await s2.translate("Hello! You can see live captions on your screen.") {
            print("   ✅ EN ➔ ES: \(r2.targetText)")
        }
    } else {
        print("   ⚠️ macOS 15+ TranslationSession not supported on this version.")
    }
}
RunLoop.main.run(until: Date().addingTimeInterval(1.5))
'

echo ""
echo "4. Network & Phone Sharing Info:"
IP=$(ipconfig getifaddr en0 2>/dev/null || echo "127.0.0.1")
echo "   • Mac Local IP: http://$IP:8765"

STATUS_JSON=$(curl -s --max-time 2 http://localhost:8765/call-link 2>/dev/null || echo "")
if [ -n "$STATUS_JSON" ]; then
    PUB_URL=$(echo "$STATUS_JSON" | sed -n 's/.*"tunnelURL":"\([^"]*\)".*/\1/p' | sed 's/\\//g')
    CALL_LINK=$(echo "$STATUS_JSON" | sed -n 's/.*"callLink":"\([^"]*\)".*/\1/p' | sed 's/\\//g')
    SHARE_URL=$(echo "$STATUS_JSON" | sed -n 's/.*"shareableURL":"\([^"]*\)".*/\1/p' | sed 's/\\//g')
    
    if [ -n "$PUB_URL" ] && [ "$PUB_URL" != "" ]; then
        echo "   • Public Tunnel URL: $PUB_URL (✅ ACTIVE)"
    else
        echo "   • Public Tunnel URL: Connecting..."
    fi
    if [ -n "$CALL_LINK" ] && [ "$CALL_LINK" != "" ]; then
        echo "   • Call Link:         $CALL_LINK"
    fi
    if [ -n "$SHARE_URL" ] && [ "$SHARE_URL" != "" ]; then
        echo "   • Phone Share URL:   $SHARE_URL"
    fi
else
    echo "   • App server: Not currently running (run ./run.sh to start)"
fi
echo ""
echo "=========================================================="
echo "  🛠️ Quick Fixes for Permissions:"
echo "=========================================================="
echo "If captions are not appearing, ensure these 3 toggles are ON in System Settings:"
echo ""
echo "  1) System Settings ➔ Privacy & Security ➔ Speech Recognition (Turn ON CallCaption)"
echo "  2) System Settings ➔ Privacy & Security ➔ Microphone (Turn ON CallCaption)"
echo "  3) System Settings ➔ Privacy & Security ➔ Screen & System Audio Recording (Turn ON CallCaption)"
echo ""
echo "To open these settings right now, run:"
echo "  open 'x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition'"
echo "  open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'"
echo "  open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone'"
echo "=========================================================="
