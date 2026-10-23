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
    
    public weak var delegate: CaptionCoordinatorDelegate?
    
    public let audioCaptureEngine = AudioCaptureEngine()
    public let speechRecognitionManager = SpeechRecognitionManager()
    
    private struct CoordinatorState {
        var isStarted: Bool = false
        var autoPausedForSystem: Bool = false
        var isPaused: Bool = false
        var lastForeignLocale: String?
        var lastTargetCode: String?
        var lastMainLocale: String?
        var lastMicTargetCode: String?
        var lastMicEnabled: Bool?
    }

    private let stateLock = OSAllocatedUnfairLock(initialState: CoordinatorState())

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
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    public func start() {
        guard AppSettings.shared.hasCompletedOnboarding else { return }
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
            if alreadyPaused { resume() }
            return
        }
        reconfigureEngines()
    }
    
    public func stop() {
        stateLock.withLock { state in
            state.isStarted = false
            state.isPaused = false
            state.autoPausedForSystem = false
            state.lastForeignLocale = nil
            state.lastTargetCode = nil
            state.lastMainLocale = nil
            state.lastMicTargetCode = nil
            state.lastMicEnabled = nil
        }
        audioCaptureEngine.stop()
        speechRecognitionManager.stop()
    }

    public func togglePauseResume() {
        if isPaused {
            resume()
        } else {
            pause()
        }
    }

    public func pause() {
        let shouldPause = stateLock.withLock { state -> Bool in
            guard state.isStarted, !state.isPaused else { return false }
            state.isPaused = true
            state.lastForeignLocale = nil
            state.lastTargetCode = nil
            state.lastMainLocale = nil
            state.lastMicTargetCode = nil
            state.lastMicEnabled = nil
            return true
        }
        guard shouldPause else { return }
        audioCaptureEngine.stop()
        speechRecognitionManager.stop()
        NotificationCenter.default.post(name: Self.pauseStateDidChangeNotification, object: self)
    }

    public func resume() {
        let shouldResume = stateLock.withLock { state -> Bool in
            guard state.isStarted, state.isPaused else { return false }
            state.isPaused = false
            state.autoPausedForSystem = false
            return true
        }
        guard shouldResume else { return }
        reconfigureEngines()
        NotificationCenter.default.post(name: Self.pauseStateDidChangeNotification, object: self)
    }

    public func recoverEnginesIfNeeded() {
        let (started, paused) = stateLock.withLock { ($0.isStarted, $0.isPaused) }
        guard started, !paused else { return }
        let settings = AppSettings.shared

        if !audioCaptureEngine.isRunning {
            reconfigureEngines()
            return
        }

        if PermissionHelper.shared.audioCaptureState == .deniedSilenceDetected {
            audioCaptureEngine.stop()
            reconfigureEngines()
            return
        }

        if settings.isMicEnabled && !audioCaptureEngine.isMicRunning {
            audioCaptureEngine.setMicrophoneEnabled(true)
        }

        if !speechRecognitionManager.isRunning {
            reconfigureEngines()
        } else {
            speechRecognitionManager.resetFailureState()
        }
    }

    public func retryAudioCapture() {
        PermissionHelper.shared.updateAudioCaptureState(.unknown)
        let (started, paused) = stateLock.withLock { ($0.isStarted, $0.isPaused) }
        if !started {
            start()
            return
        }
        if paused {
            resume()
            return
        }
        audioCaptureEngine.stop()
        reconfigureEngines()
    }

    public func autoPauseForSystem() {
        guard AppSettings.shared.pauseOnScreenLock else { return }
        let shouldPause = stateLock.withLock { state -> Bool in
            guard state.isStarted, !state.isPaused else { return false }
            state.autoPausedForSystem = true
            return true
        }
        if shouldPause {
            pause()
        }
    }

    public func autoResumeAfterSystem() {
        let shouldResume = stateLock.withLock { state -> Bool in
            guard state.autoPausedForSystem else { return false }
            state.autoPausedForSystem = false
            return state.isStarted && state.isPaused
        }
        if shouldResume {
            resume()
        }
    }

    public func prepareForLiveShareStart() {
        speechRecognitionManager.discardInFlight()
    }

    public func clearTranscript() {
        speechRecognitionManager.discardInFlight()
        TranscriptManager.shared.clear()
        LiveShareManager.shared.clearHistoryForPrivacy()
        Task { await TranslationEngine.shared.clearCache() }
    }
    
    public func reconfigureEngines() {
        let (started, paused) = stateLock.withLock { ($0.isStarted, $0.isPaused) }
        guard started, !paused else { return }
        
        let settings = AppSettings.shared
        let foreignItem = settings.foreignLanguageItem
        let mainItem = settings.mainLanguageItem
        let targetCode = settings.targetLanguageCode
        let isMicEnabled = settings.isMicEnabled
        
        let foreignLocale = SupportedLanguages.bestLocale(forCode: foreignItem.code).identifier
        let mainLocale = SupportedLanguages.bestLocale(forCode: mainItem.code).identifier
        
        let (languagesChanged, micStateChanged) = stateLock.withLock { state -> (Bool, Bool) in
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

            return (languagesChanged, micStateChanged)
        }

        if audioCaptureEngine.isRunning && !languagesChanged && micStateChanged {
            speechRecognitionManager.setMicEnabled(
                isMicEnabled,
                micLocaleId: mainLocale,
                micTargetLangCode: foreignItem.code
            )
            audioCaptureEngine.setMicrophoneEnabled(isMicEnabled)
            if isMicEnabled {
                Task {
                    await TranslationEngine.shared.prewarm(sourceCode: mainItem.code, targetCode: foreignItem.code)
                }
            }
            return
        }

        if languagesChanged {
            Task { await TranslationEngine.shared.clearCache() }
        }
        speechRecognitionManager.stop()

        Task {
            await TranslationEngine.shared.prewarm(sourceCode: foreignItem.code, targetCode: targetCode)
            if isMicEnabled {
                await TranslationEngine.shared.prewarm(sourceCode: mainItem.code, targetCode: foreignItem.code)
            }
        }
        
        speechRecognitionManager.start(
            callerLocaleId: foreignLocale,
            targetLangCode: targetCode,
            micLocaleId: mainLocale,
            micTargetLangCode: foreignItem.code,
            isMicEnabled: isMicEnabled
        )

        if foreignItem.code.lowercased() != targetCode.lowercased() {
            Task {
                let status = await TranslationEngine.shared.checkModelStatus(
                    sourceCode: foreignItem.code,
                    targetCode: targetCode
                )
                if status != .installed {
                    let foreignName = foreignItem.name
                    let targetName = settings.targetLanguageItem.name
                    let msg = (status == .unsupported)
                        ? "Translation unsupported (\(foreignName) → \(targetName))"
                        : "Download translation model (\(foreignName) → \(targetName)) in System Settings → General → Language & Region → Translation Languages"
                    self.showAlert(message: msg, actionType: .translationSettings)
                }
            }
        }

        if isMicEnabled && mainItem.code.lowercased() != foreignItem.code.lowercased() {
            Task {
                let status = await TranslationEngine.shared.checkModelStatus(
                    sourceCode: mainItem.code,
                    targetCode: foreignItem.code
                )
                if status != .installed {
                    let mainName = mainItem.name
                    let foreignName = foreignItem.name
                    let msg = (status == .unsupported)
                        ? "Translation unsupported (\(mainName) → \(foreignName))"
                        : "Download translation model (\(mainName) → \(foreignName)) in System Settings → General → Language & Region → Translation Languages"
                    self.showAlert(message: msg, actionType: .translationSettings)
                }
            }
        }
        
        if audioCaptureEngine.isRunning {
            audioCaptureEngine.setMicrophoneEnabled(isMicEnabled)
        } else {
            do {
                try audioCaptureEngine.start(enableMic: isMicEnabled)
                AppLog.coordinator.info("AudioCaptureEngine started (micEnabled: \(isMicEnabled)).")
                clearAlert()
            } catch {
                AppLog.coordinator.error("AudioCaptureEngine start failed: \(error.localizedDescription, privacy: .public)")
                showAlert(message: "Audio capture failed: \(error.localizedDescription)", actionType: .audioCapture)
            }
        }
    }
    
    @objc private func handleSettingsChanged() {
        reconfigureEngines()
    }
    
    private func showAlert(message: String, actionType: SystemAlertActionType) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.delegate?.coordinatorDidRequestShowAlert(message: message, actionType: actionType)
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                MainActor.assumeIsolated {
                    self.delegate?.coordinatorDidRequestShowAlert(message: message, actionType: actionType)
                }
            }
        }
    }
    
    private func clearAlert() {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.delegate?.coordinatorDidRequestClearAlert()
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                MainActor.assumeIsolated {
                    self.delegate?.coordinatorDidRequestClearAlert()
                }
            }
        }
    }
    
    
    public func audioCaptureDidOutputCallerAudio(pcmBuffer: AVAudioPCMBuffer) {
        speechRecognitionManager.feedCallerAudioBuffer(pcmBuffer)
    }
    
    public func audioCaptureDidUpdateCallerLevel(_ level: Float) {
        dispatchLevels()
    }
    
    public func audioCaptureDidOutputMicAudio(pcmBuffer: AVAudioPCMBuffer) {
        speechRecognitionManager.feedMicAudioBuffer(pcmBuffer)
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
        showAlert(message: "Audio capture error: \(error.localizedDescription)", actionType: .audioCapture)
    }

    public func audioCaptureDidDetectDeniedTapPermission() {
        AppLog.coordinator.warning("Audio capture tap returned silent frames while system audio is active.")
        showAlert(
            message: "System Audio Recording permission is off or denied. Enable Call Caption under System Audio Recording.",
            actionType: .audioCapture
        )
    }
    
    
    public func callerSpeechDidUpdate(utteranceID: UUID, partialOriginal: String, partialTranslated: String, isUntranslated: Bool) {
        forwardToUI(utteranceID: utteranceID, speaker: "Caller", original: partialOriginal, translated: partialTranslated, isFinal: false, isUntranslated: isUntranslated)
    }
    
    public func callerSpeechDidFinalize(utteranceID: UUID, original: String, translated: String, isUntranslated: Bool) {
        forwardToUI(utteranceID: utteranceID, speaker: "Caller", original: original, translated: translated, isFinal: true, isUntranslated: isUntranslated)
    }
    
    public func micSpeechDidUpdate(utteranceID: UUID, partialOriginal: String, partialTranslated: String, isUntranslated: Bool) {
        forwardToUI(utteranceID: utteranceID, speaker: "You", original: partialOriginal, translated: partialTranslated, isFinal: false, isUntranslated: isUntranslated)
    }
    
    public func micSpeechDidFinalize(utteranceID: UUID, original: String, translated: String, isUntranslated: Bool) {
        forwardToUI(utteranceID: utteranceID, speaker: "You", original: original, translated: translated, isFinal: true, isUntranslated: isUntranslated)
    }
    
    public func speechRecognitionDidEncounterAuthError(message: String) {
        AppLog.coordinator.warning("Speech auth/model issue: \(message, privacy: .public)")
        let lower = message.lowercased()
        let action: SystemAlertActionType
        if lower.contains("dictation") {
            action = .dictation
        } else if lower.contains("speech") {
            action = .speechRecognition
        } else if lower.contains("translation") {
            action = .translationSettings
        } else {
            action = .permissions
        }
        showAlert(message: message, actionType: action)
    }
    
    public func speechRecognitionDidClearAuthError() {
        clearAlert()
    }
    
    
    private func forwardToUI(utteranceID: UUID, speaker: String, original: String, translated: String, isFinal: Bool, isUntranslated: Bool) {
        let cleanOrig = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanOrig.isEmpty else { return }

        let settings = AppSettings.shared
        let sourceLangCode: String
        let targetLangCode: String
        if speaker == "Caller" {
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
        
        if Thread.isMainThread {
            MainActor.assumeIsolated {
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
                self?.deliverOnMain(
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
