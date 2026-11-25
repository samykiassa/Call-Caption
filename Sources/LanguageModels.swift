import Foundation
import AppKit
import AVFoundation
@preconcurrency import Speech
import os

enum AppL10n {
    private struct EffectiveLocaleCache: Sendable {
        var bundlePath: String = ""
        var locale: Locale?
        var generation: UInt64 = 0
    }

    private static let effectiveLocaleLock = OSAllocatedUnfairLock(initialState: EffectiveLocaleCache())

    private static let localeChangeObserverInstalled: Bool = {
        _ = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            invalidateEffectiveLocaleCache()
        }
        return true
    }()

    private static func invalidateEffectiveLocaleCache() {
        effectiveLocaleLock.withLock {
            $0.bundlePath = ""
            $0.locale = nil
            $0.generation &+= 1
        }
    }

    #if CALLCAPTION_TESTING
    private static let testBundleLock = OSAllocatedUnfairLock<Bundle?>(initialState: nil)

    static func setTestingBundle(_ bundle: Bundle?) {
        testBundleLock.withLock { $0 = bundle }
        invalidateEffectiveLocaleCache()
    }
    #endif

    static var resourceBundle: Bundle {
        #if CALLCAPTION_TESTING
        if let override = testBundleLock.withLock({ $0 }) {
            return override
        }
        if let envPath = ProcessInfo.processInfo.environment["CALLCAPTION_RESOURCE_BUNDLE"],
           !envPath.isEmpty,
           let bundle = Bundle(path: envPath) {
            return bundle
        }
        #endif
        return .main
    }

    static var effectiveUILocale: Locale {
        _ = localeChangeObserverInstalled
        let bundle = resourceBundle
        let bundlePath = bundle.bundlePath
        let (cachedLocale, capturedGen): (Locale?, UInt64) = effectiveLocaleLock.withLock { cache in
            if cache.bundlePath == bundlePath, let cached = cache.locale {
                return (cached, cache.generation)
            }
            return (nil, cache.generation)
        }
        if let cachedLocale {
            return cachedLocale
        }

        let resolved: Locale
        if bundle.bundleURL.pathExtension == "lproj" {
            let lang = bundle.bundleURL.deletingPathExtension().lastPathComponent
            if !lang.isEmpty {
                resolved = Locale(identifier: lang)
            } else if let loc = bundle.preferredLocalizations.first, !loc.isEmpty {
                resolved = Locale(identifier: loc)
            } else if let loc = Bundle.main.preferredLocalizations.first, !loc.isEmpty {
                resolved = Locale(identifier: loc)
            } else {
                resolved = Locale.current
            }
        } else if let loc = bundle.preferredLocalizations.first, !loc.isEmpty {
            resolved = Locale(identifier: loc)
        } else if let loc = Bundle.main.preferredLocalizations.first, !loc.isEmpty {
            resolved = Locale(identifier: loc)
        } else {
            resolved = Locale.current
        }

        effectiveLocaleLock.withLock { cache in
            if cache.generation == capturedGen {
                cache.bundlePath = bundlePath
                cache.locale = resolved
            }
        }
        return resolved
    }

    static func string(_ key: String, fallback: String) -> String {
        resourceBundle.localizedString(forKey: key, value: fallback, table: nil)
    }

    static func format(_ key: String, fallback: String, _ args: CVarArg...) -> String {
        let template = string(key, fallback: fallback)
        return String(format: template, locale: effectiveUILocale, arguments: args)
    }

    static func plural(_ key: String, fallbackSingular: String, fallbackPlural: String, count: Int) -> String {
        let sentinel = "__CALL_CAPTION_MISSING_PLURAL__"
        let localizedTemplate = resourceBundle.localizedString(forKey: key, value: sentinel, table: nil)
        let template = localizedTemplate == sentinel
            ? (count == 1 ? fallbackSingular : fallbackPlural)
            : localizedTemplate
        return String(format: template, locale: effectiveUILocale, count)
    }
}

enum AppLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.callcaption.app"
    static let app = Logger(subsystem: subsystem, category: "App")
    static let audio = Logger(subsystem: subsystem, category: "AudioCapture")
    static let speech = Logger(subsystem: subsystem, category: "SpeechRecognition")
    static let translation = Logger(subsystem: subsystem, category: "Translation")
    static let liveShare = Logger(subsystem: subsystem, category: "LiveShare")
    static let coordinator = Logger(subsystem: subsystem, category: "Coordinator")
}

struct LanguageItem: Identifiable, Hashable, Sendable {
    let id: String
    let code: String
    let speechLocale: String
    let name: String
    let flag: String

    var localizedName: String {
        SupportedLanguages.cachedLocalizedName(for: self)
    }

    var localizedPickerName: String {
        SupportedLanguages.cachedPickerName(for: self)
    }

    fileprivate func computeLocalizedName(in uiLocale: Locale) -> String {
        uiLocale.localizedString(forLanguageCode: code)?.localizedCapitalized ?? name
    }

    fileprivate func computeLocalizedPickerName(in uiLocale: Locale) -> String {
        let localized = computeLocalizedName(in: uiLocale)
        let nativeLocale = Locale(identifier: code)
        let native = nativeLocale.localizedString(forLanguageCode: code)?.capitalized(with: nativeLocale)
        if let native, !native.isEmpty, native.caseInsensitiveCompare(localized) != .orderedSame {
            return "\(localized) (\(native))"
        }
        return localized
    }
}

enum SupportedLanguages {
    static let all: [LanguageItem] = [
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

    static let rtlLanguageCodes: Set<String> = ["ar", "he", "fa", "ur"]

    private struct LocalizedLanguageCache: Sendable {
        var localeIdentifier: String = ""
        var localizedNamesByCode: [String: String] = [:]
        var pickerNamesByCode: [String: String] = [:]
        var canonicalNamesByCode: [String: String] = [:]
        var sortedItems: [LanguageItem] = []
    }

    private static let localizedCacheLock = OSAllocatedUnfairLock(initialState: LocalizedLanguageCache())

    private static func ensureLocalizedCacheLocked(_ cache: inout LocalizedLanguageCache, uiLocale: Locale, localeId: String) {
        if cache.localeIdentifier == localeId && !cache.sortedItems.isEmpty {
            return
        }
        var locNames: [String: String] = [:]
        var pickerNames: [String: String] = [:]
        var canonNames: [String: String] = [:]
        locNames.reserveCapacity(all.count)
        pickerNames.reserveCapacity(all.count)
        canonNames.reserveCapacity(all.count)
        for item in all {
            locNames[item.code] = item.computeLocalizedName(in: uiLocale)
            pickerNames[item.code] = item.computeLocalizedPickerName(in: uiLocale)
            canonNames[item.code] = item.name
        }
        let sorted = all.sorted { lhs, rhs in
            let lhsName = locNames[lhs.code] ?? lhs.name
            let rhsName = locNames[rhs.code] ?? rhs.name
            let order = lhsName.localizedStandardCompare(rhsName)
            if order != .orderedSame {
                return order == .orderedAscending
            }
            return lhs.code < rhs.code
        }
        cache = LocalizedLanguageCache(
            localeIdentifier: localeId,
            localizedNamesByCode: locNames,
            pickerNamesByCode: pickerNames,
            canonicalNamesByCode: canonNames,
            sortedItems: sorted
        )
    }

    fileprivate static func cachedLocalizedName(for item: LanguageItem) -> String {
        let uiLocale = AppL10n.effectiveUILocale
        let localeId = uiLocale.identifier
        if let cached = localizedCacheLock.withLock({ cache -> String? in
            ensureLocalizedCacheLocked(&cache, uiLocale: uiLocale, localeId: localeId)
            guard cache.canonicalNamesByCode[item.code] == item.name else { return nil }
            return cache.localizedNamesByCode[item.code]
        }) {
            return cached
        }
        return item.computeLocalizedName(in: uiLocale)
    }

    fileprivate static func cachedPickerName(for item: LanguageItem) -> String {
        let uiLocale = AppL10n.effectiveUILocale
        let localeId = uiLocale.identifier
        if let cached = localizedCacheLock.withLock({ cache -> String? in
            ensureLocalizedCacheLocked(&cache, uiLocale: uiLocale, localeId: localeId)
            guard cache.canonicalNamesByCode[item.code] == item.name else { return nil }
            return cache.pickerNamesByCode[item.code]
        }) {
            return cached
        }
        return item.computeLocalizedPickerName(in: uiLocale)
    }

    static var sortedByLocalizedName: [LanguageItem] {
        let uiLocale = AppL10n.effectiveUILocale
        let localeId = uiLocale.identifier
        return localizedCacheLock.withLock { cache in
            ensureLocalizedCacheLocked(&cache, uiLocale: uiLocale, localeId: localeId)
            return cache.sortedItems
        }
    }

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

    private struct CachedLocaleResolution: Sendable {
        let locale: Locale
        let timestamp: TimeInterval
        let ttl: TimeInterval
    }

    private static let localeCacheLock = OSAllocatedUnfairLock(initialState: [String: CachedLocaleResolution]())
    private static let localeCacheTTL: TimeInterval = 5.0
    private static let healthyLocaleCacheTTL: TimeInterval = 300.0

    static func invalidateLocaleResolutionCache() {
        localeCacheLock.withLock { $0.removeAll() }
    }

    static func item(forCode code: String) -> LanguageItem? {
        let norm = code.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        guard !norm.isEmpty else { return nil }
        if let exact = byCode[norm] { return exact }
        let base = baseCode(from: norm)
        return byCode[base]
    }

    static func baseCode(from identifier: String) -> String {
        let norm = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        let prefix = norm.split(separator: "-").first.map(String.init) ?? norm
        return prefix.isEmpty ? "en" : prefix
    }

    static func translationCode(from identifier: String) -> String {
        let clean = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        if let script = chineseScriptKind(forNormalizedCode: clean) {
            return script == "hant" ? "zh-hant" : "zh-hans"
        }
        if clean == "zh" || clean.hasPrefix("zh-") {
            return "zh-hans"
        }
        return baseCode(from: clean)
    }

    static func isRTL(languageCode: String) -> Bool {
        rtlLanguageCodes.contains(baseCode(from: languageCode))
    }

    static func bestLocale(forCode code: String) -> Locale {
        let norm = code.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        let cacheKey = norm.isEmpty ? "en" : norm
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = localeCacheLock.withLock({ state -> Locale? in
            guard let entry = state[cacheKey], (now - entry.timestamp) < entry.ttl else {
                return nil
            }
            return entry.locale
        }) {
            return cached
        }

        let resolution = resolveBestLocale(forNormalizedCode: norm)
        let ttl = resolution.isHealthy ? healthyLocaleCacheTTL : localeCacheTTL
        localeCacheLock.withLock { state in
            state[cacheKey] = CachedLocaleResolution(locale: resolution.locale, timestamp: now, ttl: ttl)
        }
        return resolution.locale
    }

    private static func resolveBestLocale(forNormalizedCode norm: String) -> (locale: Locale, isHealthy: Bool) {
        let base = baseCode(from: norm)
        let matchedItem = byCode[norm] ?? byCode[base]
        let defaultId = matchedItem?.speechLocale ?? (norm.isEmpty ? "en-US" : norm)

        let candidates = candidateLocales(
            forNormalizedCode: norm,
            base: matchedItem?.code ?? base,
            defaultLocaleId: defaultId,
            preferredLanguages: Locale.preferredLanguages,
            currentRegion: Locale.current.region?.identifier
        )

        var foundHealthy = false
        if let selected = selectBestLocale(
            candidates: candidates,
            evaluator: { locale in
                guard let recognizer = SFSpeechRecognizer(locale: locale) else {
                    return (supported: false, onDevice: false, available: false)
                }
                let onDevice = recognizer.supportsOnDeviceRecognition
                let available = recognizer.isAvailable
                if onDevice && available {
                    foundHealthy = true
                }
                return (supported: true, onDevice: onDevice, available: available)
            }
        ) {
            return (selected, foundHealthy)
        }

        return (Locale(identifier: defaultId), false)
    }

    static func candidateLocales(
        forCode code: String,
        preferredLanguages: [String] = Locale.preferredLanguages,
        currentLocale: Locale = .current,
        availableLocales: [Locale]? = nil
    ) -> [Locale] {
        let norm = code.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        let base = baseCode(from: norm)
        let matchedItem = byCode[norm] ?? byCode[base]
        let defaultId = matchedItem?.speechLocale ?? (norm.isEmpty ? "en-US" : norm)
        let localeMap: [String: Locale]? = availableLocales.map { list in
            var map: [String: Locale] = [:]
            for loc in list {
                let key = loc.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
                map[key] = loc
            }
            return map
        }
        return candidateLocales(
            forNormalizedCode: norm,
            base: matchedItem?.code ?? base,
            defaultLocaleId: defaultId,
            preferredLanguages: preferredLanguages,
            currentRegion: currentLocale.region?.identifier,
            availableLocaleMap: localeMap
        )
    }

    static func candidateLocales(
        forCode code: String,
        preferredLanguages: [String],
        currentRegion: String?,
        availableLocaleMap: [String: Locale]? = nil
    ) -> [Locale] {
        let norm = code.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        let base = baseCode(from: norm)
        let matchedItem = byCode[norm] ?? byCode[base]
        let defaultId = matchedItem?.speechLocale ?? (norm.isEmpty ? "en-US" : norm)
        return candidateLocales(
            forNormalizedCode: norm,
            base: matchedItem?.code ?? base,
            defaultLocaleId: defaultId,
            preferredLanguages: preferredLanguages,
            currentRegion: currentRegion,
            availableLocaleMap: availableLocaleMap
        )
    }

    static func candidateLocales(
        forNormalizedCode norm: String,
        base: String,
        defaultLocaleId: String,
        preferredLanguages: [String],
        currentRegion: String?,
        availableLocaleMap: [String: Locale]? = nil
    ) -> [Locale] {
        let localeMap = availableLocaleMap ?? supportedLocaleMap
        let requestedScriptTag = chineseScriptKind(forNormalizedCode: norm)

        var ordered: [Locale] = []
        var seen: Set<String> = []

        func appendIfCompatible(_ key: String) {
            let cleanKey = key.replacingOccurrences(of: "_", with: "-").lowercased()
            guard !seen.contains(cleanKey), let loc = localeMap[cleanKey] else { return }
            if base == "zh", let requestedScriptTag,
               let candScript = chineseScriptKind(forNormalizedCode: cleanKey),
               candScript != requestedScriptTag {
                return
            }
            seen.insert(cleanKey)
            ordered.append(loc)
        }

        func appendTagOrChineseMapped(_ rawTag: String) {
            let cleanTag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "_", with: "-")
                .lowercased()
            guard !cleanTag.isEmpty else { return }
            if localeMap[cleanTag] != nil {
                appendIfCompatible(cleanTag)
                return
            }
            if baseCode(from: cleanTag) == "zh" {
                let mappedKeys = expandedChineseLocaleKeys(forNormalizedCode: cleanTag)
                for mapped in mappedKeys {
                    appendIfCompatible(mapped)
                }
                return
            }
            let parts = cleanTag.split(separator: "-").map(String.init)
            if parts.count >= 3, let first = parts.first, let last = parts.last, last.count == 2 {
                appendIfCompatible("\(first)-\(last)")
            }
        }

        // 1. Explicit regional/script locale requested by caller (e.g., "es-CO", "zh-TW", "zh-Hant-TW", "zh-Hant-US", "zh-Hant-HK")
        if norm.contains("-") {
            appendTagOrChineseMapped(norm)
        }

        // 2. User's preferred languages matching the target language (e.g., "es-CO", "zh-Hant-TW" in macOS preferences)
        for pref in preferredLanguages {
            let cleanPref = pref.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "_", with: "-")
                .lowercased()
            if baseCode(from: cleanPref) == base {
                appendTagOrChineseMapped(cleanPref)
            }
        }

        // 3. Current system region combined with target base language (e.g., region "CO" -> "es-co", region "MO" -> "zh-hk", "zh-tw")
        if let region = currentRegion?.trimmingCharacters(in: .whitespacesAndNewlines), !region.isEmpty {
            appendTagOrChineseMapped("\(base)-\(region.lowercased())")
        }

        // 4. Configured default locale for the language (e.g., "en-US", "es-ES")
        appendTagOrChineseMapped(defaultLocaleId)

        // 5. All other supported dialects sharing the same base language, prioritizing country codes before M.49 numeric tags like "es-419"
        let cleanRegion = currentRegion?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefersHKFirst = norm.hasSuffix("-hk") || norm.hasSuffix("-mo") || cleanRegion == "hk" || cleanRegion == "mo"
        let siblingKeys = localeMap.keys
            .filter { $0 == base || $0.hasPrefix(base + "-") }
            .sorted { lhs, rhs in
                let lhsCountry = isLetterRegionVariant(lhs)
                let rhsCountry = isLetterRegionVariant(rhs)
                if lhsCountry != rhsCountry {
                    return lhsCountry && !rhsCountry
                }
                if base == "zh", requestedScriptTag == "hant" {
                    let primaryHant = prefersHKFirst ? "zh-hk" : "zh-tw"
                    let secondaryHant = prefersHKFirst ? "zh-tw" : "zh-hk"
                    if lhs == primaryHant && rhs == secondaryHant { return true }
                    if lhs == secondaryHant && rhs == primaryHant { return false }
                }
                return lhs < rhs
            }
        for key in siblingKeys {
            appendIfCompatible(key)
        }

        return ordered
    }

    private static func expandedChineseLocaleKeys(forNormalizedCode cleanTag: String) -> [String] {
        guard baseCode(from: cleanTag) == "zh" else { return [cleanTag] }
        let subtags = cleanTag.split(separator: "-").dropFirst()
        // Check explicit BCP-47 script subtags before inferring script from region suffixes.
        if subtags.contains("hans") {
            return ["zh-cn"]
        }
        let isHKOrMO = subtags.contains("hk") || subtags.contains("mo")
        if subtags.contains("hant") {
            return isHKOrMO ? ["zh-hk", "zh-tw"] : ["zh-tw", "zh-hk"]
        }
        if isHKOrMO {
            return ["zh-hk", "zh-tw"]
        }
        if subtags.contains("tw") {
            return ["zh-tw", "zh-hk"]
        }
        if subtags.contains("cn") || subtags.contains("sg") {
            return ["zh-cn"]
        }
        return [cleanTag]
    }

    static func selectBestLocale(
        candidates: [Locale],
        evaluator: (Locale) -> (supported: Bool, onDevice: Bool, available: Bool)
    ) -> Locale? {
        var firstOnDeviceFallback: Locale?
        for candidate in candidates {
            let status = evaluator(candidate)
            guard status.supported else { continue }
            if status.onDevice && status.available {
                return candidate
            }
            if status.onDevice && firstOnDeviceFallback == nil {
                firstOnDeviceFallback = candidate
            }
        }
        return firstOnDeviceFallback ?? candidates.first
    }

    private static func isLetterRegionVariant(_ normalizedId: String) -> Bool {
        guard let suffix = normalizedId.split(separator: "-").last else { return false }
        return suffix.count == 2 && suffix.allSatisfy(\.isLetter)
    }

    private static func chineseScriptKind(forNormalizedCode norm: String) -> String? {
        guard baseCode(from: norm) == "zh" else { return nil }
        let subtags = norm.split(separator: "-").dropFirst()
        // Check explicit BCP-47 script subtags before inferring script from region suffixes.
        if subtags.contains("hans") {
            return "hans"
        }
        if subtags.contains("hant") {
            return "hant"
        }
        if subtags.contains("tw") || subtags.contains("hk") || subtags.contains("mo") {
            return "hant"
        }
        if subtags.contains("cn") || subtags.contains("sg") {
            return "hans"
        }
        return nil
    }
}

enum AudioCapturePermissionState: Sendable, Equatable {
    case unknown
    case active
    case deniedSilenceDetected
}

final class PermissionHelper: Sendable {
    static let shared = PermissionHelper()
    static let permissionStateDidChangeNotification = Notification.Name("PermissionHelperStateDidChangeNotification")

    private let stateLock = OSAllocatedUnfairLock(initialState: AudioCapturePermissionState.unknown)

    private init() {}

    var audioCaptureState: AudioCapturePermissionState {
        stateLock.withLock { $0 }
    }

    func updateAudioCaptureState(_ newState: AudioCapturePermissionState) {
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

    var hasMicrophoneAccess: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    var hasSpeechRecognitionAccess: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    func openAudioCaptureSettings() {
        openFirstValidURL([
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ])
    }

    func openMicrophoneSettings() {
        openFirstValidURL([
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ])
    }

    func openSpeechRecognitionSettings() {
        openFirstValidURL([
            "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ])
    }

    func openDictationSettings() {
        openFirstValidURL([
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Dictation",
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.keyboard?Dictation"
        ])
    }

    func openTranslationSettings() {
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
