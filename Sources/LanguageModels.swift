import Foundation
import AppKit
import AVFoundation
@preconcurrency import Speech
import os

public enum AppLog {
    public static let subsystem = Bundle.main.bundleIdentifier ?? "com.callcaption.app"
    public static let app = Logger(subsystem: subsystem, category: "App")
    public static let audio = Logger(subsystem: subsystem, category: "AudioCapture")
    public static let speech = Logger(subsystem: subsystem, category: "SpeechRecognition")
    public static let translation = Logger(subsystem: subsystem, category: "Translation")
    public static let liveShare = Logger(subsystem: subsystem, category: "LiveShare")
    public static let coordinator = Logger(subsystem: subsystem, category: "Coordinator")
}

public struct LanguageItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let code: String
    public let speechLocale: String
    public let name: String
    public let flag: String

    public var displayName: String {
        "\(flag) \(name)"
    }

    public var pillTitle: String {
        "\(flag) \(code.uppercased())"
    }
}

public enum SupportedLanguages {
    public static let all: [LanguageItem] = [
        LanguageItem(id: "en", code: "en", speechLocale: "en-US", name: "English", flag: "🇺🇸"),
        LanguageItem(id: "es", code: "es", speechLocale: "es-ES", name: "Spanish", flag: "🇪🇸"),
        LanguageItem(id: "fr", code: "fr", speechLocale: "fr-FR", name: "French", flag: "🇫🇷"),
        LanguageItem(id: "de", code: "de", speechLocale: "de-DE", name: "German", flag: "🇩🇪"),
        LanguageItem(id: "it", code: "it", speechLocale: "it-IT", name: "Italian", flag: "🇮🇹"),
        LanguageItem(id: "pt", code: "pt", speechLocale: "pt-BR", name: "Portuguese", flag: "🇧🇷"),
        LanguageItem(id: "ar", code: "ar", speechLocale: "ar-SA", name: "Arabic", flag: "🇸🇦"),
        LanguageItem(id: "zh", code: "zh", speechLocale: "zh-CN", name: "Chinese", flag: "🇨🇳"),
        LanguageItem(id: "hi", code: "hi", speechLocale: "hi-IN", name: "Hindi", flag: "🇮🇳"),
        LanguageItem(id: "ru", code: "ru", speechLocale: "ru-RU", name: "Russian", flag: "🇷🇺"),
        LanguageItem(id: "ja", code: "ja", speechLocale: "ja-JP", name: "Japanese", flag: "🇯🇵"),
        LanguageItem(id: "ko", code: "ko", speechLocale: "ko-KR", name: "Korean", flag: "🇰🇷"),
        LanguageItem(id: "nl", code: "nl", speechLocale: "nl-NL", name: "Dutch", flag: "🇳🇱"),
        LanguageItem(id: "tr", code: "tr", speechLocale: "tr-TR", name: "Turkish", flag: "🇹🇷"),
        LanguageItem(id: "pl", code: "pl", speechLocale: "pl-PL", name: "Polish", flag: "🇵🇱"),
        LanguageItem(id: "uk", code: "uk", speechLocale: "uk-UA", name: "Ukrainian", flag: "🇺🇦"),
        LanguageItem(id: "vi", code: "vi", speechLocale: "vi-VN", name: "Vietnamese", flag: "🇻🇳"),
        LanguageItem(id: "th", code: "th", speechLocale: "th-TH", name: "Thai", flag: "🇹🇭"),
        LanguageItem(id: "id", code: "id", speechLocale: "id-ID", name: "Indonesian", flag: "🇮🇩"),
        LanguageItem(id: "sv", code: "sv", speechLocale: "sv-SE", name: "Swedish", flag: "🇸🇪")
    ]

    public static let rtlLanguageCodes: Set<String> = ["ar", "he", "fa", "ur"]

    private static let byCode: [String: LanguageItem] = {
        var map: [String: LanguageItem] = [:]
        for item in all {
            map[item.code.lowercased()] = item
            map[item.speechLocale.lowercased()] = item
        }
        return map
    }()

    private static let supportedLocaleMap: [String: Locale] = {
        var map: [String: Locale] = [:]
        for loc in SFSpeechRecognizer.supportedLocales().sorted(by: { $0.identifier < $1.identifier }) {
            let norm = loc.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
            map[norm] = loc
        }
        return map
    }()

    public static func item(forCode code: String) -> LanguageItem? {
        let norm = code.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        if let exact = byCode[norm] { return exact }
        let base = baseCode(from: norm)
        return byCode[base] ?? all.first
    }

    public static func baseCode(from identifier: String) -> String {
        let norm = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        let prefix = norm.split(separator: "-").first.map(String.init) ?? norm
        return prefix.isEmpty ? "en" : prefix
    }

    public static func translationCode(from identifier: String) -> String {
        let norm = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        if norm == "zh-tw" || norm == "zh-hk" || norm == "zh-hant" || norm.hasPrefix("zh-hant-") {
            return "zh-hant"
        }
        if norm == "zh-cn" || norm == "zh-sg" || norm == "zh-hans" || norm.hasPrefix("zh-hans-") || norm == "zh" {
            return "zh-hans"
        }
        return baseCode(from: norm)
    }

    public static func isRTL(languageCode: String) -> Bool {
        rtlLanguageCodes.contains(baseCode(from: languageCode))
    }

    public static func bestLocale(forCode code: String) -> Locale {
        let norm = code.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        if norm.contains("-"), let exact = supportedLocaleMap[norm] {
            return exact
        }
        if let item = item(forCode: norm) {
            let defKey = item.speechLocale.lowercased()
            if let defLocale = supportedLocaleMap[defKey] {
                return defLocale
            }
            if let firstPrefixMatch = supportedLocaleMap
                .filter({ $0.key == item.code || $0.key.hasPrefix(item.code + "-") })
                .sorted(by: { $0.key < $1.key })
                .first?.value {
                return firstPrefixMatch
            }
            return Locale(identifier: item.speechLocale)
        }
        return Locale(identifier: norm.isEmpty ? "en-US" : norm)
    }
}

public enum AudioCapturePermissionState: Sendable, Equatable {
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

    public var hasMicrophoneAccess: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public var hasSpeechRecognitionAccess: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    public func openAudioCaptureSettings() {
        openFirstValidURL([
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ])
    }

    public func openMicrophoneSettings() {
        openFirstValidURL([
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ])
    }

    public func openSpeechRecognitionSettings() {
        openFirstValidURL([
            "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ])
    }

    public func openDictationSettings() {
        openFirstValidURL([
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Dictation",
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.keyboard?Dictation"
        ])
    }

    public func openTranslationSettings() {
        openFirstValidURL([
            "x-apple.systempreferences:com.apple.Localization-Settings.extension?Translation",
            "x-apple.systempreferences:com.apple.Localization-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.language"
        ])
    }

    private func openFirstValidURL(_ strings: [String]) {
        let urls = strings.compactMap(URL.init(string:))
        DispatchQueue.main.async {
            for url in urls where NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
