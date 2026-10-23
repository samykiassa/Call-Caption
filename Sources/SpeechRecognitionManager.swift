import Foundation
@preconcurrency import Speech
@preconcurrency import AVFoundation
import os

public enum SpeechRecognitionErrorCode: Int, Sendable {
    case dictationDisabled = 201
    case retry = 203
    case cancelled = 216
    case requestCancelled = 301
    case noSpeechDetected = 1110
    case notAuthorizedOrMissingAsset = 1700
}

public protocol BidirectionalSpeechDelegate: AnyObject {
    func callerSpeechDidUpdate(utteranceID: UUID, partialOriginal: String, partialTranslated: String, isUntranslated: Bool)
    func callerSpeechDidFinalize(utteranceID: UUID, original: String, translated: String, isUntranslated: Bool)
    func micSpeechDidUpdate(utteranceID: UUID, partialOriginal: String, partialTranslated: String, isUntranslated: Bool)
    func micSpeechDidFinalize(utteranceID: UUID, original: String, translated: String, isUntranslated: Bool)
    func speechRecognitionDidEncounterAuthError(message: String)
    func speechRecognitionDidClearAuthError()
}

public final class SingleSpeechChannel: NSObject, @unchecked Sendable {
    private struct SendablePCMBuffer: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }

    private struct SendableWorkItem: @unchecked Sendable {
        let item: DispatchWorkItem
    }

    private struct PendingCommit: Sendable {
        let utteranceID: UUID
        let original: String
        let fallbackTranslated: String
        let fallbackUntranslated: Bool
    }

    private static let terminalPunctuationScalars: Set<UnicodeScalar> = [
        ".", "?", "!", "\u{3002}", "\u{FF1F}", "\u{FF01}", "\u{061F}"
    ]

    private struct AudioState {
        var isRunning: Bool = false
        var isSuspended: Bool = false
        var isStartingSession: Bool = false
        var isRestartScheduled: Bool = false
        var sourceLocaleId: String
        var targetLangCode: String
        var recognizer: SFSpeechRecognizer? = nil
        var request: SFSpeechAudioBufferRecognitionRequest? = nil
        var task: SFSpeechRecognitionTask? = nil
        var sessionStartTime: TimeInterval = ProcessInfo.processInfo.systemUptime
        var lastBufferArrivalTime: TimeInterval = 0
        var pendingPCMBuffers: [SendablePCMBuffer] = []
        var recentSessionBuffers: [SendablePCMBuffer] = []
        var consecutiveErrors: Int = 0
        var failureBackoffUntil: TimeInterval = 0
        var failureCount: Int = 0
        var lastReportedFailure: String? = nil
        var lastFailureReportTime: TimeInterval = 0

        var currentUtteranceID: UUID? = nil
        var currentOriginal: String = ""
        var currentTranslated: String = ""
        var currentIsUntranslated: Bool = false
        var lastRawFullText: String = ""
        var lastSpeechActivityTime: TimeInterval = 0
        var restartWorkItem: SendableWorkItem? = nil
        var silenceCommitWorkItem: SendableWorkItem? = nil
        var noBufferWatchdogWorkItem: SendableWorkItem? = nil

        var sessionEpoch: UInt64 = 0
        var resetEpoch: UInt64 = 0
        var sessionTaskId: UInt64 = 0
        var isTranslating: Bool = false
        var pendingTailText: String? = nil
    }

    private let lock: OSAllocatedUnfairLock<AudioState>

    public let channelName: String

    public var sourceLocaleId: String {
        lock.withLock { $0.sourceLocaleId }
    }

    public var targetLangCode: String {
        lock.withLock { $0.targetLangCode }
    }

    private var currentResetEpoch: UInt64 {
        lock.withLock { $0.resetEpoch }
    }

    public var onPartial: ((UUID, String, String, Bool) -> Void)?
    public var onFinal: ((UUID, String, String, Bool) -> Void)?
    public var onAuthError: ((String) -> Void)?
    public var onAuthSuccess: (() -> Void)?
    public var onSessionClosed: (() -> Void)?

    private let activeTasksLock = OSAllocatedUnfairLock(initialState: [UUID: Task<Void, Never>]())

    private func cancelInFlightTranslationTasks() {
        let tasksToCancel = activeTasksLock.withLock { tasks -> [Task<Void, Never>] in
            let list = Array(tasks.values)
            tasks.removeAll()
            return list
        }
        for task in tasksToCancel {
            task.cancel()
        }
    }

    public var isRunning: Bool {
        lock.withLock { $0.isRunning }
    }

    public var isSuspended: Bool {
        lock.withLock { $0.isSuspended }
    }

    private let pauseCommitInterval: TimeInterval = 1.65
    private let noBufferIdleTimeout: TimeInterval = 0.65
    private let maxSuspendedBuffers = 180

    public init(name: String, sourceLocaleId: String, targetLangCode: String) {
        self.channelName = name
        self.lock = OSAllocatedUnfairLock(initialState: AudioState(
            sourceLocaleId: sourceLocaleId,
            targetLangCode: targetLangCode
        ))
        super.init()
    }

    private static func resetSessionTrackingState(_ state: inout AudioState) {
        state.lastRawFullText = ""
        state.currentUtteranceID = nil
        state.currentOriginal = ""
        state.currentTranslated = ""
        state.currentIsUntranslated = false
        state.pendingTailText = nil
        state.isTranslating = false
    }

    private static func consumePendingCommit(_ state: inout AudioState) -> PendingCommit? {
        let trimmed = state.currentOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            resetSessionTrackingState(&state)
            return nil
        }
        let commit = PendingCommit(
            utteranceID: state.currentUtteranceID ?? UUID(),
            original: trimmed,
            fallbackTranslated: state.currentTranslated,
            fallbackUntranslated: state.currentIsUntranslated
        )
        resetSessionTrackingState(&state)
        state.sessionEpoch &+= 1
        return commit
    }

    private static func cancelWorkItems(_ state: inout AudioState) {
        state.restartWorkItem?.item.cancel()
        state.restartWorkItem = nil
        state.silenceCommitWorkItem?.item.cancel()
        state.silenceCommitWorkItem = nil
        state.noBufferWatchdogWorkItem?.item.cancel()
        state.noBufferWatchdogWorkItem = nil
    }

    public func start(sourceLocaleId: String, targetLangCode: String) {
        stop()
        lock.withLock { state in
            state.sourceLocaleId = sourceLocaleId
            state.targetLangCode = targetLangCode
            state.isRunning = true
            state.isSuspended = false
            state.isStartingSession = false
            state.isRestartScheduled = false
            state.consecutiveErrors = 0
            state.request = nil
            state.task = nil
            state.lastBufferArrivalTime = 0
            state.pendingPCMBuffers.removeAll(keepingCapacity: true)
            state.recentSessionBuffers.removeAll(keepingCapacity: true)
            state.failureBackoffUntil = 0
            state.failureCount = 0
            state.lastReportedFailure = nil
            state.lastFailureReportTime = 0
            state.sessionEpoch &+= 1
            state.resetEpoch &+= 1
            state.sessionTaskId &+= 1
            Self.cancelWorkItems(&state)
            Self.resetSessionTrackingState(&state)
        }

        setupRecognizer()
    }

    public func stop() {
        let (oldReq, oldTask, pendingCommit) = lock.withLock { state -> (SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?, PendingCommit?) in
            state.isRunning = false
            state.isSuspended = false
            state.isStartingSession = false
            state.isRestartScheduled = false
            let r = state.request
            state.request = nil
            let t = state.task
            state.task = nil
            state.pendingPCMBuffers.removeAll(keepingCapacity: false)
            state.recentSessionBuffers.removeAll(keepingCapacity: false)
            state.failureBackoffUntil = 0
            state.failureCount = 0
            state.lastReportedFailure = nil
            state.lastFailureReportTime = 0
            state.sessionTaskId &+= 1
            state.resetEpoch &+= 1
            Self.cancelWorkItems(&state)
            let commit = Self.consumePendingCommit(&state)
            if commit == nil {
                state.sessionEpoch &+= 1
            }
            return (r, t, commit)
        }

        if let commit = pendingCommit {
            commitCompletedSentence(
                commit.original,
                fallbackTranslated: commit.fallbackTranslated,
                fallbackUntranslated: commit.fallbackUntranslated,
                utteranceID: commit.utteranceID
            )
            onSessionClosed?()
        }

        cancelInFlightTranslationTasks()
        oldReq?.endAudio()
        oldTask?.cancel()
    }

    public func resetFailureState() {
        lock.withLock {
            $0.failureBackoffUntil = 0
            $0.failureCount = 0
            $0.lastReportedFailure = nil
            $0.lastFailureReportTime = 0
        }
    }

    public func discardInFlight() {
        let (oldReq, oldTask) = lock.withLock { state -> (SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?) in
            let r = state.request
            state.request = nil
            let t = state.task
            state.task = nil
            state.isStartingSession = false
            state.isRestartScheduled = false
            state.pendingPCMBuffers.removeAll(keepingCapacity: false)
            state.recentSessionBuffers.removeAll(keepingCapacity: false)
            state.sessionTaskId &+= 1
            state.sessionEpoch &+= 1
            state.resetEpoch &+= 1
            Self.cancelWorkItems(&state)
            Self.resetSessionTrackingState(&state)
            return (r, t)
        }
        cancelInFlightTranslationTasks()
        oldReq?.endAudio()
        oldTask?.cancel()
    }

    public func commitSentenceForTesting(
        utteranceID: UUID,
        original: String,
        fallbackTranslated: String = "",
        fallbackUntranslated: Bool = true
    ) {
        commitCompletedSentence(
            original,
            fallbackTranslated: fallbackTranslated,
            fallbackUntranslated: fallbackUntranslated,
            utteranceID: utteranceID
        )
    }

    public func advanceUtteranceEpochForTesting() {
        lock.withLock { state in
            state.sessionEpoch &+= 1
            state.isTranslating = false
        }
    }

    @discardableResult
    public func suspendForMicPriority() -> Bool {
        let isMic = (channelName == "mic")
        let (wasAlreadySuspended, oldReq) = lock.withLock { state -> (Bool, SFSpeechAudioBufferRecognitionRequest?) in
            let already = state.isSuspended
            state.isSuspended = true
            state.isStartingSession = false
            state.isRestartScheduled = false
            state.consecutiveErrors = 0
            let r = state.request
            state.request = nil
            state.recentSessionBuffers.removeAll(keepingCapacity: true)
            if isMic {
                state.pendingPCMBuffers.removeAll(keepingCapacity: true)
            }
            if !already || r != nil {
                state.sessionTaskId &+= 1
                Self.cancelWorkItems(&state)
            }
            return (already, r)
        }
        let hadActiveReq = (oldReq != nil)
        oldReq?.endAudio()
        guard !wasAlreadySuspended || hadActiveReq else { return false }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let (pendingCommit, oldTask) = self.lock.withLock { state -> (PendingCommit?, SFSpeechRecognitionTask?) in
                state.sessionTaskId &+= 1
                Self.cancelWorkItems(&state)
                let commit = Self.consumePendingCommit(&state)
                let t = state.task
                state.task = nil
                return (commit, t)
            }

            if let commit = pendingCommit {
                self.commitCompletedSentence(
                    commit.original,
                    fallbackTranslated: commit.fallbackTranslated,
                    fallbackUntranslated: commit.fallbackUntranslated,
                    utteranceID: commit.utteranceID
                )
            }

            oldTask?.cancel()
        }
        return hadActiveReq
    }

    public func resumeAfterMicPriority() {
        let isMic = (channelName == "mic")
        let now = ProcessInfo.processInfo.systemUptime
        let needsStart = lock.withLock { state -> Bool in
            guard state.isSuspended else { return false }
            state.isSuspended = false
            state.consecutiveErrors = 0
            if isMic || (now - state.lastBufferArrivalTime) > 8.0 {
                state.pendingPCMBuffers.removeAll(keepingCapacity: true)
            }
            let shouldStart = state.isRunning && !state.isStartingSession && !state.isRestartScheduled && state.request == nil && !state.pendingPCMBuffers.isEmpty
            if shouldStart {
                state.isRestartScheduled = true
            }
            return shouldStart
        }
        if needsStart {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.scheduleRestart(after: 0.03, forceReplace: false)
            }
        }
    }

    @discardableResult
    public func finishIfIdleForPeerChannel() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let (shouldClose, oldReq, oldTask, pendingCommit) = lock.withLock { state -> (Bool, SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?, PendingCommit?) in
            guard state.isRunning, state.request != nil || state.task != nil else {
                return (false, nil, nil, nil)
            }
            let isIdle = state.lastBufferArrivalTime == 0 || (now - state.lastBufferArrivalTime) >= 0.25
            guard isIdle else { return (false, nil, nil, nil) }
            state.sessionTaskId &+= 1
            Self.cancelWorkItems(&state)
            state.isStartingSession = false
            state.isRestartScheduled = false
            let r = state.request
            state.request = nil
            let t = state.task
            state.task = nil
            state.recentSessionBuffers.removeAll(keepingCapacity: true)
            state.pendingPCMBuffers.removeAll(keepingCapacity: true)
            let commit = Self.consumePendingCommit(&state)
            return (true, r, t, commit)
        }
        guard shouldClose else { return false }
        if let commit = pendingCommit {
            commitCompletedSentence(
                commit.original,
                fallbackTranslated: commit.fallbackTranslated,
                fallbackUntranslated: commit.fallbackUntranslated,
                utteranceID: commit.utteranceID
            )
        }
        oldReq?.endAudio()
        oldTask?.cancel()
        return true
    }

    public func appendPCMBuffer(_ buffer: AVAudioPCMBuffer, minimumStartDelay: TimeInterval = 0.01) {
        let wrappedBuffer = SendablePCMBuffer(buffer: buffer)
        let now = ProcessInfo.processInfo.systemUptime
        let maxSusp = maxSuspendedBuffers
        let isMic = (channelName == "mic")
        let (running, req, shouldCycle, needsStart, errCount) = lock.withLock { state -> (Bool, SFSpeechAudioBufferRecognitionRequest?, Bool, Bool, Int) in
            guard state.isRunning else { return (false, nil, false, false, 0) }
            state.lastBufferArrivalTime = now
            if state.isSuspended {
                if !isMic {
                    if state.pendingPCMBuffers.count >= maxSusp {
                        state.pendingPCMBuffers.removeFirst()
                    }
                    state.pendingPCMBuffers.append(wrappedBuffer)
                }
                return (false, nil, false, false, 0)
            }
            if state.request == nil && now < state.failureBackoffUntil {
                return (true, nil, false, false, 0)
            }
            if state.recentSessionBuffers.count >= 16 {
                state.recentSessionBuffers.removeFirst()
            }
            state.recentSessionBuffers.append(wrappedBuffer)

            guard let r = state.request, !state.isStartingSession else {
                if state.pendingPCMBuffers.count >= maxSusp {
                    state.pendingPCMBuffers.removeFirst()
                }
                state.pendingPCMBuffers.append(wrappedBuffer)
                let shouldStart = !state.isStartingSession && !state.isRestartScheduled && state.request == nil
                if shouldStart {
                    state.isRestartScheduled = true
                }
                return (true, nil, false, shouldStart, state.consecutiveErrors)
            }

            let age = now - state.sessionStartTime
            if age > 56.0 {
                state.sessionStartTime = now
                state.isRestartScheduled = true
                if state.pendingPCMBuffers.isEmpty && !state.recentSessionBuffers.isEmpty {
                    state.pendingPCMBuffers = Array(state.recentSessionBuffers.suffix(8))
                }
                return (true, r, true, false, 0)
            }
            return (true, r, false, false, 0)
        }

        guard running else { return }
        if let req = req {
            req.append(buffer)
            if shouldCycle {
                DispatchQueue.main.async { [weak self] in
                    self?.scheduleRestart(after: 0.05, forceReplace: true)
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    let hasWatchdog = self.lock.withLock { $0.noBufferWatchdogWorkItem != nil }
                    if !hasWatchdog {
                        self.scheduleNoBufferWatchdog(after: self.noBufferIdleTimeout)
                    }
                }
            }
        } else if needsStart {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let backoff = errCount > 0 ? min(0.8, 0.15 * Double(errCount)) : minimumStartDelay
                let delay = max(minimumStartDelay, backoff)
                self.scheduleRestart(after: delay, forceReplace: false)
            }
        }
    }

    private func scheduleNoBufferWatchdog(after delay: TimeInterval) {
        let work = SendableWorkItem(item: DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let (isRunningNow, hasReq, idleDuration) = self.lock.withLock { state -> (Bool, Bool, TimeInterval) in
                state.noBufferWatchdogWorkItem = nil
                let idle = ProcessInfo.processInfo.systemUptime - state.lastBufferArrivalTime
                return (state.isRunning, state.request != nil, idle)
            }
            guard isRunningNow, hasReq else { return }
            if idleDuration < (self.noBufferIdleTimeout - 0.06) {
                let remaining = max(0.12, self.noBufferIdleTimeout - idleDuration)
                self.scheduleNoBufferWatchdog(after: remaining)
                return
            }
            self.finishAudioForIdleSession()
        })
        lock.withLock { state in
            state.noBufferWatchdogWorkItem?.item.cancel()
            state.noBufferWatchdogWorkItem = work
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work.item)
    }

    private func finishAudioForIdleSession() {
        let oldReq = lock.withLock { state -> SFSpeechAudioBufferRecognitionRequest? in
            let r = state.request
            state.request = nil
            return r
        }
        guard let req = oldReq else { return }
        req.endAudio()

        let cleanupWork = SendableWorkItem(item: DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let (shouldAct, hasText, hasTask) = self.lock.withLock { state -> (Bool, Bool, Bool) in
                state.noBufferWatchdogWorkItem = nil
                guard state.isRunning else { return (false, false, false) }
                let hasActiveNewReq = state.request != nil || state.isStartingSession || state.isRestartScheduled
                guard !hasActiveNewReq else { return (false, false, false) }
                let hasOrig = !state.currentOriginal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                return (true, hasOrig, state.task != nil)
            }
            guard shouldAct else { return }
            if hasText {
                self.commitSilenceThought()
            } else if hasTask {
                self.closeCurrentSession()
            }
        })
        lock.withLock { state in
            state.noBufferWatchdogWorkItem?.item.cancel()
            state.noBufferWatchdogWorkItem = cleanupWork
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: cleanupWork.item)
    }

    private func setupRecognizer() {
        let localeId = lock.withLock { $0.sourceLocaleId }
        let loc = SupportedLanguages.bestLocale(forCode: localeId)
        if let rec = SFSpeechRecognizer(locale: loc) {
            lock.withLock { $0.recognizer = rec }
            AppLog.speech.info("[SpeechChannel \(self.channelName, privacy: .public)] Configured recognizer with locale '\(loc.identifier, privacy: .public)' (supportsOnDevice: \(rec.supportsOnDeviceRecognition, privacy: .public))")
        } else {
            let langName = SupportedLanguages.item(forCode: localeId.components(separatedBy: "-").first ?? "")?.name ?? localeId
            AppLog.speech.error("[SpeechChannel \(self.channelName, privacy: .public)] Locale '\(loc.identifier, privacy: .public)' is unsupported by SFSpeechRecognizer.")
            lock.withLock { $0.recognizer = nil }
            noteFailure("Speech recognition locale '\(langName)' is not supported by macOS.")
        }
    }

    public func startNewSession(forceReplace: Bool = false) {
        let canStart = lock.withLock { state -> Bool in
            state.restartWorkItem?.item.cancel()
            state.restartWorkItem = nil
            state.isRestartScheduled = false
            guard state.isRunning, !state.isSuspended, !state.isStartingSession else { return false }
            if !forceReplace && state.request != nil {
                return false
            }
            if state.request == nil && state.pendingPCMBuffers.isEmpty && !(forceReplace && !state.recentSessionBuffers.isEmpty) {
                return false
            }
            state.isStartingSession = true
            state.silenceCommitWorkItem?.item.cancel()
            state.silenceCommitWorkItem = nil
            return true
        }
        guard canStart else { return }
        defer {
            lock.withLock { $0.isStartingSession = false }
        }

        let authStatus = SFSpeechRecognizer.authorizationStatus()
        if authStatus == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if status == .authorized {
                        self.scheduleRestart(after: 0.05, forceReplace: false)
                    } else {
                        self.noteFailure("Speech Recognition access required")
                    }
                }
            }
            return
        } else if authStatus == .denied || authStatus == .restricted {
            noteFailure("Speech Recognition access required")
            return
        }

        if lock.withLock({ $0.recognizer == nil }) {
            setupRecognizer()
        }
        let (recognizer, localeId, inBackoff) = lock.withLock { state -> (SFSpeechRecognizer?, String, Bool) in
            let backoff = state.failureBackoffUntil > ProcessInfo.processInfo.systemUptime
            return (state.recognizer, state.sourceLocaleId, backoff)
        }
        guard let recognizer = recognizer else { return }

        let langCode = localeId.components(separatedBy: "-").first ?? ""
        let langName = SupportedLanguages.item(forCode: langCode)?.name ?? localeId

        if inBackoff {
            return
        }

        guard recognizer.isAvailable && recognizer.supportsOnDeviceRecognition else {
            noteFailure("Dictation language required: \(langName)")
            return
        }

        let (oldReq, oldTask, pendingCommit) = lock.withLock { state -> (SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?, PendingCommit?) in
            let r = state.request
            state.request = nil
            let t = state.task
            state.task = nil
            let commit = Self.consumePendingCommit(&state)
            if forceReplace && commit == nil && state.pendingPCMBuffers.isEmpty && !state.recentSessionBuffers.isEmpty {
                state.pendingPCMBuffers = Array(state.recentSessionBuffers.suffix(8))
            }
            return (r, t, commit)
        }

        oldReq?.endAudio()
        oldTask?.cancel()

        if let commit = pendingCommit {
            commitCompletedSentence(
                commit.original,
                fallbackTranslated: commit.fallbackTranslated,
                fallbackUntranslated: commit.fallbackUntranslated,
                utteranceID: commit.utteranceID
            )
        }

        let newReq = SFSpeechAudioBufferRecognitionRequest()
        newReq.shouldReportPartialResults = true
        newReq.taskHint = .dictation
        newReq.addsPunctuation = true
        newReq.requiresOnDeviceRecognition = true

        let (shouldProceed, stashedPCMs, currentTaskSession) = lock.withLock { state -> (Bool, [SendablePCMBuffer], UInt64) in
            guard state.isRunning, !state.isSuspended else {
                return (false, [], state.sessionTaskId)
            }
            state.request = newReq
            let now = ProcessInfo.processInfo.systemUptime
            state.sessionStartTime = now
            if state.lastBufferArrivalTime == 0 {
                state.lastBufferArrivalTime = now
            }
            if forceReplace && pendingCommit == nil && state.pendingPCMBuffers.isEmpty && !state.recentSessionBuffers.isEmpty {
                state.pendingPCMBuffers = Array(state.recentSessionBuffers.suffix(8))
            }
            let pcms = state.pendingPCMBuffers
            state.pendingPCMBuffers.removeAll(keepingCapacity: true)
            state.sessionTaskId &+= 1
            return (true, pcms, state.sessionTaskId)
        }
        guard shouldProceed else { return }

        for pBuf in stashedPCMs {
            newReq.append(pBuf.buffer)
        }

        scheduleNoBufferWatchdog(after: noBufferIdleTimeout)

        let newTask = recognizer.recognitionTask(with: newReq) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let nsError = error as NSError?

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let (isCurrentTask, hadNoRecognizedText, taskLocaleId) = self.lock.withLock { state -> (Bool, Bool, String) in
                    return (
                        state.sessionTaskId == currentTaskSession,
                        state.currentOriginal.isEmpty,
                        state.sourceLocaleId
                    )
                }
                guard isCurrentTask else { return }

                if let nsError = nsError {
                    let knownCode = SpeechRecognitionErrorCode(rawValue: nsError.code)
                    let now = ProcessInfo.processInfo.systemUptime
                    let (errCount, hasPending, isSusp, isRunningNow, hasPendingText) = self.lock.withLock { state -> (Int, Bool, Bool, Bool, Bool) in
                        state.request = nil
                        state.task = nil
                        state.noBufferWatchdogWorkItem?.item.cancel()
                        state.noBufferWatchdogWorkItem = nil
                        if state.isSuspended {
                            state.recentSessionBuffers.removeAll(keepingCapacity: true)
                            return (0, false, true, state.isRunning, false)
                        }
                        state.consecutiveErrors += 1
                        let recentlyActive = (now - state.lastBufferArrivalTime) < 0.65
                        if knownCode == .retry && hadNoRecognizedText && recentlyActive && state.pendingPCMBuffers.isEmpty && !state.recentSessionBuffers.isEmpty && state.consecutiveErrors == 1 {
                            state.pendingPCMBuffers = state.recentSessionBuffers
                        }
                        state.recentSessionBuffers.removeAll(keepingCapacity: true)
                        let hasOrig = !state.currentOriginal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        return (state.consecutiveErrors, !state.pendingPCMBuffers.isEmpty, false, state.isRunning, hasOrig)
                    }

                    if isSusp { return }

                    switch knownCode {
                    case .notAuthorizedOrMissingAsset:
                        let currentAuth = SFSpeechRecognizer.authorizationStatus()
                        if currentAuth == .notDetermined {
                            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                                DispatchQueue.main.async {
                                    guard let self = self else { return }
                                    if status == .authorized && self.isRunning {
                                        self.scheduleRestart(after: 0.1, forceReplace: false)
                                    } else if status != .authorized {
                                        self.noteFailure("Speech Recognition access required")
                                    }
                                }
                            }
                        } else if currentAuth == .denied || currentAuth == .restricted {
                            self.noteFailure("Speech Recognition access required")
                        } else {
                            let langCode = taskLocaleId.components(separatedBy: "-").first ?? ""
                            let langName = SupportedLanguages.item(forCode: langCode)?.name ?? taskLocaleId
                            self.noteFailure("Dictation language required: \(langName)")
                        }
                        return

                    case .dictationDisabled:
                        self.noteFailure("Dictation is disabled in System Settings")
                        return

                    case .cancelled, .requestCancelled:
                        if hasPendingText {
                            self.commitSilenceThought()
                        }
                        return

                    case .noSpeechDetected, .retry:
                        if hasPendingText {
                            self.commitSilenceThought()
                        } else {
                            self.closeCurrentSession()
                        }
                        if hasPending && isRunningNow {
                            self.scheduleRestart(after: 0.08, forceReplace: false)
                        }
                        return

                    case .none:
                        if hasPendingText {
                            self.commitSilenceThought()
                        } else {
                            self.closeCurrentSession()
                        }
                        let delay = min(1.5, 0.20 * Double(errCount))
                        if isRunningNow && hasPending {
                            self.scheduleRestart(after: delay, forceReplace: false)
                        }
                        return
                    }
                }

                guard let text = text else { return }
                self.lock.withLock {
                    $0.consecutiveErrors = 0
                    $0.recentSessionBuffers.removeAll(keepingCapacity: true)
                    $0.failureCount = 0
                    $0.failureBackoffUntil = 0
                    $0.lastReportedFailure = nil
                    $0.lastFailureReportTime = 0
                }
                self.processRecognizedSessionText(text, isFinal: isFinal)
            }
        }

        let shouldCancelNewTask = lock.withLock { state -> Bool in
            guard state.isRunning, !state.isSuspended, state.sessionTaskId == currentTaskSession else {
                return true
            }
            state.task = newTask
            return false
        }
        if shouldCancelNewTask {
            newReq.endAudio()
            newTask.cancel()
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.onAuthSuccess?()
        }
    }

    private func noteFailure(_ message: String) {
        let now = ProcessInfo.processInfo.systemUptime
        let shouldReport = lock.withLock { state -> Bool in
            state.failureCount += 1
            let exponent = min(5, max(1, state.failureCount))
            let delays: [TimeInterval] = [2, 5, 15, 60, 300, 300]
            state.failureBackoffUntil = now + delays[exponent - 1]
            let report = state.lastReportedFailure != message
                || (now - state.lastFailureReportTime) >= 60
            if report {
                state.lastReportedFailure = message
                state.lastFailureReportTime = now
            }
            return report
        }
        AppLog.speech.warning("[SpeechChannel \(self.channelName, privacy: .public)] \(message, privacy: .public)")
        if shouldReport {
            onAuthError?(message)
        }
    }

    private func scheduleRestart(after delay: TimeInterval, forceReplace: Bool = false) {
        let work = SendableWorkItem(item: DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let shouldStart = self.lock.withLock { state -> Bool in
                state.restartWorkItem = nil
                guard state.isRunning else {
                    state.isRestartScheduled = false
                    return false
                }
                return true
            }
            guard shouldStart else { return }
            self.startNewSession(forceReplace: forceReplace)
        })
        let scheduled = lock.withLock { state -> Bool in
            guard state.isRunning else {
                state.isRestartScheduled = false
                state.restartWorkItem?.item.cancel()
                state.restartWorkItem = nil
                return false
            }
            state.isRestartScheduled = true
            state.restartWorkItem?.item.cancel()
            state.restartWorkItem = work
            return true
        }
        guard scheduled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work.item)
    }


    private func dynamicPauseCommitInterval(for text: String) -> TimeInterval {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return pauseCommitInterval }

        if let lastScalar = trimmed.unicodeScalars.last, Self.terminalPunctuationScalars.contains(lastScalar) {
            return 1.35
        }
        return pauseCommitInterval
    }

    private func scheduleSilenceCommit(for text: String) {
        let timeout = dynamicPauseCommitInterval(for: text)
        scheduleSilenceCommitAfter(delay: timeout, requiredIdle: timeout)
    }

    private func scheduleSilenceCommitAfter(delay: TimeInterval, requiredIdle: TimeInterval) {
        let work = SendableWorkItem(item: DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let (isRunningNow, lastActivity) = self.lock.withLock { state -> (Bool, TimeInterval) in
                state.silenceCommitWorkItem = nil
                return (state.isRunning, state.lastSpeechActivityTime)
            }
            guard isRunningNow else { return }
            let textIdle = ProcessInfo.processInfo.systemUptime - lastActivity
            if textIdle < (requiredIdle - 0.08) {
                let remaining = max(0.15, requiredIdle - textIdle)
                self.scheduleSilenceCommitAfter(delay: remaining, requiredIdle: requiredIdle)
                return
            }
            self.commitSilenceThought()
        })
        lock.withLock { state in
            state.silenceCommitWorkItem?.item.cancel()
            state.silenceCommitWorkItem = work
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work.item)
    }

    private func processRecognizedSessionText(_ rawFullText: String, isFinal: Bool) {
        let trimmedFull = rawFullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFull.isEmpty else {
            let hasPending = lock.withLock { !$0.currentOriginal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if isFinal && hasPending {
                commitSilenceThought()
            }
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let outcome = lock.withLock { state -> (
            shouldProcess: Bool,
            shrunkCommit: PendingCommit?,
            utteranceID: UUID,
            displayTrans: String,
            displayUntranslated: Bool,
            isSameLanguage: Bool
        ) in
            if trimmedFull == state.lastRawFullText && !isFinal {
                return (false, nil, UUID(), "", false, false)
            }

            if state.currentUtteranceID == nil {
                state.currentUtteranceID = UUID()
            }

            var shrunkCommit: PendingCommit? = nil
            let prevOrig = state.currentOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prevOrig.isEmpty {
                let prevWords = prevOrig.split(whereSeparator: { $0.isWhitespace })
                let newWords = trimmedFull.split(whereSeparator: { $0.isWhitespace })
                let isPrefixShrink = prevOrig.lowercased().hasPrefix(trimmedFull.lowercased())
                let isDramaticShrink = (prevOrig.count >= 8 && (
                    (!isPrefixShrink && (trimmedFull.count * 2 <= prevOrig.count || (prevOrig.count - trimmedFull.count >= 12 && newWords.count + 2 <= prevWords.count))) ||
                    (prevWords.count >= 4 && newWords.count <= 1 && prevOrig.count - trimmedFull.count >= 14)
                ))
                if isDramaticShrink {
                    shrunkCommit = PendingCommit(
                        utteranceID: state.currentUtteranceID ?? UUID(),
                        original: prevOrig,
                        fallbackTranslated: state.currentTranslated,
                        fallbackUntranslated: state.currentIsUntranslated
                    )
                    state.currentUtteranceID = nil
                    state.currentOriginal = ""
                    state.currentTranslated = ""
                    state.currentIsUntranslated = false
                    state.pendingTailText = nil
                    state.isTranslating = false
                    state.sessionEpoch &+= 1
                }
            }

            state.lastRawFullText = trimmedFull
            state.lastSpeechActivityTime = now
            state.currentOriginal = trimmedFull
            if state.currentUtteranceID == nil {
                state.currentUtteranceID = UUID()
            }
            let utteranceID = state.currentUtteranceID!

            let src = state.sourceLocaleId.components(separatedBy: "-").first ?? "es"
            let isSameLanguage = (src.lowercased() == state.targetLangCode.lowercased())

            let displayTrans: String
            let displayUntranslated: Bool
            if isSameLanguage {
                state.currentTranslated = trimmedFull
                state.currentIsUntranslated = false
                displayTrans = trimmedFull
                displayUntranslated = false
            } else {
                displayTrans = state.currentTranslated.isEmpty ? trimmedFull : state.currentTranslated
                displayUntranslated = state.currentIsUntranslated
                state.pendingTailText = trimmedFull
            }

            state.silenceCommitWorkItem?.item.cancel()
            state.silenceCommitWorkItem = nil

            return (true, shrunkCommit, utteranceID, displayTrans, displayUntranslated, isSameLanguage)
        }

        guard outcome.shouldProcess else { return }

        if let shrunkCommit = outcome.shrunkCommit {
            commitCompletedSentence(
                shrunkCommit.original,
                fallbackTranslated: shrunkCommit.fallbackTranslated,
                fallbackUntranslated: shrunkCommit.fallbackUntranslated,
                utteranceID: shrunkCommit.utteranceID
            )
        }

        onPartial?(outcome.utteranceID, trimmedFull, outcome.displayTrans, outcome.displayUntranslated)
        if !outcome.isSameLanguage {
            pumpTranslationLoop(utteranceID: outcome.utteranceID)
        }

        if !isFinal {
            scheduleSilenceCommit(for: trimmedFull)
        } else {
            commitSilenceThought()
        }
    }

    private func pumpTranslationLoop(utteranceID: UUID) {
        let pumpParams = lock.withLock { state -> (String, String, String, UInt64, UInt64)? in
            guard !state.isTranslating else { return nil }
            guard let textToTranslate = state.pendingTailText, !textToTranslate.isEmpty else { return nil }
            state.pendingTailText = nil
            state.isTranslating = true
            let src = state.sourceLocaleId.components(separatedBy: "-").first ?? "es"
            let tgt = state.targetLangCode
            return (textToTranslate, src, tgt, state.sessionEpoch, state.resetEpoch)
        }
        guard let (textToTranslate, src, tgt, capturedEpoch, capturedResetEpoch) = pumpParams else { return }

        let taskId = UUID()
        let task = Task { [weak self] in
            defer {
                self?.activeTasksLock.withLock { tasks in
                    _ = tasks.removeValue(forKey: taskId)
                }
            }
            let translated = await TranslationEngine.shared.translate(
                text: textToTranslate,
                sourceCode: src,
                targetCode: tgt,
                isFinal: false
            )
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                let (partialUpdate, shouldPumpAgain) = self.lock.withLock { state -> ((String, String, Bool)?, Bool) in
                    if state.sessionEpoch == capturedEpoch && state.resetEpoch == capturedResetEpoch {
                        state.isTranslating = false
                    }
                    guard !Task.isCancelled,
                          state.isRunning,
                          state.sessionEpoch == capturedEpoch,
                          state.resetEpoch == capturedResetEpoch,
                          state.currentUtteranceID == utteranceID else {
                        return (nil, false)
                    }

                    if let translated = translated, !translated.isEmpty {
                        state.currentTranslated = translated
                        state.currentIsUntranslated = false
                    } else {
                        state.currentIsUntranslated = true
                    }
                    let activeOrig = state.currentOriginal
                    let partial: (String, String, Bool)?
                    if !activeOrig.isEmpty {
                        let displayTrans = state.currentTranslated.isEmpty ? activeOrig : state.currentTranslated
                        partial = (activeOrig, displayTrans, state.currentIsUntranslated)
                    } else {
                        partial = nil
                    }
                    return (partial, state.pendingTailText != nil)
                }

                if let (activeOrig, displayTrans, isUntrans) = partialUpdate {
                    self.onPartial?(utteranceID, activeOrig, displayTrans, isUntrans)
                }

                if shouldPumpAgain {
                    self.pumpTranslationLoop(utteranceID: utteranceID)
                }
            }
        }
        activeTasksLock.withLock { $0[taskId] = task }
    }

    private func commitCompletedSentence(_ orig: String, fallbackTranslated: String = "", fallbackUntranslated: Bool = false, utteranceID: UUID) {
        let cleanOrig = orig.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanOrig.isEmpty else { return }

        let (src, tgt, capturedResetEpoch) = lock.withLock { state -> (String, String, UInt64) in
            let s = state.sourceLocaleId.components(separatedBy: "-").first ?? "es"
            return (s, state.targetLangCode, state.resetEpoch)
        }
        if src.lowercased() == tgt.lowercased() {
            onFinal?(utteranceID, cleanOrig, cleanOrig, false)
            return
        }

        let cleanFallback = fallbackTranslated.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialUntranslated = fallbackUntranslated || cleanFallback.isEmpty
        let initialTrans = cleanFallback.isEmpty ? cleanOrig : cleanFallback
        onFinal?(utteranceID, cleanOrig, initialTrans, initialUntranslated)

        let taskId = UUID()
        let task = Task { [weak self] in
            defer {
                self?.activeTasksLock.withLock { tasks in
                    _ = tasks.removeValue(forKey: taskId)
                }
            }
            let translated = await TranslationEngine.shared.translate(
                text: cleanOrig,
                sourceCode: src,
                targetCode: tgt,
                isFinal: true
            )
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self = self, !Task.isCancelled, self.isRunning, self.currentResetEpoch == capturedResetEpoch else { return }
                if let translated = translated {
                    let cleanRefined = translated.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleanRefined.isEmpty && (cleanRefined != initialTrans || initialUntranslated) {
                        self.onFinal?(utteranceID, cleanOrig, cleanRefined, false)
                    }
                } else if !initialUntranslated {
                    self.onFinal?(utteranceID, cleanOrig, cleanOrig, true)
                }
            }
        }
        activeTasksLock.withLock { $0[taskId] = task }
    }

    private func commitSilenceThought() {
        let pendingCommit = lock.withLock { state -> PendingCommit? in
            state.silenceCommitWorkItem?.item.cancel()
            state.silenceCommitWorkItem = nil
            let trimmed = state.currentOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return Self.consumePendingCommit(&state)
        }
        guard let commit = pendingCommit else { return }

        commitCompletedSentence(
            commit.original,
            fallbackTranslated: commit.fallbackTranslated,
            fallbackUntranslated: commit.fallbackUntranslated,
            utteranceID: commit.utteranceID
        )
        closeCurrentSession()
    }

    private func closeCurrentSession() {
        let now = ProcessInfo.processInfo.systemUptime
        let (pendingCommit, oldReq, oldTask, shouldStartNext) = lock.withLock { state -> (PendingCommit?, SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?, Bool) in
            let commit = Self.consumePendingCommit(&state)
            state.sessionTaskId &+= 1
            Self.cancelWorkItems(&state)
            state.isStartingSession = false
            state.isRestartScheduled = false
            state.consecutiveErrors = 0
            let r = state.request
            state.request = nil
            let t = state.task
            state.task = nil
            state.recentSessionBuffers.removeAll(keepingCapacity: true)
            let hasFreshPending = state.isRunning && !state.isSuspended && !state.pendingPCMBuffers.isEmpty && (now - state.lastBufferArrivalTime) < 0.6
            if !hasFreshPending {
                state.pendingPCMBuffers.removeAll(keepingCapacity: true)
            } else {
                state.isRestartScheduled = true
            }
            return (commit, r, t, hasFreshPending)
        }

        if let commit = pendingCommit {
            commitCompletedSentence(
                commit.original,
                fallbackTranslated: commit.fallbackTranslated,
                fallbackUntranslated: commit.fallbackUntranslated,
                utteranceID: commit.utteranceID
            )
        }

        oldReq?.endAudio()
        oldTask?.cancel()
        onSessionClosed?()
        if shouldStartNext {
            scheduleRestart(after: 0.02, forceReplace: false)
        }
    }
}

public final class SpeechRecognitionManager: NSObject, @unchecked Sendable {
    public weak var delegate: BidirectionalSpeechDelegate?

    public let callerChannel = SingleSpeechChannel(name: "caller", sourceLocaleId: "es-ES", targetLangCode: "en")
    public let micChannel = SingleSpeechChannel(name: "mic", sourceLocaleId: "en-US", targetLangCode: "es")

    private let managerLock = OSAllocatedUnfairLock()
    private var _isRunning: Bool = false
    private var micFloorReleaseWorkItem: DispatchWorkItem?

    public var isRunning: Bool {
        managerLock.withLock { _isRunning }
    }

    private func cancelMicFloorReleaseWorkItem() {
        managerLock.withLock {
            micFloorReleaseWorkItem?.cancel()
            micFloorReleaseWorkItem = nil
        }
    }

    private let isolationLock = OSAllocatedUnfairLock()
    private var _overrideAcousticIsolation: Bool? = nil

    public var isAcousticallyIsolated: Bool {
        get {
            isolationLock.withLock {
                if let overridden = _overrideAcousticIsolation {
                    return overridden
                }
                return AudioCaptureEngine.isAudioOutputAcousticallyIsolated()
            }
        }
        set {
            isolationLock.withLock {
                _overrideAcousticIsolation = newValue
            }
            AudioCaptureEngine.overrideAcousticIsolation = newValue
        }
    }

    public override init() {
        super.init()
        setupCallbacks()
    }

    public static func requestAuthorization(completion: @escaping @Sendable (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status == .authorized)
            }
        }
    }

    private func setupCallbacks() {
        callerChannel.onPartial = { [weak self] utteranceID, orig, trans, isUntrans in
            self?.delegate?.callerSpeechDidUpdate(utteranceID: utteranceID, partialOriginal: orig, partialTranslated: trans, isUntranslated: isUntrans)
        }
        callerChannel.onFinal = { [weak self] utteranceID, orig, trans, isUntrans in
            self?.delegate?.callerSpeechDidFinalize(utteranceID: utteranceID, original: orig, translated: trans, isUntranslated: isUntrans)
        }
        callerChannel.onAuthError = { [weak self] msg in
            self?.delegate?.speechRecognitionDidEncounterAuthError(message: msg)
        }
        callerChannel.onAuthSuccess = { [weak self] in
            self?.delegate?.speechRecognitionDidClearAuthError()
        }
        callerChannel.onSessionClosed = { [weak self] in
            guard let self = self else { return }
            self.cancelMicFloorReleaseWorkItem()
            self.micChannel.resumeAfterMicPriority()
        }

        micChannel.onPartial = { [weak self] utteranceID, orig, trans, isUntrans in
            self?.delegate?.micSpeechDidUpdate(utteranceID: utteranceID, partialOriginal: orig, partialTranslated: trans, isUntranslated: isUntrans)
        }
        micChannel.onFinal = { [weak self] utteranceID, orig, trans, isUntrans in
            self?.delegate?.micSpeechDidFinalize(utteranceID: utteranceID, original: orig, translated: trans, isUntranslated: isUntrans)
        }
        micChannel.onAuthError = { [weak self] msg in
            self?.delegate?.speechRecognitionDidEncounterAuthError(message: msg)
        }
        micChannel.onAuthSuccess = { [weak self] in
            self?.delegate?.speechRecognitionDidClearAuthError()
        }
    }

    public func start(
        callerLocaleId: String,
        targetLangCode: String = "en",
        micLocaleId: String = "en-US",
        micTargetLangCode: String = "es",
        isMicEnabled: Bool = false
    ) {
        stop()
        managerLock.withLock {
            _isRunning = true
        }

        callerChannel.start(sourceLocaleId: callerLocaleId, targetLangCode: targetLangCode)

        if isMicEnabled {
            micChannel.start(sourceLocaleId: micLocaleId, targetLangCode: micTargetLangCode)
        } else {
            micChannel.stop()
        }
    }

    public func stop() {
        managerLock.withLock {
            _isRunning = false
            micFloorReleaseWorkItem?.cancel()
            micFloorReleaseWorkItem = nil
        }
        callerChannel.stop()
        micChannel.stop()
    }

    public func discardInFlight() {
        callerChannel.discardInFlight()
        micChannel.discardInFlight()
    }

    public func resetFailureState() {
        callerChannel.resetFailureState()
        micChannel.resetFailureState()
    }

    public func setMicEnabled(_ enabled: Bool, micLocaleId: String, micTargetLangCode: String) {
        if enabled {
            micChannel.start(sourceLocaleId: micLocaleId, targetLangCode: micTargetLangCode)
        } else {
            cancelMicFloorReleaseWorkItem()
            micChannel.stop()
            callerChannel.resumeAfterMicPriority()
        }
    }

    public func feedCallerAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        let isolated = isAcousticallyIsolated
        let toreDownMic = isolated ? false : micChannel.suspendForMicPriority()

        callerChannel.resumeAfterMicPriority()
        callerChannel.appendPCMBuffer(buffer, minimumStartDelay: toreDownMic ? 0.035 : 0.01)

        guard micChannel.isRunning && !isolated else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.micChannel.isRunning else {
                self.cancelMicFloorReleaseWorkItem()
                return
            }
            self.managerLock.withLock {
                self.micFloorReleaseWorkItem?.cancel()
                let item = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.managerLock.withLock {
                        self.micFloorReleaseWorkItem = nil
                    }
                    self.micChannel.resumeAfterMicPriority()
                }
                self.micFloorReleaseWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
            }
        }
    }

    public func feedMicAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        let closedIdleCaller = isAcousticallyIsolated ? false : callerChannel.finishIfIdleForPeerChannel()
        micChannel.appendPCMBuffer(buffer, minimumStartDelay: closedIdleCaller ? 0.035 : 0.01)
    }
}
