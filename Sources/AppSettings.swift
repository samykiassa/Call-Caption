import Foundation
import AppKit
import os

public final class AppSettings: @unchecked Sendable {
    public static let shared = AppSettings()
    
    public static let didChangeNotification = Notification.Name("AppSettingsDidChangeNotification")
    
    public static let engineConfigDidChangeNotification = Notification.Name("AppSettingsEngineConfigDidChangeNotification")

    public static let audioGainDidChangeNotification = Notification.Name("AppSettingsAudioGainDidChangeNotification")
    
    private let defaults: UserDefaults
    private let lock = OSAllocatedUnfairLock()
    private let persistenceQueue = DispatchQueue(label: "com.callcaption.settings.persistence", qos: .utility)
    private var _gainPersistScheduled = false
    private var _gainPersistGeneration: UInt64 = 0

    private static func canonicalLanguageCode(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }
        return SupportedLanguages.item(forCode: trimmed)?.code
            ?? trimmed.replacingOccurrences(of: "_", with: "-").lowercased()
    }
    
    private enum Keys {
        static let mainLanguageCode = "cc_main_language_code"
        static let foreignLanguageCode = "cc_foreign_language_code"
        static let targetLanguageCode = "cc_target_language_code"
        static let subtitleFollowsMain = "cc_subtitle_follows_main"
        static let autoPopup = "cc_auto_popup_on_foreign_speech"
        static let autoHideDelay = "cc_auto_hide_delay_seconds"
        static let showOriginal = "cc_show_original_foreign_text"
        static let fontSize = "cc_caption_font_size"
        static let isPinned = "cc_is_pinned"
        static let isMicEnabled = "cc_mic_enabled"
        static let shareBothSpeakers = "cc_share_both_speakers"
        static let allowLANShare = "cc_allow_lan_share"
        static let liveShareUseExternalTunnel = "cc_live_share_external_tunnel"
        static let pauseOnScreenLock = "cc_pause_on_screen_lock"
        static let autosaveTranscripts = "cc_autosave_transcripts"
        static let hasCompletedOnboarding = "cc_has_completed_onboarding"
        static let hasAcceptedLiveShareConsent = "cc_has_accepted_live_share_consent"
        static let hasAcceptedExternalLiveShareConsent = "cc_has_accepted_external_live_share_consent"
        static let callerInputGain = "cc_caller_input_gain"
        static let micInputGain = "cc_mic_input_gain"
        static let autoGainEnabled = "cc_auto_gain_enabled"
        static let preferredSpeechLocales = "cc_preferred_speech_locales_by_lang"
        static let appLanguageCode = "cc_app_language_code"
    }

    public static let supportedAppLanguages: [(code: String, name: String, flag: String)] = [
        ("en", "English", "🇬🇧"),
        ("es", "Español", "🇪🇸")
    ]

    public static let minInputGain: Float = 0.25
    public static let maxInputGain: Float = 8.0

    public static func clampInputGain(_ value: Float) -> Float {
        guard value.isFinite else { return 1.0 }
        return min(maxInputGain, max(minInputGain, value))
    }
    
    private var _cachedMainLanguageCode: String
    private var _cachedForeignLanguageCode: String
    private var _cachedTargetLanguageCode: String
    private var _cachedSubtitleFollowsMain: Bool
    private var _cachedAutoPopup: Bool
    private var _cachedAutoHideDelay: Double
    private var _cachedShowOriginal: Bool
    private var _cachedCaptionFontSize: CGFloat
    private var _cachedIsPinned: Bool
    private var _cachedIsMicEnabled: Bool
    private var _cachedShareBothSpeakers: Bool
    private var _cachedAllowLANShare: Bool
    private var _cachedLiveShareUseExternalTunnel: Bool
    private var _cachedPauseOnScreenLock: Bool
    private var _cachedAutosaveTranscripts: Bool
    private var _cachedHasCompletedOnboarding: Bool
    private var _cachedHasAcceptedLiveShareConsent: Bool
    private var _cachedHasAcceptedExternalLiveShareConsent: Bool
    private var _cachedCallerInputGain: Float
    private var _cachedMicInputGain: Float
    private var _cachedAutoGainEnabled: Bool
    private var _cachedPreferredSpeechLocales: [String: String]
    private var _cachedAppLanguageCode: String
    
    private static func makeDefaults() -> UserDefaults {
        guard AppPaths.isTestEnvironment else { return .standard }
        let suite = ProcessInfo.processInfo.environment["CALLCAPTION_TEST_SUITE"] ?? "com.callcaption.tests"
        guard let testDefaults = UserDefaults(suiteName: suite) else { return .standard }
        testDefaults.removePersistentDomain(forName: suite)
        return testDefaults
    }

    private init() {
        self.defaults = Self.makeDefaults()

        let savedMain = defaults.string(forKey: Keys.mainLanguageCode)
        let savedForeign = defaults.string(forKey: Keys.foreignLanguageCode)
        let savedTarget = defaults.string(forKey: Keys.targetLanguageCode)
        let hasSavedSubtitleFollows = defaults.object(forKey: Keys.subtitleFollowsMain) != nil

        let systemCode = Locale.current.language.languageCode?.identifier ?? "en"
        let defaultMain = SupportedLanguages.item(forCode: systemCode)?.code
            ?? SupportedLanguages.item(forCode: "en")?.code
            ?? "en"
        let defaultForeign = (defaultMain == "en") ? "es" : "en"

        let mainCode = savedMain.map(Self.canonicalLanguageCode) ?? defaultMain
        var foreignCode = savedForeign.map(Self.canonicalLanguageCode) ?? defaultForeign
        if foreignCode == mainCode {
            foreignCode = (mainCode == "en") ? "es" : "en"
        }

        let defaultAppLang: String
        if AppPaths.isTestEnvironment {
            defaultAppLang = "en"
        } else {
            let preferredLang = Locale.preferredLanguages.first?.lowercased() ?? "en"
            defaultAppLang = preferredLang.hasPrefix("es") ? "es" : "en"
        }
        let savedAppLang = defaults.string(forKey: Keys.appLanguageCode)?.lowercased()
        let validAppLangs: Set<String> = ["en", "es"]
        let resolvedAppLang = (savedAppLang.flatMap { validAppLangs.contains($0) ? $0 : nil }) ?? defaultAppLang

        defaults.register(defaults: [
            Keys.mainLanguageCode: defaultMain,
            Keys.foreignLanguageCode: defaultForeign,
            Keys.targetLanguageCode: defaultMain,
            Keys.appLanguageCode: defaultAppLang,
            Keys.subtitleFollowsMain: true,
            Keys.autoPopup: true,
            Keys.autoHideDelay: 8.0,
            Keys.showOriginal: true,
            Keys.fontSize: 16.0,
            Keys.isPinned: false,
            Keys.isMicEnabled: false,
            Keys.shareBothSpeakers: true,
            Keys.allowLANShare: false,
            Keys.liveShareUseExternalTunnel: true,
            Keys.pauseOnScreenLock: true,
            Keys.autosaveTranscripts: false,
            Keys.hasCompletedOnboarding: false,
            Keys.hasAcceptedLiveShareConsent: false,
            Keys.hasAcceptedExternalLiveShareConsent: false,
            Keys.callerInputGain: 1.0,
            Keys.micInputGain: 1.0,
            Keys.autoGainEnabled: true
        ])

        _cachedMainLanguageCode = mainCode
        _cachedForeignLanguageCode = foreignCode
        let targetCode = savedTarget.map(Self.canonicalLanguageCode) ?? mainCode
        _cachedTargetLanguageCode = targetCode
        if hasSavedSubtitleFollows {
            _cachedSubtitleFollowsMain = defaults.bool(forKey: Keys.subtitleFollowsMain)
        } else {
            _cachedSubtitleFollowsMain = (targetCode == mainCode)
        }
        _cachedAutoPopup = defaults.bool(forKey: Keys.autoPopup)
        let rawHideDelay = defaults.double(forKey: Keys.autoHideDelay)
        _cachedAutoHideDelay = (rawHideDelay.isFinite && rawHideDelay >= 0) ? rawHideDelay : 8.0
        _cachedShowOriginal = defaults.bool(forKey: Keys.showOriginal)

        let fs = defaults.double(forKey: Keys.fontSize)
        _cachedCaptionFontSize = (fs.isFinite && fs > 0) ? CGFloat(fs) : 16.0

        _cachedIsPinned = defaults.bool(forKey: Keys.isPinned)
        _cachedIsMicEnabled = defaults.bool(forKey: Keys.isMicEnabled)
        _cachedShareBothSpeakers = defaults.bool(forKey: Keys.shareBothSpeakers)
        _cachedAllowLANShare = defaults.bool(forKey: Keys.allowLANShare)
        _cachedLiveShareUseExternalTunnel = defaults.bool(forKey: Keys.liveShareUseExternalTunnel)
        _cachedPauseOnScreenLock = defaults.bool(forKey: Keys.pauseOnScreenLock)
        _cachedAutosaveTranscripts = defaults.bool(forKey: Keys.autosaveTranscripts)
        _cachedHasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
        _cachedHasAcceptedLiveShareConsent = defaults.bool(forKey: Keys.hasAcceptedLiveShareConsent)
        _cachedHasAcceptedExternalLiveShareConsent = defaults.bool(forKey: Keys.hasAcceptedExternalLiveShareConsent)
        let rawCallerGain = Float(defaults.double(forKey: Keys.callerInputGain))
        _cachedCallerInputGain = (rawCallerGain.isFinite && rawCallerGain > 0) ? Self.clampInputGain(rawCallerGain) : 1.0
        let rawMicGain = Float(defaults.double(forKey: Keys.micInputGain))
        _cachedMicInputGain = (rawMicGain.isFinite && rawMicGain > 0) ? Self.clampInputGain(rawMicGain) : 1.0
        _cachedAutoGainEnabled = defaults.bool(forKey: Keys.autoGainEnabled)
        _cachedPreferredSpeechLocales = (defaults.dictionary(forKey: Keys.preferredSpeechLocales) as? [String: String]) ?? [:]
        _cachedAppLanguageCode = resolvedAppLang

        if !AppPaths.isTestEnvironment {
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.flushAudioGainPersistenceSync()
            }
        }
    }

    public var appLanguageCode: String {
        get { lock.withLock { _cachedAppLanguageCode } }
        set {
            let lower = newValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normalized = (lower == "es" || lower.hasPrefix("es-")) ? "es" : "en"
            let changed = lock.withLock { () -> Bool in
                guard _cachedAppLanguageCode != normalized else { return false }
                _cachedAppLanguageCode = normalized
                persistValueLocked(normalized, forKey: Keys.appLanguageCode)
                return true
            }
            if changed { notifyChange(affectsEngine: false) }
        }
    }

    public var mainLanguageCode: String {
        get { lock.withLock { _cachedMainLanguageCode } }
        set {
            let normalized = Self.canonicalLanguageCode(newValue)
            let changed = lock.withLock { () -> Bool in
                guard _cachedMainLanguageCode != normalized else { return false }
                _cachedMainLanguageCode = normalized
                persistValueLocked(normalized, forKey: Keys.mainLanguageCode)
                if _cachedSubtitleFollowsMain {
                    _cachedTargetLanguageCode = normalized
                    persistValueLocked(normalized, forKey: Keys.targetLanguageCode)
                }
                return true
            }
            if changed { notifyChange(affectsEngine: true) }
        }
    }
    
    public var foreignLanguageCode: String {
        get { lock.withLock { _cachedForeignLanguageCode } }
        set {
            let normalized = Self.canonicalLanguageCode(newValue)
            let changed = lock.withLock { () -> Bool in
                guard _cachedForeignLanguageCode != normalized else { return false }
                _cachedForeignLanguageCode = normalized
                persistValueLocked(normalized, forKey: Keys.foreignLanguageCode)
                return true
            }
            if changed { notifyChange(affectsEngine: true) }
        }
    }
    
    public var targetLanguageCode: String {
        get { lock.withLock { _cachedTargetLanguageCode } }
        set {
            let normalized = Self.canonicalLanguageCode(newValue)
            let changed = lock.withLock { () -> Bool in
                let follows = (normalized == _cachedMainLanguageCode)
                guard _cachedTargetLanguageCode != normalized || _cachedSubtitleFollowsMain != follows else { return false }
                _cachedTargetLanguageCode = normalized
                _cachedSubtitleFollowsMain = follows
                persistValueLocked(normalized, forKey: Keys.targetLanguageCode)
                persistValueLocked(follows, forKey: Keys.subtitleFollowsMain)
                return true
            }
            if changed { notifyChange(affectsEngine: true) }
        }
    }
    
    public var subtitleFollowsMainLanguage: Bool {
        get { lock.withLock { _cachedSubtitleFollowsMain } }
        set {
            let changed = lock.withLock { () -> Bool in
                guard _cachedSubtitleFollowsMain != newValue else { return false }
                _cachedSubtitleFollowsMain = newValue
                persistValueLocked(newValue, forKey: Keys.subtitleFollowsMain)
                if newValue && _cachedTargetLanguageCode != _cachedMainLanguageCode {
                    _cachedTargetLanguageCode = _cachedMainLanguageCode
                    persistValueLocked(_cachedMainLanguageCode, forKey: Keys.targetLanguageCode)
                    return true
                }
                return true
            }
            if changed { notifyChange(affectsEngine: true) }
        }
    }
    
    public func setMainAndTargetLanguage(_ code: String) {
        let normalized = Self.canonicalLanguageCode(code)
        let changed = lock.withLock { () -> Bool in
            let targetShouldUpdate = _cachedSubtitleFollowsMain && (_cachedTargetLanguageCode != normalized)
            guard _cachedMainLanguageCode != normalized || targetShouldUpdate else { return false }
            _cachedMainLanguageCode = normalized
            persistValueLocked(normalized, forKey: Keys.mainLanguageCode)
            if _cachedSubtitleFollowsMain {
                _cachedTargetLanguageCode = normalized
                persistValueLocked(normalized, forKey: Keys.targetLanguageCode)
            }
            return true
        }
        if changed { notifyChange(affectsEngine: true) }
    }
    
    public func swapLanguages() {
        let changed = lock.withLock { () -> Bool in
            let oldMain = _cachedMainLanguageCode
            let oldForeign = _cachedForeignLanguageCode
            guard oldMain != oldForeign else { return false }
            _cachedMainLanguageCode = oldForeign
            _cachedForeignLanguageCode = oldMain
            persistValueLocked(oldForeign, forKey: Keys.mainLanguageCode)
            persistValueLocked(oldMain, forKey: Keys.foreignLanguageCode)
            if _cachedSubtitleFollowsMain {
                _cachedTargetLanguageCode = oldForeign
                persistValueLocked(oldForeign, forKey: Keys.targetLanguageCode)
            }
            return true
        }
        if changed { notifyChange(affectsEngine: true) }
    }
    
    public var autoPopupOnForeignSpeech: Bool {
        get { lock.withLock { _cachedAutoPopup } }
        set {
            let changed = lock.withLock { () -> Bool in
                guard _cachedAutoPopup != newValue else { return false }
                _cachedAutoPopup = newValue
                persistValueLocked(newValue, forKey: Keys.autoPopup)
                return true
            }
            if changed { notifyChange(affectsEngine: false) }
        }
    }
    
    public var autoHideDelay: Double {
        get { lock.withLock { _cachedAutoHideDelay } }
        set {
            guard newValue.isFinite && newValue >= 0 else { return }
            let changed = lock.withLock { () -> Bool in
                guard _cachedAutoHideDelay != newValue else { return false }
                _cachedAutoHideDelay = newValue
                persistValueLocked(newValue, forKey: Keys.autoHideDelay)
                return true
            }
            if changed { notifyChange(affectsEngine: false) }
        }
    }
    
    public var showOriginalText: Bool {
        get { lock.withLock { _cachedShowOriginal } }
        set {
            let changed = lock.withLock { () -> Bool in
                guard _cachedShowOriginal != newValue else { return false }
                _cachedShowOriginal = newValue
                persistValueLocked(newValue, forKey: Keys.showOriginal)
                return true
            }
            if changed { notifyChange(affectsEngine: false) }
        }
    }
    
    public var captionFontSize: CGFloat {
        get { lock.withLock { _cachedCaptionFontSize } }
        set {
            guard newValue.isFinite && newValue > 0 else { return }
            let changed = lock.withLock { () -> Bool in
                guard _cachedCaptionFontSize != newValue else { return false }
                _cachedCaptionFontSize = newValue
                persistValueLocked(Double(newValue), forKey: Keys.fontSize)
                return true
            }
            if changed { notifyChange(affectsEngine: false) }
        }
    }
    
    public var isPinned: Bool {
        get { lock.withLock { _cachedIsPinned } }
        set {
            let changed = lock.withLock { () -> Bool in
                guard _cachedIsPinned != newValue else { return false }
                _cachedIsPinned = newValue
                persistValueLocked(newValue, forKey: Keys.isPinned)
                return true
            }
            if changed { notifyChange(affectsEngine: false) }
        }
    }
    
    public var isMicEnabled: Bool {
        get { lock.withLock { _cachedIsMicEnabled } }
        set {
            let changed = lock.withLock { () -> Bool in
                guard _cachedIsMicEnabled != newValue else { return false }
                _cachedIsMicEnabled = newValue
                persistValueLocked(newValue, forKey: Keys.isMicEnabled)
                return true
            }
            if changed { notifyChange(affectsEngine: true) }
        }
    }
    
    public var shareBothSpeakersOnLink: Bool {
        get { lock.withLock { _cachedShareBothSpeakers } }
        set {
            let changed = lock.withLock { () -> Bool in
                guard _cachedShareBothSpeakers != newValue else { return false }
                _cachedShareBothSpeakers = newValue
                persistValueLocked(newValue, forKey: Keys.shareBothSpeakers)
                return true
            }
            if changed { notifyChange(affectsEngine: false) }
        }
    }
    
    public var allowLANShare: Bool {
        get { lock.withLock { _cachedAllowLANShare } }
        set {
            let changed = lock.withLock { () -> Bool in
                guard _cachedAllowLANShare != newValue else { return false }
                _cachedAllowLANShare = newValue
                persistValueLocked(newValue, forKey: Keys.allowLANShare)
                return true
            }
            if changed { notifyChange(affectsEngine: false) }
        }
    }
    
    public var liveShareUseExternalTunnel: Bool {
        get { lock.withLock { _cachedLiveShareUseExternalTunnel } }
        set {
            let changed = lock.withLock { () -> Bool in
                guard _cachedLiveShareUseExternalTunnel != newValue else { return false }
                _cachedLiveShareUseExternalTunnel = newValue
                persistValueLocked(newValue, forKey: Keys.liveShareUseExternalTunnel)
                return true
            }
            if changed { notifyChange(affectsEngine: false) }
        }
    }

    public var pauseOnScreenLock: Bool {
        get { lock.withLock { _cachedPauseOnScreenLock } }
        set {
            let changed = lock.withLock { () -> Bool in
                guard _cachedPauseOnScreenLock != newValue else { return false }
                _cachedPauseOnScreenLock = newValue
                persistValueLocked(newValue, forKey: Keys.pauseOnScreenLock)
                return true
            }
            if changed { notifyChange(affectsEngine: false) }
        }
    }

    public var autosaveTranscripts: Bool {
        get { lock.withLock { _cachedAutosaveTranscripts } }
        set {
            let changed = lock.withLock { () -> Bool in
                guard _cachedAutosaveTranscripts != newValue else { return false }
                _cachedAutosaveTranscripts = newValue
                persistValueLocked(newValue, forKey: Keys.autosaveTranscripts)
                return true
            }
            if changed {
                if newValue {
                    TranscriptManager.shared.scheduleAutosaveForExistingEntriesIfNeeded()
                }
                notifyChange(affectsEngine: false)
            }
        }
    }
    
    public var hasCompletedOnboarding: Bool {
        get { lock.withLock { _cachedHasCompletedOnboarding } }
        set {
            lock.withLock {
                _cachedHasCompletedOnboarding = newValue
                persistValueLocked(newValue, forKey: Keys.hasCompletedOnboarding)
            }
        }
    }
    
    public var hasAcceptedLiveShareConsent: Bool {
        get { lock.withLock { _cachedHasAcceptedLiveShareConsent } }
        set {
            lock.withLock {
                _cachedHasAcceptedLiveShareConsent = newValue
                persistValueLocked(newValue, forKey: Keys.hasAcceptedLiveShareConsent)
            }
        }
    }

    public var hasAcceptedExternalLiveShareConsent: Bool {
        get { lock.withLock { _cachedHasAcceptedExternalLiveShareConsent } }
        set {
            lock.withLock {
                _cachedHasAcceptedExternalLiveShareConsent = newValue
                persistValueLocked(newValue, forKey: Keys.hasAcceptedExternalLiveShareConsent)
            }
        }
    }

    public var callerInputGain: Float {
        get { lock.withLock { _cachedCallerInputGain } }
        set {
            let clamped = Self.clampInputGain(newValue)
            let changed = lock.withLock { () -> Bool in
                guard abs(_cachedCallerInputGain - clamped) >= 0.005 else { return false }
                _cachedCallerInputGain = clamped
                scheduleDebouncedGainPersistenceLocked()
                return true
            }
            if changed { notifyAudioGainChange() }
        }
    }

    public var micInputGain: Float {
        get { lock.withLock { _cachedMicInputGain } }
        set {
            let clamped = Self.clampInputGain(newValue)
            let changed = lock.withLock { () -> Bool in
                guard abs(_cachedMicInputGain - clamped) >= 0.005 else { return false }
                _cachedMicInputGain = clamped
                scheduleDebouncedGainPersistenceLocked()
                return true
            }
            if changed { notifyAudioGainChange() }
        }
    }

    public var isAutoGainEnabled: Bool {
        get { lock.withLock { _cachedAutoGainEnabled } }
        set {
            let changed = lock.withLock { () -> Bool in
                guard _cachedAutoGainEnabled != newValue else { return false }
                _cachedAutoGainEnabled = newValue
                persistValueLocked(newValue, forKey: Keys.autoGainEnabled)
                return true
            }
            if changed { notifyChange(affectsEngine: false) }
        }
    }

    public func resetAudioCalibration() {
        let (gainChanged, autoGainChanged) = lock.withLock { () -> (Bool, Bool) in
            let gainDiff = abs(_cachedCallerInputGain - 1.0) >= 0.005
                || abs(_cachedMicInputGain - 1.0) >= 0.005
            let autoDiff = !_cachedAutoGainEnabled
            _cachedCallerInputGain = 1.0
            _cachedMicInputGain = 1.0
            _cachedAutoGainEnabled = true
            _gainPersistScheduled = false
            _gainPersistGeneration &+= 1
            persistenceQueue.async { [self] in
                let (callerGain, micGain, autoGain) = lock.withLock {
                    (_cachedCallerInputGain, _cachedMicInputGain, _cachedAutoGainEnabled)
                }
                defaults.set(Double(callerGain), forKey: Keys.callerInputGain)
                defaults.set(Double(micGain), forKey: Keys.micInputGain)
                defaults.set(autoGain, forKey: Keys.autoGainEnabled)
            }
            return (gainDiff, autoDiff)
        }
        if gainChanged || autoGainChanged { notifyAudioGainChange() }
        if autoGainChanged { notifyChange(affectsEngine: false) }
    }
    
    public var mainLanguageItem: LanguageItem {
        SupportedLanguages.item(forCode: mainLanguageCode) ?? SupportedLanguages.all[0]
    }
    
    public var foreignLanguageItem: LanguageItem {
        SupportedLanguages.item(forCode: foreignLanguageCode) ?? SupportedLanguages.all[1]
    }
    
    public var targetLanguageItem: LanguageItem {
        SupportedLanguages.item(forCode: targetLanguageCode) ?? mainLanguageItem
    }

    public func preferredSpeechLocale(forCode code: String) -> String? {
        let clean = code.replacingOccurrences(of: "_", with: "-").lowercased().components(separatedBy: "-").first ?? code.lowercased()
        return lock.withLock { _cachedPreferredSpeechLocales[clean] }
    }

    public func setPreferredSpeechLocale(_ localeId: String?, forCode code: String) {
        let clean = code.replacingOccurrences(of: "_", with: "-").lowercased().components(separatedBy: "-").first ?? code.lowercased()
        let normLocale = localeId?.replacingOccurrences(of: "_", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = lock.withLock { () -> Bool in
            let existing = _cachedPreferredSpeechLocales[clean]
            if let normLocale = normLocale, !normLocale.isEmpty {
                guard existing != normLocale else { return false }
                _cachedPreferredSpeechLocales[clean] = normLocale
            } else {
                guard existing != nil else { return false }
                _cachedPreferredSpeechLocales.removeValue(forKey: clean)
            }
            persistValueLocked(_cachedPreferredSpeechLocales, forKey: Keys.preferredSpeechLocales)
            return true
        }
        if changed {
            SupportedLanguages.invalidateResolvedPreferenceCache(forCode: clean)
            notifyChange(affectsEngine: true)
        }
    }

    private func persistValueLocked<T: Sendable>(_ value: T, forKey key: String) {
        persistenceQueue.async { [self] in
            self.defaults.set(value, forKey: key)
        }
    }

    public func flushPersistence() {
        flushAudioGainPersistenceSync()
    }

    private func scheduleDebouncedGainPersistenceLocked() {
        guard !_gainPersistScheduled else { return }
        _gainPersistScheduled = true
        let scheduledGen = _gainPersistGeneration
        persistenceQueue.asyncAfter(deadline: .now() + 0.5) { [self] in
            let snapshot = lock.withLock { () -> (Float, Float)? in
                guard _gainPersistScheduled && _gainPersistGeneration == scheduledGen else {
                    return nil
                }
                _gainPersistScheduled = false
                return (_cachedCallerInputGain, _cachedMicInputGain)
            }
            guard let (callerGain, micGain) = snapshot else { return }
            defaults.set(Double(callerGain), forKey: Keys.callerInputGain)
            defaults.set(Double(micGain), forKey: Keys.micInputGain)
        }
    }

    private func flushAudioGainPersistenceSync() {
        let (callerGain, micGain, shouldFlush) = lock.withLock { () -> (Float, Float, Bool) in
            let pending = _gainPersistScheduled
            _gainPersistScheduled = false
            _gainPersistGeneration &+= 1
            return (_cachedCallerInputGain, _cachedMicInputGain, pending)
        }
        persistenceQueue.sync { [self] in
            if shouldFlush {
                defaults.set(Double(callerGain), forKey: Keys.callerInputGain)
                defaults.set(Double(micGain), forKey: Keys.micInputGain)
            }
        }
    }

    private func notifyAudioGainChange() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: Self.audioGainDidChangeNotification, object: self)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.audioGainDidChangeNotification, object: self)
            }
        }
    }
    
    private func notifyChange(affectsEngine: Bool) {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
            if affectsEngine {
                NotificationCenter.default.post(name: Self.engineConfigDidChangeNotification, object: self)
            }
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
                if affectsEngine {
                    NotificationCenter.default.post(name: Self.engineConfigDidChangeNotification, object: self)
                }
            }
        }
    }
}
