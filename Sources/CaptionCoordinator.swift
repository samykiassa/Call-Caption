import Foundation
import AppKit
import AVFoundation
import Observation
import Synchronization
import os

enum SystemAlertActionType: Sendable, Equatable {
    case none
    case audioCapture
    case microphone
    case speechRecognition
    case dictation
    case translationSettings

    @MainActor
    func performAction() {
        switch self {
        case .none:
            break
        case .audioCapture:
            PermissionHelper.shared.openAudioCaptureSettings()
        case .microphone:
            PermissionHelper.shared.openMicrophoneSettings()
        case .speechRecognition:
            PermissionHelper.shared.openSpeechRecognitionSettings()
        case .dictation:
            PermissionHelper.shared.openDictationSettings()
        case .translationSettings:
            PermissionHelper.shared.openTranslationSettings()
        }
    }

    var actionButtonTitle: String? {
        switch self {
        case .none:
            return nil
        case .audioCapture, .microphone, .speechRecognition, .dictation, .translationSettings:
            return AppL10n.string("alert.open_settings", fallback: "Open Settings")
        }
    }
}

enum AppAppearanceMode: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    var localizedTitle: String {
        switch self {
        case .system: return AppL10n.string("overflow.appearance.system", fallback: "System")
        case .light: return AppL10n.string("overflow.appearance.light", fallback: "Light")
        case .dark: return AppL10n.string("overflow.appearance.dark", fallback: "Dark")
        }
    }
}

struct CaptionEntry: Identifiable, Sendable, Equatable {
    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .none
        df.timeStyle = .short
        return df
    }()
    private static let timeFormatterLock = OSAllocatedUnfairLock()

    static func formatTimestamp(_ date: Date) -> String {
        let locale = AppL10n.effectiveUILocale
        return timeFormatterLock.withLock {
            if timeFormatter.locale != locale {
                timeFormatter.locale = locale
            }
            return timeFormatter.string(from: date)
        }
    }

    let id: UUID
    let speaker: String
    let original: String
    let translated: String
    let sourceLangCode: String
    let targetLangCode: String
    let timestamp: Date
    let formattedTime: String
    let isFinal: Bool
    let isUntranslated: Bool

    init(
        id: UUID,
        speaker: String,
        original: String,
        translated: String,
        sourceLangCode: String,
        targetLangCode: String,
        timestamp: Date = Date(),
        isFinal: Bool,
        isUntranslated: Bool = false
    ) {
        self.id = id
        self.speaker = speaker
        self.original = original
        self.translated = translated
        self.sourceLangCode = sourceLangCode
        self.targetLangCode = targetLangCode
        self.timestamp = timestamp
        self.formattedTime = Self.formatTimestamp(timestamp)
        self.isFinal = isFinal
        self.isUntranslated = isUntranslated
    }

    init(
        id: UUID,
        speaker: String,
        original: String,
        translated: String,
        sourceLangCode: String,
        targetLangCode: String,
        timestamp: Date,
        formattedTime: String,
        isFinal: Bool,
        isUntranslated: Bool
    ) {
        self.id = id
        self.speaker = speaker
        self.original = original
        self.translated = translated
        self.sourceLangCode = sourceLangCode
        self.targetLangCode = targetLangCode
        self.timestamp = timestamp
        self.formattedTime = formattedTime
        self.isFinal = isFinal
        self.isUntranslated = isUntranslated
    }

    static func == (lhs: CaptionEntry, rhs: CaptionEntry) -> Bool {
        lhs.id == rhs.id
            && lhs.speaker == rhs.speaker
            && lhs.original == rhs.original
            && lhs.translated == rhs.translated
            && lhs.sourceLangCode == rhs.sourceLangCode
            && lhs.targetLangCode == rhs.targetLangCode
            && lhs.timestamp == rhs.timestamp
            && lhs.isFinal == rhs.isFinal
            && lhs.isUntranslated == rhs.isUntranslated
    }
}

enum LiveShareBannerStatus: Equatable, Sendable {
    case off
    case startingLocal
    case connectingTunnel(localURL: URL?, statusText: String)
    case ready(primaryURL: URL, localURL: URL?, isPublic: Bool, viewerCount: Int)
    case failed(localURL: URL?, errorText: String)
}

@MainActor
protocol CaptionCoordinatorDelegate: AnyObject {
    func coordinatorDidRequestShowAlert(message: String, actionType: SystemAlertActionType)
    func coordinatorDidRequestClearAlert()
    func coordinatorDidReceiveSpeech(
        utteranceID: UUID,
        speaker: String,
        original: String,
        translated: String,
        sourceLangCode: String,
        targetLangCode: String,
        isFinal: Bool,
        isUntranslated: Bool
    )
    func coordinatorDidUpdateAudioLevels(callerLevel: Float, micLevel: Float)
}

enum SystemPauseReason: Sendable, Hashable {
    case systemSleep
    case sessionResigned
}

@MainActor
@Observable
final class CaptionViewModel {
    private unowned let coordinator: CaptionCoordinator

    var finalizedEntries: [CaptionEntry] = [] {
        didSet { updateHasEntries() }
    }
    var liveCallerEntry: CaptionEntry? = nil {
        didSet { updateHasEntries() }
    }
    var liveMicEntry: CaptionEntry? = nil {
        didSet { updateHasEntries() }
    }
    private(set) var hasEntries: Bool = false

    var entries: [CaptionEntry] {
        get {
            var result = finalizedEntries
            switch (liveCallerEntry, liveMicEntry) {
            case (nil, nil):
                break
            case (let c?, nil):
                result.append(c)
            case (nil, let m?):
                result.append(m)
            case (let c?, let m?):
                if c.timestamp <= m.timestamp {
                    result.append(c)
                    result.append(m)
                } else {
                    result.append(m)
                    result.append(c)
                }
            }
            return result
        }
        set {
            var finalized: [CaptionEntry] = []
            finalized.reserveCapacity(newValue.count)
            var nextCaller: CaptionEntry? = nil
            var nextMic: CaptionEntry? = nil
            for item in newValue {
                if item.isFinal {
                    finalized.append(item)
                } else if item.speaker.caseInsensitiveCompare("caller") == .orderedSame {
                    if let prev = nextCaller {
                        finalized.append(prev)
                    }
                    nextCaller = item
                } else {
                    if let prev = nextMic {
                        finalized.append(prev)
                    }
                    nextMic = item
                }
            }
            if finalized.count > 500 {
                finalized.removeFirst(finalized.count - 500)
            }
            finalizedEntries = finalized
            liveCallerEntry = nextCaller
            liveMicEntry = nextMic
        }
    }

    private func updateHasEntries() {
        let nonEmpty = !finalizedEntries.isEmpty || liveCallerEntry != nil || liveMicEntry != nil
        if hasEntries != nonEmpty {
            hasEntries = nonEmpty
        }
    }

    func containsUtterance(id: UUID) -> Bool {
        if liveCallerEntry?.id == id || liveMicEntry?.id == id {
            return true
        }
        return finalizedEntries.lastIndex(where: { $0.id == id }) != nil
    }

    func clearAllEntries() {
        finalizedEntries.removeAll()
        liveCallerEntry = nil
        liveMicEntry = nil
    }
    var callerLevel: Float = 0
    var micLevel: Float = 0
    var isPaused: Bool = false
    var alertMessage: String? = nil
    var alertAction: SystemAlertActionType = .none

    var callerLanguageCode: String
    var myLanguageCode: String
    var isConversationalMode: Bool
    var showOriginalText: Bool
    var isPinned: Bool
    var shareAllowLAN: Bool
    var shareUseTunnel: Bool
    var shareBothSpeakers: Bool
    var captionFontSize: Double
    var appearanceMode: AppAppearanceMode
    var hideFromScreenSharing: Bool = true
    var isCompactFloatingHUD: Bool = false

    var sharePublicTunnel: Bool { shareUseTunnel }

    var isAudioCapturing: Bool = false
    var isMicCapturing: Bool = false
    var isStartingUp: Bool = true
    var showAlertRetryAction: Bool = false
    var isSharing: Bool = false
    var shareStatus: LiveShareBannerStatus = .off
    var primaryShareURL: URL? = nil
    var localShareURL: URL? = nil
    var viewerCount: Int = 0
    var sharePublicLinkRotated: Bool = false
    var shareLANIPUnavailable: Bool = false
    var showShareOptions: Bool = false
    var copiedLinkFeedback: Bool = false
    var copiedTranscriptFeedback: Bool = false

    fileprivate init(
        coordinator: CaptionCoordinator,
        callerLanguageCode: String,
        myLanguageCode: String,
        isConversationalMode: Bool,
        showOriginalText: Bool,
        isPinned: Bool,
        shareAllowLAN: Bool,
        shareUseTunnel: Bool,
        shareBothSpeakers: Bool,
        captionFontSize: Double,
        appearanceMode: AppAppearanceMode,
        hideFromScreenSharing: Bool = true,
        isCompactFloatingHUD: Bool = false
    ) {
        self.coordinator = coordinator
        self.callerLanguageCode = callerLanguageCode
        self.myLanguageCode = myLanguageCode
        self.isConversationalMode = isConversationalMode
        self.showOriginalText = showOriginalText
        self.isPinned = isPinned
        self.shareAllowLAN = shareAllowLAN
        self.shareUseTunnel = shareUseTunnel
        self.shareBothSpeakers = shareBothSpeakers
        self.captionFontSize = captionFontSize
        self.appearanceMode = appearanceMode
        self.hideFromScreenSharing = hideFromScreenSharing
        self.isCompactFloatingHUD = isCompactFloatingHUD
    }

    func setCallerLanguage(_ code: String) { coordinator.setCallerLanguage(code) }
    func setMyLanguage(_ code: String) { coordinator.setMyLanguage(code) }
    func swapLanguages() { coordinator.swapLanguages() }
    func setConversationalMode(_ enabled: Bool) { coordinator.setConversationalMode(enabled) }
    func setShowOriginalText(_ show: Bool) { coordinator.setShowOriginalText(show) }
    func setPinned(_ pinned: Bool) { coordinator.setPinned(pinned) }
    func setHideFromScreenSharing(_ enabled: Bool) { coordinator.setHideFromScreenSharing(enabled) }
    func setCompactFloatingHUD(_ compact: Bool) { coordinator.setCompactFloatingHUD(compact) }
    func togglePauseResume() { coordinator.togglePauseResume() }
    func clearTranscript() { coordinator.clearTranscript() }

    @discardableResult
    func copyTranscript() -> String { coordinator.copyTranscript() }

    func toggleSharing() { coordinator.toggleSharing() }
    func retryTunnel() { coordinator.retryTunnel() }
    func retryShare() { coordinator.retryShare() }
    func copyShareLink() { coordinator.copyShareLink() }
    func copyString(_ value: String) { coordinator.copyString(value) }
    func dismissShareRotationNotice() { coordinator.dismissShareRotationNotice() }
    func setShareOptions(allowLAN: Bool? = nil, useTunnel: Bool? = nil, bothSpeakers: Bool? = nil) {
        coordinator.setShareOptions(allowLAN: allowLAN, useTunnel: useTunnel, bothSpeakers: bothSpeakers)
    }

    func setCaptionFontSize(_ size: Double) { coordinator.setCaptionFontSize(size) }
    func increaseFontSize() { coordinator.increaseFontSize() }
    func decreaseFontSize() { coordinator.decreaseFontSize() }
    func resetFontSize() { coordinator.resetFontSize() }
    func setAppearanceMode(_ mode: AppAppearanceMode) { coordinator.setAppearanceMode(mode) }
    func setLevelMeteringVisible(_ visible: Bool) { coordinator.setLevelMeteringVisible(visible) }

    func dismissAlert() { coordinator.dismissPresentedAlert() }
    func openAlertSettings() { alertAction.performAction() }
    func retryAlertAction() { coordinator.retryAlertAction() }
    func dismissShareError() { coordinator.dismissShareError() }

    #if CALLCAPTION_TESTING
    func setCaptureStateForTesting(
        isStartingUp: Bool? = nil,
        isAudioCapturing: Bool? = nil,
        isMicCapturing: Bool? = nil
    ) {
        if let isStartingUp { self.isStartingUp = isStartingUp }
        if let isAudioCapturing { self.isAudioCapturing = isAudioCapturing }
        if let isMicCapturing { self.isMicCapturing = isMicCapturing }
    }
    #endif
}

final class CaptionCoordinator: NSObject, AudioCaptureDelegate, BidirectionalSpeechDelegate, @unchecked Sendable {
    static let shared = CaptionCoordinator()
    static let pauseStateDidChangeNotification = Notification.Name("CaptionCoordinatorPauseStateDidChangeNotification")
    static let pinStateDidChangeNotification = Notification.Name("CaptionCoordinatorPinStateDidChangeNotification")
    static let alertStateDidChangeNotification = Notification.Name("CaptionCoordinatorAlertStateDidChangeNotification")
    static let captureStateDidChangeNotification = Notification.Name("CaptionCoordinatorCaptureStateDidChangeNotification")
    static let appearanceDidChangeNotification = Notification.Name("CaptionCoordinatorAppearanceDidChangeNotification")
    static let screenSharingPrivacyDidChangeNotification = Notification.Name("CaptionCoordinatorScreenSharingPrivacyDidChangeNotification")
    static let compactFloatingHUDDidChangeNotification = Notification.Name("CaptionCoordinatorCompactFloatingHUDDidChangeNotification")
    static let didDiscardInFlightSpeechNotification = Notification.Name("CaptionCoordinatorDidDiscardInFlightSpeechNotification")

    static let defaultCaptionFontSize: Double = 15.0
    static let minCaptionFontSize: Double = 12.0
    static let maxCaptionFontSize: Double = 32.0

    private enum DefaultsKey {
        static let callerLanguageCode = "callerLanguageCode"
        static let myLanguageCode = "myLanguageCode"
        static let isConversationalMode = "isConversationalMode"
        static let showOriginalText = "showOriginalText"
        static let isPinned = "isPinned"
        static let shareAllowLAN = "shareAllowLAN"
        static let shareUseTunnel = "shareUseTunnel"
        static let shareBothSpeakers = "shareBothSpeakers"
        static let captionFontSize = "captionFontSize"
        static let appearanceMode = "appearanceMode"
        static let hideFromScreenSharing = "hideFromScreenSharing"
        static let isCompactFloatingHUD = "isCompactFloatingHUD"
    }

    private enum AlertScope: Hashable, Sendable {
        case systemAudioCapture
        case microphoneCapture
        case speechAuth(channel: String)
        case translationSettings
        case general

        var priority: Int {
            switch self {
            case .systemAudioCapture: return 100
            case .microphoneCapture: return 95
            case .speechAuth: return 80
            case .translationSettings: return 50
            case .general: return 10
            }
        }

        var sortKey: String {
            switch self {
            case .systemAudioCapture: return "0_systemAudioCapture"
            case .microphoneCapture: return "1_microphoneCapture"
            case .speechAuth(let ch): return "2_speechAuth_\(ch)"
            case .translationSettings: return "3_translationSettings"
            case .general: return "4_general"
            }
        }
    }

    private struct ActiveAlert: Sendable, Equatable {
        let scope: AlertScope
        let message: String
        let actionType: SystemAlertActionType
        let canRetry: Bool
    }

    private struct CoordinatorState: Sendable {
        var callerLanguageCode: String
        var myLanguageCode: String
        var isConversationalMode: Bool
        var showOriginalText: Bool
        var isPinned: Bool
        var shareAllowLAN: Bool
        var shareUseTunnel: Bool
        var shareBothSpeakers: Bool
        var captionFontSize: Double
        var appearanceMode: AppAppearanceMode
        var hideFromScreenSharing: Bool = true
        var isCompactFloatingHUD: Bool = false

        var isStarted: Bool = false
        var isAudioCapturing: Bool = false
        var isMicCapturing: Bool = false
        var isSystemAudioTapDenied: Bool = false
        var autoPausedForSystem: Bool = false
        var activeSystemPauseReasons: Set<SystemPauseReason> = []
        var isPaused: Bool = false
        var lastForeignLocale: String?
        var lastTargetCode: String?
        var lastMainLocale: String?
        var lastMicTargetCode: String?
        var lastMicEnabled: Bool?
        var reconfigureEpoch: UInt64 = 0
        var uiDeliveryEpoch: UInt64 = 0
        var lastDeniedRecoveryAttemptTime: TimeInterval = 0
        var activeAlerts: [AlertScope: ActiveAlert] = [:]
        var suppressedAlertsByScope: [AlertScope: String] = [:]
        var presentedAlert: ActiveAlert?
        var lastRenderedAlert: ActiveAlert?
    }

    weak var delegate: CaptionCoordinatorDelegate?
    let audioCaptureEngine = AudioCaptureEngine()
    let speechRecognitionManager = SpeechRecognitionManager()
    let liveShareManager: LiveShareManager
    private let defaults: UserDefaults

    private struct WorkItemBox: @unchecked Sendable {
        let item: DispatchWorkItem
    }

    private struct BasicStateSnapshot: Equatable, Sendable {
        let isPaused: Bool
        let isStarted: Bool
        let isAudioCapturing: Bool
        let isMicCapturing: Bool
    }

    private let lifecycleQueue = DispatchQueue(label: "com.callcaption.coordinator.lifecycle", qos: .userInitiated)
    private let lifecycleQueueKey = DispatchSpecificKey<Void>()
    private let stateLock: OSAllocatedUnfairLock<CoordinatorState>
    private let fastAudioFlags: Atomic<UInt8>
    private let taskLock = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    private let deniedRecoveryLock = OSAllocatedUnfairLock<WorkItemBox?>(initialState: nil)
    private let alertSyncScheduled = OSAllocatedUnfairLock(initialState: false)
    private let maxEntries = 500

    private struct ObserverBox: @unchecked Sendable {
        let token: NSObjectProtocol
    }

    @MainActor
    private var _viewModel: CaptionViewModel?
    @MainActor
    private var lastPostedBasicState: BasicStateSnapshot?
    @MainActor
    private var copyTranscriptFeedbackTask: Task<Void, Never>?
    @MainActor
    private var copyLinkFeedbackTask: Task<Void, Never>?
    private let observerLock = OSAllocatedUnfairLock<[ObserverBox]>(initialState: [])

    @MainActor
    var viewModel: CaptionViewModel {
        if let existing = _viewModel {
            return existing
        }
        let cfg = stateLock.withLock { $0 }
        let vm = CaptionViewModel(
            coordinator: self,
            callerLanguageCode: cfg.callerLanguageCode,
            myLanguageCode: cfg.myLanguageCode,
            isConversationalMode: cfg.isConversationalMode,
            showOriginalText: cfg.showOriginalText,
            isPinned: cfg.isPinned,
            shareAllowLAN: cfg.shareAllowLAN,
            shareUseTunnel: cfg.shareUseTunnel,
            shareBothSpeakers: cfg.shareBothSpeakers,
            captionFontSize: cfg.captionFontSize,
            appearanceMode: cfg.appearanceMode,
            hideFromScreenSharing: cfg.hideFromScreenSharing,
            isCompactFloatingHUD: cfg.isCompactFloatingHUD
        )
        vm.isPaused = cfg.isPaused
        vm.isAudioCapturing = cfg.isAudioCapturing
        vm.isMicCapturing = cfg.isMicCapturing
        vm.isStartingUp = !cfg.isStarted
        vm.alertMessage = cfg.presentedAlert?.message
        vm.alertAction = cfg.presentedAlert?.actionType ?? .none
        vm.showAlertRetryAction = cfg.presentedAlert?.canRetry ?? false
        _viewModel = vm
        refreshShareStateOnMain()
        return vm
    }

    var isAudioCapturing: Bool {
        stateLock.withLock { $0.isAudioCapturing }
    }

    var isMicCapturing: Bool {
        stateLock.withLock { $0.isMicCapturing }
    }

    var hasStarted: Bool {
        stateLock.withLock { $0.isStarted }
    }

    var isPaused: Bool {
        stateLock.withLock { $0.isPaused }
    }

    var isPinned: Bool {
        stateLock.withLock { $0.isPinned }
    }

    var appearanceMode: AppAppearanceMode {
        stateLock.withLock { $0.appearanceMode }
    }

    var hideFromScreenSharing: Bool {
        stateLock.withLock { $0.hideFromScreenSharing }
    }

    var isCompactFloatingHUD: Bool {
        stateLock.withLock { $0.isCompactFloatingHUD }
    }

    var currentCallerLanguageCode: String {
        stateLock.withLock { $0.callerLanguageCode }
    }

    var currentMyLanguageCode: String {
        stateLock.withLock { $0.myLanguageCode }
    }

    var isConversationalMode: Bool {
        stateLock.withLock { $0.isConversationalMode }
    }

    init(defaults: UserDefaults = .standard, liveShareManager: LiveShareManager = .shared) {
        self.defaults = defaults
        self.liveShareManager = liveShareManager

        let storedCallerCode = defaults.string(forKey: DefaultsKey.callerLanguageCode)
        let storedMyCode = defaults.string(forKey: DefaultsKey.myLanguageCode)
        let isSpanishUI = AppL10n.effectiveUILocale.language.languageCode?.identifier.lowercased() == "es"
        let defaultCallerCode = (storedCallerCode == nil && storedMyCode == nil && isSpanishUI) ? "en" : "es"
        let defaultMyCode = (storedCallerCode == nil && storedMyCode == nil && isSpanishUI) ? "es" : "en"
        let callerCode = storedCallerCode ?? defaultCallerCode
        let myCode = storedMyCode ?? defaultMyCode
        let conversational = defaults.object(forKey: DefaultsKey.isConversationalMode) as? Bool ?? false
        let showOrig = defaults.object(forKey: DefaultsKey.showOriginalText) as? Bool ?? true
        let pinned = defaults.object(forKey: DefaultsKey.isPinned) as? Bool ?? false
        let allowLAN = defaults.object(forKey: DefaultsKey.shareAllowLAN) as? Bool ?? false
        let useTunnel = defaults.object(forKey: DefaultsKey.shareUseTunnel) as? Bool ?? true
        let bothSpeakers = defaults.object(forKey: DefaultsKey.shareBothSpeakers) as? Bool ?? true
        let storedFontSize = defaults.object(forKey: DefaultsKey.captionFontSize) as? Double ?? Self.defaultCaptionFontSize
        let clampedFontSize = min(Self.maxCaptionFontSize, max(Self.minCaptionFontSize, storedFontSize))
        let storedAppearance = defaults.string(forKey: DefaultsKey.appearanceMode).flatMap(AppAppearanceMode.init(rawValue:)) ?? .system
        let hideScreenShare = defaults.object(forKey: DefaultsKey.hideFromScreenSharing) as? Bool ?? true
        let compactHUD = defaults.object(forKey: DefaultsKey.isCompactFloatingHUD) as? Bool ?? false

        self.fastAudioFlags = Atomic<UInt8>(Self.encodeFastAudioFlags(isPaused: false, isConversationalMode: conversational))
        self.stateLock = OSAllocatedUnfairLock(initialState: CoordinatorState(
            callerLanguageCode: SupportedLanguages.item(forCode: callerCode)?.code ?? defaultCallerCode,
            myLanguageCode: SupportedLanguages.item(forCode: myCode)?.code ?? defaultMyCode,
            isConversationalMode: conversational,
            showOriginalText: showOrig,
            isPinned: pinned,
            shareAllowLAN: allowLAN,
            shareUseTunnel: useTunnel,
            shareBothSpeakers: bothSpeakers,
            captionFontSize: clampedFontSize,
            appearanceMode: storedAppearance,
            hideFromScreenSharing: hideScreenShare,
            isCompactFloatingHUD: compactHUD
        ))

        super.init()
        lifecycleQueue.setSpecific(key: lifecycleQueueKey, value: ())
        audioCaptureEngine.delegate = self
        speechRecognitionManager.delegate = self
        syncLiveShareConfig()

        let center = NotificationCenter.default
        let t1 = center.addObserver(
            forName: LiveShareManager.stateDidChangeNotification,
            object: liveShareManager,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshShareStateOnMain()
            }
        }
        let t2 = center.addObserver(
            forName: LiveShareManager.urlDidUpdateNotification,
            object: liveShareManager,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshShareStateOnMain()
            }
        }
        let box1 = ObserverBox(token: t1)
        let box2 = ObserverBox(token: t2)
        observerLock.withLock { $0 = [box1, box2] }
    }

    deinit {
        cancelDelayedDeniedRecovery()
        cancelModelCheckTask()
        let tokens = observerLock.withLock { list -> [ObserverBox] in
            let copy = list
            list.removeAll()
            return copy
        }
        for box in tokens {
            NotificationCenter.default.removeObserver(box.token)
        }
    }

    private static func encodeFastAudioFlags(isPaused: Bool, isConversationalMode: Bool) -> UInt8 {
        (isPaused ? 1 : 0) | (isConversationalMode ? 2 : 0)
    }

    private func syncFastAudioFlagsLocked(_ state: CoordinatorState) {
        fastAudioFlags.store(
            Self.encodeFastAudioFlags(isPaused: state.isPaused, isConversationalMode: state.isConversationalMode),
            ordering: .releasing
        )
    }

    private static func resetCachedEngineConfigLocked(_ state: inout CoordinatorState) {
        state.lastForeignLocale = nil
        state.lastTargetCode = nil
        state.lastMainLocale = nil
        state.lastMicTargetCode = nil
        state.lastMicEnabled = nil
    }

    private func runOnLifecycleQueueSync(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: lifecycleQueueKey) != nil {
            work()
        } else {
            lifecycleQueue.sync(execute: work)
        }
    }

    // MARK: - Lifecycle

    func start() {
        let shouldConfigure = stateLock.withLock { state -> Bool in
            if state.isStarted {
                return false
            }
            state.isStarted = true
            if !state.isPaused {
                state.autoPausedForSystem = false
                state.activeSystemPauseReasons.removeAll()
            }
            return !state.isPaused
        }
        syncViewModelBasicState()
        guard shouldConfigure else { return }
        lifecycleQueue.async { [weak self] in
            self?.reconfigureEnginesOnLifecycleQueue()
        }
    }

    func stop() {
        cancelDelayedDeniedRecovery()
        cancelModelCheckTask()
        stateLock.withLock { state in
            state.isStarted = false
            state.isAudioCapturing = false
            state.isMicCapturing = false
            state.isSystemAudioTapDenied = false
            state.autoPausedForSystem = false
            state.activeSystemPauseReasons.removeAll()
            state.isPaused = false
            state.uiDeliveryEpoch &+= 1
            state.reconfigureEpoch &+= 1
            Self.resetCachedEngineConfigLocked(&state)
            syncFastAudioFlagsLocked(state)
        }
        clearAllAlerts()
        liveShareManager.stopSharing()
        runOnLifecycleQueueSync {
            self.cancelDelayedDeniedRecovery()
            self.cancelModelCheckTask()
            self.audioCaptureEngine.stop()
            self.speechRecognitionManager.stop()
            self.stateLock.withLock { state in
                if !state.isStarted {
                    state.isAudioCapturing = false
                    state.isMicCapturing = false
                }
            }
        }
        onMain { [weak self] in
            self?._viewModel?.callerLevel = 0
            self?._viewModel?.micLevel = 0
            self?.delegate?.coordinatorDidUpdateAudioLevels(callerLevel: 0, micLevel: 0)
        }
        syncViewModelBasicState()
        postNotificationOnMain(Self.pauseStateDidChangeNotification)
    }

    func togglePauseResume() {
        enum ToggleOutcome: Sendable {
            case paused(epoch: UInt64)
            case resumed(shouldReconfigure: Bool)
        }

        let outcome = stateLock.withLock { state -> ToggleOutcome in
            if !state.isPaused {
                let epoch = Self.applyPauseStateLocked(&state)
                syncFastAudioFlagsLocked(state)
                return .paused(epoch: epoch)
            } else {
                let shouldReconfigure = Self.applyResumeStateLocked(&state)
                syncFastAudioFlagsLocked(state)
                return .resumed(shouldReconfigure: shouldReconfigure)
            }
        }

        switch outcome {
        case .paused(let epoch):
            completePauseTransition(capturedEpoch: epoch, synchronousEngineStop: false)
        case .resumed(let shouldReconfigure):
            completeResumeTransition(shouldReconfigure: shouldReconfigure)
        }
    }

    func pause() {
        let pauseEpoch = stateLock.withLock { state -> UInt64? in
            guard !state.isPaused else {
                state.autoPausedForSystem = false
                state.activeSystemPauseReasons.removeAll()
                return nil
            }
            let epoch = Self.applyPauseStateLocked(&state)
            syncFastAudioFlagsLocked(state)
            return epoch
        }
        guard let pauseEpoch else { return }
        completePauseTransition(capturedEpoch: pauseEpoch, synchronousEngineStop: false)
    }

    func resume() {
        let shouldReconfigure = stateLock.withLock { state -> Bool? in
            guard state.isPaused else { return nil }
            let res = Self.applyResumeStateLocked(&state)
            syncFastAudioFlagsLocked(state)
            return res
        }
        guard let shouldReconfigure else { return }
        completeResumeTransition(shouldReconfigure: shouldReconfigure)
    }

    private static func applyPauseStateLocked(_ state: inout CoordinatorState) -> UInt64 {
        state.isPaused = true
        state.isAudioCapturing = false
        state.isMicCapturing = false
        state.isSystemAudioTapDenied = false
        state.autoPausedForSystem = false
        state.activeSystemPauseReasons.removeAll()
        state.uiDeliveryEpoch &+= 1
        state.reconfigureEpoch &+= 1
        resetCachedEngineConfigLocked(&state)
        return state.reconfigureEpoch
    }

    private static func applyResumeStateLocked(_ state: inout CoordinatorState) -> Bool {
        state.isPaused = false
        state.autoPausedForSystem = false
        state.activeSystemPauseReasons.removeAll()
        state.reconfigureEpoch &+= 1
        resetCachedEngineConfigLocked(&state)
        return state.isStarted
    }

    private func completePauseTransition(capturedEpoch: UInt64, synchronousEngineStop: Bool) {
        cancelDelayedDeniedRecovery()
        cancelModelCheckTask()
        clearAllAlerts()
        schedulePauseCacheClearTask(capturedEpoch: capturedEpoch)
        liveShareManager.broadcastPauseState(true)
        onMain { [weak self] in
            self?._viewModel?.callerLevel = 0
            self?._viewModel?.micLevel = 0
            self?.delegate?.coordinatorDidUpdateAudioLevels(callerLevel: 0, micLevel: 0)
        }
        syncViewModelBasicState()
        postNotificationOnMain(Self.pauseStateDidChangeNotification)

        let stopEngines: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            let stillPausedOrStopped = self.stateLock.withLock { $0.isPaused || !$0.isStarted }
            guard stillPausedOrStopped else { return }
            self.audioCaptureEngine.stop()
            self.speechRecognitionManager.stop()
        }
        if synchronousEngineStop {
            runOnLifecycleQueueSync(stopEngines)
        } else {
            lifecycleQueue.async(execute: stopEngines)
        }
    }

    private func completeResumeTransition(shouldReconfigure: Bool) {
        cancelModelCheckTask()
        if shouldReconfigure {
            liveShareManager.broadcastPauseState(false)
            lifecycleQueue.async { [weak self] in
                self?.reconfigureEnginesOnLifecycleQueue()
            }
        }
        syncViewModelBasicState()
        postNotificationOnMain(Self.pauseStateDidChangeNotification)
    }

    func autoPauseForSystem(reason: SystemPauseReason = .systemSleep) {
        let pauseEpoch = stateLock.withLock { state -> UInt64? in
            if state.isPaused {
                if state.autoPausedForSystem {
                    _ = state.activeSystemPauseReasons.insert(reason)
                }
                return nil
            }
            let epoch = Self.applyPauseStateLocked(&state)
            state.autoPausedForSystem = true
            state.activeSystemPauseReasons = [reason]
            syncFastAudioFlagsLocked(state)
            return epoch
        }
        guard let pauseEpoch else { return }
        completePauseTransition(capturedEpoch: pauseEpoch, synchronousEngineStop: true)
    }

    func autoResumeAfterSystem(reason: SystemPauseReason = .systemSleep) {
        let shouldReconfigure = stateLock.withLock { state -> Bool? in
            state.activeSystemPauseReasons.remove(reason)
            guard state.autoPausedForSystem && state.isPaused && state.activeSystemPauseReasons.isEmpty else {
                return nil
            }
            let res = Self.applyResumeStateLocked(&state)
            syncFastAudioFlagsLocked(state)
            return res
        }
        guard let shouldReconfigure else { return }
        completeResumeTransition(shouldReconfigure: shouldReconfigure)
    }

    private func cancelDelayedDeniedRecovery() {
        let box = deniedRecoveryLock.withLock { item -> WorkItemBox? in
            let existing = item
            item = nil
            return existing
        }
        box?.item.cancel()
    }

    private func scheduleDelayedDeniedRecovery(after delay: TimeInterval) {
        let box = WorkItemBox(item: DispatchWorkItem { [weak self] in
            self?.recoverEnginesOnLifecycleQueue()
        })
        let prev = deniedRecoveryLock.withLock { item -> WorkItemBox? in
            let old = item
            item = box
            return old
        }
        prev?.item.cancel()
        lifecycleQueue.asyncAfter(deadline: .now() + delay, execute: box.item)
    }

    func recoverEnginesIfNeeded() {
        let snapshot = stateLock.withLock { state -> (
            started: Bool,
            paused: Bool,
            micWanted: Bool,
            tapDeniedFlag: Bool,
            hasSpeechAlert: Bool,
            hasTranslationAlert: Bool
        ) in
            let hasSpeechAlert = state.activeAlerts.keys.contains { scope in
                if case .speechAuth = scope { return true }
                return false
            }
            return (
                state.isStarted,
                state.isPaused,
                state.isConversationalMode,
                state.isSystemAudioTapDenied,
                hasSpeechAlert,
                state.activeAlerts[.translationSettings] != nil
            )
        }
        guard snapshot.started, !snapshot.paused else { return }

        let tapDenied = snapshot.tapDeniedFlag
            || PermissionHelper.shared.audioCaptureState == .deniedSilenceDetected
        let audioHealthy = audioCaptureEngine.isRunning && !tapDenied
        let micHealthy = !snapshot.micWanted || audioCaptureEngine.isMicRunning
        let speechHealthy = speechRecognitionManager.isRunning && !snapshot.hasSpeechAlert

        if audioHealthy && micHealthy && speechHealthy && !snapshot.hasTranslationAlert {
            return
        }

        lifecycleQueue.async { [weak self] in
            self?.recoverEnginesOnLifecycleQueue()
        }
    }

    private func recoverEnginesOnLifecycleQueue() {
        let (started, paused, lastDeniedAttempt, micWanted, hasSpeechAlert, hasTranslationAlert) = stateLock.withLock {
            state -> (Bool, Bool, TimeInterval, Bool, Bool, Bool) in
            let speechAlert = state.activeAlerts.keys.contains { scope in
                if case .speechAuth = scope { return true }
                return false
            }
            return (
                state.isStarted,
                state.isPaused,
                state.lastDeniedRecoveryAttemptTime,
                state.isConversationalMode,
                speechAlert,
                state.activeAlerts[.translationSettings] != nil
            )
        }
        guard started, !paused else { return }

        if !audioCaptureEngine.isRunning {
            reconfigureEnginesOnLifecycleQueue()
            syncViewModelBasicState()
            return
        }
        if PermissionHelper.shared.audioCaptureState == .deniedSilenceDetected {
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - lastDeniedAttempt
            if elapsed >= 5.0 {
                cancelDelayedDeniedRecovery()
                stateLock.withLock {
                    $0.lastDeniedRecoveryAttemptTime = now
                    $0.isSystemAudioTapDenied = true
                }
                audioCaptureEngine.stop()
                reconfigureEnginesOnLifecycleQueue()
                syncViewModelBasicState()
            } else {
                let remaining = max(0.15, 5.0 - elapsed + 0.05)
                scheduleDelayedDeniedRecovery(after: remaining)
            }
            return
        }
        if micWanted && !audioCaptureEngine.isMicRunning {
            audioCaptureEngine.setMicrophoneEnabled(true)
            let micRunning = audioCaptureEngine.isMicRunning
            stateLock.withLock { state in
                state.isMicCapturing = state.isStarted && !state.isPaused && state.isConversationalMode && micRunning
            }
        }
        if !speechRecognitionManager.isRunning {
            SupportedLanguages.invalidateLocaleResolutionCache()
            reconfigureEnginesOnLifecycleQueue()
        } else if hasSpeechAlert {
            SupportedLanguages.invalidateLocaleResolutionCache()
            speechRecognitionManager.revalidateAuthorizationAndStatus()
        }
        if hasTranslationAlert {
            scheduleCurrentModelCheckOnLifecycleQueue(clearCacheFirst: false)
        }
        syncViewModelBasicState()
    }

    func retryAudioCapture() {
        cancelDelayedDeniedRecovery()
        PermissionHelper.shared.updateAudioCaptureState(.unknown)
        let (started, paused) = stateLock.withLock { state -> (Bool, Bool) in
            state.lastDeniedRecoveryAttemptTime = 0
            state.isSystemAudioTapDenied = false
            return (state.isStarted, state.isPaused)
        }
        clearAlertScope(.systemAudioCapture)
        if !started {
            start()
            return
        }
        if paused {
            resume()
            return
        }
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            let stillActive = self.stateLock.withLock { $0.isStarted && !$0.isPaused }
            guard stillActive else { return }
            self.audioCaptureEngine.stop()
            self.reconfigureEnginesOnLifecycleQueue()
            self.syncViewModelBasicState()
        }
    }

    func retryAlertAction() {
        let activeScope = stateLock.withLock { $0.presentedAlert?.scope }
        switch activeScope {
        case .systemAudioCapture, .none:
            retryAudioCapture()
        case .microphoneCapture:
            let (started, paused, micWanted) = stateLock.withLock {
                ($0.isStarted, $0.isPaused, $0.isConversationalMode)
            }
            guard started, !paused, micWanted else { return }
            clearAlertScope(.microphoneCapture)
            lifecycleQueue.async { [weak self] in
                guard let self else { return }
                let stillActive = self.stateLock.withLock { $0.isStarted && !$0.isPaused && $0.isConversationalMode }
                guard stillActive else { return }
                self.audioCaptureEngine.setMicrophoneEnabled(false)
                self.audioCaptureEngine.setMicrophoneEnabled(true)
                let micRunning = self.audioCaptureEngine.isMicRunning
                self.stateLock.withLock { state in
                    if state.isStarted && !state.isPaused && state.isConversationalMode {
                        state.isMicCapturing = micRunning
                    }
                }
                self.syncViewModelBasicState()
            }
        case .speechAuth:
            let (started, paused) = stateLock.withLock { ($0.isStarted, $0.isPaused) }
            guard started, !paused else { return }
            clearAlertScope(.speechAuth(channel: "caller"))
            clearAlertScope(.speechAuth(channel: "mic"))
            clearAlertScope(.speechAuth(channel: "general"))
            lifecycleQueue.async { [weak self] in
                guard let self else { return }
                SupportedLanguages.invalidateLocaleResolutionCache()
                let stillActive = self.stateLock.withLock { state -> Bool in
                    guard state.isStarted && !state.isPaused else { return false }
                    Self.resetCachedEngineConfigLocked(&state)
                    return true
                }
                guard stillActive else { return }
                self.reconfigureEnginesOnLifecycleQueue()
                self.syncViewModelBasicState()
            }
        case .translationSettings:
            clearAlertScope(.translationSettings)
            let (started, paused) = stateLock.withLock { ($0.isStarted, $0.isPaused) }
            guard started, !paused else { return }
            lifecycleQueue.async { [weak self] in
                self?.scheduleCurrentModelCheckOnLifecycleQueue(clearCacheFirst: false, resetCooldownFirst: true)
            }
        case .general:
            recoverEnginesIfNeeded()
        }
    }

    // MARK: - Settings & Configuration

    func setCallerLanguage(_ code: String) {
        let normalized = SupportedLanguages.item(forCode: code)?.code ?? code.lowercased()
        let changed = stateLock.withLock { state -> Bool in
            guard state.callerLanguageCode != normalized else { return false }
            state.callerLanguageCode = normalized
            return true
        }
        guard changed else { return }
        defaults.set(normalized, forKey: DefaultsKey.callerLanguageCode)
        clearAlertScope(.speechAuth(channel: "caller"))
        clearAlertScope(.speechAuth(channel: "general"))
        clearAlertScope(.translationSettings)
        syncLiveShareConfig()
        onMain { [weak self] in
            guard let self else { return }
            let latest = self.stateLock.withLock { $0.callerLanguageCode }
            self._viewModel?.callerLanguageCode = latest
        }
        reconfigureEngines()
    }

    func setMyLanguage(_ code: String) {
        let normalized = SupportedLanguages.item(forCode: code)?.code ?? code.lowercased()
        let changed = stateLock.withLock { state -> Bool in
            guard state.myLanguageCode != normalized else { return false }
            state.myLanguageCode = normalized
            return true
        }
        guard changed else { return }
        defaults.set(normalized, forKey: DefaultsKey.myLanguageCode)
        clearAlertScope(.speechAuth(channel: "mic"))
        clearAlertScope(.speechAuth(channel: "general"))
        clearAlertScope(.translationSettings)
        syncLiveShareConfig()
        onMain { [weak self] in
            guard let self else { return }
            let latest = self.stateLock.withLock { $0.myLanguageCode }
            self._viewModel?.myLanguageCode = latest
        }
        reconfigureEngines()
    }

    func swapLanguages() {
        guard let (newCaller, newMy) = stateLock.withLock({ state -> (String, String)? in
            if state.callerLanguageCode == state.myLanguageCode {
                return nil
            }
            let oldCaller = state.callerLanguageCode
            let oldMy = state.myLanguageCode
            state.callerLanguageCode = oldMy
            state.myLanguageCode = oldCaller
            return (oldMy, oldCaller)
        }) else {
            return
        }
        defaults.set(newCaller, forKey: DefaultsKey.callerLanguageCode)
        defaults.set(newMy, forKey: DefaultsKey.myLanguageCode)
        if newCaller != newMy {
            clearAlertScope(.speechAuth(channel: "caller"))
            clearAlertScope(.speechAuth(channel: "mic"))
            clearAlertScope(.speechAuth(channel: "general"))
            clearAlertScope(.translationSettings)
        }
        syncLiveShareConfig()
        onMain { [weak self] in
            guard let self else { return }
            let (latestCaller, latestMy) = self.stateLock.withLock { ($0.callerLanguageCode, $0.myLanguageCode) }
            self._viewModel?.callerLanguageCode = latestCaller
            self._viewModel?.myLanguageCode = latestMy
        }
        reconfigureEngines()
    }

    func setConversationalMode(_ enabled: Bool) {
        let (changed, needsReconfigure) = stateLock.withLock { state -> (Bool, Bool) in
            guard state.isConversationalMode != enabled else {
                return (false, false)
            }
            state.isConversationalMode = enabled
            if !enabled {
                state.isMicCapturing = false
            }
            syncFastAudioFlagsLocked(state)
            return (true, state.isStarted && !state.isPaused)
        }
        guard changed else { return }
        defaults.set(enabled, forKey: DefaultsKey.isConversationalMode)
        if !enabled {
            clearAlertScope(.speechAuth(channel: "mic"))
            clearAlertScope(.microphoneCapture)
        }
        onMain { [weak self] in
            guard let self else { return }
            let (latestConv, latestMicCapturing) = self.stateLock.withLock {
                ($0.isConversationalMode, $0.isMicCapturing)
            }
            self._viewModel?.isConversationalMode = latestConv
            if !latestConv {
                self._viewModel?.micLevel = 0
                self._viewModel?.isMicCapturing = latestMicCapturing
            }
        }
        if needsReconfigure {
            reconfigureEngines()
        }
    }

    func setShowOriginalText(_ show: Bool) {
        stateLock.withLock { $0.showOriginalText = show }
        defaults.set(show, forKey: DefaultsKey.showOriginalText)
        onMain { [weak self] in self?._viewModel?.showOriginalText = show }
    }

    func setPinned(_ pinned: Bool) {
        stateLock.withLock { $0.isPinned = pinned }
        defaults.set(pinned, forKey: DefaultsKey.isPinned)
        onMain { [weak self] in
            self?._viewModel?.isPinned = pinned
            NotificationCenter.default.post(name: Self.pinStateDidChangeNotification, object: self)
        }
    }

    func setHideFromScreenSharing(_ enabled: Bool) {
        let changed = stateLock.withLock { state -> Bool in
            guard state.hideFromScreenSharing != enabled else { return false }
            state.hideFromScreenSharing = enabled
            return true
        }
        guard changed else { return }
        defaults.set(enabled, forKey: DefaultsKey.hideFromScreenSharing)
        onMain { [weak self] in
            self?._viewModel?.hideFromScreenSharing = enabled
            NotificationCenter.default.post(name: Self.screenSharingPrivacyDidChangeNotification, object: self)
        }
    }

    func setCompactFloatingHUD(_ compact: Bool) {
        let changed = stateLock.withLock { state -> Bool in
            guard state.isCompactFloatingHUD != compact else { return false }
            state.isCompactFloatingHUD = compact
            return true
        }
        guard changed else { return }
        defaults.set(compact, forKey: DefaultsKey.isCompactFloatingHUD)
        onMain { [weak self] in
            self?._viewModel?.isCompactFloatingHUD = compact
            NotificationCenter.default.post(name: Self.compactFloatingHUDDidChangeNotification, object: self)
        }
    }

    func setCaptionFontSize(_ size: Double) {
        let clamped = min(Self.maxCaptionFontSize, max(Self.minCaptionFontSize, size))
        let changed = stateLock.withLock { state -> Bool in
            guard abs(state.captionFontSize - clamped) > 0.01 else { return false }
            state.captionFontSize = clamped
            return true
        }
        guard changed else { return }
        defaults.set(clamped, forKey: DefaultsKey.captionFontSize)
        onMain { [weak self] in
            self?._viewModel?.captionFontSize = clamped
        }
    }

    func increaseFontSize() {
        let current = stateLock.withLock { $0.captionFontSize }
        setCaptionFontSize(current + 2.0)
    }

    func decreaseFontSize() {
        let current = stateLock.withLock { $0.captionFontSize }
        setCaptionFontSize(current - 2.0)
    }

    func resetFontSize() {
        setCaptionFontSize(Self.defaultCaptionFontSize)
    }

    func setAppearanceMode(_ mode: AppAppearanceMode) {
        let changed = stateLock.withLock { state -> Bool in
            guard state.appearanceMode != mode else { return false }
            state.appearanceMode = mode
            return true
        }
        guard changed else { return }
        defaults.set(mode.rawValue, forKey: DefaultsKey.appearanceMode)
        onMain { [weak self] in
            self?._viewModel?.appearanceMode = mode
            NotificationCenter.default.post(name: Self.appearanceDidChangeNotification, object: self)
        }
    }

    func setLevelMeteringVisible(_ visible: Bool) {
        audioCaptureEngine.setLevelMeteringVisible(visible)
        if !visible {
            onMain { [weak self] in
                self?._viewModel?.callerLevel = 0
                self?._viewModel?.micLevel = 0
            }
        }
    }

    func copyString(_ value: String) {
        guard !value.isEmpty else { return }
        onMain {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }
    }

    @MainActor
    static func postAccessibilityAnnouncement(_ message: String) {
        guard !message.isEmpty,
              ProcessInfo.processInfo.environment["CALLCAPTION_TEST"] != "1",
              let app = NSApp else {
            return
        }
        let target: Any = app.keyWindow ?? app.mainWindow ?? app
        NSAccessibility.post(
            element: target,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    func setShareOptions(allowLAN: Bool? = nil, useTunnel: Bool? = nil, bothSpeakers: Bool? = nil) {
        let snapshot = stateLock.withLock { state -> (Bool, Bool, Bool) in
            if let allowLAN { state.shareAllowLAN = allowLAN }
            if let useTunnel { state.shareUseTunnel = useTunnel }
            if let bothSpeakers { state.shareBothSpeakers = bothSpeakers }
            return (state.shareAllowLAN, state.shareUseTunnel, state.shareBothSpeakers)
        }
        if let allowLAN { defaults.set(allowLAN, forKey: DefaultsKey.shareAllowLAN) }
        if let useTunnel { defaults.set(useTunnel, forKey: DefaultsKey.shareUseTunnel) }
        if let bothSpeakers { defaults.set(bothSpeakers, forKey: DefaultsKey.shareBothSpeakers) }
        syncLiveShareConfig()
        onMain { [weak self] in
            self?._viewModel?.shareAllowLAN = snapshot.0
            self?._viewModel?.shareUseTunnel = snapshot.1
            self?._viewModel?.shareBothSpeakers = snapshot.2
        }
    }

    private func syncLiveShareConfig() {
        let cfg = stateLock.withLock {
            (
                $0.shareAllowLAN,
                $0.shareUseTunnel,
                $0.shareBothSpeakers,
                $0.callerLanguageCode,
                $0.myLanguageCode
            )
        }
        liveShareManager.configure(
            allowLAN: cfg.0,
            useExternalTunnel: cfg.1,
            shareBothSpeakers: cfg.2,
            foreignLanguageCode: cfg.3,
            mainLanguageCode: cfg.4
        )
    }

    // MARK: - Live Share & Transcript Actions

    func toggleSharing() {
        if liveShareManager.isSharing {
            stopSharing()
        } else {
            startSharing()
        }
    }

    func startSharing() {
        if isPaused {
            resume()
        }
        let cfg = stateLock.withLock {
            (
                $0.shareAllowLAN,
                $0.shareUseTunnel,
                $0.shareBothSpeakers,
                $0.callerLanguageCode,
                $0.myLanguageCode
            )
        }
        liveShareManager.startSharing(
            allowLAN: cfg.0,
            useExternalTunnel: cfg.1,
            shareBothSpeakers: cfg.2,
            foreignLanguageCode: cfg.3,
            mainLanguageCode: cfg.4
        )
        liveShareManager.broadcastPauseState(isPaused)
    }

    func stopSharing() {
        liveShareManager.stopSharing()
    }

    func retryTunnel() {
        liveShareManager.retryTunnel()
    }

    func retryShare() {
        if liveShareManager.isSharing {
            retryTunnel()
        } else {
            startSharing()
        }
    }

    func dismissShareRotationNotice() {
        liveShareManager.acknowledgePublicLinkRotation()
    }

    func dismissShareError() {
        liveShareManager.clearServerError()
    }

    func copyShareLink() {
        guard let url = liveShareManager.effectiveShareURL else { return }
        onMain { [weak self] in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            guard let self else { return }
            let vm = self.viewModel
            vm.copiedLinkFeedback = true
            self.copyLinkFeedbackTask?.cancel()
            self.copyLinkFeedbackTask = Task { @MainActor [weak vm] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                vm?.copiedLinkFeedback = false
            }
            Self.postAccessibilityAnnouncement(AppL10n.string("share.copied", fallback: "Copied"))
        }
    }

    @MainActor
    @discardableResult
    func copyTranscript() -> String {
        let callerLabel = AppL10n.string("copy.speaker.caller", fallback: "Caller")
        let youLabel = AppL10n.string("copy.speaker.you", fallback: "You")
        let formatted = viewModel.entries.map { entry -> String in
            let speakerLabel: String
            switch entry.speaker {
            case "Caller": speakerLabel = callerLabel
            case "You": speakerLabel = youLabel
            default: speakerLabel = entry.speaker
            }
            let header = "[\(speakerLabel)] \(entry.translated)"
            if viewModel.showOriginalText,
               entry.original.caseInsensitiveCompare(entry.translated) != .orderedSame {
                return "\(header)\n(\(entry.original))"
            }
            return header
        }.joined(separator: "\n\n")

        if !formatted.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(formatted, forType: .string)
            let vm = viewModel
            vm.copiedTranscriptFeedback = true
            copyTranscriptFeedbackTask?.cancel()
            copyTranscriptFeedbackTask = Task { @MainActor [weak vm] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                vm?.copiedTranscriptFeedback = false
            }
            Self.postAccessibilityAnnouncement(AppL10n.string("share.copied", fallback: "Copied"))
        }
        return formatted
    }

    func clearTranscript() {
        stateLock.withLock { $0.uiDeliveryEpoch &+= 1 }
        speechRecognitionManager.discardInFlight()
        liveShareManager.clearHistoryForPrivacy()
        onMain { [weak self] in
            self?._viewModel?.clearAllEntries()
            NotificationCenter.default.post(name: Self.didDiscardInFlightSpeechNotification, object: self)
        }
    }

    @MainActor
    private func refreshShareStateOnMain() {
        guard let vm = _viewModel else { return }
        let sharing = liveShareManager.isSharing
        let primary = liveShareManager.effectiveShareURL
        let local = liveShareManager.displayLANURL
        let viewers = liveShareManager.activeClientCount
        let serverErr = liveShareManager.serverError
        let tunnelErr = liveShareManager.tunnelError
        let tunnelStarting = liveShareManager.isTunnelStarting
        let isPublic = liveShareManager.publicShareURL != nil
        let lanUnavailable = liveShareManager.lanIPUnavailable
        let linkRotated = liveShareManager.publicLinkRotated

        vm.isSharing = sharing
        vm.primaryShareURL = primary
        vm.localShareURL = local
        vm.viewerCount = viewers
        vm.shareLANIPUnavailable = lanUnavailable
        vm.sharePublicLinkRotated = linkRotated

        if !sharing {
            if let serverErr {
                vm.shareStatus = .failed(localURL: nil, errorText: serverErr)
            } else {
                vm.shareStatus = .off
            }
        } else if let primary, isPublic {
            vm.shareStatus = .ready(primaryURL: primary, localURL: local, isPublic: true, viewerCount: viewers)
        } else if tunnelStarting {
            vm.shareStatus = .connectingTunnel(
                localURL: local,
                statusText: tunnelErr ?? AppL10n.string("share.connecting_tunnel", fallback: "Connecting public link…")
            )
        } else if let tunnelErr {
            vm.shareStatus = .failed(localURL: local, errorText: tunnelErr)
        } else if let primary {
            vm.shareStatus = .ready(primaryURL: primary, localURL: local, isPublic: false, viewerCount: viewers)
        } else if !tunnelStarting, tunnelErr == nil, let fallbackLocal = liveShareManager.localShareURL {
            vm.shareStatus = .ready(primaryURL: fallbackLocal, localURL: nil, isPublic: false, viewerCount: viewers)
        } else {
            vm.shareStatus = .startingLocal
        }
    }

    // MARK: - Engine Reconfiguration

    func reconfigureEngines() {
        lifecycleQueue.async { [weak self] in
            self?.reconfigureEnginesOnLifecycleQueue()
        }
    }

    private struct ModelCheckConfig: Sendable {
        let callerSource: String
        let callerTarget: String
        let callerName: String
        let checkCaller: Bool
        let micSource: String
        let micTarget: String
        let myName: String
        let checkMic: Bool
        let isMicEnabled: Bool
    }

    private static func makeModelCheckConfig(
        callerCode: String,
        myCode: String,
        isMicEnabled: Bool,
        callerLocale: String? = nil,
        myLocale: String? = nil
    ) -> ModelCheckConfig {
        let resolvedCallerLocale = callerLocale ?? SupportedLanguages.bestLocale(forCode: callerCode).identifier
        let resolvedMyLocale = myLocale ?? SupportedLanguages.bestLocale(forCode: myCode).identifier
        let sameLanguage = callerCode.lowercased() == myCode.lowercased()
        return ModelCheckConfig(
            callerSource: SupportedLanguages.translationCode(from: resolvedCallerLocale),
            callerTarget: SupportedLanguages.translationCode(from: resolvedMyLocale),
            callerName: SupportedLanguages.item(forCode: callerCode)?.localizedName ?? callerCode,
            checkCaller: !sameLanguage,
            micSource: SupportedLanguages.translationCode(from: resolvedMyLocale),
            micTarget: SupportedLanguages.translationCode(from: resolvedCallerLocale),
            myName: SupportedLanguages.item(forCode: myCode)?.localizedName ?? myCode,
            checkMic: isMicEnabled && !sameLanguage,
            isMicEnabled: isMicEnabled
        )
    }

    private func reconfigureEnginesOnLifecycleQueue() {
        let cfg = stateLock.withLock {
            ($0.isStarted, $0.isPaused, $0.callerLanguageCode, $0.myLanguageCode, $0.isConversationalMode)
        }
        guard cfg.0, !cfg.1 else { return }

        let callerCode = cfg.2
        let myCode = cfg.3
        let isMicEnabled = cfg.4
        let callerLocale = SupportedLanguages.bestLocale(forCode: callerCode).identifier
        let myLocale = SupportedLanguages.bestLocale(forCode: myCode).identifier

        let audioRunningBefore = audioCaptureEngine.isRunning
        let speechRunningBefore = speechRecognitionManager.isRunning
        let micRunningBefore = audioCaptureEngine.isMicRunning

        enum ReconfigurePlan: Sendable {
            case abort
            case noOp
            case retryLatest
            case proceed(
                languagesChanged: Bool,
                micStateChanged: Bool,
                callerSpeechChanged: Bool,
                micSpeechChanged: Bool,
                capturedEpoch: UInt64
            )
        }

        let plan = stateLock.withLock { state -> ReconfigurePlan in
            guard state.isStarted, !state.isPaused else { return .abort }
            if state.callerLanguageCode != callerCode
                || state.myLanguageCode != myCode
                || state.isConversationalMode != isMicEnabled {
                return .retryLatest
            }
            let callerChanged = callerLocale != state.lastForeignLocale
            let micLocaleChanged = myLocale != state.lastMainLocale
            let langChanged = (
                callerChanged ||
                myCode != state.lastTargetCode ||
                micLocaleChanged ||
                callerCode != state.lastMicTargetCode
            )
            let micChanged = (isMicEnabled != state.lastMicEnabled)
            if !langChanged && !micChanged && audioRunningBefore && speechRunningBefore && (!isMicEnabled || micRunningBefore) {
                return .noOp
            }
            state.lastForeignLocale = callerLocale
            state.lastTargetCode = myCode
            state.lastMainLocale = myLocale
            state.lastMicTargetCode = callerCode
            state.lastMicEnabled = isMicEnabled
            state.reconfigureEpoch &+= 1
            return .proceed(
                languagesChanged: langChanged,
                micStateChanged: micChanged,
                callerSpeechChanged: callerChanged,
                micSpeechChanged: micLocaleChanged,
                capturedEpoch: state.reconfigureEpoch
            )
        }

        let languagesChanged: Bool
        let micStateChanged: Bool
        let callerSpeechChanged: Bool
        let micSpeechChanged: Bool
        let capturedEpoch: UInt64
        switch plan {
        case .abort, .noOp:
            return
        case .retryLatest:
            lifecycleQueue.async { [weak self] in
                self?.reconfigureEnginesOnLifecycleQueue()
            }
            return
        case .proceed(let lc, let mc, let csc, let msc, let epoch):
            languagesChanged = lc
            micStateChanged = mc
            callerSpeechChanged = csc
            micSpeechChanged = msc
            capturedEpoch = epoch
        }

        if callerSpeechChanged {
            clearAlertScope(.speechAuth(channel: "caller"))
            clearAlertScope(.speechAuth(channel: "general"))
        }
        if micSpeechChanged || !isMicEnabled {
            clearAlertScope(.speechAuth(channel: "mic"))
        }
        if !isMicEnabled {
            clearAlertScope(.microphoneCapture)
        }

        let modelCfg = Self.makeModelCheckConfig(
            callerCode: callerCode,
            myCode: myCode,
            isMicEnabled: isMicEnabled,
            callerLocale: callerLocale,
            myLocale: myLocale
        )

        cancelModelCheckTask()

        if audioCaptureEngine.isRunning && speechRecognitionManager.isRunning && !languagesChanged && micStateChanged {
            if !isMicEnabled {
                audioCaptureEngine.setMicrophoneEnabled(false)
                speechRecognitionManager.setMicEnabled(
                    false,
                    micLocaleId: myLocale,
                    micTargetLangCode: callerCode
                )
            } else {
                speechRecognitionManager.setMicEnabled(
                    true,
                    micLocaleId: myLocale,
                    micTargetLangCode: callerCode
                )
                audioCaptureEngine.setMicrophoneEnabled(true)
            }
            let micRunningAfter = audioCaptureEngine.isMicRunning
            let stillCurrent = stateLock.withLock { state -> Bool in
                guard state.isStarted, !state.isPaused, state.reconfigureEpoch == capturedEpoch else {
                    return false
                }
                state.isMicCapturing = isMicEnabled && micRunningAfter
                return true
            }
            guard stillCurrent else { return }
            syncViewModelBasicState()
            scheduleModelCheckTask(config: modelCfg, clearCacheFirst: false, resetCooldownFirst: false, capturedEpoch: capturedEpoch)
            return
        }

        speechRecognitionManager.stop()
        clearAlertScope(.translationSettings)

        if audioCaptureEngine.isRunning {
            audioCaptureEngine.setMicrophoneEnabled(isMicEnabled)
            let micRunningAfter = audioCaptureEngine.isMicRunning
            let (stillCurrent, tapDenied) = stateLock.withLock { state -> (Bool, Bool) in
                guard state.isStarted, !state.isPaused, state.reconfigureEpoch == capturedEpoch else {
                    return (false, false)
                }
                let denied = PermissionHelper.shared.audioCaptureState == .deniedSilenceDetected
                    || state.isSystemAudioTapDenied
                state.isAudioCapturing = !denied
                state.isMicCapturing = isMicEnabled && micRunningAfter
                return (true, denied)
            }
            guard stillCurrent else { return }
            if tapDenied {
                setAlert(
                    scope: .systemAudioCapture,
                    message: AppL10n.string(
                        "alert.tap_permission",
                        fallback: "System Audio Recording permission is off. Enable Call Caption under System Audio Recording."
                    ),
                    actionType: .audioCapture,
                    canRetry: true
                )
            }
            syncViewModelBasicState()
        } else {
            do {
                try audioCaptureEngine.start(enableMic: isMicEnabled)
                let audioRunningAfter = audioCaptureEngine.isRunning
                let micRunningAfter = audioCaptureEngine.isMicRunning
                let (stillCurrent, shouldStopStaleAudio, tapDenied) = stateLock.withLock { state -> (Bool, Bool, Bool) in
                    if !state.isStarted || state.isPaused {
                        return (false, true, false)
                    }
                    guard state.reconfigureEpoch == capturedEpoch else {
                        return (false, false, false)
                    }
                    let denied = PermissionHelper.shared.audioCaptureState == .deniedSilenceDetected
                        || state.isSystemAudioTapDenied
                    state.isAudioCapturing = audioRunningAfter && !denied
                    state.isMicCapturing = isMicEnabled && micRunningAfter
                    return (true, false, denied)
                }
                if shouldStopStaleAudio {
                    audioCaptureEngine.stop()
                    return
                }
                guard stillCurrent else { return }
                if !tapDenied {
                    clearAlertScope(.systemAudioCapture)
                } else {
                    setAlert(
                        scope: .systemAudioCapture,
                        message: AppL10n.string(
                            "alert.tap_permission",
                            fallback: "System Audio Recording permission is off. Enable Call Caption under System Audio Recording."
                        ),
                        actionType: .audioCapture,
                        canRetry: true
                    )
                }
                syncViewModelBasicState()
            } catch {
                AppLog.coordinator.error("AudioCaptureEngine start failed: \(error.localizedDescription, privacy: .public)")
                cancelModelCheckTask()
                let stillActive = stateLock.withLock { state -> Bool in
                    Self.resetCachedEngineConfigLocked(&state)
                    state.isAudioCapturing = false
                    state.isMicCapturing = false
                    return state.isStarted && !state.isPaused && state.reconfigureEpoch == capturedEpoch
                }
                onMain { [weak self] in
                    self?._viewModel?.callerLevel = 0
                    self?._viewModel?.micLevel = 0
                    self?.delegate?.coordinatorDidUpdateAudioLevels(callerLevel: 0, micLevel: 0)
                }
                syncViewModelBasicState()
                guard stillActive else { return }
                if case AudioCaptureError.tapPermissionRequired = error {
                    // Permission callback already posts the actionable system audio permission alert if `-60005`.
                    if !stateLock.withLock({ $0.isSystemAudioTapDenied }) {
                        setAlert(
                            scope: .systemAudioCapture,
                            message: AppL10n.string(
                                "alert.tap_permission",
                                fallback: "System Audio Recording permission is off. Enable Call Caption under System Audio Recording."
                            ),
                            actionType: .audioCapture,
                            canRetry: true
                        )
                    }
                    return
                }
                let isMicErr = (error as? AudioCaptureError)?.isMicrophoneError ?? false
                let scope: AlertScope = isMicErr ? .microphoneCapture : .systemAudioCapture
                let action: SystemAlertActionType = isMicErr ? .microphone : .audioCapture
                setAlert(
                    scope: scope,
                    message: Self.formattedAudioAlertMessage(error, isStartupFailure: true),
                    actionType: action,
                    canRetry: true
                )
                return
            }
        }

        guard stateLock.withLock({ $0.isStarted && !$0.isPaused && $0.reconfigureEpoch == capturedEpoch }) else {
            return
        }

        scheduleModelCheckTask(config: modelCfg, clearCacheFirst: languagesChanged, resetCooldownFirst: false, capturedEpoch: capturedEpoch)

        speechRecognitionManager.start(
            callerLocaleId: callerLocale,
            targetLangCode: myCode,
            micLocaleId: myLocale,
            micTargetLangCode: callerCode,
            isMicEnabled: isMicEnabled
        )
    }

    private func scheduleCurrentModelCheckOnLifecycleQueue(clearCacheFirst: Bool = false, resetCooldownFirst: Bool = false) {
        let (started, paused, callerCode, myCode, isMicEnabled, epoch) = stateLock.withLock {
            ($0.isStarted, $0.isPaused, $0.callerLanguageCode, $0.myLanguageCode, $0.isConversationalMode, $0.reconfigureEpoch)
        }
        guard started, !paused else { return }
        let modelCfg = Self.makeModelCheckConfig(callerCode: callerCode, myCode: myCode, isMicEnabled: isMicEnabled)
        cancelModelCheckTask()
        scheduleModelCheckTask(config: modelCfg, clearCacheFirst: clearCacheFirst, resetCooldownFirst: resetCooldownFirst, capturedEpoch: epoch)
    }

    private func cancelModelCheckTask() {
        let task = taskLock.withLock { existing -> Task<Void, Never>? in
            let copy = existing
            existing = nil
            return copy
        }
        task?.cancel()
    }

    private func replaceTrackedTask(_ newTask: Task<Void, Never>) {
        let previous = taskLock.withLock { existing -> Task<Void, Never>? in
            let old = existing
            existing = newTask
            return old
        }
        previous?.cancel()
    }

    private func schedulePauseCacheClearTask(capturedEpoch: UInt64) {
        let newTask = Task { [weak self] in
            guard !Task.isCancelled, let self else { return }
            let stillPaused = self.stateLock.withLock {
                $0.reconfigureEpoch == capturedEpoch && $0.isPaused
            }
            guard !Task.isCancelled, stillPaused else { return }
            await TranslationEngine.shared.clearCache(invalidateFinals: false)
        }
        replaceTrackedTask(newTask)
    }

    private func scheduleModelCheckTask(
        config: ModelCheckConfig,
        clearCacheFirst: Bool,
        resetCooldownFirst: Bool,
        capturedEpoch: UInt64
    ) {
        let newTask = Task { [weak self] in
            guard !Task.isCancelled, let self else { return }
            let isCurrentBeforeClear = self.stateLock.withLock {
                $0.reconfigureEpoch == capturedEpoch && $0.isStarted && !$0.isPaused
            }
            guard !Task.isCancelled, isCurrentBeforeClear else { return }
            if clearCacheFirst {
                await TranslationEngine.shared.clearCache(invalidateFinals: false)
            }
            guard !Task.isCancelled else { return }
            if resetCooldownFirst {
                let stillCurrent = self.stateLock.withLock {
                    $0.reconfigureEpoch == capturedEpoch && $0.isStarted && !$0.isPaused
                }
                guard stillCurrent else { return }
                await TranslationEngine.shared.resetFailureCooldown()
            }
            guard !Task.isCancelled else { return }

            var missingMessage: String? = nil
            var isUnsupported = false
            var callerInstalled = false
            var micInstalled = false

            if config.checkMic {
                let status = await TranslationEngine.shared.checkModelStatus(sourceCode: config.micSource, targetCode: config.micTarget)
                guard !Task.isCancelled else { return }
                micInstalled = (status == .installed)
                if status != .installed {
                    isUnsupported = (status == .unsupported)
                    missingMessage = isUnsupported
                        ? AppL10n.format("alert.translation_unsupported", fallback: "Translation unsupported (%@ → %@)", config.myName, config.callerName)
                        : AppL10n.format("alert.translation_download", fallback: "Download translation model (%@ → %@) in System Settings → Translation Languages", config.myName, config.callerName)
                }
            }
            if missingMessage == nil, config.checkCaller {
                let status = await TranslationEngine.shared.checkModelStatus(sourceCode: config.callerSource, targetCode: config.callerTarget)
                guard !Task.isCancelled else { return }
                callerInstalled = (status == .installed)
                if status != .installed {
                    isUnsupported = (status == .unsupported)
                    missingMessage = isUnsupported
                        ? AppL10n.format("alert.translation_unsupported", fallback: "Translation unsupported (%@ → %@)", config.callerName, config.myName)
                        : AppL10n.format("alert.translation_download", fallback: "Download translation model (%@ → %@) in System Settings → Translation Languages", config.callerName, config.myName)
                }
            }

            let isCurrent = self.stateLock.withLock {
                $0.reconfigureEpoch == capturedEpoch && $0.isStarted && !$0.isPaused
            }
            guard !Task.isCancelled, isCurrent else { return }
            if let msg = missingMessage {
                self.setAlert(
                    scope: .translationSettings,
                    message: msg,
                    actionType: isUnsupported ? .none : .translationSettings,
                    canRetry: !isUnsupported
                )
            } else {
                self.clearAlertScope(.translationSettings)
            }

            if config.checkMic && micInstalled {
                await TranslationEngine.shared.prewarm(sourceCode: config.micSource, targetCode: config.micTarget)
            }
            guard !Task.isCancelled else { return }
            if config.checkCaller && callerInstalled {
                await TranslationEngine.shared.prewarm(sourceCode: config.callerSource, targetCode: config.callerTarget)
            }
        }
        replaceTrackedTask(newTask)
    }

    // MARK: - Alerts

    func dismissPresentedAlert() {
        stateLock.withLock { state in
            guard let presented = state.presentedAlert else { return }
            let signature = "\(presented.actionType)::\(presented.message)"
            for (scope, alert) in state.activeAlerts {
                if alert.message == presented.message && alert.actionType == presented.actionType {
                    state.activeAlerts.removeValue(forKey: scope)
                    state.suppressedAlertsByScope[scope] = signature
                }
            }
            state.suppressedAlertsByScope[presented.scope] = signature
            state.presentedAlert = Self.highestPriorityAlert(in: state.activeAlerts)
        }
        scheduleAlertSync()
    }

    private func setAlert(scope: AlertScope, message: String, actionType: SystemAlertActionType, canRetry: Bool = false) {
        let signature = "\(actionType)::\(message)"
        let changed = stateLock.withLock { state -> Bool in
            if state.suppressedAlertsByScope[scope] == signature {
                return false
            }
            state.suppressedAlertsByScope.removeValue(forKey: scope)
            let newAlert = ActiveAlert(scope: scope, message: message, actionType: actionType, canRetry: canRetry)
            state.activeAlerts[scope] = newAlert
            state.presentedAlert = Self.highestPriorityAlert(in: state.activeAlerts)
            return true
        }
        if changed {
            scheduleAlertSync()
        }
    }

    private func clearAlertScope(_ scope: AlertScope) {
        let changed = stateLock.withLock { state -> Bool in
            state.suppressedAlertsByScope.removeValue(forKey: scope)
            let removed = state.activeAlerts.removeValue(forKey: scope) != nil
            state.presentedAlert = Self.highestPriorityAlert(in: state.activeAlerts)
            return removed
        }
        if changed {
            scheduleAlertSync()
        }
    }

    private func clearAllAlerts() {
        let hadAlerts = stateLock.withLock { state -> Bool in
            let had = !state.activeAlerts.isEmpty || state.presentedAlert != nil
            state.activeAlerts.removeAll()
            state.suppressedAlertsByScope.removeAll()
            state.presentedAlert = nil
            return had
        }
        if hadAlerts {
            scheduleAlertSync()
        }
    }

    private static func highestPriorityAlert(in alerts: [AlertScope: ActiveAlert]) -> ActiveAlert? {
        alerts.max { lhs, rhs in
            if lhs.key.priority != rhs.key.priority {
                return lhs.key.priority < rhs.key.priority
            }
            if lhs.value.message != rhs.value.message {
                return lhs.value.message < rhs.value.message
            }
            return lhs.key.sortKey < rhs.key.sortKey
        }?.value
    }

    private static func formattedAudioAlertMessage(_ error: Error, isStartupFailure: Bool) -> String {
        if let captureErr = error as? AudioCaptureError {
            switch captureErr {
            case .microphonePermissionDenied:
                return captureErr.localizedDescription
            case .tapPermissionRequired:
                return AppL10n.string(
                    "alert.tap_permission",
                    fallback: "System Audio Recording permission is off. Enable Call Caption under System Audio Recording."
                )
            default:
                break
            }
        }
        if isStartupFailure {
            return AppL10n.format("alert.audio_failed", fallback: "Audio capture failed: %@", error.localizedDescription)
        }
        return AppL10n.format("alert.audio_error", fallback: "Audio capture error: %@", error.localizedDescription)
    }

    private func scheduleAlertSync() {
        let shouldSchedule = alertSyncScheduled.withLock { scheduled -> Bool in
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        guard shouldSchedule else { return }
        onMain { [weak self] in
            self?.applyAlertStateOnMain()
        }
    }

    @MainActor
    private func applyAlertStateOnMain() {
        alertSyncScheduled.withLock { $0 = false }
        let transition = stateLock.withLock { state -> (shouldApply: Bool, alert: ActiveAlert?) in
            let target = state.presentedAlert
            if target == state.lastRenderedAlert {
                return (false, target)
            }
            state.lastRenderedAlert = target
            return (true, target)
        }
        guard transition.shouldApply else { return }
        if let alert = transition.alert {
            _viewModel?.alertMessage = alert.message
            _viewModel?.alertAction = alert.actionType
            _viewModel?.showAlertRetryAction = alert.canRetry
            delegate?.coordinatorDidRequestShowAlert(message: alert.message, actionType: alert.actionType)
        } else {
            _viewModel?.alertMessage = nil
            _viewModel?.alertAction = .none
            _viewModel?.showAlertRetryAction = false
            delegate?.coordinatorDidRequestClearAlert()
        }
        NotificationCenter.default.post(name: Self.alertStateDidChangeNotification, object: self)
    }

    // MARK: - AudioCaptureDelegate

    func audioCaptureDidOutputCallerAudio(pcmBuffer: AVAudioPCMBuffer) {
        let paused = (fastAudioFlags.load(ordering: .acquiring) & 1) != 0
        guard !paused else { return }
        let userHasFloor = audioCaptureEngine.isUserSpeaking
        speechRecognitionManager.feedCallerAudioBuffer(pcmBuffer, userHasFloor: userHasFloor)
    }

    func audioCaptureDidOutputMicAudio(pcmBuffer: AVAudioPCMBuffer) {
        let flags = fastAudioFlags.load(ordering: .acquiring)
        let paused = (flags & 1) != 0
        let micEnabled = (flags & 2) != 0
        guard !paused, micEnabled else { return }
        // Buffers reaching this delegate already passed AudioCaptureEngine's echo-aware mic gate.
        speechRecognitionManager.feedMicAudioBuffer(pcmBuffer, isUserSpeaking: true)
    }

    func audioCaptureDidUpdateLevels(callerLevel: Float, micLevel: Float) {
        let flags = fastAudioFlags.load(ordering: .acquiring)
        let paused = (flags & 1) != 0
        let micEnabled = (flags & 2) != 0
        let c = paused ? 0 : callerLevel
        let m = (paused || !micEnabled) ? 0 : micLevel
        onMain { [weak self] in
            guard let self else { return }
            if let vm = self._viewModel {
                if (c == 0 && vm.callerLevel != 0) || abs(vm.callerLevel - c) >= 0.001 {
                    vm.callerLevel = c
                }
                if (m == 0 && vm.micLevel != 0) || abs(vm.micLevel - m) >= 0.001 {
                    vm.micLevel = m
                }
            }
            self.delegate?.coordinatorDidUpdateAudioLevels(callerLevel: c, micLevel: m)
        }
    }

    func audioCaptureDidEncounterError(_ error: Error) {
        if let captureErr = error as? AudioCaptureError, captureErr.isMicrophoneError {
            audioCaptureDidEncounterMicError(error)
            return
        }
        guard stateLock.withLock({ !$0.isPaused }) else { return }
        if case AudioCaptureError.tapPermissionRequired = error {
            audioCaptureDidDetectDeniedTapPermission()
            return
        }
        AppLog.coordinator.error("Audio capture error: \(error.localizedDescription, privacy: .public)")
        stateLock.withLock { $0.isAudioCapturing = false }
        onMain { [weak self] in
            self?._viewModel?.callerLevel = 0
            self?.delegate?.coordinatorDidUpdateAudioLevels(callerLevel: 0, micLevel: 0)
        }
        syncViewModelBasicState()
        setAlert(
            scope: .systemAudioCapture,
            message: Self.formattedAudioAlertMessage(error, isStartupFailure: false),
            actionType: .audioCapture,
            canRetry: true
        )
    }

    func audioCaptureDidDetectDeniedTapPermission() {
        guard stateLock.withLock({ !$0.isPaused }) else { return }
        cancelDelayedDeniedRecovery()
        stateLock.withLock {
            $0.isSystemAudioTapDenied = true
            $0.isAudioCapturing = false
        }
        onMain { [weak self] in
            self?._viewModel?.callerLevel = 0
            self?.delegate?.coordinatorDidUpdateAudioLevels(callerLevel: 0, micLevel: 0)
        }
        syncViewModelBasicState()
        setAlert(
            scope: .systemAudioCapture,
            message: AppL10n.string(
                "alert.tap_permission",
                fallback: "System Audio Recording permission is off. Enable Call Caption under System Audio Recording."
            ),
            actionType: .audioCapture,
            canRetry: true
        )
    }

    func audioCaptureDidRestoreTapPermission() {
        cancelDelayedDeniedRecovery()
        let audioRunning = audioCaptureEngine.isRunning
        stateLock.withLock { state in
            state.isSystemAudioTapDenied = false
            state.isAudioCapturing = state.isStarted && !state.isPaused && audioRunning
        }
        syncViewModelBasicState()
        clearAlertScope(.systemAudioCapture)
    }

    func audioCaptureDidRecoverTap() {
        let shouldHandle = stateLock.withLock { $0.isStarted && !$0.isPaused }
        guard shouldHandle else { return }
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            let (started, paused, micWanted, tapDeniedFlag) = self.stateLock.withLock {
                ($0.isStarted, $0.isPaused, $0.isConversationalMode, $0.isSystemAudioTapDenied)
            }
            guard started, !paused else { return }
            let tapDenied = PermissionHelper.shared.audioCaptureState == .deniedSilenceDetected || tapDeniedFlag
            let audioRunning = self.audioCaptureEngine.isRunning
            let micRunning = self.audioCaptureEngine.isMicRunning
            if !tapDenied {
                self.clearAlertScope(.systemAudioCapture)
                self.stateLock.withLock { state in
                    guard state.isStarted && !state.isPaused else { return }
                    state.isAudioCapturing = audioRunning
                    state.isMicCapturing = micWanted && micRunning
                }
            } else {
                self.stateLock.withLock { state in
                    guard state.isStarted && !state.isPaused else { return }
                    state.isAudioCapturing = false
                    state.isMicCapturing = micWanted && micRunning
                }
            }
            if !self.speechRecognitionManager.isRunning || (micWanted && !micRunning) {
                self.reconfigureEnginesOnLifecycleQueue()
            } else {
                self.speechRecognitionManager.resetFailureState()
            }
            self.syncViewModelBasicState()
        }
    }

    func audioCaptureDidDetectDeniedMicPermission() {
        let shouldHandle = stateLock.withLock { state -> Bool in
            guard !state.isPaused, !(state.isStarted && !state.isConversationalMode) else { return false }
            state.isMicCapturing = false
            return true
        }
        guard shouldHandle else { return }
        onMain { [weak self] in
            self?._viewModel?.micLevel = 0
        }
        syncViewModelBasicState()
        setAlert(
            scope: .microphoneCapture,
            message: AppL10n.string(
                "alert.mic_permission",
                fallback: "Microphone permission is off. Enable Call Caption under Microphone in System Settings."
            ),
            actionType: .microphone,
            canRetry: true
        )
    }

    func audioCaptureDidEncounterMicError(_ error: Error) {
        let shouldHandle = stateLock.withLock { state -> Bool in
            guard !state.isPaused, !(state.isStarted && !state.isConversationalMode) else { return false }
            state.isMicCapturing = false
            return true
        }
        guard shouldHandle else { return }
        AppLog.coordinator.error("Microphone capture error: \(error.localizedDescription, privacy: .public)")
        onMain { [weak self] in
            self?._viewModel?.micLevel = 0
        }
        syncViewModelBasicState()
        setAlert(
            scope: .microphoneCapture,
            message: Self.formattedAudioAlertMessage(error, isStartupFailure: false),
            actionType: .microphone,
            canRetry: true
        )
    }

    func audioCaptureDidRestoreMic() {
        stateLock.withLock { state in
            state.isMicCapturing = state.isStarted && !state.isPaused && state.isConversationalMode
        }
        syncViewModelBasicState()
        clearAlertScope(.microphoneCapture)
    }

    // MARK: - BidirectionalSpeechDelegate

    func callerSpeechDidUpdate(utteranceID: UUID, partialOriginal: String, partialTranslated: String, isUntranslated: Bool) {
        forwardToUI(utteranceID: utteranceID, speaker: "Caller", original: partialOriginal, translated: partialTranslated, sourceLangCode: nil, targetLangCode: nil, isFinal: false, isUntranslated: isUntranslated)
    }

    func callerSpeechDidUpdate(utteranceID: UUID, partialOriginal: String, partialTranslated: String, sourceLangCode: String, targetLangCode: String, isUntranslated: Bool) {
        forwardToUI(utteranceID: utteranceID, speaker: "Caller", original: partialOriginal, translated: partialTranslated, sourceLangCode: sourceLangCode, targetLangCode: targetLangCode, isFinal: false, isUntranslated: isUntranslated)
    }

    func callerSpeechDidFinalize(utteranceID: UUID, original: String, translated: String, isUntranslated: Bool) {
        forwardToUI(utteranceID: utteranceID, speaker: "Caller", original: original, translated: translated, sourceLangCode: nil, targetLangCode: nil, isFinal: true, isUntranslated: isUntranslated)
    }

    func callerSpeechDidFinalize(utteranceID: UUID, original: String, translated: String, sourceLangCode: String, targetLangCode: String, isUntranslated: Bool) {
        forwardToUI(utteranceID: utteranceID, speaker: "Caller", original: original, translated: translated, sourceLangCode: sourceLangCode, targetLangCode: targetLangCode, isFinal: true, isUntranslated: isUntranslated)
    }

    func micSpeechDidUpdate(utteranceID: UUID, partialOriginal: String, partialTranslated: String, isUntranslated: Bool) {
        forwardToUI(utteranceID: utteranceID, speaker: "You", original: partialOriginal, translated: partialTranslated, sourceLangCode: nil, targetLangCode: nil, isFinal: false, isUntranslated: isUntranslated)
    }

    func micSpeechDidUpdate(utteranceID: UUID, partialOriginal: String, partialTranslated: String, sourceLangCode: String, targetLangCode: String, isUntranslated: Bool) {
        forwardToUI(utteranceID: utteranceID, speaker: "You", original: partialOriginal, translated: partialTranslated, sourceLangCode: sourceLangCode, targetLangCode: targetLangCode, isFinal: false, isUntranslated: isUntranslated)
    }

    func micSpeechDidFinalize(utteranceID: UUID, original: String, translated: String, isUntranslated: Bool) {
        forwardToUI(utteranceID: utteranceID, speaker: "You", original: original, translated: translated, sourceLangCode: nil, targetLangCode: nil, isFinal: true, isUntranslated: isUntranslated)
    }

    func micSpeechDidFinalize(utteranceID: UUID, original: String, translated: String, sourceLangCode: String, targetLangCode: String, isUntranslated: Bool) {
        forwardToUI(utteranceID: utteranceID, speaker: "You", original: original, translated: translated, sourceLangCode: sourceLangCode, targetLangCode: targetLangCode, isFinal: true, isUntranslated: isUntranslated)
    }

    func speechRecognitionDidEncounterAuthError(message: String) {
        speechRecognitionDidEncounterAuthError(channelName: "general", message: message)
    }

    func speechRecognitionDidEncounterAuthError(channelName: String, message: String) {
        AppLog.coordinator.warning("Speech issue (\(channelName, privacy: .public)): \(message, privacy: .public)")
        let lower = message.lowercased()
        let localizedDictDisabled = AppL10n.string("speech.error.dictation_disabled", fallback: "Dictation is disabled in System Settings").lowercased()
        let localizedDictReqPrefix = AppL10n.string("speech.error.dictation_required", fallback: "Dictation language required: %@")
            .replacingOccurrences(of: "%@", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let localizedTransPrefix = AppL10n.string("alert.translation_download", fallback: "Download translation model")
            .components(separatedBy: "(")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        let kind: SpeechAuthIssueKind
        if lower.contains("dictation")
            || lower.contains("dictado")
            || lower == localizedDictDisabled
            || (!localizedDictReqPrefix.isEmpty && lower.contains(localizedDictReqPrefix)) {
            kind = .dictationDisabled
        } else if lower.contains("translation")
            || lower.contains("traducción")
            || (!localizedTransPrefix.isEmpty && lower.contains(localizedTransPrefix)) {
            kind = .translationSettings
        } else {
            kind = .speechPermissionDenied
        }
        speechRecognitionDidEncounterIssue(channelName: channelName, kind: kind, message: message)
    }

    func speechRecognitionDidEncounterIssue(channelName: String, kind: SpeechAuthIssueKind, message: String) {
        AppLog.coordinator.warning("Speech issue (\(channelName, privacy: .public)): \(message, privacy: .public)")
        let action: SystemAlertActionType
        let canRetry: Bool
        switch kind {
        case .speechPermissionDenied:
            action = .speechRecognition
            canRetry = true
        case .recognitionError:
            action = .none
            canRetry = true
        case .dictationDisabled, .dictationAssetRequired:
            action = .dictation
            canRetry = true
        case .unsupportedLocale:
            action = .none
            canRetry = false
        case .translationSettings:
            action = .translationSettings
            canRetry = true
        }
        setAlert(scope: .speechAuth(channel: channelName), message: message, actionType: action, canRetry: canRetry)
    }

    func speechRecognitionDidClearAuthError() {
        speechRecognitionDidClearAuthError(channelName: "general")
    }

    func speechRecognitionDidClearAuthError(channelName: String) {
        clearAlertScope(.speechAuth(channel: channelName))
    }

    // MARK: - Caption Delivery

    private func forwardToUI(
        utteranceID: UUID,
        speaker: String,
        original: String,
        translated: String,
        sourceLangCode explicitSourceLang: String?,
        targetLangCode explicitTargetLang: String?,
        isFinal: Bool,
        isUntranslated: Bool
    ) {
        let cleanOrig = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanOrig.isEmpty else { return }

        let (callerLang, myLang, enqueuedEpoch, allowed) = stateLock.withLock { state -> (String, String, UInt64, Bool) in
            let speakerAllowed = !state.isPaused && !(speaker == "You" && state.isStarted && !state.isConversationalMode)
            return (state.callerLanguageCode, state.myLanguageCode, state.uiDeliveryEpoch, speakerAllowed)
        }
        guard allowed || isFinal else { return }
        let sourceLangCode: String
        let targetLangCode: String
        if let explicitSourceLang, !explicitSourceLang.isEmpty,
           let explicitTargetLang, !explicitTargetLang.isEmpty {
            sourceLangCode = explicitSourceLang.lowercased()
            targetLangCode = explicitTargetLang.lowercased()
        } else if speaker == "Caller" {
            sourceLangCode = callerLang.lowercased()
            targetLangCode = myLang.lowercased()
        } else {
            sourceLangCode = myLang.lowercased()
            targetLangCode = callerLang.lowercased()
        }

        let displayTrans = translated.isEmpty ? cleanOrig : translated

        onMain { [weak self] in
            guard let self else { return }
            let isExistingFinal = isFinal && (self._viewModel?.containsUtterance(id: utteranceID) ?? false)
            if !allowed {
                guard isExistingFinal else { return }
            } else {
                let epochMatches = self.stateLock.withLock { $0.uiDeliveryEpoch == enqueuedEpoch }
                guard epochMatches || isExistingFinal else { return }
            }
            let delivered = self.deliverOnMain(
                utteranceID: utteranceID,
                speaker: speaker,
                cleanOrig: cleanOrig,
                displayTrans: displayTrans,
                sourceLangCode: sourceLangCode,
                targetLangCode: targetLangCode,
                isFinal: isFinal,
                isUntranslated: isUntranslated
            )
            guard delivered else { return }
            self.liveShareManager.broadcastCaption(
                speaker: speaker,
                original: cleanOrig,
                translated: displayTrans,
                sourceLangCode: sourceLangCode,
                targetLangCode: targetLangCode,
                isFinal: isFinal,
                isUntranslated: isUntranslated,
                utteranceID: utteranceID
            )
        }
    }

    @MainActor
    @discardableResult
    private func deliverOnMain(
        utteranceID: UUID,
        speaker: String,
        cleanOrig: String,
        displayTrans: String,
        sourceLangCode: String,
        targetLangCode: String,
        isFinal: Bool,
        isUntranslated: Bool
    ) -> Bool {
        let vm = viewModel
        if let idx = vm.finalizedEntries.lastIndex(where: { $0.id == utteranceID }) {
            let prev = vm.finalizedEntries[idx]
            if prev.isFinal && !isFinal { return false }
            if prev.isFinal && !prev.isUntranslated && isUntranslated { return false }
            let updated = CaptionEntry(
                id: utteranceID,
                speaker: speaker,
                original: cleanOrig,
                translated: displayTrans,
                sourceLangCode: sourceLangCode,
                targetLangCode: targetLangCode,
                timestamp: prev.timestamp,
                formattedTime: prev.formattedTime,
                isFinal: isFinal || prev.isFinal,
                isUntranslated: isUntranslated
            )
            if prev == updated { return false }
            vm.finalizedEntries[idx] = updated
        } else {
            let isCallerSpeaker = speaker.caseInsensitiveCompare("caller") == .orderedSame
            let currentLive = isCallerSpeaker ? vm.liveCallerEntry : vm.liveMicEntry
            if let prev = currentLive, prev.id == utteranceID {
                let updated = CaptionEntry(
                    id: utteranceID,
                    speaker: speaker,
                    original: cleanOrig,
                    translated: displayTrans,
                    sourceLangCode: sourceLangCode,
                    targetLangCode: targetLangCode,
                    timestamp: prev.timestamp,
                    formattedTime: prev.formattedTime,
                    isFinal: isFinal,
                    isUntranslated: isUntranslated
                )
                if prev == updated { return false }
                if isFinal {
                    if isCallerSpeaker {
                        vm.liveCallerEntry = nil
                    } else {
                        vm.liveMicEntry = nil
                    }
                    vm.finalizedEntries.append(updated)
                    if vm.finalizedEntries.count > maxEntries {
                        vm.finalizedEntries.removeFirst(vm.finalizedEntries.count - maxEntries)
                    }
                } else {
                    if isCallerSpeaker {
                        vm.liveCallerEntry = updated
                    } else {
                        vm.liveMicEntry = updated
                    }
                }
            } else {
                let now = Date()
                let entry = CaptionEntry(
                    id: utteranceID,
                    speaker: speaker,
                    original: cleanOrig,
                    translated: displayTrans,
                    sourceLangCode: sourceLangCode,
                    targetLangCode: targetLangCode,
                    timestamp: now,
                    isFinal: isFinal,
                    isUntranslated: isUntranslated
                )
                if isFinal {
                    vm.finalizedEntries.append(entry)
                    if vm.finalizedEntries.count > maxEntries {
                        vm.finalizedEntries.removeFirst(vm.finalizedEntries.count - maxEntries)
                    }
                } else {
                    if let displaced = currentLive {
                        vm.finalizedEntries.append(displaced)
                        if vm.finalizedEntries.count > maxEntries {
                            vm.finalizedEntries.removeFirst(vm.finalizedEntries.count - maxEntries)
                        }
                    }
                    if isCallerSpeaker {
                        vm.liveCallerEntry = entry
                    } else {
                        vm.liveMicEntry = entry
                    }
                }
            }
        }

        delegate?.coordinatorDidReceiveSpeech(
            utteranceID: utteranceID,
            speaker: speaker,
            original: cleanOrig,
            translated: displayTrans,
            sourceLangCode: sourceLangCode,
            targetLangCode: targetLangCode,
            isFinal: isFinal,
            isUntranslated: isUntranslated
        )
        return true
    }

    // MARK: - Main Helpers

    private func syncViewModelBasicState() {
        onMain { [weak self] in
            guard let self else { return }
            let snapshot = self.stateLock.withLock {
                BasicStateSnapshot(
                    isPaused: $0.isPaused,
                    isStarted: $0.isStarted,
                    isAudioCapturing: $0.isAudioCapturing,
                    isMicCapturing: $0.isMicCapturing
                )
            }
            var didChange = (self.lastPostedBasicState != snapshot)
            self.lastPostedBasicState = snapshot
            if let vm = self._viewModel {
                if vm.isPaused != snapshot.isPaused {
                    vm.isPaused = snapshot.isPaused
                    didChange = true
                }
                let startingUp = !snapshot.isStarted
                if vm.isStartingUp != startingUp {
                    vm.isStartingUp = startingUp
                    didChange = true
                }
                if vm.isAudioCapturing != snapshot.isAudioCapturing {
                    vm.isAudioCapturing = snapshot.isAudioCapturing
                    didChange = true
                }
                if vm.isMicCapturing != snapshot.isMicCapturing {
                    vm.isMicCapturing = snapshot.isMicCapturing
                    didChange = true
                }
            }
            if didChange {
                NotificationCenter.default.post(name: Self.captureStateDidChangeNotification, object: self)
            }
        }
    }

    private func postNotificationOnMain(_ name: Notification.Name) {
        onMain { [weak self] in
            NotificationCenter.default.post(name: name, object: self)
        }
    }

    private func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { work() }
            }
        }
    }
}
