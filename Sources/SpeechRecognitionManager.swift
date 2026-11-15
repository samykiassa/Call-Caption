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

    func callerSpeechDidUpdate(utteranceID: UUID, partialOriginal: String, partialTranslated: String, sourceLangCode: String, targetLangCode: String, isUntranslated: Bool)
    func callerSpeechDidFinalize(utteranceID: UUID, original: String, translated: String, sourceLangCode: String, targetLangCode: String, isUntranslated: Bool)
    func micSpeechDidUpdate(utteranceID: UUID, partialOriginal: String, partialTranslated: String, sourceLangCode: String, targetLangCode: String, isUntranslated: Bool)
    func micSpeechDidFinalize(utteranceID: UUID, original: String, translated: String, sourceLangCode: String, targetLangCode: String, isUntranslated: Bool)
    func speechRecognitionDidEncounterAuthError(channelName: String, message: String)
    func speechRecognitionDidClearAuthError(channelName: String)
}

public extension BidirectionalSpeechDelegate {
    func callerSpeechDidUpdate(utteranceID: UUID, partialOriginal: String, partialTranslated: String, sourceLangCode: String, targetLangCode: String, isUntranslated: Bool) {
        callerSpeechDidUpdate(utteranceID: utteranceID, partialOriginal: partialOriginal, partialTranslated: partialTranslated, isUntranslated: isUntranslated)
    }

    func callerSpeechDidFinalize(utteranceID: UUID, original: String, translated: String, sourceLangCode: String, targetLangCode: String, isUntranslated: Bool) {
        callerSpeechDidFinalize(utteranceID: utteranceID, original: original, translated: translated, isUntranslated: isUntranslated)
    }

    func micSpeechDidUpdate(utteranceID: UUID, partialOriginal: String, partialTranslated: String, sourceLangCode: String, targetLangCode: String, isUntranslated: Bool) {
        micSpeechDidUpdate(utteranceID: utteranceID, partialOriginal: partialOriginal, partialTranslated: partialTranslated, isUntranslated: isUntranslated)
    }

    func micSpeechDidFinalize(utteranceID: UUID, original: String, translated: String, sourceLangCode: String, targetLangCode: String, isUntranslated: Bool) {
        micSpeechDidFinalize(utteranceID: utteranceID, original: original, translated: translated, isUntranslated: isUntranslated)
    }

    func speechRecognitionDidEncounterAuthError(channelName: String, message: String) {
        speechRecognitionDidEncounterAuthError(message: message)
    }

    func speechRecognitionDidClearAuthError(channelName: String) {
        speechRecognitionDidClearAuthError()
    }
}

public final class SingleSpeechChannel: NSObject, @unchecked Sendable {
    private struct SendablePCMBuffer: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let arrivalTime: TimeInterval

        init(buffer: AVAudioPCMBuffer, arrivalTime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
            self.buffer = buffer
            self.arrivalTime = arrivalTime
        }
    }

    private struct SendableWorkItem: @unchecked Sendable {
        let item: DispatchWorkItem
    }

    private final class ManagedRequest: @unchecked Sendable {
        let request: SFSpeechAudioBufferRecognitionRequest
        var isEnded: Bool = false

        init(_ request: SFSpeechAudioBufferRecognitionRequest) {
            self.request = request
        }
    }

    private struct PendingCommit: Sendable {
        let utteranceID: UUID
        let original: String
        let fallbackTranslated: String
        let fallbackUntranslated: Bool
        let sourceLocaleId: String
        let targetLangCode: String
    }

    /// A recognition task whose audio has ended but which is still allowed to
    /// deliver its final hypothesis. Cancelling a task right after `endAudio()`
    /// discards the words the recognizer has not emitted yet, which showed up
    /// as the last word or two of an utterance going missing.
    private struct DrainingTask {
        let utteranceID: UUID
        var text: String
        let fallbackTranslated: String
        let fallbackUntranslated: Bool
        let sourceLocaleId: String
        let targetLangCode: String
        let task: SFSpeechRecognitionTask
    }

    private enum TaskKind {
        case partial
        case final
    }

    private static let terminalPunctuationScalars: Set<UnicodeScalar> = [
        ".", "?", "!", "\u{3002}", "\u{FF1F}", "\u{FF01}", "\u{061F}"
    ]

    private static let spokenNumberWords: Set<String> = [
        "zero", "oh", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
        "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy",
        "eighty", "ninety", "hundred", "thousand", "million", "billion", "trillion",
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
        "half", "quarter", "percent", "dollar", "dollars", "cent", "cents", "euro", "euros", "pound", "pounds",
        "point", "dot", "slash", "dash", "plus", "minus", "am", "pm"
    ]

    private struct AudioState {
        var isRunning: Bool = false
        var isSuspended: Bool = false
        var sessionStartToken: UUID? = nil
        var isStartingSession: Bool { sessionStartToken != nil }
        var isRestartScheduled: Bool = false
        var isRotationScheduled: Bool = false
        var sourceLocaleId: String
        var targetLangCode: String
        var recognizer: SFSpeechRecognizer? = nil
        var request: ManagedRequest? = nil
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
        var discardEpoch: UInt64 = 0
        var sessionTaskId: UInt64 = 0
        var activeTaskId: UInt64 = 0
        var drainingTasks: [UInt64: DrainingTask] = [:]
        var isTranslating: Bool = false
        var activeTranslationTaskId: UUID? = nil
        var pendingTailText: String? = nil
    }

    private let lock: OSAllocatedUnfairLock<AudioState>
    // Serializes SFSpeechAudioBufferRecognitionRequest.append vs endAudio;
    // lock ordering invariant: always acquire `lock` before `requestIOLock`, never reverse.
    private let requestIOLock = NSLock()

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

    private var currentDiscardEpoch: UInt64 {
        lock.withLock { $0.discardEpoch }
    }

    public var onPartial: ((UUID, String, String, Bool) -> Void)?
    public var onFinal: ((UUID, String, String, Bool) -> Void)?
    public var onPartialWithLanguages: ((UUID, String, String, String, String, Bool) -> Void)?
    public var onFinalWithLanguages: ((UUID, String, String, String, String, Bool) -> Void)?
    public var onAuthError: ((String) -> Void)?
    public var onAuthSuccess: (() -> Void)?
    public var onAuthErrorWithChannel: ((String, String) -> Void)?
    public var onAuthSuccessWithChannel: ((String) -> Void)?
    public var onSessionClosed: (() -> Void)?

    private let activeTasksLock = OSAllocatedUnfairLock(initialState: [UUID: (kind: TaskKind, task: Task<Void, Never>)]())

    private func cancelInFlightTranslationTasks(partialsOnly: Bool = false) {
        let tasksToCancel = activeTasksLock.withLock { tasks -> [Task<Void, Never>] in
            if partialsOnly {
                var cancelled: [Task<Void, Never>] = []
                for (id, entry) in tasks where entry.kind == .partial {
                    cancelled.append(entry.task)
                    tasks.removeValue(forKey: id)
                }
                return cancelled
            } else {
                let list = Array(tasks.values.map(\.task))
                tasks.removeAll()
                return list
            }
        }
        for task in tasksToCancel {
            task.cancel()
        }
    }

    private static func baseLanguageCode(from identifier: String) -> String {
        let norm = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        let prefix = norm.components(separatedBy: "-").first ?? norm
        return prefix.isEmpty ? "es" : prefix
    }

    private static func translationLanguageCode(from identifier: String, resolveBareChinese: Bool = false) -> String {
        let norm = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        if norm == "zh-tw" || norm == "zh-hk" || norm == "zh-hant" || norm.hasPrefix("zh-hant-") {
            return "zh-hant"
        }
        if norm == "zh-cn" || norm == "zh-sg" || norm == "zh-hans" || norm.hasPrefix("zh-hans-") {
            return "zh-hans"
        }
        if norm == "zh" {
            if resolveBareChinese {
                let preferred = SupportedLanguages.bestLocale(forCode: "zh").identifier
                    .replacingOccurrences(of: "_", with: "-")
                    .lowercased()
                if preferred.contains("tw") || preferred.contains("hk") || preferred.contains("hant") {
                    return "zh-hant"
                }
            }
            return "zh-hans"
        }
        return baseLanguageCode(from: norm)
    }

    private func appendBuffer(_ buffer: AVAudioPCMBuffer, to managed: ManagedRequest?) -> Bool {
        guard let managed else { return false }
        requestIOLock.lock()
        defer { requestIOLock.unlock() }
        guard !managed.isEnded else { return false }
        managed.request.append(buffer)
        return true
    }

    private func endManagedRequest(_ managed: ManagedRequest?) {
        guard let managed else { return }
        requestIOLock.lock()
        let shouldEnd = !managed.isEnded
        if shouldEnd {
            managed.isEnded = true
        }
        requestIOLock.unlock()
        if shouldEnd {
            managed.request.endAudio()
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
    private static let drainTimeout: TimeInterval = 1.2

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
        state.activeTranslationTaskId = nil
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
            fallbackUntranslated: state.currentIsUntranslated,
            sourceLocaleId: state.sourceLocaleId,
            targetLangCode: state.targetLangCode
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

    /// Detaches the current recognition task from the live session and parks it
    /// in `drainingTasks` so it can still deliver its final result. The pending
    /// utterance text is moved into the drain entry and committed when the task
    /// finishes (or when `drainTimeout` elapses). Returns the drain id to schedule
    /// a timeout for, or a commit to perform immediately when there is no live task.
    /// The caller is responsible for calling `endManagedRequest(...)` on the request.
    private static func retireTaskForDraining(_ state: inout AudioState) -> (drainId: UInt64?, commit: PendingCommit?) {
        let srcLocale = state.sourceLocaleId
        let tgtCode = state.targetLangCode
        let commit = consumePendingCommit(&state)
        guard let task = state.task else { return (nil, commit) }
        state.task = nil
        switch task.state {
        case .starting, .running, .finishing:
            break
        default:
            return (nil, commit)
        }
        let id = state.activeTaskId
        if let existing = state.drainingTasks.removeValue(forKey: id) {
            existing.task.cancel()
        }
        state.drainingTasks[id] = DrainingTask(
            utteranceID: commit?.utteranceID ?? UUID(),
            text: commit?.original ?? "",
            fallbackTranslated: commit?.fallbackTranslated ?? "",
            fallbackUntranslated: commit?.fallbackUntranslated ?? true,
            sourceLocaleId: commit?.sourceLocaleId ?? srcLocale,
            targetLangCode: commit?.targetLangCode ?? tgtCode,
            task: task
        )
        return (id, nil)
    }

    private func scheduleDrainTimeout(_ drainId: UInt64) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.drainTimeout) { [weak self] in
            self?.finalizeDrain(drainId, latestText: nil)
        }
    }

    private func handleDrainingTaskCallback(taskId: UInt64, text: String?, isFinal: Bool, failed: Bool) {
        if isFinal || failed {
            finalizeDrain(taskId, latestText: text)
            return
        }
        guard let text = text else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.withLock { state in
            guard var drain = state.drainingTasks[taskId] else { return }
            drain.text = Self.preferredDrainText(previous: drain.text, candidate: trimmed)
            state.drainingTasks[taskId] = drain
        }
    }

    private func finalizeDrain(_ drainId: UInt64, latestText: String?) {
        let drain = lock.withLock { state -> DrainingTask? in
            guard var d = state.drainingTasks.removeValue(forKey: drainId) else { return nil }
            if let latest = latestText?.trimmingCharacters(in: .whitespacesAndNewlines), !latest.isEmpty {
                d.text = Self.preferredDrainText(previous: d.text, candidate: latest)
            }
            return d
        }
        guard let drain = drain else { return }
        drain.task.cancel()
        guard !drain.text.isEmpty else { return }
        commitCompletedSentence(
            drain.text,
            fallbackTranslated: drain.fallbackTranslated,
            fallbackUntranslated: drain.fallbackUntranslated,
            utteranceID: drain.utteranceID,
            sourceLocaleId: drain.sourceLocaleId,
            targetLangCode: drain.targetLangCode
        )
    }

    /// Accepts the recognizer's newer hypothesis unless it collapsed to a much
    /// shorter string (the recognizer occasionally resets), in which case the
    /// text already shown to the user is kept.
    private static func preferredDrainText(previous: String, candidate: String) -> String {
        guard !previous.isEmpty else { return candidate }
        return candidate.count * 10 >= previous.count * 7 ? candidate : previous
    }

    private func takeAllDrains() -> [DrainingTask] {
        lock.withLock { state -> [DrainingTask] in
            let all = Array(state.drainingTasks.values)
            state.drainingTasks.removeAll()
            return all
        }
    }

    public func start(sourceLocaleId: String, targetLangCode: String) {
        stop()
        cancelInFlightTranslationTasks(partialsOnly: false)
        let normLocale = sourceLocaleId.replacingOccurrences(of: "_", with: "-")
        lock.withLock { state in
            state.sourceLocaleId = normLocale
            state.targetLangCode = targetLangCode
            state.isRunning = true
            state.isSuspended = false
            state.isRestartScheduled = false
            state.isRotationScheduled = false
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
            state.discardEpoch &+= 1
            state.sessionTaskId &+= 1
            Self.cancelWorkItems(&state)
            Self.resetSessionTrackingState(&state)
        }

        setupRecognizer()
    }

    public func stop() {
        let (oldReq, oldTask, pendingCommit) = lock.withLock { state -> (ManagedRequest?, SFSpeechRecognitionTask?, PendingCommit?) in
            state.isRunning = false
            state.isSuspended = false
            state.isRestartScheduled = false
            state.isRotationScheduled = false
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

        // Cancel in-flight partial translations before committing finalized drains/pending utterances,
        // while keeping newly spawned final refinement tasks alive to deliver updated translations.
        cancelInFlightTranslationTasks(partialsOnly: true)

        for drain in takeAllDrains() {
            drain.task.cancel()
            if !drain.text.isEmpty {
                commitCompletedSentence(
                    drain.text,
                    fallbackTranslated: drain.fallbackTranslated,
                    fallbackUntranslated: drain.fallbackUntranslated,
                    utteranceID: drain.utteranceID,
                    sourceLocaleId: drain.sourceLocaleId,
                    targetLangCode: drain.targetLangCode
                )
            }
        }

        if let commit = pendingCommit {
            commitCompletedSentence(
                commit.original,
                fallbackTranslated: commit.fallbackTranslated,
                fallbackUntranslated: commit.fallbackUntranslated,
                utteranceID: commit.utteranceID,
                sourceLocaleId: commit.sourceLocaleId,
                targetLangCode: commit.targetLangCode
            )
            onSessionClosed?()
        }

        endManagedRequest(oldReq)
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
        let (oldReq, oldTask) = lock.withLock { state -> (ManagedRequest?, SFSpeechRecognitionTask?) in
            let r = state.request
            state.request = nil
            let t = state.task
            state.task = nil
            state.isRestartScheduled = false
            state.isRotationScheduled = false
            state.pendingPCMBuffers.removeAll(keepingCapacity: false)
            state.recentSessionBuffers.removeAll(keepingCapacity: false)
            state.sessionTaskId &+= 1
            state.sessionEpoch &+= 1
            state.resetEpoch &+= 1
            state.discardEpoch &+= 1
            Self.cancelWorkItems(&state)
            Self.resetSessionTrackingState(&state)
            return (r, t)
        }
        for drain in takeAllDrains() {
            drain.task.cancel()
        }
        cancelInFlightTranslationTasks(partialsOnly: false)
        endManagedRequest(oldReq)
        oldTask?.cancel()
    }

    #if CALLCAPTION_TESTING
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
            state.activeTranslationTaskId = nil
        }
    }

    public static func isLikelyInverseTextNormalizationForTesting(previous: String, updated: String) -> Bool {
        isLikelyInverseTextNormalization(previous: previous, updated: updated)
    }

    public func processRecognizedTextForTesting(_ text: String, isFinal: Bool = false) {
        processRecognizedSessionText(text, isFinal: isFinal)
    }

    public func activeUtteranceStateForTesting() -> (
        isRunning: Bool,
        utteranceID: UUID?,
        isTranslating: Bool,
        activeTranslationTaskId: UUID?,
        currentOriginal: String,
        discardEpoch: UInt64
    ) {
        lock.withLock { state in
            (
                state.isRunning,
                state.currentUtteranceID,
                state.isTranslating,
                state.activeTranslationTaskId,
                state.currentOriginal,
                state.discardEpoch
            )
        }
    }
    #endif

    @discardableResult
    public func suspendForMicPriority() -> Bool {
        // Audio that reaches a suspended channel is stashed in `pendingPCMBuffers`
        // (bounded by `maxSuspendedBuffers`) and replayed on resume. For the mic
        // channel those buffers have already passed the capture engine's
        // echo-aware gate, so dropping them only lost the user's first words when
        // replying right after the caller finished speaking.
        let (wasAlreadySuspended, oldReq, drainId, immediateCommit, capturedResetEpoch, capturedDiscardEpoch) = lock.withLock { state -> (Bool, ManagedRequest?, UInt64?, PendingCommit?, UInt64, UInt64) in
            let already = state.isSuspended
            state.isSuspended = true
            state.isRestartScheduled = false
            state.isRotationScheduled = false
            state.consecutiveErrors = 0
            let r = state.request
            state.request = nil
            state.recentSessionBuffers.removeAll(keepingCapacity: true)
            var drainId: UInt64? = nil
            var commit: PendingCommit? = nil
            if !already || r != nil {
                state.sessionTaskId &+= 1
                Self.cancelWorkItems(&state)
                (drainId, commit) = Self.retireTaskForDraining(&state)
            }
            return (already, r, drainId, commit, state.resetEpoch, state.discardEpoch)
        }
        let hadActiveReq = (oldReq != nil)
        endManagedRequest(oldReq)
        if let drainId = drainId {
            scheduleDrainTimeout(drainId)
        }
        guard !wasAlreadySuspended || hadActiveReq else { return false }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let (canCommitImmediate, lateCommit, strayTask) = self.lock.withLock { state -> (Bool, PendingCommit?, SFSpeechRecognitionTask?) in
                guard state.isRunning,
                      state.resetEpoch == capturedResetEpoch,
                      state.discardEpoch == capturedDiscardEpoch else {
                    return (false, nil, nil)
                }
                guard state.isSuspended else {
                    return (true, nil, nil)
                }
                let commit = Self.consumePendingCommit(&state)
                let t = state.task
                state.task = nil
                return (true, commit, t)
            }

            if canCommitImmediate, let immediateCommit = immediateCommit {
                self.commitCompletedSentence(
                    immediateCommit.original,
                    fallbackTranslated: immediateCommit.fallbackTranslated,
                    fallbackUntranslated: immediateCommit.fallbackUntranslated,
                    utteranceID: immediateCommit.utteranceID,
                    sourceLocaleId: immediateCommit.sourceLocaleId,
                    targetLangCode: immediateCommit.targetLangCode
                )
            }
            if let lateCommit = lateCommit {
                self.commitCompletedSentence(
                    lateCommit.original,
                    fallbackTranslated: lateCommit.fallbackTranslated,
                    fallbackUntranslated: lateCommit.fallbackUntranslated,
                    utteranceID: lateCommit.utteranceID,
                    sourceLocaleId: lateCommit.sourceLocaleId,
                    targetLangCode: lateCommit.targetLangCode
                )
            }

            strayTask?.cancel()
        }
        return hadActiveReq
    }

    public func resumeAfterMicPriority() {
        let now = ProcessInfo.processInfo.systemUptime
        let needsStart = lock.withLock { state -> Bool in
            guard state.isSuspended else { return false }
            state.isSuspended = false
            state.consecutiveErrors = 0
            state.pendingPCMBuffers.removeAll { (now - $0.arrivalTime) > 8.0 }
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
        let (shouldClose, oldReq, drainId, pendingCommit) = lock.withLock { state -> (Bool, ManagedRequest?, UInt64?, PendingCommit?) in
            guard state.isRunning, state.request != nil || state.task != nil else {
                return (false, nil, nil, nil)
            }
            let isIdle = state.lastBufferArrivalTime == 0 || (now - state.lastBufferArrivalTime) >= 0.25
            guard isIdle else { return (false, nil, nil, nil) }
            state.sessionTaskId &+= 1
            Self.cancelWorkItems(&state)
            state.isRestartScheduled = false
            state.isRotationScheduled = false
            let r = state.request
            state.request = nil
            state.recentSessionBuffers.removeAll(keepingCapacity: true)
            state.pendingPCMBuffers.removeAll(keepingCapacity: true)
            let (drainId, commit) = Self.retireTaskForDraining(&state)
            return (true, r, drainId, commit)
        }
        guard shouldClose else { return false }
        if let commit = pendingCommit {
            commitCompletedSentence(
                commit.original,
                fallbackTranslated: commit.fallbackTranslated,
                fallbackUntranslated: commit.fallbackUntranslated,
                utteranceID: commit.utteranceID,
                sourceLocaleId: commit.sourceLocaleId,
                targetLangCode: commit.targetLangCode
            )
        }
        endManagedRequest(oldReq)
        if let drainId = drainId {
            scheduleDrainTimeout(drainId)
        }
        return true
    }

    public func appendPCMBuffer(_ buffer: AVAudioPCMBuffer, minimumStartDelay: TimeInterval = 0.01) {
        let now = ProcessInfo.processInfo.systemUptime
        let wrappedBuffer = SendablePCMBuffer(buffer: buffer, arrivalTime: now)
        let maxSusp = maxSuspendedBuffers
        let (running, req, shouldCycle, needsStart, needsWatchdog, errCount) = lock.withLock { state -> (Bool, ManagedRequest?, Bool, Bool, Bool, Int) in
            guard state.isRunning else { return (false, nil, false, false, false, 0) }
            if state.isSuspended {
                if state.pendingPCMBuffers.count >= maxSusp {
                    state.pendingPCMBuffers.removeFirst()
                }
                state.pendingPCMBuffers.append(wrappedBuffer)
                return (false, nil, false, false, false, 0)
            }
            state.lastBufferArrivalTime = now
            if state.request == nil && now < state.failureBackoffUntil {
                return (true, nil, false, false, false, 0)
            }
            if state.recentSessionBuffers.count >= 16 {
                state.recentSessionBuffers.removeFirst()
            }
            state.recentSessionBuffers.append(wrappedBuffer)

            guard let r = state.request, !state.isStartingSession, !state.isRotationScheduled else {
                if state.pendingPCMBuffers.count >= maxSusp {
                    state.pendingPCMBuffers.removeFirst()
                }
                state.pendingPCMBuffers.append(wrappedBuffer)
                let shouldStart = !state.isStartingSession && !state.isRestartScheduled && state.request == nil
                if shouldStart {
                    state.isRestartScheduled = true
                }
                return (true, nil, false, shouldStart, false, state.consecutiveErrors)
            }

            let age = now - state.sessionStartTime
            if age > 56.0 {
                // Defer `sessionStartTime` and `isRestartScheduled` mutations until `appendBuffer` succeeds.
                return (true, r, true, false, false, 0)
            }
            let needWatchdog = (state.noBufferWatchdogWorkItem == nil)
            return (true, r, false, false, needWatchdog, 0)
        }

        guard running else { return }
        if let req = req {
            let appended = appendBuffer(buffer, to: req)
            if appended {
                if shouldCycle {
                    let didScheduleRotation = lock.withLock { state -> Bool in
                        guard state.isRunning, !state.isSuspended, state.request === req, !state.isRotationScheduled else {
                            return false
                        }
                        state.sessionStartTime = now
                        state.isRestartScheduled = true
                        state.isRotationScheduled = true
                        // Retain boundary frames for the incoming rotated request so active speech isn't clipped.
                        if state.pendingPCMBuffers.count < maxSusp {
                            state.pendingPCMBuffers.append(wrappedBuffer)
                        }
                        return true
                    }
                    if didScheduleRotation {
                        DispatchQueue.main.async { [weak self] in
                            self?.scheduleRestart(after: 0.05, forceReplace: true)
                        }
                    }
                } else if needsWatchdog {
                    scheduleNoBufferWatchdog(after: noBufferIdleTimeout, force: false)
                }
            } else {
                // Request ended concurrently right before append; stash buffer so it isn't dropped if restarting.
                let fallbackStart = lock.withLock { state -> Bool in
                    guard state.isRunning, !state.isSuspended, state.request == nil else { return false }
                    if state.pendingPCMBuffers.count >= maxSusp {
                        state.pendingPCMBuffers.removeFirst()
                    }
                    state.pendingPCMBuffers.append(wrappedBuffer)
                    let shouldStart = !state.isStartingSession && !state.isRestartScheduled
                    if shouldStart {
                        state.isRestartScheduled = true
                    }
                    return shouldStart
                }
                if fallbackStart {
                    DispatchQueue.main.async { [weak self] in
                        self?.scheduleRestart(after: minimumStartDelay, forceReplace: false)
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

    private func scheduleNoBufferWatchdog(after delay: TimeInterval, force: Bool = true) {
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
                self.scheduleNoBufferWatchdog(after: remaining, force: true)
                return
            }
            self.finishAudioForIdleSession()
        })
        let scheduled = lock.withLock { state -> Bool in
            guard state.isRunning, state.request != nil else { return false }
            if !force && state.noBufferWatchdogWorkItem != nil {
                return false
            }
            state.noBufferWatchdogWorkItem?.item.cancel()
            state.noBufferWatchdogWorkItem = work
            return true
        }
        guard scheduled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work.item)
    }

    private func finishAudioForIdleSession() {
        let oldReq = lock.withLock { state -> ManagedRequest? in
            let r = state.request
            state.request = nil
            return r
        }
        guard let req = oldReq else { return }
        endManagedRequest(req)

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
            let langCode = Self.baseLanguageCode(from: localeId)
            let langName = SupportedLanguages.item(forCode: langCode)?.name ?? localeId
            AppLog.speech.error("[SpeechChannel \(self.channelName, privacy: .public)] Locale '\(loc.identifier, privacy: .public)' is unsupported by SFSpeechRecognizer.")
            lock.withLock { $0.recognizer = nil }
            noteFailure("Speech recognition locale '\(langName)' is not supported by macOS.")
        }
    }

    public func startNewSession(forceReplace: Bool = false) {
        let startToken = UUID()
        let canStart = lock.withLock { state -> Bool in
            state.restartWorkItem?.item.cancel()
            state.restartWorkItem = nil
            state.isRestartScheduled = false
            state.isRotationScheduled = false
            guard state.isRunning, !state.isSuspended, state.sessionStartToken == nil else { return false }
            if !forceReplace && state.request != nil {
                return false
            }
            if state.request == nil && state.pendingPCMBuffers.isEmpty && !(forceReplace && !state.recentSessionBuffers.isEmpty) {
                return false
            }
            state.sessionStartToken = startToken
            state.silenceCommitWorkItem?.item.cancel()
            state.silenceCommitWorkItem = nil
            return true
        }
        guard canStart else { return }
        defer {
            lock.withLock { state in
                if state.sessionStartToken == startToken {
                    state.sessionStartToken = nil
                }
            }
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

        if lock.withLock({ $0.recognizer == nil || $0.recognizer?.supportsOnDeviceRecognition == false }) {
            setupRecognizer()
        }
        let (recognizer, localeId, inBackoff) = lock.withLock { state -> (SFSpeechRecognizer?, String, Bool) in
            let backoff = state.failureBackoffUntil > ProcessInfo.processInfo.systemUptime
            return (state.recognizer, state.sourceLocaleId, backoff)
        }
        guard let recognizer = recognizer else { return }

        let langCode = Self.baseLanguageCode(from: localeId)
        let langName = SupportedLanguages.item(forCode: langCode)?.name ?? localeId

        if inBackoff {
            return
        }

        guard recognizer.isAvailable && recognizer.supportsOnDeviceRecognition else {
            if SpeechAssetDownloader.shared.isDownloading(forCode: langCode) {
                let pct = SpeechAssetDownloader.shared.progressPercent(forCode: langCode)
                let suffix = pct > 0 ? " \(pct)%" : ""
                noteFailure("Downloading \(langName) dictation model…\(suffix)", isDownloadingAsset: true)
            } else {
                noteFailure("Dictation language required: \(langName)")
            }
            return
        }

        let (oldReq, oldTask, drainId, pendingCommit) = lock.withLock { state -> (ManagedRequest?, SFSpeechRecognitionTask?, UInt64?, PendingCommit?) in
            let r = state.request
            state.request = nil
            let hasText = !state.currentOriginal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let willReplayRecent = forceReplace && !hasText && state.pendingPCMBuffers.isEmpty && !state.recentSessionBuffers.isEmpty
            if willReplayRecent {
                // The recent audio is replayed into the new request, so the old
                // task must not also finalize it (that would duplicate words).
                let commit = Self.consumePendingCommit(&state)
                let t = state.task
                state.task = nil
                state.pendingPCMBuffers = Array(state.recentSessionBuffers.suffix(8))
                return (r, t, nil, commit)
            }
            let (drainId, commit) = Self.retireTaskForDraining(&state)
            return (r, nil, drainId, commit)
        }

        endManagedRequest(oldReq)
        oldTask?.cancel()
        if let drainId = drainId {
            scheduleDrainTimeout(drainId)
        }

        if let commit = pendingCommit {
            commitCompletedSentence(
                commit.original,
                fallbackTranslated: commit.fallbackTranslated,
                fallbackUntranslated: commit.fallbackUntranslated,
                utteranceID: commit.utteranceID,
                sourceLocaleId: commit.sourceLocaleId,
                targetLangCode: commit.targetLangCode
            )
        }

        let newReq = SFSpeechAudioBufferRecognitionRequest()
        newReq.shouldReportPartialResults = true
        newReq.taskHint = .dictation
        newReq.addsPunctuation = true
        newReq.requiresOnDeviceRecognition = true
        let managedNewReq = ManagedRequest(newReq)

        let (shouldProceed, stashedPCMs, currentTaskSession) = lock.withLock { state -> (Bool, [SendablePCMBuffer], UInt64) in
            guard state.isRunning, !state.isSuspended else {
                return (false, [], state.sessionTaskId)
            }
            let now = ProcessInfo.processInfo.systemUptime
            state.pendingPCMBuffers.removeAll { (now - $0.arrivalTime) > 8.0 }
            let pcms = state.pendingPCMBuffers
            state.pendingPCMBuffers.removeAll(keepingCapacity: true)
            state.sessionTaskId &+= 1
            return (true, pcms, state.sessionTaskId)
        }
        guard shouldProceed else { return }

        requestIOLock.lock()
        for pBuf in stashedPCMs {
            newReq.append(pBuf.buffer)
        }
        requestIOLock.unlock()

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
                guard isCurrentTask else {
                    self.handleDrainingTaskCallback(
                        taskId: currentTaskSession,
                        text: text,
                        isFinal: isFinal,
                        failed: nsError != nil
                    )
                    return
                }

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
                            let langCode = Self.baseLanguageCode(from: taskLocaleId)
                            let langName = SupportedLanguages.item(forCode: langCode)?.name ?? taskLocaleId
                            if SpeechAssetDownloader.shared.isDownloading(forCode: langCode) {
                                let pct = SpeechAssetDownloader.shared.progressPercent(forCode: langCode)
                                let pctSuffix = pct > 0 ? " (\(pct)%)" : "…"
                                self.noteFailure("Downloading \(langName) dictation model\(pctSuffix)", isDownloadingAsset: true)
                            } else {
                                self.noteFailure("Dictation language required: \(langName)")
                            }
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
                        if errCount >= 3 {
                            self.noteFailure("Speech recognition error: \(nsError.localizedDescription)")
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
                    $0.failureCount = 0
                    $0.failureBackoffUntil = 0
                    $0.lastReportedFailure = nil
                    $0.lastFailureReportTime = 0
                }
                self.processRecognizedSessionText(text, isFinal: isFinal)
            }
        }

        // Flush any buffers that arrived while recognitionTask was spinning up and publish
        // `state.request` atomically with `state.task`. Maintain strict lock order: lock -> requestIOLock.
        let shouldCancelNewTask = lock.withLock { state -> Bool in
            guard state.isRunning, !state.isSuspended, state.sessionTaskId == currentTaskSession else {
                return true
            }
            let now = ProcessInfo.processInfo.systemUptime
            state.pendingPCMBuffers.removeAll { (now - $0.arrivalTime) > 8.0 }
            let extraPCMs = state.pendingPCMBuffers
            state.pendingPCMBuffers.removeAll(keepingCapacity: true)
            if !extraPCMs.isEmpty {
                requestIOLock.lock()
                if !managedNewReq.isEnded {
                    for pBuf in extraPCMs {
                        newReq.append(pBuf.buffer)
                    }
                }
                requestIOLock.unlock()
            }
            state.request = managedNewReq
            state.task = newTask
            state.activeTaskId = currentTaskSession
            state.sessionStartTime = now
            if state.lastBufferArrivalTime == 0 {
                state.lastBufferArrivalTime = now
            }
            return false
        }
        if shouldCancelNewTask {
            endManagedRequest(managedNewReq)
            newTask.cancel()
            return
        }

        scheduleNoBufferWatchdog(after: noBufferIdleTimeout, force: false)

        let chName = channelName
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onAuthSuccess?()
            self.onAuthSuccessWithChannel?(chName)
        }
    }

    private func noteFailure(_ message: String, isDownloadingAsset: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        let shouldReport = lock.withLock { state -> Bool in
            if isDownloadingAsset {
                state.failureBackoffUntil = now + 2.0
            } else {
                state.failureCount += 1
                let exponent = min(5, max(1, state.failureCount))
                let delays: [TimeInterval] = [2, 5, 15, 60, 300, 300]
                state.failureBackoffUntil = now + delays[exponent - 1]
            }
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
            onAuthErrorWithChannel?(channelName, message)
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
            let (hasPending, hasActiveSession) = lock.withLock {
                (!$0.currentOriginal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, $0.task != nil || $0.request != nil)
            }
            if isFinal {
                if hasPending {
                    commitSilenceThought()
                } else if hasActiveSession {
                    closeCurrentSession()
                }
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
            isSameLanguage: Bool,
            uiSourceCode: String,
            uiTargetCode: String
        ) in
            if trimmedFull == state.lastRawFullText && !isFinal {
                return (false, nil, UUID(), "", false, false, "", "")
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
                let isITNRewrite = Self.isLikelyInverseTextNormalization(previous: prevOrig, updated: trimmedFull)
                let isDramaticShrink = !isITNRewrite && (prevOrig.count >= 8 && (
                    (!isPrefixShrink && (trimmedFull.count * 2 <= prevOrig.count || (prevOrig.count - trimmedFull.count >= 12 && newWords.count + 2 <= prevWords.count))) ||
                    (prevWords.count >= 4 && newWords.count <= 1 && prevOrig.count - trimmedFull.count >= 14)
                ))
                if isDramaticShrink {
                    shrunkCommit = PendingCommit(
                        utteranceID: state.currentUtteranceID ?? UUID(),
                        original: prevOrig,
                        fallbackTranslated: state.currentTranslated,
                        fallbackUntranslated: state.currentIsUntranslated,
                        sourceLocaleId: state.sourceLocaleId,
                        targetLangCode: state.targetLangCode
                    )
                    state.currentUtteranceID = nil
                    state.currentOriginal = ""
                    state.currentTranslated = ""
                    state.currentIsUntranslated = false
                    state.pendingTailText = nil
                    state.isTranslating = false
                    state.activeTranslationTaskId = nil
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

            let uiSrc = Self.baseLanguageCode(from: state.sourceLocaleId)
            let uiTgt = Self.baseLanguageCode(from: state.targetLangCode)
            let isSameLanguage = (uiSrc == uiTgt)

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
                if !isFinal {
                    state.pendingTailText = trimmedFull
                }
            }

            state.silenceCommitWorkItem?.item.cancel()
            state.silenceCommitWorkItem = nil

            return (true, shrunkCommit, utteranceID, displayTrans, displayUntranslated, isSameLanguage, uiSrc, uiTgt)
        }

        guard outcome.shouldProcess else { return }

        if let shrunkCommit = outcome.shrunkCommit {
            commitCompletedSentence(
                shrunkCommit.original,
                fallbackTranslated: shrunkCommit.fallbackTranslated,
                fallbackUntranslated: shrunkCommit.fallbackUntranslated,
                utteranceID: shrunkCommit.utteranceID,
                sourceLocaleId: shrunkCommit.sourceLocaleId,
                targetLangCode: shrunkCommit.targetLangCode
            )
        }

        if isFinal {
            // Skip partial emission and partial translation when the recognizer already delivered `isFinal`;
            // `commitSilenceThought()` commits directly and spawns the authoritative `isFinal: true` refinement.
            commitSilenceThought()
        } else {
            onPartial?(outcome.utteranceID, trimmedFull, outcome.displayTrans, outcome.displayUntranslated)
            onPartialWithLanguages?(
                outcome.utteranceID,
                trimmedFull,
                outcome.displayTrans,
                outcome.uiSourceCode,
                outcome.uiTargetCode,
                outcome.displayUntranslated
            )
            if !outcome.isSameLanguage {
                pumpTranslationLoop(utteranceID: outcome.utteranceID)
            }
            scheduleSilenceCommit(for: trimmedFull)
        }
    }

    private static func isLikelyInverseTextNormalization(previous: String, updated: String) -> Bool {
        let prevDigits = previous.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        let newDigits = updated.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        guard newDigits > prevDigits, newDigits > 0 else { return false }

        let prevWords = previous.lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)
        let newWords = updated.lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)

        let spokenCount = prevWords.filter { spokenNumberWords.contains($0) }.count
        if spokenCount >= 2 {
            return true
        }
        if let firstPrev = prevWords.first, let firstNew = newWords.first, firstPrev == firstNew {
            return true
        }
        return false
    }

    private func pumpTranslationLoop(utteranceID: UUID) {
        let taskId = UUID()
        let pumpParams = lock.withLock { state -> (String, String, String, String, String, UInt64, UInt64, UInt64)? in
            guard !state.isTranslating else { return nil }
            guard let textToTranslate = state.pendingTailText, !textToTranslate.isEmpty else { return nil }
            state.pendingTailText = nil
            state.isTranslating = true
            state.activeTranslationTaskId = taskId
            let transSrc = Self.translationLanguageCode(from: state.sourceLocaleId)
            let transTgt = Self.translationLanguageCode(from: state.targetLangCode, resolveBareChinese: true)
            let uiSrc = Self.baseLanguageCode(from: state.sourceLocaleId)
            let uiTgt = Self.baseLanguageCode(from: state.targetLangCode)
            return (textToTranslate, transSrc, transTgt, uiSrc, uiTgt, state.sessionEpoch, state.resetEpoch, state.discardEpoch)
        }
        guard let (textToTranslate, transSrc, transTgt, uiSrc, uiTgt, capturedEpoch, capturedResetEpoch, capturedDiscardEpoch) = pumpParams else { return }

        let task = Task { [weak self] in
            defer {
                if let self = self {
                    self.activeTasksLock.withLock { tasks in
                        _ = tasks.removeValue(forKey: taskId)
                    }
                    self.lock.withLock { state in
                        if state.activeTranslationTaskId == taskId &&
                            state.sessionEpoch == capturedEpoch &&
                            state.resetEpoch == capturedResetEpoch &&
                            state.discardEpoch == capturedDiscardEpoch {
                            state.isTranslating = false
                            state.activeTranslationTaskId = nil
                        }
                    }
                }
            }
            let translated = await TranslationEngine.shared.translate(
                text: textToTranslate,
                sourceCode: transSrc,
                targetCode: transTgt,
                isFinal: false
            )
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                let (partialUpdate, shouldPumpAgain) = self.lock.withLock { state -> ((String, String, Bool)?, Bool) in
                    if state.activeTranslationTaskId == taskId &&
                        state.sessionEpoch == capturedEpoch &&
                        state.resetEpoch == capturedResetEpoch &&
                        state.discardEpoch == capturedDiscardEpoch {
                        state.isTranslating = false
                        state.activeTranslationTaskId = nil
                    }
                    guard !Task.isCancelled,
                          state.isRunning,
                          state.sessionEpoch == capturedEpoch,
                          state.resetEpoch == capturedResetEpoch,
                          state.discardEpoch == capturedDiscardEpoch,
                          state.currentUtteranceID == utteranceID else {
                        return (nil, false)
                    }

                    if let translated = translated, !translated.isEmpty {
                        state.currentTranslated = translated
                        state.currentIsUntranslated = false
                    } else if state.currentTranslated.isEmpty && state.pendingTailText == nil {
                        // Do not overwrite an existing valid partial translation or flag
                        // active superseded partials as untranslated.
                        state.currentIsUntranslated = true
                    } else {
                        return (nil, state.pendingTailText != nil)
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
                    self.onPartialWithLanguages?(utteranceID, activeOrig, displayTrans, uiSrc, uiTgt, isUntrans)
                }

                if shouldPumpAgain {
                    self.pumpTranslationLoop(utteranceID: utteranceID)
                }
            }
        }
        activeTasksLock.withLock { $0[taskId] = (.partial, task) }
    }

    private func commitCompletedSentence(
        _ orig: String,
        fallbackTranslated: String = "",
        fallbackUntranslated: Bool = false,
        utteranceID: UUID,
        sourceLocaleId: String? = nil,
        targetLangCode: String? = nil
    ) {
        let cleanOrig = orig.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanOrig.isEmpty else { return }

        let (effSrcLocale, effTgtCode, capturedDiscardEpoch) = lock.withLock { state -> (String, String, UInt64) in
            return (sourceLocaleId ?? state.sourceLocaleId, targetLangCode ?? state.targetLangCode, state.discardEpoch)
        }
        let uiSrc = Self.baseLanguageCode(from: effSrcLocale)
        let uiTgt = Self.baseLanguageCode(from: effTgtCode)

        if uiSrc == uiTgt {
            onFinal?(utteranceID, cleanOrig, cleanOrig, false)
            onFinalWithLanguages?(utteranceID, cleanOrig, cleanOrig, uiSrc, uiTgt, false)
            return
        }

        let transSrc = Self.translationLanguageCode(from: effSrcLocale)
        let transTgt = Self.translationLanguageCode(from: effTgtCode, resolveBareChinese: true)

        let cleanFallback = fallbackTranslated.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialUntranslated = fallbackUntranslated || cleanFallback.isEmpty
        let initialTrans = cleanFallback.isEmpty ? cleanOrig : cleanFallback
        onFinal?(utteranceID, cleanOrig, initialTrans, initialUntranslated)
        onFinalWithLanguages?(utteranceID, cleanOrig, initialTrans, uiSrc, uiTgt, initialUntranslated)

        let taskId = UUID()
        let task = Task { [weak self] in
            defer {
                self?.activeTasksLock.withLock { tasks in
                    _ = tasks.removeValue(forKey: taskId)
                }
            }
            let translated = await TranslationEngine.shared.translate(
                text: cleanOrig,
                sourceCode: transSrc,
                targetCode: transTgt,
                isFinal: true
            )
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self = self, !Task.isCancelled, self.currentDiscardEpoch == capturedDiscardEpoch else { return }
                if let translated = translated {
                    let cleanRefined = translated.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleanRefined.isEmpty && (cleanRefined != initialTrans || initialUntranslated) {
                        self.onFinal?(utteranceID, cleanOrig, cleanRefined, false)
                        self.onFinalWithLanguages?(utteranceID, cleanOrig, cleanRefined, uiSrc, uiTgt, false)
                    }
                } else if !initialUntranslated {
                    self.onFinal?(utteranceID, cleanOrig, cleanOrig, true)
                    self.onFinalWithLanguages?(utteranceID, cleanOrig, cleanOrig, uiSrc, uiTgt, true)
                }
            }
        }
        activeTasksLock.withLock { $0[taskId] = (.final, task) }
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
            utteranceID: commit.utteranceID,
            sourceLocaleId: commit.sourceLocaleId,
            targetLangCode: commit.targetLangCode
        )
        closeCurrentSession()
    }

    private func closeCurrentSession() {
        let now = ProcessInfo.processInfo.systemUptime
        let (pendingCommit, oldReq, oldTask, shouldStartNext) = lock.withLock { state -> (PendingCommit?, ManagedRequest?, SFSpeechRecognitionTask?, Bool) in
            let commit = Self.consumePendingCommit(&state)
            state.sessionTaskId &+= 1
            Self.cancelWorkItems(&state)
            state.isRestartScheduled = false
            state.isRotationScheduled = false
            state.consecutiveErrors = 0
            let r = state.request
            state.request = nil
            let t = state.task
            state.task = nil
            state.recentSessionBuffers.removeAll(keepingCapacity: true)
            state.pendingPCMBuffers.removeAll { (now - $0.arrivalTime) >= 0.6 }
            let hasFreshPending = state.isRunning && !state.isSuspended && !state.pendingPCMBuffers.isEmpty
            if hasFreshPending {
                state.isRestartScheduled = true
            }
            return (commit, r, t, hasFreshPending)
        }

        if let commit = pendingCommit {
            commitCompletedSentence(
                commit.original,
                fallbackTranslated: commit.fallbackTranslated,
                fallbackUntranslated: commit.fallbackUntranslated,
                utteranceID: commit.utteranceID,
                sourceLocaleId: commit.sourceLocaleId,
                targetLangCode: commit.targetLangCode
            )
        }

        endManagedRequest(oldReq)
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
    private var micFloorHoldUntil: TimeInterval = 0
    private var micFloorTimerScheduled: Bool = false
    private var micFloorTimerToken: UInt64 = 0

    public var isRunning: Bool {
        managerLock.withLock { _isRunning }
    }

    private func cancelMicFloorReleaseWorkItem() {
        managerLock.withLock {
            micFloorTimerToken &+= 1
            micFloorTimerScheduled = false
            micFloorHoldUntil = 0
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
        callerChannel.onPartialWithLanguages = { [weak self] utteranceID, orig, trans, srcCode, tgtCode, isUntrans in
            self?.delegate?.callerSpeechDidUpdate(
                utteranceID: utteranceID,
                partialOriginal: orig,
                partialTranslated: trans,
                sourceLangCode: srcCode,
                targetLangCode: tgtCode,
                isUntranslated: isUntrans
            )
        }
        callerChannel.onFinalWithLanguages = { [weak self] utteranceID, orig, trans, srcCode, tgtCode, isUntrans in
            self?.delegate?.callerSpeechDidFinalize(
                utteranceID: utteranceID,
                original: orig,
                translated: trans,
                sourceLangCode: srcCode,
                targetLangCode: tgtCode,
                isUntranslated: isUntrans
            )
        }
        callerChannel.onAuthErrorWithChannel = { [weak self] chName, msg in
            self?.delegate?.speechRecognitionDidEncounterAuthError(channelName: chName, message: msg)
        }
        callerChannel.onAuthSuccessWithChannel = { [weak self] chName in
            self?.delegate?.speechRecognitionDidClearAuthError(channelName: chName)
        }
        callerChannel.onSessionClosed = { [weak self] in
            guard let self = self else { return }
            self.cancelMicFloorReleaseWorkItem()
            self.micChannel.resumeAfterMicPriority()
        }

        micChannel.onPartialWithLanguages = { [weak self] utteranceID, orig, trans, srcCode, tgtCode, isUntrans in
            self?.delegate?.micSpeechDidUpdate(
                utteranceID: utteranceID,
                partialOriginal: orig,
                partialTranslated: trans,
                sourceLangCode: srcCode,
                targetLangCode: tgtCode,
                isUntranslated: isUntrans
            )
        }
        micChannel.onFinalWithLanguages = { [weak self] utteranceID, orig, trans, srcCode, tgtCode, isUntrans in
            self?.delegate?.micSpeechDidFinalize(
                utteranceID: utteranceID,
                original: orig,
                translated: trans,
                sourceLangCode: srcCode,
                targetLangCode: tgtCode,
                isUntranslated: isUntrans
            )
        }
        micChannel.onAuthErrorWithChannel = { [weak self] chName, msg in
            self?.delegate?.speechRecognitionDidEncounterAuthError(channelName: chName, message: msg)
        }
        micChannel.onAuthSuccessWithChannel = { [weak self] chName in
            self?.delegate?.speechRecognitionDidClearAuthError(channelName: chName)
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
        cancelMicFloorReleaseWorkItem()
        managerLock.withLock {
            _isRunning = false
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

    /// Feeds system (caller) audio.
    ///
    /// On open speakers the mic channel is normally suspended while the caller
    /// has the floor, so the session boundary follows the turn. When
    /// `userHasFloor` is true the user started speaking before the caller
    /// (turn-taking is arbitrated by the capture engine), so the caller's
    /// audio must not tear down the user's in-progress reply: the caller is
    /// still transcribed on its own channel, but the user keeps their turn.
    public func feedCallerAudioBuffer(_ buffer: AVAudioPCMBuffer, userHasFloor: Bool = false) {
        let isolated = isAcousticallyIsolated
        let yieldToCaller = !isolated && !userHasFloor
        let toreDownMic = yieldToCaller ? micChannel.suspendForMicPriority() : false

        callerChannel.resumeAfterMicPriority()
        callerChannel.appendPCMBuffer(buffer, minimumStartDelay: toreDownMic ? 0.035 : 0.01)

        guard micChannel.isRunning && yieldToCaller else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let delay: TimeInterval = 0.35
        let scheduledToken = managerLock.withLock { () -> UInt64? in
            micFloorHoldUntil = now + delay
            guard !micFloorTimerScheduled else { return nil }
            micFloorTimerScheduled = true
            return micFloorTimerToken
        }
        if let token = scheduledToken {
            scheduleMicFloorRelease(after: delay, token: token)
        }
    }

    private func scheduleMicFloorRelease(after delay: TimeInterval, token: UInt64) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            let decision = self.managerLock.withLock { () -> (shouldRelease: Bool, rescheduleAfter: TimeInterval?) in
                guard self._isRunning, self.micFloorTimerScheduled, self.micFloorTimerToken == token else {
                    return (false, nil)
                }
                let remaining = self.micFloorHoldUntil - ProcessInfo.processInfo.systemUptime
                if remaining > 0.03 {
                    return (false, remaining)
                }
                self.micFloorTimerScheduled = false
                return (true, nil)
            }
            if let remaining = decision.rescheduleAfter {
                self.scheduleMicFloorRelease(after: remaining, token: token)
                return
            }
            guard decision.shouldRelease, self.micChannel.isRunning else { return }
            self.micChannel.resumeAfterMicPriority()
        }
    }

    /// Feeds microphone audio that already passed the capture engine's gate.
    ///
    /// `isUserSpeaking` means the user holds the speaking floor (they started
    /// before the caller, or the caller's turn has ended). In that case the floor is handed
    /// to the mic immediately instead of waiting for the caller's VAD hangover
    /// plus the floor-release delay, so a quick reply starts transcribing at once.
    public func feedMicAudioBuffer(_ buffer: AVAudioPCMBuffer, isUserSpeaking: Bool = false) {
        let isolated = isAcousticallyIsolated
        if isUserSpeaking && !isolated && micChannel.isSuspended {
            cancelMicFloorReleaseWorkItem()
            micChannel.resumeAfterMicPriority()
        }
        let closedIdleCaller = isolated ? false : callerChannel.finishIfIdleForPeerChannel()
        micChannel.appendPCMBuffer(buffer, minimumStartDelay: closedIdleCaller ? 0.035 : 0.01)
    }
}
