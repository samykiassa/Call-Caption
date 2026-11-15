import Foundation
import AppKit
import AVFoundation
import Observation
import os

public enum SystemAlertActionType: Sendable, Equatable {
    case none
    case audioCapture
    case microphone
    case speechRecognition
    case dictation
    case translationSettings

    @MainActor
    public func performAction() {
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

    public var actionButtonTitle: String? {
        switch self {
        case .none:
            return nil
        case .audioCapture, .microphone, .speechRecognition, .dictation, .translationSettings:
            return "Open Settings"
        }
    }
}

public struct CaptionEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let speaker: String
    public let original: String
    public let translated: String
    public let sourceLangCode: String
    public let targetLangCode: String
    public let timestamp: Date
    public let isFinal: Bool
    public let isUntranslated: Bool

    public init(
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
        self.isFinal = isFinal
        self.isUntranslated = isUntranslated
    }
}

public enum LiveShareBannerStatus: Equatable, Sendable {
    case off
    case startingLocal
    case connectingTunnel(localURL: URL?, statusText: String)
    case ready(primaryURL: URL, localURL: URL?, isPublic: Bool, viewerCount: Int)
    case failed(localURL: URL?, errorText: String)
}

@MainActor
public protocol CaptionCoordinatorDelegate: AnyObject {
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

@MainActor
@Observable
public final class CaptionViewModel {
    private unowned let coordinator: CaptionCoordinator

    public internal(set) var entries: [CaptionEntry] = []
    public internal(set) var callerLevel: Float = 0
    public internal(set) var micLevel: Float = 0
    public internal(set) var isPaused: Bool = false
    public internal(set) var alertMessage: String? = nil
    public internal(set) var alertAction: SystemAlertActionType = .none

    public internal(set) var callerLanguageCode: String
    public internal(set) var myLanguageCode: String
    public internal(set) var isConversationalMode: Bool
    public internal(set) var showOriginalText: Bool
    public internal(set) var isPinned: Bool
    public internal(set) var shareAllowLAN: Bool
    public internal(set) var shareUseTunnel: Bool
    public internal(set) var shareBothSpeakers: Bool

    public internal(set) var isSharing: Bool = false
    public internal(set) var shareStatus: LiveShareBannerStatus = .off
    public internal(set) var primaryShareURL: URL? = nil
    public internal(set) var localShareURL: URL? = nil
    public internal(set) var viewerCount: Int = 0
    public var showShareOptions: Bool = false
    public var copiedLinkFeedback: Bool = false
    public var copiedTranscriptFeedback: Bool = false

    fileprivate init(
        coordinator: CaptionCoordinator,
        callerLanguageCode: String,
        myLanguageCode: String,
        isConversationalMode: Bool,
        showOriginalText: Bool,
        isPinned: Bool,
        shareAllowLAN: Bool,
        shareUseTunnel: Bool,
        shareBothSpeakers: Bool
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
    }

    public func setCallerLanguage(_ code: String) { coordinator.setCallerLanguage(code) }
    public func setMyLanguage(_ code: String) { coordinator.setMyLanguage(code) }
    public func swapLanguages() { coordinator.swapLanguages() }
    public func setConversationalMode(_ enabled: Bool) { coordinator.setConversationalMode(enabled) }
    public func setShowOriginalText(_ show: Bool) { coordinator.setShowOriginalText(show) }
    public func setPinned(_ pinned: Bool) { coordinator.setPinned(pinned) }
    public func togglePauseResume() { coordinator.togglePauseResume() }
    public func clearTranscript() { coordinator.clearTranscript() }

    @discardableResult
    public func copyTranscript() -> String { coordinator.copyTranscript() }

    public func toggleSharing() { coordinator.toggleSharing() }
    public func retryTunnel() { coordinator.retryTunnel() }
    public func copyShareLink() { coordinator.copyShareLink() }
    public func setShareOptions(allowLAN: Bool? = nil, useTunnel: Bool? = nil, bothSpeakers: Bool? = nil) {
        coordinator.setShareOptions(allowLAN: allowLAN, useTunnel: useTunnel, bothSpeakers: bothSpeakers)
    }

    public func dismissAlert() { coordinator.dismissPresentedAlert() }
    public func openAlertSettings() { alertAction.performAction() }
}

public final class CaptionCoordinator: NSObject, AudioCaptureDelegate, BidirectionalSpeechDelegate, @unchecked Sendable {
    public static let shared = CaptionCoordinator()
    public static let pauseStateDidChangeNotification = Notification.Name("CaptionCoordinatorPauseStateDidChangeNotification")
    public static let pinStateDidChangeNotification = Notification.Name("CaptionCoordinatorPinStateDidChangeNotification")
    public static let didDiscardInFlightSpeechNotification = Notification.Name("CaptionCoordinatorDidDiscardInFlightSpeechNotification")

    private enum DefaultsKey {
        static let callerLanguageCode = "callerLanguageCode"
        static let myLanguageCode = "myLanguageCode"
        static let isConversationalMode = "isConversationalMode"
        static let showOriginalText = "showOriginalText"
        static let isPinned = "isPinned"
        static let shareAllowLAN = "shareAllowLAN"
        static let shareUseTunnel = "shareUseTunnel"
        static let shareBothSpeakers = "shareBothSpeakers"
    }

    private enum AlertScope: Hashable, Sendable {
        case audioCapture
        case speechAuth(channel: String)
        case translationSettings
        case general

        var priority: Int {
            switch self {
            case .audioCapture: return 100
            case .speechAuth: return 80
            case .translationSettings: return 50
            case .general: return 10
            }
        }
    }

    private struct ActiveAlert: Sendable, Equatable {
        let message: String
        let actionType: SystemAlertActionType
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

        var isStarted: Bool = false
        var autoPausedForSystem: Bool = false
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
        var presentedAlert: ActiveAlert?
        var lastRenderedAlert: ActiveAlert?
    }

    public weak var delegate: CaptionCoordinatorDelegate?
    public let audioCaptureEngine = AudioCaptureEngine()
    public let speechRecognitionManager = SpeechRecognitionManager()
    public let liveShareManager: LiveShareManager
    private let defaults: UserDefaults

    private let lifecycleLock = NSRecursiveLock()
    private let stateLock: OSAllocatedUnfairLock<CoordinatorState>
    private let taskLock = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    private let alertSyncScheduled = OSAllocatedUnfairLock(initialState: false)
    private let maxEntries = 500

    private struct ObserverBox: @unchecked Sendable {
        let token: NSObjectProtocol
    }

    @MainActor
    private var _viewModel: CaptionViewModel?
    private let observerLock = OSAllocatedUnfairLock<[ObserverBox]>(initialState: [])

    @MainActor
    public var viewModel: CaptionViewModel {
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
            shareBothSpeakers: cfg.shareBothSpeakers
        )
        vm.isPaused = cfg.isPaused
        vm.alertMessage = cfg.presentedAlert?.message
        vm.alertAction = cfg.presentedAlert?.actionType ?? .none
        _viewModel = vm
        refreshShareStateOnMain()
        return vm
    }

    public var isPaused: Bool {
        stateLock.withLock { $0.isPaused }
    }

    public var isPinned: Bool {
        stateLock.withLock { $0.isPinned }
    }

    public var currentCallerLanguageCode: String {
        stateLock.withLock { $0.callerLanguageCode }
    }

    public var currentMyLanguageCode: String {
        stateLock.withLock { $0.myLanguageCode }
    }

    public var isConversationalMode: Bool {
        stateLock.withLock { $0.isConversationalMode }
    }

    public init(defaults: UserDefaults = .standard, liveShareManager: LiveShareManager = .shared) {
        self.defaults = defaults
        self.liveShareManager = liveShareManager

        let callerCode = defaults.string(forKey: DefaultsKey.callerLanguageCode) ?? "es"
        let myCode = defaults.string(forKey: DefaultsKey.myLanguageCode) ?? "en"
        let conversational = defaults.object(forKey: DefaultsKey.isConversationalMode) as? Bool ?? false
        let showOrig = defaults.object(forKey: DefaultsKey.showOriginalText) as? Bool ?? true
        let pinned = defaults.object(forKey: DefaultsKey.isPinned) as? Bool ?? false
        let allowLAN = defaults.object(forKey: DefaultsKey.shareAllowLAN) as? Bool ?? false
        let useTunnel = defaults.object(forKey: DefaultsKey.shareUseTunnel) as? Bool ?? true
        let bothSpeakers = defaults.object(forKey: DefaultsKey.shareBothSpeakers) as? Bool ?? true

        self.stateLock = OSAllocatedUnfairLock(initialState: CoordinatorState(
            callerLanguageCode: SupportedLanguages.item(forCode: callerCode)?.code ?? "es",
            myLanguageCode: SupportedLanguages.item(forCode: myCode)?.code ?? "en",
            isConversationalMode: conversational,
            showOriginalText: showOrig,
            isPinned: pinned,
            shareAllowLAN: allowLAN,
            shareUseTunnel: useTunnel,
            shareBothSpeakers: bothSpeakers
        ))

        super.init()
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
        let tokens = observerLock.withLock { list -> [ObserverBox] in
            let copy = list
            list.removeAll()
            return copy
        }
        for box in tokens {
            NotificationCenter.default.removeObserver(box.token)
        }
    }

    private static func resetCachedEngineConfigLocked(_ state: inout CoordinatorState) {
        state.lastForeignLocale = nil
        state.lastTargetCode = nil
        state.lastMainLocale = nil
        state.lastMicTargetCode = nil
        state.lastMicEnabled = nil
    }

    // MARK: - Lifecycle

    public func start() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        let shouldConfigure = stateLock.withLock { state -> Bool in
            if state.isStarted {
                return false
            }
            state.isStarted = true
            state.autoPausedForSystem = false
            return true
        }
        if shouldConfigure {
            reconfigureEnginesLocked()
        }
    }

    public func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        stateLock.withLock { state in
            state.isStarted = false
            state.autoPausedForSystem = false
            state.isPaused = false
            state.uiDeliveryEpoch &+= 1
            Self.resetCachedEngineConfigLocked(&state)
        }
        cancelModelCheckTask()
        clearAllAlerts()
        audioCaptureEngine.stop()
        speechRecognitionManager.stop()
        liveShareManager.stopSharing()
        syncViewModelBasicState()
        postNotificationOnMain(Self.pauseStateDidChangeNotification)
    }

    public func togglePauseResume() {
        lifecycleLock.lock()
        let shouldPause = stateLock.withLock { !$0.isPaused }
        let changed = shouldPause ? pauseLocked() : resumeLocked()
        lifecycleLock.unlock()

        if changed {
            syncViewModelBasicState()
            postNotificationOnMain(Self.pauseStateDidChangeNotification)
        }
    }

    public func pause() {
        lifecycleLock.lock()
        let changed = pauseLocked()
        lifecycleLock.unlock()
        if changed {
            syncViewModelBasicState()
            postNotificationOnMain(Self.pauseStateDidChangeNotification)
        }
    }

    public func resume() {
        lifecycleLock.lock()
        let changed = resumeLocked()
        lifecycleLock.unlock()
        if changed {
            syncViewModelBasicState()
            postNotificationOnMain(Self.pauseStateDidChangeNotification)
        }
    }

    private func pauseLocked() -> Bool {
        let alreadyPaused = stateLock.withLock { $0.isPaused }
        guard !alreadyPaused else { return false }

        stateLock.withLock { state in
            state.isPaused = true
            state.autoPausedForSystem = false
            state.uiDeliveryEpoch &+= 1
            Self.resetCachedEngineConfigLocked(&state)
        }
        cancelModelCheckTask()
        clearAllAlerts()
        audioCaptureEngine.stop()
        speechRecognitionManager.stop()
        liveShareManager.broadcastPauseState(true)
        onMain { [weak self] in
            self?._viewModel?.callerLevel = 0
            self?._viewModel?.micLevel = 0
            self?.delegate?.coordinatorDidUpdateAudioLevels(callerLevel: 0, micLevel: 0)
        }
        return true
    }

    private func resumeLocked() -> Bool {
        let canResume = stateLock.withLock { $0.isPaused }
        guard canResume else { return false }

        stateLock.withLock { state in
            state.isStarted = true
            state.isPaused = false
            state.autoPausedForSystem = false
            Self.resetCachedEngineConfigLocked(&state)
        }
        reconfigureEnginesLocked()
        liveShareManager.broadcastPauseState(false)
        return true
    }

    public func autoPauseForSystem() {
        lifecycleLock.lock()
        let shouldPause = stateLock.withLock { state -> Bool in
            guard state.isStarted, !state.isPaused else { return false }
            state.autoPausedForSystem = true
            return true
        }
        guard shouldPause else {
            lifecycleLock.unlock()
            return
        }
        let changed = pauseLocked()
        if changed {
            stateLock.withLock { $0.autoPausedForSystem = true }
        }
        lifecycleLock.unlock()
        if changed {
            syncViewModelBasicState()
            postNotificationOnMain(Self.pauseStateDidChangeNotification)
        }
    }

    public func autoResumeAfterSystem() {
        lifecycleLock.lock()
        let shouldResume = stateLock.withLock { $0.autoPausedForSystem && $0.isPaused }
        guard shouldResume else {
            lifecycleLock.unlock()
            return
        }
        let changed = resumeLocked()
        lifecycleLock.unlock()
        if changed {
            syncViewModelBasicState()
            postNotificationOnMain(Self.pauseStateDidChangeNotification)
        }
    }

    public func recoverEnginesIfNeeded() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        let (started, paused, lastDeniedAttempt, micWanted) = stateLock.withLock {
            ($0.isStarted, $0.isPaused, $0.lastDeniedRecoveryAttemptTime, $0.isConversationalMode)
        }
        guard started, !paused else { return }

        if !audioCaptureEngine.isRunning {
            reconfigureEnginesLocked()
            return
        }
        if PermissionHelper.shared.audioCaptureState == .deniedSilenceDetected {
            let now = ProcessInfo.processInfo.systemUptime
            guard (now - lastDeniedAttempt) >= 5.0 else { return }
            stateLock.withLock { $0.lastDeniedRecoveryAttemptTime = now }
            PermissionHelper.shared.updateAudioCaptureState(.unknown)
            audioCaptureEngine.stop()
            reconfigureEnginesLocked()
            return
        }
        if micWanted && !audioCaptureEngine.isMicRunning {
            audioCaptureEngine.setMicrophoneEnabled(true)
        }
        if !speechRecognitionManager.isRunning {
            reconfigureEnginesLocked()
        } else {
            speechRecognitionManager.resetFailureState()
        }
    }

    public func retryAudioCapture() {
        PermissionHelper.shared.updateAudioCaptureState(.unknown)
        lifecycleLock.lock()
        stateLock.withLock { $0.lastDeniedRecoveryAttemptTime = 0 }
        let (started, paused) = stateLock.withLock { ($0.isStarted, $0.isPaused) }
        if !started {
            lifecycleLock.unlock()
            start()
            return
        }
        if paused {
            let didResume = resumeLocked()
            lifecycleLock.unlock()
            if didResume {
                syncViewModelBasicState()
                postNotificationOnMain(Self.pauseStateDidChangeNotification)
            }
            return
        }
        audioCaptureEngine.stop()
        reconfigureEnginesLocked()
        lifecycleLock.unlock()
    }

    // MARK: - Settings & Configuration

    public func setCallerLanguage(_ code: String) {
        let normalized = SupportedLanguages.item(forCode: code)?.code ?? code.lowercased()
        let changed = stateLock.withLock { state -> Bool in
            guard state.callerLanguageCode != normalized else { return false }
            state.callerLanguageCode = normalized
            return true
        }
        guard changed else { return }
        defaults.set(normalized, forKey: DefaultsKey.callerLanguageCode)
        syncLiveShareConfig()
        onMain { [weak self] in self?._viewModel?.callerLanguageCode = normalized }
        reconfigureEngines()
    }

    public func setMyLanguage(_ code: String) {
        let normalized = SupportedLanguages.item(forCode: code)?.code ?? code.lowercased()
        let changed = stateLock.withLock { state -> Bool in
            guard state.myLanguageCode != normalized else { return false }
            state.myLanguageCode = normalized
            return true
        }
        guard changed else { return }
        defaults.set(normalized, forKey: DefaultsKey.myLanguageCode)
        syncLiveShareConfig()
        onMain { [weak self] in self?._viewModel?.myLanguageCode = normalized }
        reconfigureEngines()
    }

    public func swapLanguages() {
        let (newCaller, newMy) = stateLock.withLock { state -> (String, String) in
            let oldCaller = state.callerLanguageCode
            let oldMy = state.myLanguageCode
            state.callerLanguageCode = oldMy
            state.myLanguageCode = oldCaller
            return (oldMy, oldCaller)
        }
        defaults.set(newCaller, forKey: DefaultsKey.callerLanguageCode)
        defaults.set(newMy, forKey: DefaultsKey.myLanguageCode)
        syncLiveShareConfig()
        onMain { [weak self] in
            self?._viewModel?.callerLanguageCode = newCaller
            self?._viewModel?.myLanguageCode = newMy
        }
        reconfigureEngines()
    }

    public func setConversationalMode(_ enabled: Bool) {
        let changed = stateLock.withLock { state -> Bool in
            guard state.isConversationalMode != enabled else { return false }
            state.isConversationalMode = enabled
            return true
        }
        guard changed else { return }
        defaults.set(enabled, forKey: DefaultsKey.isConversationalMode)
        onMain { [weak self] in
            self?._viewModel?.isConversationalMode = enabled
            if !enabled {
                self?._viewModel?.micLevel = 0
            }
        }
        reconfigureEngines()
    }

    public func setShowOriginalText(_ show: Bool) {
        stateLock.withLock { $0.showOriginalText = show }
        defaults.set(show, forKey: DefaultsKey.showOriginalText)
        onMain { [weak self] in self?._viewModel?.showOriginalText = show }
    }

    public func setPinned(_ pinned: Bool) {
        stateLock.withLock { $0.isPinned = pinned }
        defaults.set(pinned, forKey: DefaultsKey.isPinned)
        onMain { [weak self] in
            self?._viewModel?.isPinned = pinned
            NotificationCenter.default.post(name: Self.pinStateDidChangeNotification, object: self)
        }
    }

    public func setShareOptions(allowLAN: Bool? = nil, useTunnel: Bool? = nil, bothSpeakers: Bool? = nil) {
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

    public func toggleSharing() {
        if liveShareManager.isSharing {
            stopSharing()
        } else {
            startSharing()
        }
    }

    public func startSharing() {
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

    public func stopSharing() {
        liveShareManager.stopSharing()
    }

    public func retryTunnel() {
        liveShareManager.retryTunnel()
    }

    public func copyShareLink() {
        guard let url = liveShareManager.effectiveShareURL else { return }
        onMain {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
    }

    @MainActor
    @discardableResult
    public func copyTranscript() -> String {
        let formatted = viewModel.entries.map { entry -> String in
            let header = "[\(entry.speaker)] \(entry.translated)"
            if viewModel.showOriginalText,
               entry.original.caseInsensitiveCompare(entry.translated) != .orderedSame {
                return "\(header)\n(\(entry.original))"
            }
            return header
        }.joined(separator: "\n\n")

        if !formatted.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(formatted, forType: .string)
        }
        return formatted
    }

    public func clearTranscript() {
        stateLock.withLock { $0.uiDeliveryEpoch &+= 1 }
        speechRecognitionManager.discardInFlight()
        liveShareManager.clearHistoryForPrivacy()
        onMain { [weak self] in
            self?._viewModel?.entries.removeAll()
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
        let tunnelErr = liveShareManager.tunnelError
        let tunnelStarting = liveShareManager.isTunnelStarting
        let isPublic = liveShareManager.publicShareURL != nil

        vm.isSharing = sharing
        vm.primaryShareURL = primary
        vm.localShareURL = local
        vm.viewerCount = viewers

        if !sharing {
            vm.shareStatus = .off
        } else if let primary, isPublic {
            vm.shareStatus = .ready(primaryURL: primary, localURL: local, isPublic: true, viewerCount: viewers)
        } else if tunnelStarting {
            vm.shareStatus = .connectingTunnel(localURL: local, statusText: tunnelErr ?? "Connecting public link…")
        } else if let tunnelErr {
            vm.shareStatus = .failed(localURL: local, errorText: tunnelErr)
        } else if let primary {
            vm.shareStatus = .ready(primaryURL: primary, localURL: local, isPublic: false, viewerCount: viewers)
        } else {
            vm.shareStatus = .startingLocal
        }
    }

    // MARK: - Engine Reconfiguration

    public func reconfigureEngines() {
        lifecycleLock.lock()
        reconfigureEnginesLocked()
        lifecycleLock.unlock()
    }

    private func reconfigureEnginesLocked() {
        let cfg = stateLock.withLock {
            ($0.isStarted, $0.isPaused, $0.callerLanguageCode, $0.myLanguageCode, $0.isConversationalMode)
        }
        guard cfg.0, !cfg.1 else { return }

        let callerCode = cfg.2
        let myCode = cfg.3
        let isMicEnabled = cfg.4
        let callerLocale = SupportedLanguages.bestLocale(forCode: callerCode).identifier
        let myLocale = SupportedLanguages.bestLocale(forCode: myCode).identifier

        let (languagesChanged, micStateChanged, capturedEpoch) = stateLock.withLock { state -> (Bool, Bool, UInt64) in
            let langChanged = (
                callerLocale != state.lastForeignLocale ||
                myCode != state.lastTargetCode ||
                myLocale != state.lastMainLocale ||
                callerCode != state.lastMicTargetCode
            )
            let micChanged = (isMicEnabled != state.lastMicEnabled)
            state.lastForeignLocale = callerLocale
            state.lastTargetCode = myCode
            state.lastMainLocale = myLocale
            state.lastMicTargetCode = callerCode
            state.lastMicEnabled = isMicEnabled
            state.reconfigureEpoch &+= 1
            return (langChanged, micChanged, state.reconfigureEpoch)
        }

        let callerTransSource = SupportedLanguages.translationCode(from: callerLocale)
        let callerTransTarget = SupportedLanguages.translationCode(from: myCode)
        let micTransSource = SupportedLanguages.translationCode(from: myLocale)
        let micTransTarget = SupportedLanguages.translationCode(from: callerLocale)
        let callerName = SupportedLanguages.item(forCode: callerCode)?.name ?? callerCode
        let myName = SupportedLanguages.item(forCode: myCode)?.name ?? myCode
        let checkCaller = callerCode.lowercased() != myCode.lowercased()
        let checkMic = isMicEnabled && myCode.lowercased() != callerCode.lowercased()

        cancelModelCheckTask()

        if audioCaptureEngine.isRunning && speechRecognitionManager.isRunning && !languagesChanged && micStateChanged {
            speechRecognitionManager.setMicEnabled(
                isMicEnabled,
                micLocaleId: myLocale,
                micTargetLangCode: callerCode
            )
            audioCaptureEngine.setMicrophoneEnabled(isMicEnabled)
            scheduleModelCheckTask(
                callerSource: callerTransSource,
                callerTarget: callerTransTarget,
                callerName: callerName,
                myName: myName,
                checkCaller: checkCaller,
                micSource: micTransSource,
                micTarget: micTransTarget,
                checkMic: checkMic,
                isMicEnabled: isMicEnabled,
                clearCacheFirst: false,
                capturedEpoch: capturedEpoch
            )
            return
        }

        speechRecognitionManager.stop()
        clearAlertScope(.translationSettings)

        scheduleModelCheckTask(
            callerSource: callerTransSource,
            callerTarget: callerTransTarget,
            callerName: callerName,
            myName: myName,
            checkCaller: checkCaller,
            micSource: micTransSource,
            micTarget: micTransTarget,
            checkMic: checkMic,
            isMicEnabled: isMicEnabled,
            clearCacheFirst: languagesChanged,
            capturedEpoch: capturedEpoch
        )

        if audioCaptureEngine.isRunning {
            audioCaptureEngine.setMicrophoneEnabled(isMicEnabled)
        } else {
            do {
                try audioCaptureEngine.start(enableMic: isMicEnabled)
                clearAlertScope(.audioCapture)
            } catch {
                AppLog.coordinator.error("AudioCaptureEngine start failed: \(error.localizedDescription, privacy: .public)")
                cancelModelCheckTask()
                stateLock.withLock { Self.resetCachedEngineConfigLocked(&$0) }
                let lower = error.localizedDescription.lowercased()
                let action: SystemAlertActionType = (lower.contains("microphone") || lower.contains("input"))
                    ? .microphone
                    : .audioCapture
                setAlert(scope: .audioCapture, message: "Audio capture failed: \(error.localizedDescription)", actionType: action)
                return
            }
        }

        speechRecognitionManager.start(
            callerLocaleId: callerLocale,
            targetLangCode: myCode,
            micLocaleId: myLocale,
            micTargetLangCode: callerCode,
            isMicEnabled: isMicEnabled
        )
    }

    private func cancelModelCheckTask() {
        let task = taskLock.withLock { existing -> Task<Void, Never>? in
            let copy = existing
            existing = nil
            return copy
        }
        task?.cancel()
    }

    private func scheduleModelCheckTask(
        callerSource: String,
        callerTarget: String,
        callerName: String,
        myName: String,
        checkCaller: Bool,
        micSource: String,
        micTarget: String,
        checkMic: Bool,
        isMicEnabled: Bool,
        clearCacheFirst: Bool,
        capturedEpoch: UInt64
    ) {
        let newTask = Task { [weak self] in
            if clearCacheFirst {
                await TranslationEngine.shared.clearCache()
            }
            guard !Task.isCancelled else { return }

            await TranslationEngine.shared.prewarm(sourceCode: callerSource, targetCode: callerTarget)
            if isMicEnabled {
                await TranslationEngine.shared.prewarm(sourceCode: micSource, targetCode: micTarget)
            }
            guard !Task.isCancelled, let self else { return }

            var missingMessage: String? = nil
            if checkCaller {
                let status = await TranslationEngine.shared.checkModelStatus(sourceCode: callerSource, targetCode: callerTarget)
                guard !Task.isCancelled else { return }
                if status != .installed {
                    missingMessage = (status == .unsupported)
                        ? "Translation unsupported (\(callerName) → \(myName))"
                        : "Download translation model (\(callerName) → \(myName)) in System Settings → Translation Languages"
                }
            }
            if missingMessage == nil, checkMic {
                let status = await TranslationEngine.shared.checkModelStatus(sourceCode: micSource, targetCode: micTarget)
                guard !Task.isCancelled else { return }
                if status != .installed {
                    missingMessage = (status == .unsupported)
                        ? "Translation unsupported (\(myName) → \(callerName))"
                        : "Download translation model (\(myName) → \(callerName)) in System Settings → Translation Languages"
                }
            }

            let isCurrent = self.stateLock.withLock {
                $0.reconfigureEpoch == capturedEpoch && $0.isStarted && !$0.isPaused
            }
            guard !Task.isCancelled, isCurrent else { return }
            if let msg = missingMessage {
                self.setAlert(scope: .translationSettings, message: msg, actionType: .translationSettings)
            } else {
                self.clearAlertScope(.translationSettings)
            }
        }
        taskLock.withLock { $0 = newTask }
    }

    // MARK: - Alerts

    public func dismissPresentedAlert() {
        stateLock.withLock { state in
            guard let presented = state.presentedAlert else { return }
            state.activeAlerts = state.activeAlerts.filter { $0.value != presented }
            state.presentedAlert = Self.highestPriorityAlert(in: state.activeAlerts)
        }
        scheduleAlertSync()
    }

    private func setAlert(scope: AlertScope, message: String, actionType: SystemAlertActionType) {
        stateLock.withLock { state in
            let newAlert = ActiveAlert(message: message, actionType: actionType)
            state.activeAlerts[scope] = newAlert
            state.presentedAlert = Self.highestPriorityAlert(in: state.activeAlerts)
        }
        scheduleAlertSync()
    }

    private func clearAlertScope(_ scope: AlertScope) {
        let changed = stateLock.withLock { state -> Bool in
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
            return lhs.value.message < rhs.value.message
        }?.value
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
            delegate?.coordinatorDidRequestShowAlert(message: alert.message, actionType: alert.actionType)
        } else {
            _viewModel?.alertMessage = nil
            _viewModel?.alertAction = .none
            delegate?.coordinatorDidRequestClearAlert()
        }
    }

    // MARK: - AudioCaptureDelegate

    public func audioCaptureDidOutputCallerAudio(pcmBuffer: AVAudioPCMBuffer) {
        let paused = stateLock.withLock { $0.isPaused }
        guard !paused else { return }
        let userHasFloor = audioCaptureEngine.speechFloorOwner == .user
        speechRecognitionManager.feedCallerAudioBuffer(pcmBuffer, userHasFloor: userHasFloor)
    }

    public func audioCaptureDidOutputMicAudio(pcmBuffer: AVAudioPCMBuffer) {
        let (paused, micEnabled) = stateLock.withLock { ($0.isPaused, $0.isConversationalMode) }
        guard !paused, micEnabled else { return }
        let isUserSpeaking = audioCaptureEngine.speechFloorOwner == .user
        speechRecognitionManager.feedMicAudioBuffer(pcmBuffer, isUserSpeaking: isUserSpeaking)
    }

    public func audioCaptureDidUpdateLevels(callerLevel: Float, micLevel: Float) {
        let (paused, micEnabled) = stateLock.withLock { ($0.isPaused, $0.isConversationalMode) }
        let c = paused ? 0 : callerLevel
        let m = (paused || !micEnabled) ? 0 : micLevel
        onMain { [weak self] in
            self?._viewModel?.callerLevel = c
            self?._viewModel?.micLevel = m
            self?.delegate?.coordinatorDidUpdateAudioLevels(callerLevel: c, micLevel: m)
        }
    }

    public func audioCaptureDidEncounterError(_ error: Error) {
        AppLog.coordinator.error("Audio capture error: \(error.localizedDescription, privacy: .public)")
        let lower = error.localizedDescription.lowercased()
        let action: SystemAlertActionType = (lower.contains("microphone") || lower.contains("input"))
            ? .microphone
            : .audioCapture
        setAlert(scope: .audioCapture, message: "Audio capture error: \(error.localizedDescription)", actionType: action)
    }

    public func audioCaptureDidDetectDeniedTapPermission() {
        setAlert(
            scope: .audioCapture,
            message: "System Audio Recording permission is off. Enable Call Caption under System Audio Recording.",
            actionType: .audioCapture
        )
    }

    public func audioCaptureDidRestoreTapPermission() {
        clearAlertScope(.audioCapture)
    }

    // MARK: - BidirectionalSpeechDelegate

    public func callerSpeechDidUpdate(utteranceID: UUID, partialOriginal: String, partialTranslated: String, isUntranslated: Bool) {
        forwardToUI(utteranceID: utteranceID, speaker: "Caller", original: partialOriginal, translated: partialTranslated, sourceLangCode: nil, targetLangCode: nil, isFinal: false, isUntranslated: isUntranslated)
    }

    public func callerSpeechDidUpdate(utteranceID: UUID, partialOriginal: String, partialTranslated: String, sourceLangCode: String, targetLangCode: String, isUntranslated: Bool) {
        forwardToUI(utteranceID: utteranceID, speaker: "Caller", original: partialOriginal, translated: partialTranslated, sourceLangCode: sourceLangCode, targetLangCode: targetLangCode, isFinal: false, isUntranslated: isUntranslated)
    }

    public func callerSpeechDidFinalize(utteranceID: UUID, original: String, translated: String, isUntranslated: Bool) {
        forwardToUI(utteranceID: utteranceID, speaker: "Caller", original: original, translated: translated, sourceLangCode: nil, targetLangCode: nil, isFinal: true, isUntranslated: isUntranslated)
    }

    public func callerSpeechDidFinalize(utteranceID: UUID, original: String, translated: String, sourceLangCode: String, targetLangCode: String, isUntranslated: Bool) {
        forwardToUI(utteranceID: utteranceID, speaker: "Caller", original: original, translated: translated, sourceLangCode: sourceLangCode, targetLangCode: targetLangCode, isFinal: true, isUntranslated: isUntranslated)
    }

    public func micSpeechDidUpdate(utteranceID: UUID, partialOriginal: String, partialTranslated: String, isUntranslated: Bool) {
        forwardToUI(utteranceID: utteranceID, speaker: "You", original: partialOriginal, translated: partialTranslated, sourceLangCode: nil, targetLangCode: nil, isFinal: false, isUntranslated: isUntranslated)
    }

    public func micSpeechDidUpdate(utteranceID: UUID, partialOriginal: String, partialTranslated: String, sourceLangCode: String, targetLangCode: String, isUntranslated: Bool) {
        forwardToUI(utteranceID: utteranceID, speaker: "You", original: partialOriginal, translated: partialTranslated, sourceLangCode: sourceLangCode, targetLangCode: targetLangCode, isFinal: false, isUntranslated: isUntranslated)
    }

    public func micSpeechDidFinalize(utteranceID: UUID, original: String, translated: String, isUntranslated: Bool) {
        forwardToUI(utteranceID: utteranceID, speaker: "You", original: original, translated: translated, sourceLangCode: nil, targetLangCode: nil, isFinal: true, isUntranslated: isUntranslated)
    }

    public func micSpeechDidFinalize(utteranceID: UUID, original: String, translated: String, sourceLangCode: String, targetLangCode: String, isUntranslated: Bool) {
        forwardToUI(utteranceID: utteranceID, speaker: "You", original: original, translated: translated, sourceLangCode: sourceLangCode, targetLangCode: targetLangCode, isFinal: true, isUntranslated: isUntranslated)
    }

    public func speechRecognitionDidEncounterAuthError(message: String) {
        speechRecognitionDidEncounterAuthError(channelName: "general", message: message)
    }

    public func speechRecognitionDidEncounterAuthError(channelName: String, message: String) {
        AppLog.coordinator.warning("Speech issue (\(channelName, privacy: .public)): \(message, privacy: .public)")
        let lower = message.lowercased()
        let action: SystemAlertActionType
        if lower.contains("dictation") {
            action = .dictation
        } else if lower.contains("speech") {
            action = .speechRecognition
        } else if lower.contains("translation") {
            action = .translationSettings
        } else {
            action = .speechRecognition
        }
        setAlert(scope: .speechAuth(channel: channelName), message: message, actionType: action)
    }

    public func speechRecognitionDidClearAuthError() {
        speechRecognitionDidClearAuthError(channelName: "general")
    }

    public func speechRecognitionDidClearAuthError(channelName: String) {
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

        let (callerLang, myLang, enqueuedEpoch) = stateLock.withLock {
            ($0.callerLanguageCode, $0.myLanguageCode, $0.uiDeliveryEpoch)
        }
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

        liveShareManager.broadcastCaption(
            speaker: speaker,
            original: cleanOrig,
            translated: displayTrans,
            sourceLangCode: sourceLangCode,
            targetLangCode: targetLangCode,
            isFinal: isFinal,
            isUntranslated: isUntranslated,
            utteranceID: utteranceID
        )

        onMain { [weak self] in
            guard let self,
                  self.stateLock.withLock({ $0.uiDeliveryEpoch == enqueuedEpoch }) else { return }
            self.deliverOnMain(
                utteranceID: utteranceID,
                speaker: speaker,
                cleanOrig: cleanOrig,
                displayTrans: displayTrans,
                sourceLangCode: sourceLangCode,
                targetLangCode: targetLangCode,
                isFinal: isFinal,
                isUntranslated: isUntranslated
            )
        }
    }

    @MainActor
    private func deliverOnMain(
        utteranceID: UUID,
        speaker: String,
        cleanOrig: String,
        displayTrans: String,
        sourceLangCode: String,
        targetLangCode: String,
        isFinal: Bool,
        isUntranslated: Bool
    ) {
        if let vm = _viewModel {
            if let idx = vm.entries.firstIndex(where: { $0.id == utteranceID }) {
                let prev = vm.entries[idx]
                vm.entries[idx] = CaptionEntry(
                    id: utteranceID,
                    speaker: speaker,
                    original: cleanOrig,
                    translated: displayTrans,
                    sourceLangCode: sourceLangCode,
                    targetLangCode: targetLangCode,
                    timestamp: prev.timestamp,
                    isFinal: isFinal || prev.isFinal,
                    isUntranslated: isUntranslated
                )
            } else {
                vm.entries.append(CaptionEntry(
                    id: utteranceID,
                    speaker: speaker,
                    original: cleanOrig,
                    translated: displayTrans,
                    sourceLangCode: sourceLangCode,
                    targetLangCode: targetLangCode,
                    timestamp: Date(),
                    isFinal: isFinal,
                    isUntranslated: isUntranslated
                ))
                if vm.entries.count > maxEntries {
                    let overflow = vm.entries.count - maxEntries
                    vm.entries.removeFirst(overflow)
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
    }

    // MARK: - Main Helpers

    private func syncViewModelBasicState() {
        let paused = stateLock.withLock { $0.isPaused }
        onMain { [weak self] in
            self?._viewModel?.isPaused = paused
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
