import Foundation
import AppKit
import os

public final class AppSettings: @unchecked Sendable {
    public static let shared = AppSettings()
    
    public static let didChangeNotification = Notification.Name("AppSettingsDidChangeNotification")
    
    public static let engineConfigDidChangeNotification = Notification.Name("AppSettingsEngineConfigDidChangeNotification")
    
    private let defaults: UserDefaults
    private let lock = OSAllocatedUnfairLock()
    
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

        let systemCode = Locale.current.language.languageCode?.identifier ?? "en"
        let defaultMain = SupportedLanguages.item(forCode: systemCode)?.code
            ?? SupportedLanguages.item(forCode: "en")?.code
            ?? "en"
        let defaultForeign = (defaultMain == "en") ? "es" : "en"

        let mainCode = savedMain ?? defaultMain
        let foreignCode = savedForeign ?? defaultForeign

        defaults.register(defaults: [
            Keys.mainLanguageCode: defaultMain,
            Keys.foreignLanguageCode: defaultForeign,
            Keys.targetLanguageCode: defaultMain,
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
            Keys.hasAcceptedExternalLiveShareConsent: false
        ])

        _cachedMainLanguageCode = mainCode
        _cachedForeignLanguageCode = foreignCode
        let targetCode = defaults.string(forKey: Keys.targetLanguageCode) ?? mainCode
        _cachedTargetLanguageCode = targetCode
        if defaults.object(forKey: Keys.subtitleFollowsMain) != nil {
            _cachedSubtitleFollowsMain = defaults.bool(forKey: Keys.subtitleFollowsMain)
        } else {
            _cachedSubtitleFollowsMain = (targetCode == mainCode)
        }
        _cachedAutoPopup = defaults.bool(forKey: Keys.autoPopup)
        _cachedAutoHideDelay = defaults.double(forKey: Keys.autoHideDelay)
        _cachedShowOriginal = defaults.bool(forKey: Keys.showOriginal)

        let fs = defaults.double(forKey: Keys.fontSize)
        _cachedCaptionFontSize = fs > 0 ? CGFloat(fs) : 16.0

        _cachedIsPinned = defaults.bool(forKey: Keys.isPinned)
        _cachedIsMicEnabled = defaults.object(forKey: Keys.isMicEnabled) != nil ? defaults.bool(forKey: Keys.isMicEnabled) : false
        _cachedShareBothSpeakers = defaults.object(forKey: Keys.shareBothSpeakers) != nil ? defaults.bool(forKey: Keys.shareBothSpeakers) : true
        _cachedAllowLANShare = defaults.bool(forKey: Keys.allowLANShare)
        _cachedLiveShareUseExternalTunnel = defaults.object(forKey: Keys.liveShareUseExternalTunnel) != nil
            ? defaults.bool(forKey: Keys.liveShareUseExternalTunnel)
            : true
        _cachedPauseOnScreenLock = defaults.object(forKey: Keys.pauseOnScreenLock) != nil
            ? defaults.bool(forKey: Keys.pauseOnScreenLock)
            : true
        _cachedAutosaveTranscripts = defaults.bool(forKey: Keys.autosaveTranscripts)
        _cachedHasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
        _cachedHasAcceptedLiveShareConsent = defaults.bool(forKey: Keys.hasAcceptedLiveShareConsent)
        _cachedHasAcceptedExternalLiveShareConsent = defaults.bool(forKey: Keys.hasAcceptedExternalLiveShareConsent)
    }

    public var mainLanguageCode: String {
        get { lock.withLock { _cachedMainLanguageCode } }
        set {
            let changed = lock.withLock { () -> Bool in
                guard _cachedMainLanguageCode != newValue else { return false }
                _cachedMainLanguageCode = newValue
                defaults.set(newValue, forKey: Keys.mainLanguageCode)
                if _cachedSubtitleFollowsMain {
                    _cachedTargetLanguageCode = newValue
                    defaults.set(newValue, forKey: Keys.targetLanguageCode)
                }
                return true
            }
            if changed { notifyChange(affectsEngine: true) }
        }
    }
    
    public var foreignLanguageCode: String {
        get { lock.withLock { _cachedForeignLanguageCode } }
        set {
            let changed = lock.withLock { () -> Bool in
                guard _cachedForeignLanguageCode != newValue else { return false }
                _cachedForeignLanguageCode = newValue
                defaults.set(newValue, forKey: Keys.foreignLanguageCode)
                return true
            }
            if changed { notifyChange(affectsEngine: true) }
        }
    }
    
    public var targetLanguageCode: String {
        get { lock.withLock { _cachedTargetLanguageCode } }
        set {
            let changed = lock.withLock { () -> Bool in
                let follows = (newValue == _cachedMainLanguageCode)
                guard _cachedTargetLanguageCode != newValue || _cachedSubtitleFollowsMain != follows else { return false }
                _cachedTargetLanguageCode = newValue
                _cachedSubtitleFollowsMain = follows
                defaults.set(newValue, forKey: Keys.targetLanguageCode)
                defaults.set(follows, forKey: Keys.subtitleFollowsMain)
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
                defaults.set(newValue, forKey: Keys.subtitleFollowsMain)
                if newValue && _cachedTargetLanguageCode != _cachedMainLanguageCode {
                    _cachedTargetLanguageCode = _cachedMainLanguageCode
                    defaults.set(_cachedMainLanguageCode, forKey: Keys.targetLanguageCode)
                    return true
                }
                return true
            }
            if changed { notifyChange(affectsEngine: true) }
        }
    }
    
    public func setMainAndTargetLanguage(_ code: String) {
        let changed = lock.withLock { () -> Bool in
            let targetShouldUpdate = _cachedSubtitleFollowsMain && (_cachedTargetLanguageCode != code)
            guard _cachedMainLanguageCode != code || targetShouldUpdate else { return false }
            _cachedMainLanguageCode = code
            defaults.set(code, forKey: Keys.mainLanguageCode)
            if _cachedSubtitleFollowsMain {
                _cachedTargetLanguageCode = code
                defaults.set(code, forKey: Keys.targetLanguageCode)
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
            defaults.set(oldForeign, forKey: Keys.mainLanguageCode)
            defaults.set(oldMain, forKey: Keys.foreignLanguageCode)
            if _cachedSubtitleFollowsMain {
                _cachedTargetLanguageCode = oldForeign
                defaults.set(oldForeign, forKey: Keys.targetLanguageCode)
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
                defaults.set(newValue, forKey: Keys.autoPopup)
                return true
            }
            if changed { notifyChange(affectsEngine: false) }
        }
    }
    
    public var autoHideDelay: Double {
        get { lock.withLock { _cachedAutoHideDelay } }
        set {
            let changed = lock.withLock { () -> Bool in
                guard _cachedAutoHideDelay != newValue else { return false }
                _cachedAutoHideDelay = newValue
                defaults.set(newValue, forKey: Keys.autoHideDelay)
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
                defaults.set(newValue, forKey: Keys.showOriginal)
                return true
            }
            if changed { notifyChange(affectsEngine: false) }
        }
    }
    
    public var captionFontSize: CGFloat {
        get { lock.withLock { _cachedCaptionFontSize } }
        set {
            let changed = lock.withLock { () -> Bool in
                guard _cachedCaptionFontSize != newValue else { return false }
                _cachedCaptionFontSize = newValue
                defaults.set(Double(newValue), forKey: Keys.fontSize)
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
                defaults.set(newValue, forKey: Keys.isPinned)
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
                defaults.set(newValue, forKey: Keys.isMicEnabled)
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
                defaults.set(newValue, forKey: Keys.shareBothSpeakers)
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
                defaults.set(newValue, forKey: Keys.allowLANShare)
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
                defaults.set(newValue, forKey: Keys.liveShareUseExternalTunnel)
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
                defaults.set(newValue, forKey: Keys.pauseOnScreenLock)
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
                defaults.set(newValue, forKey: Keys.autosaveTranscripts)
                return true
            }
            if changed { notifyChange(affectsEngine: false) }
        }
    }
    
    public var hasCompletedOnboarding: Bool {
        get { lock.withLock { _cachedHasCompletedOnboarding } }
        set {
            lock.withLock {
                _cachedHasCompletedOnboarding = newValue
                defaults.set(newValue, forKey: Keys.hasCompletedOnboarding)
            }
        }
    }
    
    public var hasAcceptedLiveShareConsent: Bool {
        get { lock.withLock { _cachedHasAcceptedLiveShareConsent } }
        set {
            lock.withLock {
                _cachedHasAcceptedLiveShareConsent = newValue
                defaults.set(newValue, forKey: Keys.hasAcceptedLiveShareConsent)
            }
        }
    }

    public var hasAcceptedExternalLiveShareConsent: Bool {
        get { lock.withLock { _cachedHasAcceptedExternalLiveShareConsent } }
        set {
            lock.withLock {
                _cachedHasAcceptedExternalLiveShareConsent = newValue
                defaults.set(newValue, forKey: Keys.hasAcceptedExternalLiveShareConsent)
            }
        }
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
