import Foundation
import AppKit
import AVFoundation
import Speech
import os

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

public final class CaptionCoordinator: NSObject, AudioCaptureDelegate, BidirectionalSpeechDelegate, @unchecked Sendable {
    public static let shared = CaptionCoordinator()
    public static let pauseStateDidChangeNotification = Notification.Name("CaptionCoordinatorPauseStateDidChangeNotification")
    public static let didDiscardInFlightSpeechNotification = Notification.Name("CaptionCoordinatorDidDiscardInFlightSpeechNotification")
    
    public weak var delegate: CaptionCoordinatorDelegate?
    
    public let audioCaptureEngine = AudioCaptureEngine()
    public let speechRecognitionManager = SpeechRecognitionManager()
    
    private enum AlertScope: Hashable, Sendable {
        case audioCapture
        case speechAuth(channel: String)
        case dictationDownload(code: String)
        case translationSettings
        case general

        var priority: Int {
            switch self {
            case .audioCapture: return 100
            case .speechAuth: return 90
            case .dictationDownload: return 70
            case .translationSettings: return 50
            case .general: return 10
            }
        }
    }

    private struct ActiveAlert: Sendable {
        let message: String
        let actionType: SystemAlertActionType

        static func sameAction(_ lhs: SystemAlertActionType, _ rhs: SystemAlertActionType) -> Bool {
            switch (lhs, rhs) {
            case (.none, .none),
                 (.audioCapture, .audioCapture),
                 (.screenRecording, .screenRecording),
                 (.speechRecognition, .speechRecognition),
                 (.dictation, .dictation),
                 (.translationSettings, .translationSettings),
                 (.permissions, .permissions),
                 (.clearRestoredTranscript, .clearRestoredTranscript):
                return true
            case (.dictationDownload(let a), .dictationDownload(let b)):
                return a == b
            default:
                return false
            }
        }

        static func equals(_ lhs: ActiveAlert?, _ rhs: ActiveAlert?) -> Bool {
            switch (lhs, rhs) {
            case (.none, .none):
                return true
            case (.some(let a), .some(let b)):
                return a.message == b.message && sameAction(a.actionType, b.actionType)
            default:
                return false
            }
        }
    }

    private struct CoordinatorState {
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

    private static func resetCachedEngineConfigLocked(_ state: inout CoordinatorState) {
        state.lastForeignLocale = nil
        state.lastTargetCode = nil
        state.lastMainLocale = nil
        state.lastMicTargetCode = nil
        state.lastMicEnabled = nil
    }

    private let stateLock = OSAllocatedUnfairLock(initialState: CoordinatorState())
    // Serializes lifecycle state changes and engine reconfiguration/start/stop transitions.
    // Lock ordering invariant: acquire `lifecycleLock` before `stateLock`, never reverse.
    private let lifecycleLock = NSRecursiveLock()
    private var modelCheckTask: Task<Void, Never>?

    public var hasStarted: Bool {
        stateLock.withLock { $0.isStarted }
    }

    public var isPaused: Bool {
        stateLock.withLock { $0.isPaused }
    }

    private override init() {
        super.init()
        audioCaptureEngine.delegate = self
        speechRecognitionManager.delegate = self
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChanged),
            name: AppSettings.engineConfigDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSpeechAssetStateChanged(_:)),
            name: SpeechAssetDownloader.stateDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSpeechAssetDownloadFinished(_:)),
            name: SpeechAssetDownloader.didFinishDownloadNotification,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    public func start() {
        guard AppSettings.shared.hasCompletedOnboarding else { return }
        lifecycleLock.lock()
        let (alreadyStarted, alreadyPaused) = stateLock.withLock { state -> (Bool, Bool) in
            if state.isStarted {
                return (true, state.isPaused)
            }
            state.isStarted = true
            state.isPaused = false
            state.autoPausedForSystem = false
            return (false, false)
        }
        if alreadyStarted {
            if alreadyPaused {
                let didResume = resumeLocked()
                lifecycleLock.unlock()
                if didResume {
                    postPauseStateChanged()
                }
                return
            }
            lifecycleLock.unlock()
            return
        }
        reconfigureEnginesLocked()
        lifecycleLock.unlock()
    }

    /// Starts `audioCaptureEngine` for Audio Check / Gain Calibration / System Audio permission
    /// checks without requiring or mutating `AppSettings.shared.hasCompletedOnboarding`.
    public func startForAudioDiagnostics() {
        let isMicEnabled = AppSettings.shared.isMicEnabled
        lifecycleLock.lock()
        if audioCaptureEngine.isRunning {
            audioCaptureEngine.setMicrophoneEnabled(isMicEnabled)
            lifecycleLock.unlock()
            return
        }
        do {
            try audioCaptureEngine.start(enableMic: isMicEnabled)
            AppLog.coordinator.info("AudioCaptureEngine started for diagnostics (micEnabled: \(isMicEnabled)).")
            lifecycleLock.unlock()
            clearAlertScope(.audioCapture)
        } catch {
            AppLog.coordinator.error("AudioCaptureEngine diagnostics start failed: \(error.localizedDescription, privacy: .public)")
            lifecycleLock.unlock()
            setAlert(scope: .audioCapture, message: "Audio capture failed: \(error.localizedDescription)", actionType: .audioCapture)
        }
    }
    
    public func stop() {
        lifecycleLock.lock()
        modelCheckTask?.cancel()
        modelCheckTask = nil
        stateLock.withLock { state in
            state.isStarted = false
            state.isPaused = false
            state.autoPausedForSystem = false
            Self.resetCachedEngineConfigLocked(&state)
            state.reconfigureEpoch &+= 1
            state.uiDeliveryEpoch &+= 1
        }
        audioCaptureEngine.stop()
        speechRecognitionManager.stop()
        lifecycleLock.unlock()
        clearAllAlerts()
    }

    public func togglePauseResume() {
        lifecycleLock.lock()
        let pausedNow = stateLock.withLock { $0.isPaused }
        let didChange: Bool
        if pausedNow {
            didChange = resumeLocked()
        } else {
            didChange = pauseLocked()
        }
        lifecycleLock.unlock()
        if didChange {
            postPauseStateChanged()
        }
    }

    public func pause() {
        lifecycleLock.lock()
        let didPause = pauseLocked()
        lifecycleLock.unlock()
        if didPause {
            postPauseStateChanged()
        }
    }

    private func pauseLocked() -> Bool {
        modelCheckTask?.cancel()
        modelCheckTask = nil
        let shouldPause = stateLock.withLock { state -> Bool in
            guard state.isStarted, !state.isPaused else { return false }
            state.isPaused = true
            Self.resetCachedEngineConfigLocked(&state)
            state.reconfigureEpoch &+= 1
            state.uiDeliveryEpoch &+= 1
            return true
        }
        guard shouldPause else { return false }
        audioCaptureEngine.stop()
        speechRecognitionManager.stop()
        return true
    }

    public func resume() {
        lifecycleLock.lock()
        let didResume = resumeLocked()
        lifecycleLock.unlock()
        if didResume {
            postPauseStateChanged()
        }
    }

    private func resumeLocked() -> Bool {
        let shouldResume = stateLock.withLock { state -> Bool in
            guard state.isStarted, state.isPaused else { return false }
            state.isPaused = false
            state.autoPausedForSystem = false
            return true
        }
        guard shouldResume else { return false }
        reconfigureEnginesLocked()
        return true
    }

    private func postNotificationOnMain(_ name: Notification.Name) {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: name, object: self)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                NotificationCenter.default.post(name: name, object: self)
            }
        }
    }

    private func postPauseStateChanged() {
        postNotificationOnMain(Self.pauseStateDidChangeNotification)
    }

    public func recoverEnginesIfNeeded() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        let (started, paused, lastDeniedAttempt) = stateLock.withLock {
            ($0.isStarted, $0.isPaused, $0.lastDeniedRecoveryAttemptTime)
        }
        guard started, !paused else { return }
        let settings = AppSettings.shared

        if !audioCaptureEngine.isRunning {
            reconfigureEnginesLocked()
            return
        }

        if PermissionHelper.shared.audioCaptureState == .deniedSilenceDetected {
            let now = ProcessInfo.processInfo.systemUptime
            guard (now - lastDeniedAttempt) >= 5.0 else {
                return
            }
            stateLock.withLock { $0.lastDeniedRecoveryAttemptTime = now }
            PermissionHelper.shared.updateAudioCaptureState(.unknown)
            audioCaptureEngine.stop()
            reconfigureEnginesLocked()
            return
        }

        if settings.isMicEnabled && !audioCaptureEngine.isMicRunning {
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
                postPauseStateChanged()
            }
            return
        }
        audioCaptureEngine.stop()
        reconfigureEnginesLocked()
        lifecycleLock.unlock()
    }

    public func autoPauseForSystem() {
        guard AppSettings.shared.pauseOnScreenLock else { return }
        lifecycleLock.lock()
        let shouldPause = stateLock.withLock { state -> Bool in
            guard state.isStarted, !state.isPaused else { return false }
            state.autoPausedForSystem = true
            return true
        }
        let didPause = shouldPause ? pauseLocked() : false
        lifecycleLock.unlock()
        if didPause {
            postPauseStateChanged()
        }
    }

    public func autoResumeAfterSystem() {
        lifecycleLock.lock()
        let shouldResume = stateLock.withLock { state -> Bool in
            guard state.autoPausedForSystem else { return false }
            state.autoPausedForSystem = false
            return state.isStarted && state.isPaused
        }
        let didResume = shouldResume ? resumeLocked() : false
        lifecycleLock.unlock()
        if didResume {
            postPauseStateChanged()
        }
    }

    public func prepareForLiveShareStart() {
        stateLock.withLock { $0.uiDeliveryEpoch &+= 1 }
        speechRecognitionManager.discardInFlight()
        postNotificationOnMain(Self.didDiscardInFlightSpeechNotification)
    }

    public func clearTranscript() {
        stateLock.withLock { $0.uiDeliveryEpoch &+= 1 }
        speechRecognitionManager.discardInFlight()
        postNotificationOnMain(Self.didDiscardInFlightSpeechNotification)
        TranscriptManager.shared.clear()
        LiveShareManager.shared.clearHistoryForPrivacy()
        Task { await TranslationEngine.shared.clearCache() }
    }
    
    public func reconfigureEngines() {
        lifecycleLock.lock()
        reconfigureEnginesLocked()
        lifecycleLock.unlock()
    }

    private static func translationCode(forCode code: String, resolvedLocaleId: String? = nil) -> String {
        let raw = (resolvedLocaleId?.isEmpty == false ? resolvedLocaleId! : code)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        let base = raw.components(separatedBy: "-").first ?? raw
        guard base == "zh" else { return base }
        if raw.contains("tw") || raw.contains("hk") || raw.contains("hant") {
            return "zh-hant"
        }
        let best = SupportedLanguages.bestLocale(forCode: "zh").identifier
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        if best.contains("tw") || best.contains("hk") || best.contains("hant") {
            return "zh-hant"
        }
        return "zh-hans"
    }

    private func reconfigureEnginesLocked() {
        let (started, paused) = stateLock.withLock { ($0.isStarted, $0.isPaused) }
        guard started, !paused else { return }
        
        let settings = AppSettings.shared
        let foreignItem = settings.foreignLanguageItem
        let mainItem = settings.mainLanguageItem
        let targetCode = settings.targetLanguageCode
        let isMicEnabled = settings.isMicEnabled
        
        let foreignLocale = SupportedLanguages.bestLocale(forCode: foreignItem.code).identifier
        let mainLocale = SupportedLanguages.bestLocale(forCode: mainItem.code).identifier
        
        let (languagesChanged, micStateChanged, capturedEpoch) = stateLock.withLock { state -> (Bool, Bool, UInt64) in
            let languagesChanged = (
                foreignLocale != state.lastForeignLocale ||
                targetCode != state.lastTargetCode ||
                mainLocale != state.lastMainLocale ||
                foreignItem.code != state.lastMicTargetCode
            )
            let micStateChanged = (isMicEnabled != state.lastMicEnabled)
            
            state.lastForeignLocale = foreignLocale
            state.lastTargetCode = targetCode
            state.lastMainLocale = mainLocale
            state.lastMicTargetCode = foreignItem.code
            state.lastMicEnabled = isMicEnabled
            state.reconfigureEpoch &+= 1

            return (languagesChanged, micStateChanged, state.reconfigureEpoch)
        }

        let callerTransSource = Self.translationCode(forCode: foreignItem.code, resolvedLocaleId: foreignLocale)
        let callerTransTarget = Self.translationCode(forCode: targetCode)
        let micTransSource = Self.translationCode(forCode: mainItem.code, resolvedLocaleId: mainLocale)
        let micTransTarget = Self.translationCode(forCode: foreignItem.code, resolvedLocaleId: foreignLocale)
        let checkCallerTranslation = foreignItem.code.lowercased() != targetCode.lowercased()
        let checkMicTranslation = isMicEnabled && mainItem.code.lowercased() != foreignItem.code.lowercased()

        modelCheckTask?.cancel()
        modelCheckTask = nil

        if audioCaptureEngine.isRunning && speechRecognitionManager.isRunning && !languagesChanged && micStateChanged {
            speechRecognitionManager.setMicEnabled(
                isMicEnabled,
                micLocaleId: mainLocale,
                micTargetLangCode: foreignItem.code
            )
            audioCaptureEngine.setMicrophoneEnabled(isMicEnabled)

            modelCheckTask = makeModelCheckTask(
                callerSource: callerTransSource,
                callerTarget: callerTransTarget,
                foreignName: foreignItem.name,
                targetName: settings.targetLanguageItem.name,
                checkCaller: checkCallerTranslation,
                micSource: micTransSource,
                micTarget: micTransTarget,
                mainName: mainItem.name,
                checkMic: checkMicTranslation,
                isMicEnabled: isMicEnabled,
                clearCacheFirst: false,
                capturedEpoch: capturedEpoch
            )

            if !AppPaths.isTestEnvironment {
                updateDictationDownloadBannerIfNeeded()
            }
            return
        }

        speechRecognitionManager.stop()
        clearAlertScope(.translationSettings)

        modelCheckTask = makeModelCheckTask(
            callerSource: callerTransSource,
            callerTarget: callerTransTarget,
            foreignName: foreignItem.name,
            targetName: settings.targetLanguageItem.name,
            checkCaller: checkCallerTranslation,
            micSource: micTransSource,
            micTarget: micTransTarget,
            mainName: mainItem.name,
            checkMic: checkMicTranslation,
            isMicEnabled: isMicEnabled,
            clearCacheFirst: languagesChanged,
            capturedEpoch: capturedEpoch
        )

        if audioCaptureEngine.isRunning {
            audioCaptureEngine.setMicrophoneEnabled(isMicEnabled)
        } else {
            do {
                try audioCaptureEngine.start(enableMic: isMicEnabled)
                AppLog.coordinator.info("AudioCaptureEngine started (micEnabled: \(isMicEnabled)).")
                clearAlertScope(.audioCapture)
            } catch {
                AppLog.coordinator.error("AudioCaptureEngine start failed: \(error.localizedDescription, privacy: .public)")
                modelCheckTask?.cancel()
                modelCheckTask = nil
                stateLock.withLock { Self.resetCachedEngineConfigLocked(&$0) }
                setAlert(scope: .audioCapture, message: "Audio capture failed: \(error.localizedDescription)", actionType: .audioCapture)
                return
            }
        }

        speechRecognitionManager.start(
            callerLocaleId: foreignLocale,
            targetLangCode: targetCode,
            micLocaleId: mainLocale,
            micTargetLangCode: foreignItem.code,
            isMicEnabled: isMicEnabled
        )

        if !AppPaths.isTestEnvironment {
            updateDictationDownloadBannerIfNeeded()
        }
    }

    private func makeModelCheckTask(
        callerSource: String,
        callerTarget: String,
        foreignName: String,
        targetName: String,
        checkCaller: Bool,
        micSource: String,
        micTarget: String,
        mainName: String,
        checkMic: Bool,
        isMicEnabled: Bool,
        clearCacheFirst: Bool,
        capturedEpoch: UInt64
    ) -> Task<Void, Never> {
        Task { [weak self] in
            if clearCacheFirst {
                await TranslationEngine.shared.clearCache()
            }
            guard !Task.isCancelled else { return }

            await TranslationEngine.shared.prewarm(sourceCode: callerSource, targetCode: callerTarget)
            if isMicEnabled {
                await TranslationEngine.shared.prewarm(sourceCode: micSource, targetCode: micTarget)
            }
            guard !Task.isCancelled, let self = self else { return }

            var missingMessage: String? = nil

            if checkCaller {
                let status = await TranslationEngine.shared.checkModelStatus(
                    sourceCode: callerSource,
                    targetCode: callerTarget
                )
                guard !Task.isCancelled else { return }
                if status != .installed {
                    missingMessage = (status == .unsupported)
                        ? "Translation unsupported (\(foreignName) → \(targetName))"
                        : "Download translation model (\(foreignName) → \(targetName)) in System Settings → General → Language & Region → Translation Languages"
                }
            }

            if missingMessage == nil && checkMic {
                let status = await TranslationEngine.shared.checkModelStatus(
                    sourceCode: micSource,
                    targetCode: micTarget
                )
                guard !Task.isCancelled else { return }
                if status != .installed {
                    missingMessage = (status == .unsupported)
                        ? "Translation unsupported (\(mainName) → \(foreignName))"
                        : "Download translation model (\(mainName) → \(foreignName)) in System Settings → General → Language & Region → Translation Languages"
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
    }
    
    @objc private func handleSettingsChanged() {
        reconfigureEngines()
    }

    @objc private func handleSpeechAssetStateChanged(_ notification: Notification) {
        guard !AppPaths.isTestEnvironment else { return }
        let (started, paused) = stateLock.withLock { ($0.isStarted, $0.isPaused) }
        guard started, !paused else { return }
        updateDictationDownloadBannerIfNeeded()
    }

    @objc private func handleSpeechAssetDownloadFinished(_ notification: Notification) {
        let code = (notification.userInfo?["languageCode"] as? String)
            ?? (notification.userInfo?["code"] as? String)
            ?? ""
        SupportedLanguages.invalidateCache(forCode: code.isEmpty ? nil : code)

        lifecycleLock.lock()
        let (started, paused) = stateLock.withLock { state -> (Bool, Bool) in
            state.lastForeignLocale = nil
            state.lastMainLocale = nil
            return (state.isStarted, state.isPaused)
        }
        guard started, !paused else {
            lifecycleLock.unlock()
            return
        }
        speechRecognitionManager.resetFailureState()
        clearAlertScopes { scope in
            switch scope {
            case .speechAuth, .dictationDownload:
                return true
            case .audioCapture, .translationSettings, .general:
                return false
            }
        }
        reconfigureEnginesLocked()
        lifecycleLock.unlock()
    }

    private func updateDictationDownloadBannerIfNeeded() {
        let settings = AppSettings.shared
        let activeCodes: [String] = settings.isMicEnabled
            ? [settings.foreignLanguageCode.lowercased(), settings.mainLanguageCode.lowercased()]
            : [settings.foreignLanguageCode.lowercased()]
        let activeSet = Set(activeCodes)

        // Remove stale dictation alerts for inactive or now-installed languages first.
        clearAlertScopes { scope in
            if case .dictationDownload(let code) = scope {
                if !activeSet.contains(code.lowercased()) {
                    return true
                }
                switch SpeechAssetDownloader.shared.status(forCode: code) {
                case .installed, .unknown, .unsupported:
                    return true
                case .downloading, .failed, .notInstalled:
                    return false
                }
            }
            return false
        }

        for code in activeCodes {
            let langName = SupportedLanguages.item(forCode: code)?.name ?? code
            switch SpeechAssetDownloader.shared.status(forCode: code) {
            case .downloading(let progress):
                let pct = Int((progress * 100.0).rounded())
                let msg = pct > 0
                    ? "Downloading \(langName) dictation model… \(pct)%"
                    : "Downloading \(langName) dictation model…"
                setAlert(scope: .dictationDownload(code: code), message: msg, actionType: .dictationDownload(code))
                return
            case .failed(let reason):
                setAlert(
                    scope: .dictationDownload(code: code),
                    message: "Dictation model for \(langName) not ready (\(reason))",
                    actionType: .dictationDownload(code)
                )
                return
            case .notInstalled:
                setAlert(
                    scope: .dictationDownload(code: code),
                    message: "Dictation language required: \(langName)",
                    actionType: .dictationDownload(code)
                )
                return
            case .installed, .unknown, .unsupported:
                break
            }
        }
    }

    /// Acknowledges user dismissal of the currently presented system alert banner,
    /// removing its scope from `activeAlerts` so repeat or lower-priority alerts can show.
    public func dismissPresentedAlert() {
        let shouldSync = stateLock.withLock { state -> Bool in
            guard let current = state.presentedAlert else { return false }
            if let matchingScope = state.activeAlerts
                .sorted(by: { $0.key.priority > $1.key.priority })
                .first(where: { ActiveAlert.equals($0.value, current) })?.key {
                state.activeAlerts.removeValue(forKey: matchingScope)
            }
            state.presentedAlert = Self.highestPriorityAlert(in: state.activeAlerts)
            return true
        }
        if shouldSync {
            scheduleAlertSync()
        }
    }

    private func scheduleAlertSync() {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.applyAlertStateOnMain()
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                MainActor.assumeIsolated {
                    self.applyAlertStateOnMain()
                }
            }
        }
    }

    @MainActor
    private func applyAlertStateOnMain() {
        // Atomically compare the current desired alert with the last alert rendered on the main thread
        // so background setAlert calls can never overwrite a newer main-thread clearAllAlerts.
        let update: (Bool, ActiveAlert?)? = stateLock.withLock { state in
            guard !ActiveAlert.equals(state.presentedAlert, state.lastRenderedAlert) else {
                return nil
            }
            state.lastRenderedAlert = state.presentedAlert
            return (true, state.presentedAlert)
        }
        guard let (_, alert) = update else { return }
        if let alert = alert {
            delegate?.coordinatorDidRequestShowAlert(message: alert.message, actionType: alert.actionType)
        } else {
            delegate?.coordinatorDidRequestClearAlert()
        }
    }

    private func setAlert(scope: AlertScope, message: String, actionType: SystemAlertActionType) {
        let needsSync = stateLock.withLock { state -> Bool in
            state.activeAlerts[scope] = ActiveAlert(message: message, actionType: actionType)
            let top = Self.highestPriorityAlert(in: state.activeAlerts)
            state.presentedAlert = top
            return !ActiveAlert.equals(top, state.lastRenderedAlert)
        }
        if needsSync {
            scheduleAlertSync()
        }
    }

    private func clearAlertScope(_ scope: AlertScope) {
        let needsSync = stateLock.withLock { state -> Bool in
            state.activeAlerts.removeValue(forKey: scope)
            let top = Self.highestPriorityAlert(in: state.activeAlerts)
            state.presentedAlert = top
            return !ActiveAlert.equals(top, state.lastRenderedAlert)
        }
        if needsSync {
            scheduleAlertSync()
        }
    }

    private func clearAlertScopes(where predicate: @Sendable (AlertScope) -> Bool) {
        let needsSync = stateLock.withLock { state -> Bool in
            for scope in state.activeAlerts.keys where predicate(scope) {
                state.activeAlerts.removeValue(forKey: scope)
            }
            let top = Self.highestPriorityAlert(in: state.activeAlerts)
            state.presentedAlert = top
            return !ActiveAlert.equals(top, state.lastRenderedAlert)
        }
        if needsSync {
            scheduleAlertSync()
        }
    }

    private func clearAllAlerts() {
        let needsSync = stateLock.withLock { state -> Bool in
            state.activeAlerts.removeAll()
            state.presentedAlert = nil
            return state.lastRenderedAlert != nil
        }
        if needsSync {
            scheduleAlertSync()
        }
    }

    private static func highestPriorityAlert(in alerts: [AlertScope: ActiveAlert]) -> ActiveAlert? {
        alerts.max(by: { lhs, rhs in
            lhs.key.priority < rhs.key.priority
        })?.value
    }
    
    public func audioCaptureDidOutputCallerAudio(pcmBuffer: AVAudioPCMBuffer) {
        // Whoever started speaking first keeps the floor: if the user was
        // already talking, the caller must not cut their caption off.
        speechRecognitionManager.feedCallerAudioBuffer(
            pcmBuffer,
            userHasFloor: audioCaptureEngine.speechFloorOwner == .user
        )
    }
    
    public func audioCaptureDidUpdateCallerLevel(_ level: Float) {
        dispatchLevels()
    }
    
    public func audioCaptureDidOutputMicAudio(pcmBuffer: AVAudioPCMBuffer) {
        // If the caller was already talking, the user's audio is held (and
        // replayed) until the caller's turn ends instead of interrupting it.
        speechRecognitionManager.feedMicAudioBuffer(
            pcmBuffer,
            isUserSpeaking: audioCaptureEngine.speechFloorOwner == .user
        )
    }
    
    public func audioCaptureDidUpdateMicLevel(_ level: Float) {
        dispatchLevels()
    }

    private func dispatchLevels() {
        let cLvl = audioCaptureEngine.callerLevel
        let mLvl = audioCaptureEngine.micLevel
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.delegate?.coordinatorDidUpdateAudioLevels(callerLevel: cLvl, micLevel: mLvl)
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                MainActor.assumeIsolated {
                    self.delegate?.coordinatorDidUpdateAudioLevels(callerLevel: cLvl, micLevel: mLvl)
                }
            }
        }
    }
    
    public func audioCaptureDidEncounterError(_ error: Error) {
        AppLog.coordinator.error("Audio capture error: \(error.localizedDescription, privacy: .public)")
        setAlert(scope: .audioCapture, message: "Audio capture error: \(error.localizedDescription)", actionType: .audioCapture)
    }

    public func audioCaptureDidDetectDeniedTapPermission() {
        AppLog.coordinator.warning("Audio capture tap returned silent frames while system audio is active.")
        setAlert(
            scope: .audioCapture,
            message: "System Audio Recording permission is off or denied. Enable Call Caption under System Audio Recording.",
            actionType: .audioCapture
        )
    }

    public func audioCaptureDidRestoreTapPermission() {
        AppLog.coordinator.info("System Audio Recording tap permission restored; clearing audio capture alert.")
        clearAlertScope(.audioCapture)
    }
    
    
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
        AppLog.coordinator.warning("Speech auth/model issue (\(channelName, privacy: .public)): \(message, privacy: .public)")
        let lower = message.lowercased()
        let action: SystemAlertActionType
        let scope: AlertScope
        let settings = AppSettings.shared

        let channelLangCode: String? = {
            switch channelName {
            case "caller": return settings.foreignLanguageCode
            case "mic": return settings.mainLanguageCode
            default: return nil
            }
        }()

        if lower.contains("downloading") && lower.contains("dictation") {
            let code = channelLangCode ?? (
                SpeechAssetDownloader.shared.isDownloading(forCode: settings.foreignLanguageCode)
                    ? settings.foreignLanguageCode
                    : settings.mainLanguageCode
            )
            action = .dictationDownload(code)
            scope = .dictationDownload(code: code.lowercased())
        } else if lower.contains("dictation language required") {
            let code = channelLangCode ?? (
                !SupportedLanguages.isOnDeviceDownloaded(forCode: settings.foreignLanguageCode)
                    ? settings.foreignLanguageCode
                    : settings.mainLanguageCode
            )
            action = .dictationDownload(code)
            scope = .dictationDownload(code: code.lowercased())
        } else if lower.contains("dictation") {
            action = .dictation
            scope = .speechAuth(channel: channelName)
        } else if lower.contains("speech") {
            action = .speechRecognition
            scope = .speechAuth(channel: channelName)
        } else if lower.contains("translation") {
            action = .translationSettings
            scope = .translationSettings
        } else {
            action = .permissions
            scope = .speechAuth(channel: channelName)
        }
        setAlert(scope: scope, message: message, actionType: action)
    }
    
    public func speechRecognitionDidClearAuthError() {
        clearAlertScopes { scope in
            if case .speechAuth = scope { return true }
            return false
        }
    }

    public func speechRecognitionDidClearAuthError(channelName: String) {
        let settings = AppSettings.shared
        let channelCode: String? = {
            switch channelName {
            case "caller": return settings.foreignLanguageCode.lowercased()
            case "mic": return settings.mainLanguageCode.lowercased()
            default: return nil
            }
        }()
        clearAlertScopes { scope in
            switch scope {
            case .speechAuth(let ch):
                return ch == channelName
            case .dictationDownload(let code):
                if let channelCode, code.lowercased() == channelCode {
                    return SpeechAssetDownloader.shared.status(forCode: code) == .installed
                }
                return false
            case .audioCapture, .translationSettings, .general:
                return false
            }
        }
    }
    
    
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

        let settings = AppSettings.shared
        let sourceLangCode: String
        let targetLangCode: String
        if let explicitSourceLang, !explicitSourceLang.isEmpty,
           let explicitTargetLang, !explicitTargetLang.isEmpty {
            sourceLangCode = explicitSourceLang.lowercased()
            targetLangCode = explicitTargetLang.lowercased()
        } else if speaker == "Caller" {
            sourceLangCode = settings.foreignLanguageCode.lowercased()
            targetLangCode = settings.targetLanguageCode.lowercased()
        } else {
            sourceLangCode = settings.mainLanguageCode.lowercased()
            targetLangCode = settings.foreignLanguageCode.lowercased()
        }
        
        let displayTrans = translated.isEmpty ? cleanOrig : translated
        
        LiveShareManager.shared.broadcastCaption(
            speaker: speaker,
            original: cleanOrig,
            translated: displayTrans,
            sourceLangCode: sourceLangCode,
            targetLangCode: targetLangCode,
            isFinal: isFinal,
            isUntranslated: isUntranslated,
            utteranceID: utteranceID
        )
        
        let enqueuedEpoch = stateLock.withLock { $0.uiDeliveryEpoch }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                guard self.stateLock.withLock({ $0.uiDeliveryEpoch == enqueuedEpoch }) else { return }
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
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                guard self.stateLock.withLock({ $0.uiDeliveryEpoch == enqueuedEpoch }) else { return }
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
        
        if isFinal {
            TranscriptManager.shared.addEntry(
                speaker: speaker,
                original: cleanOrig,
                translated: displayTrans,
                isUntranslated: isUntranslated,
                utteranceID: utteranceID,
                sourceLangCode: sourceLangCode,
                targetLangCode: targetLangCode
            )
        }
    }
}
