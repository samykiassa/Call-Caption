import Foundation
import AppKit
import AVFoundation
import Speech
import ScreenCaptureKit

public class PermissionHelper {
    public static let shared = PermissionHelper()
    
    private init() {}
    
    public var hasScreenCaptureAccess: Bool {
        if #available(macOS 14.0, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return true
    }
    
    public func requestScreenCaptureAccess() {
        if #available(macOS 14.0, *) {
            let granted = CGRequestScreenCaptureAccess()
            if granted {
                NSLog("[PermissionHelper] CGRequestScreenCaptureAccess returned true")
                return
            }
        }
        openScreenCaptureSettings()
    }
    
    public func openScreenCaptureSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenRecording",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
            "x-apple.systempreferences:com.apple.preference.security"
        ]
        for urlStr in urls {
            if let url = URL(string: urlStr), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
    
    public func checkMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }
    
    public func openMicrophoneSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
            "x-apple.systempreferences:com.apple.preference.security"
        ]
        for urlStr in urls {
            if let url = URL(string: urlStr), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
    
    public var hasSpeechRecognitionAccess: Bool {
        return SFSpeechRecognizer.authorizationStatus() == .authorized
    }
    
    public var hasMicrophoneAccess: Bool {
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    
    public func openSpeechRecognitionSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
            "x-apple.systempreferences:com.apple.preference.security"
        ]
        for urlStr in urls {
            if let url = URL(string: urlStr), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
    
    public func openGeneralPrivacySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
            "x-apple.systempreferences:com.apple.preference.security"
        ]
        for urlStr in urls {
            if let url = URL(string: urlStr), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
    
    public func openLocalNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }
    
    public func openDictationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Dictation") {
            NSWorkspace.shared.open(url)
        }
    }
    
    public func checkSpeechRecognitionAccess(completion: @escaping (Bool) -> Void) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            completion(true)
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async { completion(status == .authorized) }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }
    
    /// macOS requires restarting the app after granting Screen & Audio Recording permission.
    public func restartApp() {
        WebCaptionServer.shared.stop()
        
        let appUrl = Bundle.main.bundleURL
        let script = "sleep 0.5 && open -n \"\(appUrl.path)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()
        
        NSApp.terminate(nil)
    }
}
