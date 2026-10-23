import Foundation
import AppKit
import Speech
import AVFoundation
import os

public enum AudioCapturePermissionState: Sendable {
    case unknown
    case active
    case deniedSilenceDetected
}

public final class PermissionHelper: Sendable {
    public static let shared = PermissionHelper()
    public static let permissionStateDidChangeNotification = Notification.Name("PermissionHelperStateDidChangeNotification")

    private let stateLock = OSAllocatedUnfairLock(initialState: AudioCapturePermissionState.unknown)

    private init() {}

    public var audioCaptureState: AudioCapturePermissionState {
        stateLock.withLock { $0 }
    }

    public func updateAudioCaptureState(_ newState: AudioCapturePermissionState) {
        let changed = stateLock.withLock { state -> Bool in
            guard state != newState else { return false }
            state = newState
            return true
        }
        if changed {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.permissionStateDidChangeNotification, object: self)
            }
        }
    }

    public var hasAudioCaptureAccess: Bool {
        let state = audioCaptureState
        switch state {
        case .active:
            return true
        case .deniedSilenceDetected:
            return false
        case .unknown:
            return CaptionCoordinator.shared.audioCaptureEngine.isRunning
        }
    }

    public func requestAudioCaptureAccess() {
        if audioCaptureState == .deniedSilenceDetected {
            openAudioCaptureSettings()
            return
        }
        if !CaptionCoordinator.shared.audioCaptureEngine.isRunning {
            CaptionCoordinator.shared.start()
        } else {
            openAudioCaptureSettings()
        }
    }

    public var hasMicrophoneAccess: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public func requestMicrophoneAccess(completion: @escaping @Sendable @MainActor (Bool) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized {
            Task { @MainActor in completion(true) }
        } else if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    completion(granted)
                }
            }
        } else {
            openMicrophoneSettings()
            Task { @MainActor in completion(false) }
        }
    }

    public func openMicrophoneSettings() {
        openFirstValidSystemSettings([
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
            "x-apple.systempreferences:com.apple.preference.security"
        ])
    }

    public func openAudioCaptureSettings() {
        openFirstValidSystemSettings([
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
            "x-apple.systempreferences:com.apple.preference.security"
        ])
    }

    public var hasSpeechRecognitionAccess: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    public func openSpeechRecognitionSettings() {
        openFirstValidSystemSettings([
            "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
            "x-apple.systempreferences:com.apple.preference.security"
        ])
    }

    public func openDictationSettings() {
        openFirstValidSystemSettings([
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Dictation",
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.keyboard?Dictation",
            "x-apple.systempreferences:com.apple.preference.keyboard"
        ])
    }

    public func openTranslationSettings() {
        openFirstValidSystemSettings([
            "x-apple.systempreferences:com.apple.Localization-Settings.extension?Translation",
            "x-apple.systempreferences:com.apple.Localization-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.language"
        ])
    }

    public func checkSpeechRecognitionAccess(completion: @escaping @Sendable @MainActor (Bool) -> Void) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            Task { @MainActor in completion(true) }
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { status in
                Task { @MainActor in completion(status == .authorized) }
            }
        case .denied, .restricted:
            Task { @MainActor in completion(false) }
        @unknown default:
            Task { @MainActor in completion(false) }
        }
    }

    public func restartApp() {
        let bundlePath = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let escapedPath = bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        let script = "i=0; while kill -0 \(pid) 2>/dev/null; do i=$((i+1)); if [ $i -ge 50 ]; then exit 0; fi; sleep 0.2; done; /usr/bin/open '\(escapedPath)'"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        do {
            try process.run()
        } catch {
            AppLog.app.error("Failed to schedule restart: \(error.localizedDescription, privacy: .public)")
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
            return
        }
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    private func openFirstValidSystemSettings(_ urls: [String]) {
        for urlStr in urls {
            if let url = URL(string: urlStr), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
