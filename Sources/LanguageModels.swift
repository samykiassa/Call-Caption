import Foundation
@preconcurrency import Speech
@preconcurrency import AVFoundation
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
    private static let bundleCacheLock = OSAllocatedUnfairLock<[String: Bundle]>(initialState: [:])
    private static let missingSentinel = "__CC_L10N_MISSING__"

    private static func bundle(forLanguageCode code: String) -> Bundle? {
        let normalized = code.lowercased().hasPrefix("es") ? "es" : "en"
        return bundleCacheLock.withLock { cache in
            if let existing = cache[normalized] {
                return existing
            }
            let bundlePath = Bundle.main.path(forResource: normalized, ofType: "lproj")
                ?? {
                    let repoResources = URL(fileURLWithPath: #filePath)
                        .deletingLastPathComponent()
                        .deletingLastPathComponent()
                        .appendingPathComponent("Resources/\(normalized).lproj")
                    return FileManager.default.fileExists(atPath: repoResources.path) ? repoResources.path : nil
                }()
            if let path = bundlePath, let bundle = Bundle(path: path) {
                cache[normalized] = bundle
                return bundle
            }
            return nil
        }
    }

    public static func tr(_ key: String, _ defaultValue: String? = nil, language: String? = nil) -> String {
        let langCode = language ?? AppSettings.shared.appLanguageCode
        if let langBundle = bundle(forLanguageCode: langCode) {
            let value = langBundle.localizedString(forKey: key, value: missingSentinel, table: "Localizable")
            if value != missingSentinel {
                return value
            }
        }
        if !langCode.lowercased().hasPrefix("en"), let enBundle = bundle(forLanguageCode: "en") {
            let value = enBundle.localizedString(forKey: key, value: missingSentinel, table: "Localizable")
            if value != missingSentinel {
                return value
            }
        }
        return defaultValue ?? key
    }
}

public struct LanguageItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let code: String
    public let speechLocale: String
    public let name: String
    public let flag: String

    public var localizedName: String {
        L10n.tr("lang.\(code)", name)
    }

    public var displayName: String {
        "\(flag) \(name)"
    }
}

public struct SpeechVariant: Identifiable, Hashable, Sendable {
    public var id: String { localeId }
    public let languageCode: String
    public let localeId: String
    public let regionName: String
    public let flag: String

    public init(languageCode: String, localeId: String, regionName: String, flag: String) {
        self.languageCode = languageCode
        self.localeId = localeId
        self.regionName = regionName
        self.flag = flag
    }

    public var languageName: String {
        SupportedLanguages.item(forCode: languageCode)?.name ?? languageCode.uppercased()
    }

    public var localizedRegionName: String {
        L10n.tr("region.\(localeId)", regionName)
    }

    public var displayTitle: String {
        "\(flag) \(languageName) — \(regionName)"
    }

    public var localizedDisplayTitle: String {
        let langName = SupportedLanguages.item(forCode: languageCode)?.localizedName ?? languageName
        return "\(flag) \(langName) — \(localizedRegionName)"
    }

    public var shortRegionTitle: String {
        "\(flag) \(regionName)"
    }
}

public struct SupportedLanguages: Sendable {
    private struct CacheState: Sendable {
        var localeCache: [String: (locale: Locale, timestamp: TimeInterval)] = [:]
        var downloadedCache: [String: (isDownloaded: Bool, timestamp: TimeInterval)] = [:]
        var localeDownloadedCache: [String: (isDownloaded: Bool, timestamp: TimeInterval)] = [:]
        var dictationPrefsCache: (installed: Set<String>, hasDict: Bool, timestamp: TimeInterval)?
        var speechRecognitionPrefsCache: (preferred: [String], visibleEnabled: [String], timestamp: TimeInterval)?
        var pendingLocaleProbes: Set<String> = []
        var isProbingLocales: Bool = false
        var isPrewarming: Bool = false
        var pendingPrewarmCodes: Set<String> = []
        var pendingPrewarmCompletions: [@Sendable @MainActor () -> Void] = []
    }

    private static let cacheLock = OSAllocatedUnfairLock(initialState: CacheState())
    private static let cacheTTL: TimeInterval = 120.0
    private static let notDownloadedCacheTTL: TimeInterval = 5.0
    private static let dictationPrefsCacheTTL: TimeInterval = 5.0
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

    private static let supportedIdentifierSet: Set<String> = {
        var set = Set<String>()
        for loc in SFSpeechRecognizer.supportedLocales() {
            set.insert(loc.identifier.replacingOccurrences(of: "_", with: "-").lowercased())
        }
        return set
    }()

    private static let commonFallbacksByPrefix: [String: [String]] = [
        "es": ["es-CO", "es-419", "es-US", "es-MX", "es-CL"],
        "en": ["en-GB", "en-AU", "en-CA", "en-IN", "en-IE", "en-NZ", "en-SG", "en-ZA"],
        "pt": ["pt-PT"],
        "fr": ["fr-CA", "fr-BE", "fr-CH"],
        "zh": ["zh-TW", "zh-HK"],
        "de": ["de-AT", "de-CH"],
        "it": ["it-CH"],
        "nl": ["nl-BE"]
    ]

    public static let variantsByLanguageCode: [String: [SpeechVariant]] = [
        "en": [
            SpeechVariant(languageCode: "en", localeId: "en-US", regionName: "United States", flag: "🇺🇸"),
            SpeechVariant(languageCode: "en", localeId: "en-GB", regionName: "United Kingdom", flag: "🇬🇧"),
            SpeechVariant(languageCode: "en", localeId: "en-CA", regionName: "Canada", flag: "🇨🇦"),
            SpeechVariant(languageCode: "en", localeId: "en-AU", regionName: "Australia", flag: "🇦🇺"),
            SpeechVariant(languageCode: "en", localeId: "en-IN", regionName: "India", flag: "🇮🇳"),
            SpeechVariant(languageCode: "en", localeId: "en-IE", regionName: "Ireland", flag: "🇮🇪"),
            SpeechVariant(languageCode: "en", localeId: "en-NZ", regionName: "New Zealand", flag: "🇳🇿"),
            SpeechVariant(languageCode: "en", localeId: "en-SG", regionName: "Singapore", flag: "🇸🇬"),
            SpeechVariant(languageCode: "en", localeId: "en-ZA", regionName: "South Africa", flag: "🇿🇦")
        ],
        "es": [
            SpeechVariant(languageCode: "es", localeId: "es-ES", regionName: "Spain", flag: "🇪🇸"),
            SpeechVariant(languageCode: "es", localeId: "es-CO", regionName: "Colombia", flag: "🇨🇴"),
            SpeechVariant(languageCode: "es", localeId: "es-MX", regionName: "Mexico", flag: "🇲🇽"),
            SpeechVariant(languageCode: "es", localeId: "es-US", regionName: "United States", flag: "🇺🇸"),
            SpeechVariant(languageCode: "es", localeId: "es-CL", regionName: "Chile", flag: "🇨🇱"),
            SpeechVariant(languageCode: "es", localeId: "es-419", regionName: "Latin America", flag: "🌎")
        ],
        "fr": [
            SpeechVariant(languageCode: "fr", localeId: "fr-FR", regionName: "France", flag: "🇫🇷"),
            SpeechVariant(languageCode: "fr", localeId: "fr-CA", regionName: "Canada", flag: "🇨🇦"),
            SpeechVariant(languageCode: "fr", localeId: "fr-BE", regionName: "Belgium", flag: "🇧🇪"),
            SpeechVariant(languageCode: "fr", localeId: "fr-CH", regionName: "Switzerland", flag: "🇨🇭")
        ],
        "de": [
            SpeechVariant(languageCode: "de", localeId: "de-DE", regionName: "Germany", flag: "🇩🇪"),
            SpeechVariant(languageCode: "de", localeId: "de-AT", regionName: "Austria", flag: "🇦🇹"),
            SpeechVariant(languageCode: "de", localeId: "de-CH", regionName: "Switzerland", flag: "🇨🇭")
        ],
        "it": [
            SpeechVariant(languageCode: "it", localeId: "it-IT", regionName: "Italy", flag: "🇮🇹"),
            SpeechVariant(languageCode: "it", localeId: "it-CH", regionName: "Switzerland", flag: "🇨🇭")
        ],
        "pt": [
            SpeechVariant(languageCode: "pt", localeId: "pt-BR", regionName: "Brazil", flag: "🇧🇷"),
            SpeechVariant(languageCode: "pt", localeId: "pt-PT", regionName: "Portugal", flag: "🇵🇹")
        ],
        "zh": [
            SpeechVariant(languageCode: "zh", localeId: "zh-CN", regionName: "Mainland China", flag: "🇨🇳"),
            SpeechVariant(languageCode: "zh", localeId: "zh-TW", regionName: "Taiwan", flag: "🇹🇼"),
            SpeechVariant(languageCode: "zh", localeId: "zh-HK", regionName: "Hong Kong", flag: "🇭🇰")
        ],
        "nl": [
            SpeechVariant(languageCode: "nl", localeId: "nl-NL", regionName: "Netherlands", flag: "🇳🇱"),
            SpeechVariant(languageCode: "nl", localeId: "nl-BE", regionName: "Belgium", flag: "🇧🇪")
        ],
        "ar": [SpeechVariant(languageCode: "ar", localeId: "ar-SA", regionName: "Saudi Arabia", flag: "🇸🇦")],
        "hi": [SpeechVariant(languageCode: "hi", localeId: "hi-IN", regionName: "India", flag: "🇮🇳")],
        "ru": [SpeechVariant(languageCode: "ru", localeId: "ru-RU", regionName: "Russia", flag: "🇷🇺")],
        "ja": [SpeechVariant(languageCode: "ja", localeId: "ja-JP", regionName: "Japan", flag: "🇯🇵")],
        "ko": [SpeechVariant(languageCode: "ko", localeId: "ko-KR", regionName: "South Korea", flag: "🇰🇷")],
        "tr": [SpeechVariant(languageCode: "tr", localeId: "tr-TR", regionName: "Turkey", flag: "🇹🇷")],
        "pl": [SpeechVariant(languageCode: "pl", localeId: "pl-PL", regionName: "Poland", flag: "🇵🇱")],
        "uk": [SpeechVariant(languageCode: "uk", localeId: "uk-UA", regionName: "Ukraine", flag: "🇺🇦")],
        "vi": [SpeechVariant(languageCode: "vi", localeId: "vi-VN", regionName: "Vietnam", flag: "🇻🇳")],
        "th": [SpeechVariant(languageCode: "th", localeId: "th-TH", regionName: "Thailand", flag: "🇹🇭")],
        "id": [SpeechVariant(languageCode: "id", localeId: "id-ID", regionName: "Indonesia", flag: "🇮🇩")],
        "sv": [SpeechVariant(languageCode: "sv", localeId: "sv-SE", regionName: "Sweden", flag: "🇸🇪")]
    ]

    public static func variants(forCode code: String) -> [SpeechVariant] {
        let clean = code.replacingOccurrences(of: "_", with: "-").lowercased().components(separatedBy: "-").first ?? code.lowercased()
        if let list = variantsByLanguageCode[clean], !list.isEmpty {
            return list
        }
        if let item = item(forCode: clean) {
            return [SpeechVariant(languageCode: item.code, localeId: item.speechLocale, regionName: item.name, flag: item.flag)]
        }
        return []
    }

    public static func variant(forLocaleId localeId: String) -> SpeechVariant? {
        let norm = localeId.replacingOccurrences(of: "_", with: "-").lowercased()
        let prefix = norm.components(separatedBy: "-").first ?? norm
        if let list = variantsByLanguageCode[prefix] {
            if let exact = list.first(where: { $0.localeId.lowercased() == norm }) {
                return exact
            }
        }
        return nil
    }

    public static func activeVariant(forCode code: String) -> SpeechVariant? {
        let clean = code.replacingOccurrences(of: "_", with: "-").lowercased().components(separatedBy: "-").first ?? code.lowercased()
        let list = variants(forCode: clean)
        guard !list.isEmpty else { return nil }
        if let pref = AppSettings.shared.preferredSpeechLocale(forCode: clean),
           let match = list.first(where: { $0.localeId.caseInsensitiveCompare(pref) == .orderedSame }) {
            return match
        }
        let resolvedId = bestLocale(forCode: clean).identifier.replacingOccurrences(of: "_", with: "-")
        if let match = list.first(where: { $0.localeId.caseInsensitiveCompare(resolvedId) == .orderedSame }) {
            return match
        }
        return list.first
    }

    /// Maps SFSpeechRecognizer locales without a standalone DictationTranscriber entry
    /// to their deterministic macOS Assistant/Dictation backing locale, avoiding non-deterministic
    /// `Set` fallback iteration in `DictationTranscriber.supportedLocale(equivalentTo:)`.
    public static let dictationBackingLocaleAliases: [String: String] = [
        "es-co": "es-US",
        "es-419": "es-US"
    ]

    public static func dictationBackingLocaleId(for localeId: String) -> String? {
        let norm = localeId.replacingOccurrences(of: "_", with: "-").lowercased()
        return dictationBackingLocaleAliases[norm]
    }

    public static func isLocaleDownloaded(_ localeId: String) -> Bool {
        let norm = localeId.replacingOccurrences(of: "_", with: "-")
        if SpeechAssetDownloader.shared.isLocaleMarkedDeleted(norm) {
            return false
        }
        if SpeechAssetDownloader.shared.isLocaleMarkedInstalled(norm) {
            return true
        }
        let lower = norm.lowercased()
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = cacheLock.withLock({ state -> Bool? in
            if let entry = state.localeDownloadedCache[lower] {
                let ttl = entry.isDownloaded ? cacheTTL : notDownloadedCacheTTL
                if (now - entry.timestamp) < ttl {
                    return entry.isDownloaded
                }
            }
            return nil
        }) {
            return cached
        }

        if let installedSet = cachedOfflineDictationSet(now: now) {
            if installedSet.contains(lower) {
                cacheLock.withLock { $0.localeDownloadedCache[lower] = (true, now) }
                return true
            }
            if let backingId = dictationBackingLocaleId(for: norm),
               !SpeechAssetDownloader.shared.isLocaleMarkedDeleted(backingId),
               installedSet.contains(backingId.lowercased()) {
                cacheLock.withLock { $0.localeDownloadedCache[lower] = (true, now) }
                return true
            }
        }

        if Thread.isMainThread {
            // Avoid synchronous main-thread SFSpeechRecognizer IPC across dozens of locales;
            // enqueue a coalesced background probe without poisoning the cache with an unprobed false entry.
            cacheLock.withLock { state in
                _ = state.pendingLocaleProbes.insert(norm)
            }
            scheduleBackgroundLocaleProbe()
            return false
        }

        let result = SFSpeechRecognizer(locale: Locale(identifier: norm))?.supportsOnDeviceRecognition ?? false
        cacheLock.withLock { $0.localeDownloadedCache[lower] = (result, now) }
        return result
    }

    private static func cachedOfflineDictationSet(now: TimeInterval) -> Set<String>? {
        if let cached = cacheLock.withLock({ state -> (installed: Set<String>, hasDict: Bool)? in
            if let entry = state.dictationPrefsCache, (now - entry.timestamp) < dictationPrefsCacheTTL {
                return (entry.installed, entry.hasDict)
            }
            return nil
        }) {
            return cached.hasDict ? cached.installed : nil
        }

        if let dict = UserDefaults(suiteName: "com.apple.assistant.support")?.dictionary(forKey: "Offline Dictation Status") as? [String: [String: Any]] {
            var installed = Set<String>()
            installed.reserveCapacity(dict.count)
            for (key, value) in dict {
                if (value["Installed"] as? NSNumber)?.boolValue == true {
                    installed.insert(key.replacingOccurrences(of: "_", with: "-").lowercased())
                }
            }
            let installedSet = installed
            cacheLock.withLock { state in
                state.dictationPrefsCache = (installedSet, true, now)
            }
            return installedSet
        }

        cacheLock.withLock { state in
            state.dictationPrefsCache = ([], false, now)
        }
        return nil
    }

    private static func scheduleBackgroundLocaleProbe() {
        let shouldStart = cacheLock.withLock { state -> Bool in
            guard !state.isProbingLocales, !state.pendingLocaleProbes.isEmpty else { return false }
            state.isProbingLocales = true
            return true
        }
        guard shouldStart else { return }

        prewarmQueue.async {
            while true {
                let batch = cacheLock.withLock { state -> [String] in
                    let items = Array(state.pendingLocaleProbes)
                    state.pendingLocaleProbes.removeAll()
                    if items.isEmpty {
                        state.isProbingLocales = false
                    }
                    return items
                }
                guard !batch.isEmpty else { break }

                var anyBecameAvailable = false
                let probeNow = ProcessInfo.processInfo.systemUptime
                for rawId in batch {
                    let norm = rawId.replacingOccurrences(of: "_", with: "-")
                    let lower = norm.lowercased()
                    if SpeechAssetDownloader.shared.isLocaleMarkedDeleted(norm) {
                        continue
                    }
                    let supported = SFSpeechRecognizer(locale: Locale(identifier: norm))?.supportsOnDeviceRecognition ?? false
                    let changed = cacheLock.withLock { state -> Bool in
                        let prev = state.localeDownloadedCache[lower]?.isDownloaded ?? false
                        state.localeDownloadedCache[lower] = (supported, probeNow)
                        if supported != prev {
                            let prefix = lower.components(separatedBy: "-").first ?? lower
                            state.localeCache.removeValue(forKey: prefix)
                            state.downloadedCache.removeValue(forKey: prefix)
                            return supported
                        }
                        return false
                    }
                    if changed {
                        anyBecameAvailable = true
                    }
                }

                if anyBecameAvailable {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: SpeechAssetDownloader.stateDidChangeNotification,
                            object: SpeechAssetDownloader.shared
                        )
                    }
                }
            }
        }
    }

    public static func systemPreferredDictationLocales(forPrefix clean: String) -> [String] {
        let now = ProcessInfo.processInfo.systemUptime
        let snapshot: (preferred: [String], visibleEnabled: [String])
        if let cached = cacheLock.withLock({ state -> (preferred: [String], visibleEnabled: [String])? in
            if let entry = state.speechRecognitionPrefsCache, (now - entry.timestamp) < dictationPrefsCacheTTL {
                return (entry.preferred, entry.visibleEnabled)
            }
            return nil
        }) {
            snapshot = cached
        } else if let prefs = UserDefaults(suiteName: "com.apple.speech.recognition.AppleSpeechRecognition.prefs") {
            let preferred = prefs.stringArray(forKey: "DictationIMPreferredLanguageIdentifiers") ?? []
            var visibleEnabled: [String] = []
            if let visible = prefs.dictionary(forKey: "VisibleNetworkSRLocaleIdentifiers") {
                visibleEnabled.reserveCapacity(visible.count)
                for (key, val) in visible.sorted(by: { $0.key < $1.key }) {
                    if (val as? NSNumber)?.boolValue == true {
                        visibleEnabled.append(key)
                    }
                }
            }
            let entry = (preferred, visibleEnabled)
            cacheLock.withLock { state in
                state.speechRecognitionPrefsCache = (entry.0, entry.1, now)
            }
            snapshot = entry
        } else {
            cacheLock.withLock { state in
                state.speechRecognitionPrefsCache = ([], [], now)
            }
            return []
        }

        var results: [String] = []
        var seen = Set<String>()

        let addIfMatching: (String) -> Void = { rawId in
            let normalized = rawId.replacingOccurrences(of: "_", with: "-")
            let lower = normalized.lowercased()
            guard lower == clean || lower.hasPrefix(clean + "-") else { return }
            guard supportedIdentifierSet.contains(lower) else { return }
            if seen.insert(lower).inserted {
                results.append(normalized)
            }
        }

        for id in snapshot.preferred {
            addIfMatching(id)
        }
        for key in snapshot.visibleEnabled {
            addIfMatching(key)
        }
        return results
    }

    public static func item(forCode code: String) -> LanguageItem? {
        let clean = code.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        guard !clean.isEmpty else { return nil }
        if let direct = byCode[clean] {
            return direct
        }
        if let prefix = clean.components(separatedBy: "-").first, let byPrefix = byCode[prefix] {
            return byPrefix
        }
        return nil
    }

    public static func invalidateResolvedPreferenceCache(forCode code: String) {
        let clean = code.replacingOccurrences(of: "_", with: "-").lowercased().components(separatedBy: "-").first ?? code.lowercased()
        guard !clean.isEmpty else { return }
        cacheLock.withLock { state in
            state.localeCache.removeValue(forKey: clean)
            state.downloadedCache.removeValue(forKey: clean)
        }
    }

    public static func invalidateCache(forCode code: String? = nil) {
        cacheLock.withLock { state in
            state.dictationPrefsCache = nil
            state.speechRecognitionPrefsCache = nil
            if let code = code, !code.isEmpty {
                let clean = code.replacingOccurrences(of: "_", with: "-").lowercased().components(separatedBy: "-").first ?? code.lowercased()
                state.localeCache.removeValue(forKey: clean)
                state.downloadedCache.removeValue(forKey: clean)
                for key in state.localeDownloadedCache.keys where key == clean || key.hasPrefix(clean + "-") {
                    state.localeDownloadedCache.removeValue(forKey: key)
                }
            } else {
                state.localeCache.removeAll(keepingCapacity: true)
                state.downloadedCache.removeAll(keepingCapacity: true)
                state.localeDownloadedCache.removeAll(keepingCapacity: true)
                state.pendingLocaleProbes.removeAll()
            }
        }
    }

    public static func refreshCacheInBackground(forCodes codes: [String] = [], completion: (@Sendable @MainActor () -> Void)? = nil) {
        let settings = AppSettings.shared
        let requestedCodes = codes.isEmpty ? [settings.foreignLanguageCode, settings.mainLanguageCode] : codes

        let shouldStart = cacheLock.withLock { state -> Bool in
            for code in requestedCodes {
                let clean = code.replacingOccurrences(of: "_", with: "-").lowercased().components(separatedBy: "-").first ?? code.lowercased()
                if !clean.isEmpty {
                    state.pendingPrewarmCodes.insert(clean)
                }
            }
            if let completion = completion {
                state.pendingPrewarmCompletions.append(completion)
            }
            if state.isPrewarming {
                return false
            }
            state.isPrewarming = true
            return true
        }
        guard shouldStart else { return }

        prewarmQueue.async {
            while true {
                let batch = cacheLock.withLock { state -> ([String], [@Sendable @MainActor () -> Void]) in
                    let batchCodes = Array(state.pendingPrewarmCodes)
                    state.pendingPrewarmCodes.removeAll()
                    let batchCompletions = state.pendingPrewarmCompletions
                    state.pendingPrewarmCompletions.removeAll()
                    if batchCodes.isEmpty && batchCompletions.isEmpty {
                        state.isPrewarming = false
                    }
                    return (batchCodes, batchCompletions)
                }
                if batch.0.isEmpty && batch.1.isEmpty {
                    break
                }
                for clean in batch.0 {
                    _ = resolveLocaleUncached(forCode: clean)
                }
                let callbacks = batch.1
                if !callbacks.isEmpty {
                    DispatchQueue.main.async {
                        for cb in callbacks {
                            cb()
                        }
                    }
                }
            }
        }
    }

    public static func bestLocale(forCode code: String) -> Locale {
        let clean = code.replacingOccurrences(of: "_", with: "-").lowercased().components(separatedBy: "-").first ?? code.lowercased()
        let now = ProcessInfo.processInfo.systemUptime

        if let cached = cacheLock.withLock({ state -> Locale? in
            if let entry = state.localeCache[clean] {
                let isDown = state.downloadedCache[clean]?.isDownloaded ?? false
                let ttl = isDown ? cacheTTL : notDownloadedCacheTTL
                if (now - entry.timestamp) < ttl {
                    return entry.locale
                }
            }
            return nil
        }) {
            return cached
        }

        return resolveLocaleUncached(forCode: clean)
    }

    private static func resolveLocaleUncached(forCode clean: String) -> Locale {
        let now = ProcessInfo.processInfo.systemUptime

        if let userPref = AppSettings.shared.preferredSpeechLocale(forCode: clean), !userPref.isEmpty {
            let normPref = userPref.replacingOccurrences(of: "_", with: "-")
            if !SpeechAssetDownloader.shared.isLocaleMarkedDeleted(normPref) {
                let prefLoc = Locale(identifier: normPref)
                let downloaded = isLocaleDownloaded(normPref)
                cacheLock.withLock { state in
                    state.localeCache[clean] = (prefLoc, now)
                    state.downloadedCache[clean] = (downloaded, now)
                }
                return prefLoc
            }
        }

        var resolvedLocale: Locale? = nil
        var isDownloaded = false
        let dictationPrefs = systemPreferredDictationLocales(forPrefix: clean)
        var checkedLowers = Set<String>()

        for prefId in dictationPrefs {
            let lower = prefId.lowercased()
            guard checkedLowers.insert(lower).inserted else { continue }
            if isLocaleDownloaded(prefId) {
                resolvedLocale = Locale(identifier: prefId)
                isDownloaded = true
                break
            }
        }

        if resolvedLocale == nil, let item = item(forCode: clean) {
            let norm = item.speechLocale.replacingOccurrences(of: "_", with: "-")
            let lower = norm.lowercased()
            if checkedLowers.insert(lower).inserted, isLocaleDownloaded(norm) {
                resolvedLocale = Locale(identifier: norm)
                isDownloaded = true
            }
        }

        if resolvedLocale == nil, let fallbacks = commonFallbacksByPrefix[clean] {
            for fallbackId in fallbacks {
                let norm = fallbackId.replacingOccurrences(of: "_", with: "-")
                let lower = norm.lowercased()
                guard supportedIdentifierSet.contains(lower),
                      checkedLowers.insert(lower).inserted else { continue }
                if isLocaleDownloaded(norm) {
                    resolvedLocale = Locale(identifier: norm)
                    isDownloaded = true
                    break
                }
            }
        }

        if resolvedLocale == nil, let supported = supportedLocalesByPrefix[clean] {
            for loc in supported {
                let norm = loc.identifier.replacingOccurrences(of: "_", with: "-")
                let lower = norm.lowercased()
                guard checkedLowers.insert(lower).inserted else { continue }
                if isLocaleDownloaded(norm) {
                    resolvedLocale = loc
                    isDownloaded = true
                    break
                }
            }
        }

        let finalLocale: Locale
        if let resolved = resolvedLocale {
            finalLocale = resolved
        } else if let prefId = dictationPrefs.first(where: { !SpeechAssetDownloader.shared.isLocaleMarkedDeleted($0) }) {
            finalLocale = Locale(identifier: prefId)
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
        let clean = code.replacingOccurrences(of: "_", with: "-").lowercased().components(separatedBy: "-").first ?? code.lowercased()
        let now = ProcessInfo.processInfo.systemUptime

        if let cached = cacheLock.withLock({ state -> Bool? in
            if let entry = state.downloadedCache[clean] {
                let ttl = entry.isDownloaded ? cacheTTL : notDownloadedCacheTTL
                if (now - entry.timestamp) < ttl {
                    return entry.isDownloaded
                }
            }
            return nil
        }) {
            return cached
        }

        _ = resolveLocaleUncached(forCode: clean)
        return cacheLock.withLock { $0.downloadedCache[clean]?.isDownloaded ?? false }
    }
}

public enum SpeechAssetDownloadStatus: Sendable, Equatable {
    case unknown
    case installed
    case downloading(progress: Double)
    case notInstalled
    case failed(message: String)
    case unsupported

    public var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    public var isInstalled: Bool {
        self == .installed
    }
}

public final class SpeechAssetDownloader: @unchecked Sendable {
    public static let shared = SpeechAssetDownloader()

    public static let stateDidChangeNotification = Notification.Name("SpeechAssetDownloaderStateDidChangeNotification")
    public static let didFinishDownloadNotification = Notification.Name("SpeechAssetDownloaderDidFinishDownloadNotification")

    private struct ActiveTaskEntry {
        let token: UUID
        let task: Task<Bool, Never>
        let localeId: String
    }

    private struct DownloaderState {
        var statuses: [String: SpeechAssetDownloadStatus] = [:]
        var activeTasks: [String: ActiveTaskEntry] = [:]
        var completions: [String: [@Sendable @MainActor (Bool) -> Void]] = [:]
        var lastNotifiedPercent: [String: Int] = [:]
        var deletedLocales: Set<String> = []
        var installedLocales: Set<String> = []
    }

    private final class ObservationBox: @unchecked Sendable {
        var observation: NSKeyValueObservation?
        deinit {
            observation?.invalidate()
        }
    }

    private let lock = OSAllocatedUnfairLock(initialState: DownloaderState())

    private init() {}

    public static func normalizeCode(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        return trimmed.components(separatedBy: "-").first ?? trimmed
    }

    public static func normalizeLocaleId(_ localeId: String) -> String {
        localeId.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }

    public func isLocaleMarkedDeleted(_ localeId: String) -> Bool {
        let norm = Self.normalizeLocaleId(localeId)
        let prefix = Self.normalizeCode(norm)
        return lock.withLock { state in
            state.deletedLocales.contains(norm) || state.deletedLocales.contains(prefix)
        }
    }

    public func isLocaleMarkedInstalled(_ localeId: String) -> Bool {
        let norm = Self.normalizeLocaleId(localeId)
        return lock.withLock { state in
            state.installedLocales.contains(norm)
        }
    }

    public func status(forCode code: String) -> SpeechAssetDownloadStatus {
        let clean = Self.normalizeCode(code)
        guard !clean.isEmpty else { return .unsupported }

        let existing = lock.withLock { $0.statuses[clean] }
        if let existing = existing {
            if case .downloading = existing {
                return existing
            }
            if existing == .installed && SupportedLanguages.isOnDeviceDownloaded(forCode: clean) {
                return .installed
            }
            if existing == .unsupported {
                if SupportedLanguages.isOnDeviceDownloaded(forCode: clean) {
                    lock.withLock { $0.statuses[clean] = .installed }
                    return .installed
                }
                return .unsupported
            }
            if case .failed = existing {
                if SupportedLanguages.isOnDeviceDownloaded(forCode: clean) {
                    lock.withLock { $0.statuses[clean] = .installed }
                    return .installed
                }
                return existing
            }
        }

        if SupportedLanguages.isOnDeviceDownloaded(forCode: clean) {
            lock.withLock { $0.statuses[clean] = .installed }
            return .installed
        }
        return .notInstalled
    }

    public func isDownloading(forCode code: String) -> Bool {
        let clean = Self.normalizeCode(code)
        return lock.withLock {
            if case .downloading = $0.statuses[clean] { return true }
            return false
        }
    }

    public func progressPercent(forCode code: String) -> Int {
        let clean = Self.normalizeCode(code)
        return lock.withLock { state in
            if case .downloading(let progress) = state.statuses[clean] {
                let clamped = min(1.0, max(0.0, progress.isFinite ? progress : 0.0))
                return Int(round(clamped * 100.0))
            }
            if state.statuses[clean] == .installed {
                return 100
            }
            return 0
        }
    }

    #if CALLCAPTION_TESTING
    public func _setStatusForTesting(_ status: SpeechAssetDownloadStatus, forCode code: String) {
        let clean = Self.normalizeCode(code)
        lock.withLock { $0.statuses[clean] = status }
    }

    public func _resetStateForTesting() {
        let tasks = lock.withLock { state -> [Task<Bool, Never>] in
            let all = state.activeTasks.values.map(\.task)
            state.activeTasks.removeAll()
            state.statuses.removeAll()
            state.completions.removeAll()
            state.lastNotifiedPercent.removeAll()
            state.deletedLocales.removeAll()
            state.installedLocales.removeAll()
            return all
        }
        for t in tasks {
            t.cancel()
        }
    }
    #endif

    public func ensureActiveLanguagesDownloaded(force: Bool = false) {
        let settings = AppSettings.shared
        let foreignCode = settings.foreignLanguageCode
        let mainCode = settings.mainLanguageCode
        if force || !isLocaleMarkedDeleted(foreignCode) {
            ensureDownloaded(forCode: foreignCode, preferredLocaleId: settings.preferredSpeechLocale(forCode: foreignCode), force: force)
        }
        if Self.normalizeCode(mainCode) != Self.normalizeCode(foreignCode) {
            if force || !isLocaleMarkedDeleted(mainCode) {
                ensureDownloaded(forCode: mainCode, preferredLocaleId: settings.preferredSpeechLocale(forCode: mainCode), force: force)
            }
        }
    }

    public static func resolveTargetLocaleId(
        forCode code: String,
        preferredLocaleId: String? = nil,
        savedPreferredLocaleId: String? = nil,
        systemPreferredLocales: [String]? = nil
    ) -> String {
        let clean = normalizeCode(code)
        if let preferredLocaleId = preferredLocaleId, !preferredLocaleId.isEmpty {
            return preferredLocaleId
        }
        if let savedPreferredLocaleId = savedPreferredLocaleId, !savedPreferredLocaleId.isEmpty {
            return savedPreferredLocaleId
        }
        let sysPrefs = systemPreferredLocales ?? SupportedLanguages.systemPreferredDictationLocales(forPrefix: clean)
        if let firstPref = sysPrefs.first, !firstPref.isEmpty {
            return firstPref
        }
        return SupportedLanguages.item(forCode: clean)?.speechLocale ?? clean
    }

    public func ensureDownloaded(
        forCode code: String,
        preferredLocaleId: String? = nil,
        force: Bool = false,
        completion: (@Sendable @MainActor (Bool) -> Void)? = nil
    ) {
        let clean = Self.normalizeCode(code)
        guard !clean.isEmpty else {
            if let completion = completion {
                Task { @MainActor in completion(false) }
            }
            return
        }

        let explicitPreferred = (preferredLocaleId?.isEmpty == false) ? preferredLocaleId : nil
        let targetLocaleId = Self.resolveTargetLocaleId(
            forCode: clean,
            preferredLocaleId: explicitPreferred,
            savedPreferredLocaleId: AppSettings.shared.preferredSpeechLocale(forCode: clean)
        )
        let normTargetLocale = Self.normalizeLocaleId(targetLocaleId)

        lock.withLock { state in
            state.deletedLocales.remove(clean)
            state.deletedLocales.remove(normTargetLocale)
            if let backing = SupportedLanguages.dictationBackingLocaleId(for: normTargetLocale) {
                state.deletedLocales.remove(Self.normalizeLocaleId(backing))
            }
        }

        if force {
            SupportedLanguages.invalidateCache(forCode: clean)
        }

        let alreadyInstalled = !force && SupportedLanguages.isLocaleDownloaded(targetLocaleId)
        if alreadyInstalled {
            let (changed, cancelledTask, drainedCompletions) = lock.withLock { state -> (Bool, Task<Bool, Never>?, [@Sendable @MainActor (Bool) -> Void]) in
                let prev = state.statuses[clean]
                let oldTask = state.activeTasks.removeValue(forKey: clean)?.task
                let pendingCallbacks = state.completions.removeValue(forKey: clean) ?? []
                state.statuses[clean] = .installed
                state.installedLocales.insert(normTargetLocale)
                state.lastNotifiedPercent.removeValue(forKey: clean)
                return (prev != .installed, oldTask, pendingCallbacks)
            }
            cancelledTask?.cancel()
            if let explicitPreferred = explicitPreferred {
                AppSettings.shared.setPreferredSpeechLocale(explicitPreferred, forCode: clean)
            }
            if changed {
                postStateChanged(forCode: clean)
            }
            if !drainedCompletions.isEmpty || completion != nil {
                Task { @MainActor in
                    for cb in drainedCompletions {
                        cb(true)
                    }
                    completion?(true)
                }
            }
            return
        }

        let (startedNew, supersededTask) = lock.withLock { state -> (Bool, Task<Bool, Never>?) in
            if let completion = completion {
                state.completions[clean, default: []].append(completion)
            }
            var oldTask: Task<Bool, Never>?
            if let existing = state.activeTasks[clean] {
                if existing.localeId == normTargetLocale {
                    return (false, nil)
                }
                oldTask = existing.task
                state.activeTasks.removeValue(forKey: clean)
            }
            let taskToken = UUID()
            state.statuses[clean] = .downloading(progress: 0.0)
            state.lastNotifiedPercent[clean] = -1
            let task = Task<Bool, Never> { [weak self] in
                guard let self = self else { return false }
                return await self.performDownloadAndInstall(
                    forCode: clean,
                    requestedLocaleId: targetLocaleId,
                    taskToken: taskToken
                )
            }
            state.activeTasks[clean] = ActiveTaskEntry(token: taskToken, task: task, localeId: normTargetLocale)
            return (true, oldTask)
        }

        supersededTask?.cancel()

        // Publish preferred locale change AFTER statuses[clean] is atomically .downloading so
        // AppSettings observers immediately see the in-progress download state.
        if let explicitPreferred = explicitPreferred {
            AppSettings.shared.setPreferredSpeechLocale(explicitPreferred, forCode: clean)
        }

        guard startedNew else { return }
        postStateChanged(forCode: clean)
    }

    public func deleteDownloadedAsset(
        forCode code: String,
        localeId: String? = nil,
        completion: (@Sendable @MainActor (Bool) -> Void)? = nil
    ) {
        let clean = Self.normalizeCode(code)
        guard !clean.isEmpty else {
            if let completion = completion {
                Task { @MainActor in completion(false) }
            }
            return
        }

        let (cancelledTask, drainedCompletions) = lock.withLock { state -> (Task<Bool, Never>?, [@Sendable @MainActor (Bool) -> Void]) in
            let oldTask = state.activeTasks.removeValue(forKey: clean)?.task
            let pendingCallbacks = state.completions.removeValue(forKey: clean) ?? []
            if let localeId = localeId, !localeId.isEmpty {
                let norm = Self.normalizeLocaleId(localeId)
                state.deletedLocales.insert(norm)
                state.installedLocales.remove(norm)
            } else {
                state.deletedLocales.insert(clean)
                for v in SupportedLanguages.variants(forCode: clean) {
                    let norm = Self.normalizeLocaleId(v.localeId)
                    state.deletedLocales.insert(norm)
                    state.installedLocales.remove(norm)
                }
            }
            state.statuses[clean] = .notInstalled
            state.lastNotifiedPercent.removeValue(forKey: clean)
            return (oldTask, pendingCallbacks)
        }

        cancelledTask?.cancel()
        if let currentPref = AppSettings.shared.preferredSpeechLocale(forCode: clean) {
            if let localeId = localeId, !localeId.isEmpty {
                if Self.normalizeLocaleId(currentPref) == Self.normalizeLocaleId(localeId) {
                    AppSettings.shared.setPreferredSpeechLocale(nil, forCode: clean)
                }
            } else {
                AppSettings.shared.setPreferredSpeechLocale(nil, forCode: clean)
            }
        }
        if !drainedCompletions.isEmpty {
            Task { @MainActor in
                for cb in drainedCompletions {
                    cb(false)
                }
            }
        }

        SupportedLanguages.invalidateCache(forCode: clean)
        postStateChanged(forCode: clean)

        if AppPaths.isTestEnvironment {
            if let completion = completion {
                Task { @MainActor in completion(true) }
            }
            return
        }

        let explicitTargetLocaleStr = (localeId?.isEmpty == false) ? localeId : nil
        Task { [weak self] in
            guard let self = self else { return }
            var releasedAny = false
            let allSupported = Array(await DictationTranscriber.supportedLocales)
            if let targetLocaleStr = explicitTargetLocaleStr {
                let loc = Locale(identifier: targetLocaleStr.replacingOccurrences(of: "-", with: "_"))
                if let equiv = Self.resolveDictationTranscriberLocale(
                    for: loc,
                    cleanCode: clean,
                    supportedLocales: allSupported
                ) {
                    if await AssetInventory.release(reservedLocale: equiv) {
                        releasedAny = true
                    }
                }
                if await AssetInventory.release(reservedLocale: loc) {
                    releasedAny = true
                }
            }
            let targetBackingNorm = explicitTargetLocaleStr.flatMap {
                SupportedLanguages.dictationBackingLocaleId(for: $0).map(Self.normalizeLocaleId)
            }
            let reserved = await AssetInventory.reservedLocales
            for loc in reserved {
                let norm = Self.normalizeLocaleId(loc.identifier)
                let shouldRelease: Bool
                if let targetLocaleStr = explicitTargetLocaleStr {
                    let targetNorm = Self.normalizeLocaleId(targetLocaleStr)
                    shouldRelease = (norm == targetNorm) || (targetBackingNorm != nil && norm == targetBackingNorm)
                } else {
                    shouldRelease = (Self.normalizeCode(norm) == clean)
                }
                if shouldRelease {
                    if await AssetInventory.release(reservedLocale: loc) {
                        releasedAny = true
                    }
                }
            }
            AppLog.speech.info("[SpeechAssetDownloader] Deleted/released dictation model for '\(clean, privacy: .public)' (locale: \(explicitTargetLocaleStr ?? "all", privacy: .public), releasedFromInventory: \(releasedAny))")
            SupportedLanguages.invalidateCache(forCode: clean)
            self.postStateChanged(forCode: clean)
            if let completion = completion {
                await MainActor.run {
                    completion(true)
                }
            }
        }
    }

    #if CALLCAPTION_TESTING
    public func setStatusForTesting(_ status: SpeechAssetDownloadStatus, forCode code: String) {
        let clean = Self.normalizeCode(code)
        lock.withLock { state in
            state.statuses[clean] = status
        }
        postStateChanged(forCode: clean)
        if status == .installed {
            postDownloadFinished(forCode: clean)
        }
    }

    public func resetForTesting() {
        let tasks = lock.withLock { state -> [Task<Bool, Never>] in
            let all = state.activeTasks.values.map(\.task)
            state.activeTasks.removeAll()
            state.statuses.removeAll()
            state.completions.removeAll()
            state.lastNotifiedPercent.removeAll()
            state.deletedLocales.removeAll()
            state.installedLocales.removeAll()
            return all
        }
        for t in tasks {
            t.cancel()
        }
    }
    #endif

    private func updateProgress(forCode clean: String, token: UUID, fraction: Double) {
        let clamped = min(0.99, max(0.0, fraction.isFinite ? fraction : 0.0))
        let pct = Int(round(clamped * 100.0))
        let shouldNotify = lock.withLock { state -> Bool in
            guard state.activeTasks[clean]?.token == token else { return false }
            guard case .downloading = state.statuses[clean] else { return false }
            state.statuses[clean] = .downloading(progress: clamped)
            let lastPct = state.lastNotifiedPercent[clean] ?? -1
            if pct != lastPct {
                state.lastNotifiedPercent[clean] = pct
                return true
            }
            return false
        }
        if shouldNotify {
            postStateChanged(forCode: clean)
        }
    }

    /// Deterministically resolves the `DictationTranscriber` / `AssetInventory` locale for a
    /// requested speech locale from the OS's supported set. Avoids Apple's non-deterministic
    /// `DictationTranscriber.supportedLocale(equivalentTo:)` when a regional dialect (e.g. `es-CO`)
    /// maps to a shared backing asset (`es-US`).
    public static func resolveDictationTranscriberLocale(
        for requestedLocale: Locale,
        cleanCode: String,
        supportedLocales: [Locale],
        preferredSystemLocales: [String]? = nil
    ) -> Locale? {
        let sorted = supportedLocales.sorted {
            normalizeLocaleId($0.identifier) < normalizeLocaleId($1.identifier)
        }
        guard !sorted.isEmpty else { return nil }

        var byNorm: [String: Locale] = [:]
        byNorm.reserveCapacity(sorted.count)
        for loc in sorted {
            let norm = normalizeLocaleId(loc.identifier)
            if byNorm[norm] == nil {
                byNorm[norm] = loc
            }
        }

        let reqNorm = normalizeLocaleId(requestedLocale.identifier)
        if let exact = byNorm[reqNorm] {
            return exact
        }

        if let backingId = SupportedLanguages.dictationBackingLocaleId(for: reqNorm),
           let backed = byNorm[normalizeLocaleId(backingId)] {
            return backed
        }

        let sysPrefs = preferredSystemLocales ?? SupportedLanguages.systemPreferredDictationLocales(forPrefix: cleanCode)
        for pref in sysPrefs {
            let prefNorm = normalizeLocaleId(pref)
            if let match = byNorm[prefNorm] {
                return match
            }
            if let backingId = SupportedLanguages.dictationBackingLocaleId(for: prefNorm),
               let backed = byNorm[normalizeLocaleId(backingId)] {
                return backed
            }
        }

        if let item = SupportedLanguages.item(forCode: cleanCode) {
            let itemNorm = normalizeLocaleId(item.speechLocale)
            if let match = byNorm[itemNorm] {
                return match
            }
            if let backingId = SupportedLanguages.dictationBackingLocaleId(for: itemNorm),
               let backed = byNorm[normalizeLocaleId(backingId)] {
                return backed
            }
        }

        if let exactLang = byNorm[cleanCode] {
            return exactLang
        }

        return sorted.first { loc in
            normalizeCode(loc.identifier) == cleanCode
        }
    }

    private func performDownloadAndInstall(
        forCode clean: String,
        requestedLocaleId: String?,
        taskToken: UUID
    ) async -> Bool {
        if Task.isCancelled {
            cleanupCancelledTask(forCode: clean, token: taskToken)
            return false
        }

        if AppPaths.isTestEnvironment {
            let installed = SupportedLanguages.isOnDeviceDownloaded(forCode: clean)
            finishTask(forCode: clean, token: taskToken, status: installed ? .installed : .notInstalled, succeeded: installed)
            return installed
        }

        let langName = SupportedLanguages.item(forCode: clean)?.name ?? clean
        let bestLoc: Locale
        if let requestedLocaleId = requestedLocaleId, !requestedLocaleId.isEmpty {
            bestLoc = Locale(identifier: requestedLocaleId.replacingOccurrences(of: "_", with: "-"))
        } else {
            bestLoc = SupportedLanguages.bestLocale(forCode: clean)
        }

        let allSupported = await DictationTranscriber.supportedLocales
        var targetEquiv = Self.resolveDictationTranscriberLocale(
            for: bestLoc,
            cleanCode: clean,
            supportedLocales: Array(allSupported)
        )
        if targetEquiv == nil {
            targetEquiv = await DictationTranscriber.supportedLocale(equivalentTo: bestLoc)
        }

        guard let equivLocale = targetEquiv else {
            AppLog.speech.error("[SpeechAssetDownloader] No supported DictationTranscriber locale for '\(clean, privacy: .public)'")
            finishTask(forCode: clean, token: taskToken, status: .unsupported, succeeded: false)
            return false
        }

        AppLog.speech.info("[SpeechAssetDownloader] Ensuring dictation model for '\(langName, privacy: .public)' (requested: \(bestLoc.identifier, privacy: .public), assetLocale: \(equivLocale.identifier, privacy: .public))")

        await reserveAssetSlotIfNeeded(for: equivLocale, cleanCode: clean)
        if Task.isCancelled {
            cleanupCancelledTask(forCode: clean, token: taskToken)
            return false
        }

        let transcriber = DictationTranscriber(locale: equivLocale, preset: .progressiveLongDictation)
        let obsBox = ObservationBox()

        do {
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                AppLog.speech.info("[SpeechAssetDownloader] Starting macOS asset installation for '\(equivLocale.identifier, privacy: .public)'")
                obsBox.observation = req.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] progress, _ in
                    self?.updateProgress(forCode: clean, token: taskToken, fraction: progress.fractionCompleted)
                }
                try await req.downloadAndInstall()
                obsBox.observation?.invalidate()
                obsBox.observation = nil
                AppLog.speech.info("[SpeechAssetDownloader] Completed macOS asset installation for '\(equivLocale.identifier, privacy: .public)'")
            } else {
                AppLog.speech.info("[SpeechAssetDownloader] AssetInventory reports '\(equivLocale.identifier, privacy: .public)' is already installed")
            }
        } catch is CancellationError {
            obsBox.observation?.invalidate()
            cleanupCancelledTask(forCode: clean, token: taskToken)
            return false
        } catch {
            obsBox.observation?.invalidate()
            if Task.isCancelled {
                cleanupCancelledTask(forCode: clean, token: taskToken)
                return false
            }
            AppLog.speech.error("[SpeechAssetDownloader] Download failed for '\(equivLocale.identifier, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            finishTask(forCode: clean, token: taskToken, status: .failed(message: error.localizedDescription), succeeded: false)
            return false
        }

        if Task.isCancelled {
            cleanupCancelledTask(forCode: clean, token: taskToken)
            return false
        }

        _ = try? await AssetInventory.reserve(locale: equivLocale)
        await warmUpSpeechRecognizer(locale: equivLocale)
        if Self.normalizeLocaleId(bestLoc.identifier) != Self.normalizeLocaleId(equivLocale.identifier) {
            await warmUpSpeechRecognizer(locale: bestLoc)
        }

        var verified = false
        for _ in 0..<8 {
            if Task.isCancelled {
                cleanupCancelledTask(forCode: clean, token: taskToken)
                return false
            }
            let supportsEquiv = SFSpeechRecognizer(locale: equivLocale)?.supportsOnDeviceRecognition ?? false
            let supportsBest = SFSpeechRecognizer(locale: bestLoc)?.supportsOnDeviceRecognition ?? false
            if supportsEquiv || supportsBest {
                verified = true
                break
            }
            let installedLocales = await DictationTranscriber.installedLocales
            let equivNorm = Self.normalizeLocaleId(equivLocale.identifier)
            let isInDictationInstalled = installedLocales.contains { loc in
                Self.normalizeLocaleId(loc.identifier) == equivNorm
            }
            if isInDictationInstalled {
                await warmUpSpeechRecognizer(locale: equivLocale)
                if SFSpeechRecognizer(locale: equivLocale)?.supportsOnDeviceRecognition == true ||
                    SFSpeechRecognizer(locale: bestLoc)?.supportsOnDeviceRecognition == true {
                    verified = true
                    break
                }
            }
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                cleanupCancelledTask(forCode: clean, token: taskToken)
                return false
            }
        }

        let stillOwned = lock.withLock { $0.activeTasks[clean]?.token == taskToken }
        guard stillOwned else {
            return false
        }

        if verified {
            let bestNorm = Self.normalizeLocaleId(bestLoc.identifier)
            let equivNorm = Self.normalizeLocaleId(equivLocale.identifier)
            lock.withLock { state in
                guard state.activeTasks[clean]?.token == taskToken else { return }
                state.installedLocales.insert(bestNorm)
                state.installedLocales.insert(equivNorm)
            }
            SupportedLanguages.invalidateCache(forCode: clean)
            AppLog.speech.info("[SpeechAssetDownloader] Dictation model ready for '\(langName, privacy: .public)'")
            finishTask(forCode: clean, token: taskToken, status: .installed, succeeded: true)
            return true
        } else {
            SupportedLanguages.invalidateCache(forCode: clean)
            AppLog.speech.warning("[SpeechAssetDownloader] Model for '\(langName, privacy: .public)' still awaiting SFSpeechRecognizer activation")
            finishTask(forCode: clean, token: taskToken, status: .failed(message: "Model awaiting macOS activation"), succeeded: false)
            return false
        }
    }

    private func cleanupCancelledTask(forCode clean: String, token: UUID) {
        let (didClean, callbacks) = lock.withLock { state -> (Bool, [@Sendable @MainActor (Bool) -> Void]) in
            guard state.activeTasks[clean]?.token == token else {
                return (false, [])
            }
            state.activeTasks.removeValue(forKey: clean)
            if case .downloading = state.statuses[clean] {
                state.statuses[clean] = .notInstalled
            }
            state.lastNotifiedPercent.removeValue(forKey: clean)
            let pending = state.completions.removeValue(forKey: clean) ?? []
            return (true, pending)
        }
        guard didClean else { return }
        postStateChanged(forCode: clean)
        if !callbacks.isEmpty {
            Task { @MainActor in
                for cb in callbacks {
                    cb(false)
                }
            }
        }
    }

    private func reserveAssetSlotIfNeeded(for equivLocale: Locale, cleanCode: String) async {
        var reserved = await AssetInventory.reservedLocales
        let targetNorm = Self.normalizeLocaleId(equivLocale.identifier)

        // Release any stale sibling dialect reservations for this same language so macOS
        // does not keep or re-download unwanted dialects alongside the selected one.
        var releasedSibling = false
        for oldLoc in reserved {
            let norm = Self.normalizeLocaleId(oldLoc.identifier)
            if Self.normalizeCode(norm) == cleanCode && norm != targetNorm {
                _ = await AssetInventory.release(reservedLocale: oldLoc)
                releasedSibling = true
            }
        }
        if releasedSibling {
            reserved = await AssetInventory.reservedLocales
        }

        if reserved.contains(where: { Self.normalizeLocaleId($0.identifier) == targetNorm }) {
            return
        }
        let maxSlots = AssetInventory.maximumReservedLocales
        if reserved.count >= maxSlots {
            let activeForeign = Self.normalizeCode(AppSettings.shared.foreignLanguageCode)
            let activeMain = Self.normalizeCode(AppSettings.shared.mainLanguageCode)
            let protectedPrefixes: Set<String> = [cleanCode, activeForeign, activeMain]
            for oldLoc in reserved {
                let prefix = Self.normalizeCode(oldLoc.identifier)
                if !protectedPrefixes.contains(prefix) {
                    _ = await AssetInventory.release(reservedLocale: oldLoc)
                    break
                }
            }
        }
        _ = try? await AssetInventory.reserve(locale: equivLocale)
    }

    private func warmUpSpeechRecognizer(locale: Locale) async {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return }
        guard let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = false
        req.taskHint = .dictation
        req.requiresOnDeviceRecognition = true
        if let fmt = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
           let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 160) {
            buf.frameLength = 160
            req.append(buf)
        }
        req.endAudio()
        let task = rec.recognitionTask(with: req) { _, _ in }
        try? await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
    }

    private func finishTask(forCode clean: String, token: UUID, status: SpeechAssetDownloadStatus, succeeded: Bool) {
        let (owned, callbacks) = lock.withLock { state -> (Bool, [@Sendable @MainActor (Bool) -> Void]) in
            guard state.activeTasks[clean]?.token == token else {
                return (false, [])
            }
            state.activeTasks.removeValue(forKey: clean)
            state.statuses[clean] = status
            state.lastNotifiedPercent.removeValue(forKey: clean)
            let list = state.completions.removeValue(forKey: clean) ?? []
            return (true, list)
        }
        guard owned else { return }
        postStateChanged(forCode: clean)
        if succeeded {
            postDownloadFinished(forCode: clean)
        }
        if !callbacks.isEmpty {
            Task { @MainActor in
                for cb in callbacks {
                    cb(succeeded)
                }
            }
        }
    }

    private func postStateChanged(forCode clean: String) {
        let info: [String: String] = ["languageCode": clean]
        if Thread.isMainThread {
            NotificationCenter.default.post(name: Self.stateDidChangeNotification, object: self, userInfo: info)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.stateDidChangeNotification, object: self, userInfo: info)
            }
        }
    }

    private func postDownloadFinished(forCode clean: String) {
        let info: [String: String] = ["languageCode": clean]
        if Thread.isMainThread {
            NotificationCenter.default.post(name: Self.didFinishDownloadNotification, object: self, userInfo: info)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.didFinishDownloadNotification, object: self, userInfo: info)
            }
        }
    }
}
