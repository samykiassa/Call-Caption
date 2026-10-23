import Foundation
import Speech
import os

public enum AppLog {
    public static let subsystem = Bundle.main.bundleIdentifier ?? "com.callcaption.app"
    public static let app = Logger(subsystem: subsystem, category: "App")
    public static let audio = Logger(subsystem: subsystem, category: "AudioCapture")
    public static let speech = Logger(subsystem: subsystem, category: "SpeechRecognition")
    public static let translation = Logger(subsystem: subsystem, category: "Translation")
    public static let liveShare = Logger(subsystem: subsystem, category: "LiveShare")
    public static let coordinator = Logger(subsystem: subsystem, category: "Coordinator")
    public static let transcript = Logger(subsystem: subsystem, category: "Transcript")
}

public enum L10n {
    public static func tr(_ key: String, _ defaultValue: String? = nil) -> String {
        NSLocalizedString(key, value: defaultValue ?? key, comment: "")
    }
}

public struct LanguageItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let code: String
    public let speechLocale: String
    public let name: String
    public let flag: String

    public var localizedName: String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? L10n.tr("lang.\(code)", name)
    }

    public var displayName: String {
        "\(flag) \(name)"
    }
}

public struct SupportedLanguages: Sendable {
    private struct CacheState: Sendable {
        var localeCache: [String: (locale: Locale, timestamp: TimeInterval)] = [:]
        var downloadedCache: [String: (isDownloaded: Bool, timestamp: TimeInterval)] = [:]
        var isPrewarming: Bool = false
    }

    private static let cacheLock = OSAllocatedUnfairLock(initialState: CacheState())
    private static let cacheTTL: TimeInterval = 120.0
    private static let prewarmQueue = DispatchQueue(label: "com.callcaption.languages.prewarm", qos: .utility)

    public static let all: [LanguageItem] = [
        LanguageItem(id: "en", code: "en", speechLocale: "en-US", name: "English", flag: "🇬🇧"),
        LanguageItem(id: "es", code: "es", speechLocale: "es-ES", name: "Spanish", flag: "🇪🇸"),
        LanguageItem(id: "fr", code: "fr", speechLocale: "fr-FR", name: "French", flag: "🇫🇷"),
        LanguageItem(id: "de", code: "de", speechLocale: "de-DE", name: "German", flag: "🇩🇪"),
        LanguageItem(id: "it", code: "it", speechLocale: "it-IT", name: "Italian", flag: "🇮🇹"),
        LanguageItem(id: "pt", code: "pt", speechLocale: "pt-BR", name: "Portuguese", flag: "🇧🇷"),
        LanguageItem(id: "ar", code: "ar", speechLocale: "ar-SA", name: "Arabic", flag: "🇸🇦"),
        LanguageItem(id: "zh", code: "zh", speechLocale: "zh-CN", name: "Chinese (Mandarin)", flag: "🇨🇳"),
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

    public static func isRTL(languageCode: String) -> Bool {
        let prefix = languageCode.lowercased().components(separatedBy: "-").first ?? languageCode.lowercased()
        return rtlLanguageCodes.contains(prefix)
    }

    private static let byCode: [String: LanguageItem] = {
        var map: [String: LanguageItem] = [:]
        map.reserveCapacity(all.count * 2)
        for item in all {
            map[item.code.lowercased()] = item
            map[item.speechLocale.lowercased()] = item
        }
        return map
    }()

    private static let supportedLocalesByPrefix: [String: [Locale]] = {
        var grouped: [String: [Locale]] = [:]
        let allSupported = SFSpeechRecognizer.supportedLocales().sorted { $0.identifier < $1.identifier }
        for loc in allSupported {
            let id = loc.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
            let prefix = id.components(separatedBy: "-").first ?? id
            grouped[prefix, default: []].append(loc)
        }
        return grouped
    }()

    private static let commonFallbacksByPrefix: [String: [String]] = [
        "es": ["es-MX", "es-US"],
        "en": ["en-GB", "en-AU", "en-CA"],
        "pt": ["pt-PT"],
        "fr": ["fr-CA"],
        "zh": ["zh-TW", "zh-HK"]
    ]

    public static func item(forCode code: String) -> LanguageItem? {
        let clean = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return nil }
        if let direct = byCode[clean] {
            return direct
        }
        if let prefix = clean.components(separatedBy: "-").first, let byPrefix = byCode[prefix] {
            return byPrefix
        }
        return nil
    }

    public static func invalidateCache() {
        cacheLock.withLock { state in
            state.localeCache.removeAll(keepingCapacity: true)
            state.downloadedCache.removeAll(keepingCapacity: true)
        }
    }

    public static func refreshCacheInBackground(forCodes codes: [String] = [], completion: (@Sendable @MainActor () -> Void)? = nil) {
        let shouldStart = cacheLock.withLock { state -> Bool in
            if state.isPrewarming { return false }
            state.isPrewarming = true
            return true
        }
        guard shouldStart else { return }

        let targetCodes = codes.isEmpty ? all.map(\.code) : codes
        prewarmQueue.async {
            for code in targetCodes {
                let clean = code.lowercased().components(separatedBy: "-").first ?? code.lowercased()
                _ = resolveLocaleUncached(forCode: clean)
            }
            cacheLock.withLock { state in
                state.isPrewarming = false
            }
            if let completion = completion {
                DispatchQueue.main.async {
                    completion()
                }
            }
        }
    }

    public static func bestLocale(forCode code: String) -> Locale {
        let clean = code.lowercased().components(separatedBy: "-").first ?? code.lowercased()
        let now = ProcessInfo.processInfo.systemUptime

        if let cached = cacheLock.withLock({ state -> Locale? in
            if let entry = state.localeCache[clean], (now - entry.timestamp) < cacheTTL {
                return entry.locale
            }
            return nil
        }) {
            return cached
        }

        if Thread.isMainThread {
            let fallbackLocale: Locale
            if let item = item(forCode: clean) {
                fallbackLocale = Locale(identifier: item.speechLocale)
            } else {
                fallbackLocale = Locale(identifier: clean)
            }
            refreshCacheInBackground(forCodes: [clean])
            return fallbackLocale
        }

        return resolveLocaleUncached(forCode: clean)
    }

    private static func resolveLocaleUncached(forCode clean: String) -> Locale {
        let now = ProcessInfo.processInfo.systemUptime
        var resolvedLocale: Locale? = nil
        var isDownloaded = false
        var testedIdentifiers = Set<String>()

        if let item = item(forCode: clean) {
            let preferredLoc = Locale(identifier: item.speechLocale)
            testedIdentifiers.insert(item.speechLocale.lowercased())
            if let rec = SFSpeechRecognizer(locale: preferredLoc), rec.supportsOnDeviceRecognition {
                resolvedLocale = preferredLoc
                isDownloaded = true
            }
        }

        if resolvedLocale == nil {
            let sysId = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
            let sysLower = sysId.lowercased()
            if (sysLower == clean || sysLower.hasPrefix(clean + "-")) && testedIdentifiers.insert(sysLower).inserted {
                let sysLoc = Locale(identifier: sysId)
                if let rec = SFSpeechRecognizer(locale: sysLoc), rec.supportsOnDeviceRecognition {
                    resolvedLocale = sysLoc
                    isDownloaded = true
                }
            }
        }

        if resolvedLocale == nil, let fallbacks = commonFallbacksByPrefix[clean] {
            for fb in fallbacks where testedIdentifiers.insert(fb.lowercased()).inserted {
                let fbLoc = Locale(identifier: fb)
                if let rec = SFSpeechRecognizer(locale: fbLoc), rec.supportsOnDeviceRecognition {
                    resolvedLocale = fbLoc
                    isDownloaded = true
                    break
                }
            }
        }

        if resolvedLocale == nil, let candidates = supportedLocalesByPrefix[clean] {
            for loc in candidates {
                let normId = loc.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
                guard testedIdentifiers.insert(normId).inserted else { continue }
                if let rec = SFSpeechRecognizer(locale: loc), rec.supportsOnDeviceRecognition {
                    resolvedLocale = loc
                    isDownloaded = true
                    break
                }
            }
        }

        let finalLocale: Locale
        if let resolved = resolvedLocale {
            finalLocale = resolved
        } else if let item = item(forCode: clean) {
            finalLocale = Locale(identifier: item.speechLocale)
        } else {
            finalLocale = Locale(identifier: clean)
        }

        let finalDownloaded = isDownloaded
        cacheLock.withLock { state in
            state.localeCache[clean] = (finalLocale, now)
            state.downloadedCache[clean] = (finalDownloaded, now)
        }

        return finalLocale
    }

    public static func isOnDeviceDownloaded(forCode code: String) -> Bool {
        let clean = code.lowercased().components(separatedBy: "-").first ?? code.lowercased()
        let now = ProcessInfo.processInfo.systemUptime

        if let cached = cacheLock.withLock({ state -> Bool? in
            if let entry = state.downloadedCache[clean], (now - entry.timestamp) < cacheTTL {
                return entry.isDownloaded
            }
            return nil
        }) {
            return cached
        }

        if Thread.isMainThread {
            refreshCacheInBackground(forCodes: [clean])
            if let item = item(forCode: clean), let rec = SFSpeechRecognizer(locale: Locale(identifier: item.speechLocale)) {
                return rec.supportsOnDeviceRecognition
            }
            return false
        }

        _ = resolveLocaleUncached(forCode: clean)
        return cacheLock.withLock { $0.downloadedCache[clean]?.isDownloaded ?? false }
    }
}
