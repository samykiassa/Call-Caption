import Foundation
@preconcurrency import Speech
@preconcurrency import AVFoundation
import os

enum SpeechRecognitionErrorCode: Int, Sendable {
    case dictationDisabled = 201
    case retry = 203
    case cancelled = 216
    case requestCancelled = 301
    case noSpeechDetected = 1110
    case notAuthorizedOrMissingAsset = 1700
}

enum SpeechAuthIssueKind: Sendable, Equatable {
    case speechPermissionDenied
    case dictationDisabled
    case dictationAssetRequired
    case unsupportedLocale
    case recognitionError
    case translationSettings
}

protocol BidirectionalSpeechDelegate: AnyObject {
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
    func speechRecognitionDidEncounterIssue(channelName: String, kind: SpeechAuthIssueKind, message: String)
    func speechRecognitionDidClearAuthError(channelName: String)
}

extension BidirectionalSpeechDelegate {
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

    func speechRecognitionDidEncounterIssue(channelName: String, kind: SpeechAuthIssueKind, message: String) {
        speechRecognitionDidEncounterAuthError(channelName: channelName, message: message)
    }

    func speechRecognitionDidClearAuthError(channelName: String) {
        speechRecognitionDidClearAuthError()
    }
}

final class SingleSpeechChannel: NSObject, @unchecked Sendable {
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
        let fallbackTranslatedSource: String
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
        let alreadyCommittedText: String
        let fallbackTranslated: String
        let fallbackUntranslated: Bool
        let fallbackTranslatedSource: String
        let sourceLocaleId: String
        let targetLangCode: String
        let task: SFSpeechRecognitionTask
    }

    private enum TaskKind {
        case partial
        case final
    }

    private struct UncheckedBox<Value>: @unchecked Sendable {
        let value: Value
    }

    private struct Callbacks: @unchecked Sendable {
        var onPartial: ((UUID, String, String, Bool) -> Void)?
        var onFinal: ((UUID, String, String, Bool) -> Void)?
        var onPartialWithLanguages: ((UUID, String, String, String, String, Bool) -> Void)?
        var onFinalWithLanguages: ((UUID, String, String, String, String, Bool) -> Void)?
        var onAuthError: ((String) -> Void)?
        var onAuthSuccess: (() -> Void)?
        var onAuthErrorWithChannel: ((String, String) -> Void)?
        var onIssueWithChannel: ((String, SpeechAuthIssueKind, String) -> Void)?
        var onAuthSuccessWithChannel: ((String) -> Void)?
        var onSessionClosed: (() -> Void)?
    }

    private struct ActiveTasksState {
        struct Entry {
            let kind: TaskKind
            let utteranceID: UUID?
            let revision: UInt64
            let cancelAllGen: UInt64
            let cancelPartialGen: UInt64
            var task: Task<Void, Never>?
        }

        var tasks: [UUID: Entry] = [:]
        var cancelAllGeneration: UInt64 = 0
        var cancelPartialsGeneration: UInt64 = 0
        var utteranceFinalRevisions: [UUID: UInt64] = [:]
        var utteranceRevisionOrder: [UUID] = []
    }

    private static let terminalPunctuationScalars: Set<UnicodeScalar> = [
        ".", "?", "!", "\u{3002}", "\u{FF1F}", "\u{FF01}", "\u{061F}"
    ]

    private static let spokenNumberWords: Set<String> = [
        // English
        "zero", "oh", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
        "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy",
        "eighty", "ninety", "hundred", "thousand", "million", "billion", "trillion",
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
        "half", "quarter", "percent", "dollar", "dollars", "cent", "cents", "euro", "euros", "pound", "pounds",
        "point", "dot", "slash", "dash", "plus", "minus", "am", "pm",
        // Spanish (folded lowercase)
        "cero", "uno", "una", "dos", "tres", "cuatro", "cinco", "seis", "siete", "ocho", "nueve",
        "diez", "once", "doce", "trece", "catorce", "quince", "dieciseis", "diecisiete", "dieciocho", "diecinueve",
        "veinte", "veintiuno", "veintidos", "veintitres", "veinticuatro", "veinticinco", "veintiseis",
        "veintisiete", "veintiocho", "veintinueve", "treinta", "cuarenta", "cincuenta", "sesenta",
        "setenta", "ochenta", "noventa", "cien", "ciento", "doscientos", "trescientos", "cuatrocientos",
        "quinientos", "seiscientos", "setecientos", "ochocientos", "novecientos", "mil", "millon", "millones",
        "cientos", "primero", "segundo", "tercero", "cuarto", "quinto", "ciento", "por", "punto", "coma",
        "dolar", "dolares", "centavo", "centavos", "y",
        // French / German / Italian / Portuguese basics
        "un", "une", "deux", "trois", "quatre", "cinq", "sept", "huit", "neuf", "dix", "vingt", "cent", "mille",
        "eins", "zwei", "drei", "vier", "funf", "sechs", "sieben", "acht", "neun", "zehn", "hundert", "tausend",
        "due", "tre", "quattro", "sette", "otto", "nove", "dieci", "cento", "mila",
        "um", "uma", "dois", "duas", "quatro", "sete", "oito", "cem", "cento"
    ]

    private struct AudioState {
        var isRunning: Bool = false
        var isSuspended: Bool = false
        var isRequestingSpeechAuth: Bool = false
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
        var pendingPCMBuffers = RingBuffer<SendablePCMBuffer>()
        var recentSessionBuffers = RingBuffer<SendablePCMBuffer>()
        var consecutiveErrors: Int = 0
        var failureBackoffUntil: TimeInterval = 0
        var failureCount: Int = 0
        var lastReportedFailure: String? = nil
        var lastFailureReportTime: TimeInterval = 0
        var lastFailureKind: SpeechAuthIssueKind? = nil
        var hasReportedAuthHealthy: Bool = false

        var currentUtteranceID: UUID? = nil
        var currentOriginal: String = ""
        var currentTranslated: String = ""
        var currentTranslatedSourceText: String = ""
        var currentIsUntranslated: Bool = false
        var lastRawFullText: String = ""
        var lastSpeechActivityTime: TimeInterval = 0
        var requiredSilenceIdle: TimeInterval = 1.65
        var restartWorkItem: SendableWorkItem? = nil
        var silenceCommitWorkItem: SendableWorkItem? = nil
        var noBufferWatchdogWorkItem: SendableWorkItem? = nil
        var partialThrottleWorkItem: SendableWorkItem? = nil

        var sessionEpoch: UInt64 = 0
        var resetEpoch: UInt64 = 0
        var discardEpoch: UInt64 = 0
        var sessionTaskId: UInt64 = 0
        var activeTaskId: UInt64 = 0
        var drainingTasks: [UInt64: DrainingTask] = [:]
        var isTranslating: Bool = false
        var activeTranslationTaskId: UUID? = nil
        var pendingTailText: String? = nil
        var lastPartialTranslationStartTime: TimeInterval = 0
    }

    private let lock: OSAllocatedUnfairLock<AudioState>
    // Serializes SFSpeechAudioBufferRecognitionRequest.append vs endAudio;
    // lock ordering invariant: always acquire `lock` before `requestIOLock`, never reverse.
    private let requestIOLock = NSLock()
    private let callbackLock = OSAllocatedUnfairLock(initialState: Callbacks())

    let channelName: String

    var sourceLocaleId: String {
        lock.withLock { $0.sourceLocaleId }
    }

    var targetLangCode: String {
        lock.withLock { $0.targetLangCode }
    }

    private var currentResetEpoch: UInt64 {
        lock.withLock { $0.resetEpoch }
    }

    private var currentDiscardEpoch: UInt64 {
        lock.withLock { $0.discardEpoch }
    }

    var onPartial: ((UUID, String, String, Bool) -> Void)? {
        get { callbackLock.withLock { UncheckedBox(value: $0.onPartial) }.value }
        set {
            let box = UncheckedBox(value: newValue)
            callbackLock.withLock { $0.onPartial = box.value }
        }
    }

    var onFinal: ((UUID, String, String, Bool) -> Void)? {
        get { callbackLock.withLock { UncheckedBox(value: $0.onFinal) }.value }
        set {
            let box = UncheckedBox(value: newValue)
            callbackLock.withLock { $0.onFinal = box.value }
        }
    }

    var onPartialWithLanguages: ((UUID, String, String, String, String, Bool) -> Void)? {
        get { callbackLock.withLock { UncheckedBox(value: $0.onPartialWithLanguages) }.value }
        set {
            let box = UncheckedBox(value: newValue)
            callbackLock.withLock { $0.onPartialWithLanguages = box.value }
        }
    }

    var onFinalWithLanguages: ((UUID, String, String, String, String, Bool) -> Void)? {
        get { callbackLock.withLock { UncheckedBox(value: $0.onFinalWithLanguages) }.value }
        set {
            let box = UncheckedBox(value: newValue)
            callbackLock.withLock { $0.onFinalWithLanguages = box.value }
        }
    }

    var onAuthError: ((String) -> Void)? {
        get { callbackLock.withLock { UncheckedBox(value: $0.onAuthError) }.value }
        set {
            let box = UncheckedBox(value: newValue)
            callbackLock.withLock { $0.onAuthError = box.value }
        }
    }

    var onAuthSuccess: (() -> Void)? {
        get { callbackLock.withLock { UncheckedBox(value: $0.onAuthSuccess) }.value }
        set {
            let box = UncheckedBox(value: newValue)
            callbackLock.withLock { $0.onAuthSuccess = box.value }
        }
    }

    var onAuthErrorWithChannel: ((String, String) -> Void)? {
        get { callbackLock.withLock { UncheckedBox(value: $0.onAuthErrorWithChannel) }.value }
        set {
            let box = UncheckedBox(value: newValue)
            callbackLock.withLock { $0.onAuthErrorWithChannel = box.value }
        }
    }

    var onIssueWithChannel: ((String, SpeechAuthIssueKind, String) -> Void)? {
        get { callbackLock.withLock { UncheckedBox(value: $0.onIssueWithChannel) }.value }
        set {
            let box = UncheckedBox(value: newValue)
            callbackLock.withLock { $0.onIssueWithChannel = box.value }
        }
    }

    var onAuthSuccessWithChannel: ((String) -> Void)? {
        get { callbackLock.withLock { UncheckedBox(value: $0.onAuthSuccessWithChannel) }.value }
        set {
            let box = UncheckedBox(value: newValue)
            callbackLock.withLock { $0.onAuthSuccessWithChannel = box.value }
        }
    }

    var onSessionClosed: (() -> Void)? {
        get { callbackLock.withLock { UncheckedBox(value: $0.onSessionClosed) }.value }
        set {
            let box = UncheckedBox(value: newValue)
            callbackLock.withLock { $0.onSessionClosed = box.value }
        }
    }

    private let activeTasksLock = OSAllocatedUnfairLock(initialState: ActiveTasksState())
    private static let maxTrackedUtteranceRevisions = 256

    private static func bumpUtteranceFinalRevisionLocked(_ state: inout ActiveTasksState, utteranceID: UUID) -> (revision: UInt64, supersededTasks: [Task<Void, Never>]) {
        if state.utteranceFinalRevisions[utteranceID] == nil {
            state.utteranceRevisionOrder.append(utteranceID)
        }
        let nextRev = (state.utteranceFinalRevisions[utteranceID] ?? 0) &+ 1
        state.utteranceFinalRevisions[utteranceID] = nextRev

        var superseded: [Task<Void, Never>] = []
        for (id, entry) in state.tasks where entry.kind == .final && entry.utteranceID == utteranceID {
            if let existingTask = entry.task {
                superseded.append(existingTask)
            }
            state.tasks.removeValue(forKey: id)
        }

        if state.utteranceRevisionOrder.count > maxTrackedUtteranceRevisions {
            let activeFinalUtteranceIDs = Set(state.tasks.values.compactMap { $0.kind == .final ? $0.utteranceID : nil })
            var scan = 0
            while state.utteranceRevisionOrder.count > maxTrackedUtteranceRevisions && scan < state.utteranceRevisionOrder.count {
                let candidate = state.utteranceRevisionOrder[scan]
                if candidate != utteranceID && !activeFinalUtteranceIDs.contains(candidate) {
                    state.utteranceRevisionOrder.remove(at: scan)
                    state.utteranceFinalRevisions.removeValue(forKey: candidate)
                } else {
                    scan += 1
                }
            }
        }
        return (nextRev, superseded)
    }

    private func advanceFinalRevisionAndCancelPrior(for utteranceID: UUID) {
        let superseded = activeTasksLock.withLock { state -> [Task<Void, Never>] in
            Self.bumpUtteranceFinalRevisionLocked(&state, utteranceID: utteranceID).supersededTasks
        }
        for task in superseded {
            task.cancel()
        }
    }

    private func reservePartialTranslationTask(id: UUID) {
        activeTasksLock.withLock { state in
            state.tasks[id] = ActiveTasksState.Entry(
                kind: .partial,
                utteranceID: nil,
                revision: 0,
                cancelAllGen: state.cancelAllGeneration,
                cancelPartialGen: state.cancelPartialsGeneration,
                task: nil
            )
        }
    }

    private func reserveFinalTranslationTask(for utteranceID: UUID) -> (id: UUID, revision: UInt64) {
        let id = UUID()
        let (revision, superseded) = activeTasksLock.withLock { state -> (UInt64, [Task<Void, Never>]) in
            let bumped = Self.bumpUtteranceFinalRevisionLocked(&state, utteranceID: utteranceID)
            state.tasks[id] = ActiveTasksState.Entry(
                kind: .final,
                utteranceID: utteranceID,
                revision: bumped.revision,
                cancelAllGen: state.cancelAllGeneration,
                cancelPartialGen: state.cancelPartialsGeneration,
                task: nil
            )
            return (bumped.revision, bumped.supersededTasks)
        }
        for task in superseded {
            task.cancel()
        }
        return (id, revision)
    }

    private func isLatestFinalRevision(_ revision: UInt64, for utteranceID: UUID) -> Bool {
        activeTasksLock.withLock { state in
            state.utteranceFinalRevisions[utteranceID] == revision
        }
    }

    private func attachTranslationTask(_ task: Task<Void, Never>, id: UUID) {
        let shouldCancel = activeTasksLock.withLock { state -> Bool in
            guard var entry = state.tasks[id] else {
                // Already finished (unregistered) or already cancelled/superseded before attachment.
                return true
            }
            let cancelledByGen = (state.cancelAllGeneration != entry.cancelAllGen)
                || (entry.kind == .partial && state.cancelPartialsGeneration != entry.cancelPartialGen)
            let supersededFinal = (entry.kind == .final)
                && (entry.utteranceID.map { state.utteranceFinalRevisions[$0] != entry.revision } ?? false)
            if cancelledByGen || supersededFinal {
                state.tasks.removeValue(forKey: id)
                return true
            }
            entry.task = task
            state.tasks[id] = entry
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }

    private func unregisterTranslationTask(id: UUID) {
        activeTasksLock.withLock { state in
            _ = state.tasks.removeValue(forKey: id)
        }
    }

    private func cancelInFlightTranslationTasks(partialsOnly: Bool = false) {
        let tasksToCancel = activeTasksLock.withLock { state -> [Task<Void, Never>] in
            if partialsOnly {
                state.cancelPartialsGeneration &+= 1
                var cancelled: [Task<Void, Never>] = []
                for (id, entry) in state.tasks where entry.kind == .partial {
                    if let task = entry.task {
                        cancelled.append(task)
                    }
                    state.tasks.removeValue(forKey: id)
                }
                return cancelled
            } else {
                state.cancelAllGeneration &+= 1
                state.cancelPartialsGeneration &+= 1
                let list = state.tasks.values.compactMap(\.task)
                state.tasks.removeAll()
                state.utteranceFinalRevisions.removeAll(keepingCapacity: true)
                state.utteranceRevisionOrder.removeAll(keepingCapacity: true)
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
        let clean = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        if clean == "zh" && resolveBareChinese {
            let preferred = SupportedLanguages.bestLocale(forCode: "zh").identifier
            return SupportedLanguages.translationCode(from: preferred)
        }
        return SupportedLanguages.translationCode(from: clean)
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

    var isRunning: Bool {
        lock.withLock { $0.isRunning }
    }

    var isSuspended: Bool {
        lock.withLock { $0.isSuspended }
    }

    private let pauseCommitInterval: TimeInterval = 1.65
    private let noBufferIdleTimeout: TimeInterval = 0.65
    private let maxSuspendedBuffers = 180
    private let maxSuspendedEchoBuffers = 80
    private let maxSuspendedEchoGap: TimeInterval = 1.25
    private let maxSuspendedEchoAge: TimeInterval = 2.50
    private static let drainTimeout: TimeInterval = 1.2
    private static let partialTranslationThrottleInterval: TimeInterval = 0.18

    init(name: String, sourceLocaleId: String, targetLangCode: String) {
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
        state.currentTranslatedSourceText = ""
        state.currentIsUntranslated = false
        state.pendingTailText = nil
        state.isTranslating = false
        state.activeTranslationTaskId = nil
        state.lastPartialTranslationStartTime = 0
        state.requiredSilenceIdle = 1.65
        state.partialThrottleWorkItem?.item.cancel()
        state.partialThrottleWorkItem = nil
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
            fallbackTranslatedSource: state.currentTranslatedSourceText,
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
        state.partialThrottleWorkItem?.item.cancel()
        state.partialThrottleWorkItem = nil
    }

    /// Detaches the current recognition task from the live session and parks it
    /// in `drainingTasks` so it can still deliver its final result. The pending
    /// utterance text is moved into the drain entry and committed when the task
    /// finishes (or when `drainTimeout` elapses). Returns the drain id to schedule
    /// a timeout for, or a commit to perform immediately when there is no live task.
    /// The caller is responsible for calling `endManagedRequest(...)` on the request.
    private static func retireTaskForDraining(
        _ state: inout AudioState,
        alreadyCommitted: PendingCommit? = nil
    ) -> (drainId: UInt64?, commit: PendingCommit?) {
        let srcLocale = state.sourceLocaleId
        let tgtCode = state.targetLangCode
        let freshCommit = consumePendingCommit(&state)
        let effectiveCommit = freshCommit ?? alreadyCommitted
        guard let task = state.task else { return (nil, freshCommit) }
        state.task = nil
        switch task.state {
        case .starting, .running, .finishing:
            break
        default:
            return (nil, freshCommit)
        }
        let id = state.activeTaskId
        if let existing = state.drainingTasks.removeValue(forKey: id) {
            existing.task.cancel()
        }
        state.drainingTasks[id] = DrainingTask(
            utteranceID: effectiveCommit?.utteranceID ?? UUID(),
            text: effectiveCommit?.original ?? "",
            alreadyCommittedText: freshCommit == nil ? (alreadyCommitted?.original ?? "") : "",
            fallbackTranslated: effectiveCommit?.fallbackTranslated ?? "",
            fallbackUntranslated: effectiveCommit?.fallbackUntranslated ?? true,
            fallbackTranslatedSource: effectiveCommit?.fallbackTranslatedSource ?? "",
            sourceLocaleId: effectiveCommit?.sourceLocaleId ?? srcLocale,
            targetLangCode: effectiveCommit?.targetLangCode ?? tgtCode,
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
        guard !drain.text.isEmpty, drain.text != drain.alreadyCommittedText else { return }
        commitCompletedSentence(
            drain.text,
            fallbackTranslated: drain.fallbackTranslated,
            fallbackUntranslated: drain.fallbackUntranslated,
            fallbackTranslatedSource: drain.fallbackTranslatedSource,
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

    func start(sourceLocaleId: String, targetLangCode: String) {
        stop()
        // Keep in-flight final refinement tasks from the just-stopped utterance alive
        // so completed sentences retain their translated text across restarts/language changes.
        cancelInFlightTranslationTasks(partialsOnly: true)
        let normLocale = sourceLocaleId.replacingOccurrences(of: "_", with: "-")
        lock.withLock { state in
            state.sourceLocaleId = normLocale
            state.targetLangCode = targetLangCode
            state.isRunning = true
            state.isSuspended = false
            state.sessionStartToken = nil
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
            state.lastFailureKind = nil
            state.hasReportedAuthHealthy = false
            state.sessionEpoch &+= 1
            state.resetEpoch &+= 1
            state.sessionTaskId &+= 1
            Self.cancelWorkItems(&state)
            Self.resetSessionTrackingState(&state)
        }

        setupRecognizer()
    }

    func stop() {
        let (oldReq, oldTask, pendingCommit, drains) = lock.withLock { state -> (ManagedRequest?, SFSpeechRecognitionTask?, PendingCommit?, [DrainingTask]) in
            state.isRunning = false
            state.isSuspended = false
            state.sessionStartToken = nil
            state.isRestartScheduled = false
            state.isRotationScheduled = false
            let r = state.request
            state.request = nil
            let t = state.task
            state.task = nil
            let existingDrains = Array(state.drainingTasks.values)
            state.drainingTasks.removeAll()
            state.pendingPCMBuffers.removeAll(keepingCapacity: false)
            state.recentSessionBuffers.removeAll(keepingCapacity: false)
            state.failureBackoffUntil = 0
            state.failureCount = 0
            state.lastReportedFailure = nil
            state.lastFailureReportTime = 0
            state.lastFailureKind = nil
            state.sessionTaskId &+= 1
            state.resetEpoch &+= 1
            Self.cancelWorkItems(&state)
            let commit = Self.consumePendingCommit(&state)
            if commit == nil {
                state.sessionEpoch &+= 1
            }
            return (r, t, commit, existingDrains)
        }

        // Cancel in-flight partial translations before committing finalized drains/pending utterances,
        // while keeping newly spawned final refinement tasks alive to deliver updated translations.
        cancelInFlightTranslationTasks(partialsOnly: true)

        for drain in drains {
            drain.task.cancel()
            if !drain.text.isEmpty && drain.text != drain.alreadyCommittedText {
                commitCompletedSentence(
                    drain.text,
                    fallbackTranslated: drain.fallbackTranslated,
                    fallbackUntranslated: drain.fallbackUntranslated,
                    fallbackTranslatedSource: drain.fallbackTranslatedSource,
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
                fallbackTranslatedSource: commit.fallbackTranslatedSource,
                utteranceID: commit.utteranceID,
                sourceLocaleId: commit.sourceLocaleId,
                targetLangCode: commit.targetLangCode
            )
            onSessionClosed?()
        }

        endManagedRequest(oldReq)
        oldTask?.cancel()
    }

    func resetFailureState() {
        lock.withLock {
            $0.failureBackoffUntil = 0
            $0.failureCount = 0
            $0.lastReportedFailure = nil
            $0.lastFailureReportTime = 0
        }
    }

    func revalidateAuthorizationAndStatus() {
        let (running, localeId, capturedResetEpoch, previousFailureKind, shouldScheduleRestart) = lock.withLock { state -> (Bool, String, UInt64, SpeechAuthIssueKind?, Bool) in
            let prevKind = state.lastFailureKind
            state.failureBackoffUntil = 0
            state.failureCount = 0
            state.lastReportedFailure = nil
            state.lastFailureReportTime = 0
            let canRestart = state.isRunning && !state.isSuspended && !state.isRequestingSpeechAuth && state.request == nil && !state.pendingPCMBuffers.isEmpty
            return (state.isRunning, state.sourceLocaleId, state.resetEpoch, prevKind, canRestart)
        }
        guard running else { return }

        SupportedLanguages.invalidateLocaleResolutionCache()
        let langCode = Self.baseLanguageCode(from: localeId)
        let primaryLoc = SupportedLanguages.bestLocale(forCode: localeId)
        let primaryRec = SFSpeechRecognizer(locale: primaryLoc)
        let (resolvedLoc, resolvedRecognizer): (Locale, SFSpeechRecognizer?) = {
            if primaryRec == nil || primaryRec?.supportsOnDeviceRecognition == false {
                let fallbackLoc = SupportedLanguages.bestLocale(forCode: langCode)
                if let fallbackRec = SFSpeechRecognizer(locale: fallbackLoc),
                   fallbackRec.supportsOnDeviceRecognition {
                    return (fallbackLoc, fallbackRec)
                }
            }
            return (primaryLoc, primaryRec)
        }()
        let resolvedLocIdentifier = resolvedLoc.identifier.replacingOccurrences(of: "_", with: "-")
        let langName = SupportedLanguages.item(forCode: langCode)?.localizedName ?? localeId
        let stillCurrent = lock.withLock { state -> Bool in
            guard state.isRunning,
                  state.resetEpoch == capturedResetEpoch,
                  state.sourceLocaleId == localeId else {
                return false
            }
            state.recognizer = resolvedRecognizer
            state.sourceLocaleId = resolvedLocIdentifier
            return true
        }
        guard stillCurrent else { return }

        guard let rec = resolvedRecognizer else {
            noteFailure(
                kind: .unsupportedLocale,
                message: AppL10n.format(
                    "speech.error.unsupported_locale",
                    fallback: "Speech recognition locale '%@' is not supported by macOS.",
                    langName
                ),
                expectedResetEpoch: capturedResetEpoch
            )
            return
        }

        let authStatus = SFSpeechRecognizer.authorizationStatus()
        if authStatus == .denied || authStatus == .restricted {
            noteFailure(
                kind: .speechPermissionDenied,
                message: AppL10n.string(
                    "speech.error.access_required",
                    fallback: "Speech Recognition access required"
                ),
                expectedResetEpoch: capturedResetEpoch
            )
            return
        }

        if authStatus == .authorized && !rec.supportsOnDeviceRecognition {
            noteFailure(
                kind: .dictationAssetRequired,
                message: AppL10n.format(
                    "speech.error.dictation_required",
                    fallback: "Dictation language required: %@",
                    langName
                ),
                expectedResetEpoch: capturedResetEpoch
            )
            return
        }

        if authStatus == .authorized && rec.supportsOnDeviceRecognition && !rec.isAvailable {
            noteFailure(
                kind: .recognitionError,
                message: AppL10n.format(
                    "speech.error.unavailable",
                    fallback: "Speech recognition for %@ is temporarily unavailable. Try again in a moment.",
                    langName
                ),
                expectedResetEpoch: capturedResetEpoch
            )
            return
        }

        if authStatus == .authorized && rec.supportsOnDeviceRecognition && rec.isAvailable {
            let (stillValid, canRestartNow) = lock.withLock { state -> (Bool, Bool) in
                guard state.isRunning, state.resetEpoch == capturedResetEpoch else {
                    return (false, false)
                }
                if previousFailureKind != .dictationDisabled && state.lastFailureKind == previousFailureKind {
                    state.lastFailureKind = nil
                }
                if previousFailureKind != .dictationDisabled {
                    state.hasReportedAuthHealthy = true
                }
                let restart = shouldScheduleRestart && !state.isSuspended && !state.isRequestingSpeechAuth && state.request == nil && !state.pendingPCMBuffers.isEmpty
                return (true, restart)
            }
            guard stillValid else { return }
            if previousFailureKind != .dictationDisabled {
                let chName = channelName
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isRunning, self.currentResetEpoch == capturedResetEpoch else { return }
                    self.onAuthSuccess?()
                    self.onAuthSuccessWithChannel?(chName)
                }
            }
            if canRestartNow {
                scheduleRestart(after: 0.05, forceReplace: false)
            }
        }
    }

    func discardInFlight() {
        let (oldReq, oldTask, drains) = lock.withLock { state -> (ManagedRequest?, SFSpeechRecognitionTask?, [DrainingTask]) in
            let r = state.request
            state.request = nil
            let t = state.task
            state.task = nil
            let existingDrains = Array(state.drainingTasks.values)
            state.drainingTasks.removeAll()
            state.sessionStartToken = nil
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
            return (r, t, existingDrains)
        }
        for drain in drains {
            drain.task.cancel()
        }
        cancelInFlightTranslationTasks(partialsOnly: false)
        endManagedRequest(oldReq)
        oldTask?.cancel()
    }

    #if CALLCAPTION_TESTING
    func commitSentenceForTesting(
        utteranceID: UUID,
        original: String,
        fallbackTranslated: String = "",
        fallbackUntranslated: Bool = true,
        fallbackTranslatedSource: String? = nil
    ) {
        commitCompletedSentence(
            original,
            fallbackTranslated: fallbackTranslated,
            fallbackUntranslated: fallbackUntranslated,
            fallbackTranslatedSource: fallbackTranslatedSource,
            utteranceID: utteranceID
        )
    }

    func advanceUtteranceEpochForTesting() {
        lock.withLock { state in
            state.sessionEpoch &+= 1
            state.isTranslating = false
            state.activeTranslationTaskId = nil
        }
    }

    static func isLikelyInverseTextNormalizationForTesting(previous: String, updated: String) -> Bool {
        isLikelyInverseTextNormalization(previous: previous, updated: updated)
    }

    func processRecognizedTextForTesting(_ text: String, isFinal: Bool = false) {
        processRecognizedSessionText(text, isFinal: isFinal)
    }

    func pendingBufferCountForTesting() -> Int {
        lock.withLock { $0.pendingPCMBuffers.count }
    }

    func activeUtteranceStateForTesting() -> (
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
    func suspendForMicPriority() -> Bool {
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
                let discardValid = (state.discardEpoch == capturedDiscardEpoch)
                guard state.isRunning,
                      state.resetEpoch == capturedResetEpoch,
                      discardValid else {
                    return (discardValid, nil, nil)
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
                    fallbackTranslatedSource: immediateCommit.fallbackTranslatedSource,
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
                    fallbackTranslatedSource: lateCommit.fallbackTranslatedSource,
                    utteranceID: lateCommit.utteranceID,
                    sourceLocaleId: lateCommit.sourceLocaleId,
                    targetLangCode: lateCommit.targetLangCode
                )
            }

            strayTask?.cancel()
        }
        return hadActiveReq
    }

    private static func pruneSuspendedEchoBuffers(
        _ buffers: inout RingBuffer<SendablePCMBuffer>,
        now: TimeInterval,
        maxCount: Int,
        maxGap: TimeInterval,
        maxAge: TimeInterval
    ) {
        guard !buffers.isEmpty else { return }
        if buffers.count > 1 {
            var cutIndex = 0
            var prevArrival: TimeInterval = 0
            buffers.forEachEnumerated { idx, item in
                if idx > 0 && (item.arrivalTime - prevArrival) > maxGap {
                    cutIndex = idx
                }
                prevArrival = item.arrivalTime
            }
            if cutIndex > 0 {
                buffers.removeFirst(cutIndex)
            }
        }
        buffers.removeAll { (now - $0.arrivalTime) > maxAge }
        if buffers.count > maxCount {
            buffers.removeFirst(buffers.count - maxCount)
        }
    }

    func resumeAfterMicPriority() {
        let now = ProcessInfo.processInfo.systemUptime
        let maxEchoCount = maxSuspendedEchoBuffers
        let maxEchoGap = maxSuspendedEchoGap
        let maxEchoAge = maxSuspendedEchoAge
        let needsStart = lock.withLock { state -> Bool in
            guard state.isSuspended else { return false }
            state.isSuspended = false
            state.consecutiveErrors = 0
            Self.pruneSuspendedEchoBuffers(
                &state.pendingPCMBuffers,
                now: now,
                maxCount: maxEchoCount,
                maxGap: maxEchoGap,
                maxAge: maxEchoAge
            )
            let shouldStart = state.isRunning && !state.isStartingSession && !state.isRestartScheduled && !state.isRequestingSpeechAuth && state.request == nil && !state.pendingPCMBuffers.isEmpty
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
    func finishIfIdleForPeerChannel() -> Bool {
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
                fallbackTranslatedSource: commit.fallbackTranslatedSource,
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

    func appendPCMBuffer(_ buffer: AVAudioPCMBuffer, minimumStartDelay: TimeInterval = 0.01) {
        let now = ProcessInfo.processInfo.systemUptime
        let wrappedBuffer = SendablePCMBuffer(buffer: buffer, arrivalTime: now)
        let maxSusp = maxSuspendedBuffers
        let maxEchoCount = maxSuspendedEchoBuffers
        let maxEchoGap = maxSuspendedEchoGap
        let maxEchoAge = maxSuspendedEchoAge
        let (running, req, shouldCycle, needsStart, needsWatchdog, errCount) = lock.withLock { state -> (Bool, ManagedRequest?, Bool, Bool, Bool, Int) in
            guard state.isRunning else { return (false, nil, false, false, false, 0) }
            if state.isSuspended {
                if let last = state.pendingPCMBuffers.last,
                   (now - last.arrivalTime) > maxEchoGap {
                    state.pendingPCMBuffers.removeAll(keepingCapacity: true)
                }
                state.pendingPCMBuffers.append(wrappedBuffer)
                Self.pruneSuspendedEchoBuffers(
                    &state.pendingPCMBuffers,
                    now: now,
                    maxCount: maxEchoCount,
                    maxGap: maxEchoGap,
                    maxAge: maxEchoAge
                )
                return (false, nil, false, false, false, 0)
            }
            state.lastBufferArrivalTime = now
            if state.request == nil && now < state.failureBackoffUntil {
                return (true, nil, false, false, false, 0)
            }
            if state.recentSessionBuffers.count >= 16 {
                _ = state.recentSessionBuffers.popFirst()
            }
            state.recentSessionBuffers.append(wrappedBuffer)

            guard let r = state.request, !state.isStartingSession, !state.isRotationScheduled else {
                if state.pendingPCMBuffers.count >= maxSusp {
                    _ = state.pendingPCMBuffers.popFirst()
                }
                state.pendingPCMBuffers.append(wrappedBuffer)
                let shouldStart = !state.isStartingSession && !state.isRestartScheduled && !state.isRequestingSpeechAuth && state.request == nil
                if shouldStart {
                    state.isRestartScheduled = true
                }
                return (true, nil, false, shouldStart, false, state.consecutiveErrors)
            }

            let age = now - state.sessionStartTime
            if age > 180.0 {
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
                        // Retain recent onset frames for the incoming rotated request so active speech isn't clipped.
                        if state.currentOriginal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let recent = state.recentSessionBuffers.suffix(4)
                            for buf in recent {
                                if state.pendingPCMBuffers.count >= maxSusp {
                                    _ = state.pendingPCMBuffers.popFirst()
                                }
                                state.pendingPCMBuffers.append(buf)
                            }
                        } else if state.pendingPCMBuffers.count < maxSusp {
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
                        _ = state.pendingPCMBuffers.popFirst()
                    }
                    state.pendingPCMBuffers.append(wrappedBuffer)
                    let shouldStart = !state.isStartingSession && !state.isRestartScheduled && !state.isRequestingSpeechAuth
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
        let (isRunningNow, localeId, capturedResetEpoch) = lock.withLock { state -> (Bool, String, UInt64) in
            (state.isRunning, state.sourceLocaleId, state.resetEpoch)
        }
        guard isRunningNow else { return }

        let loc = SupportedLanguages.bestLocale(forCode: localeId)
        let langCode = Self.baseLanguageCode(from: localeId)
        let langName = SupportedLanguages.item(forCode: langCode)?.localizedName ?? localeId
        guard let rec = SFSpeechRecognizer(locale: loc) else {
            let stillCurrent = lock.withLock { state -> Bool in
                guard state.isRunning,
                      state.resetEpoch == capturedResetEpoch,
                      state.sourceLocaleId == localeId else {
                    return false
                }
                state.recognizer = nil
                return true
            }
            guard stillCurrent else { return }
            AppLog.speech.error("[SpeechChannel \(self.channelName, privacy: .public)] Locale '\(loc.identifier, privacy: .public)' is unsupported by SFSpeechRecognizer.")
            noteFailure(
                kind: .unsupportedLocale,
                message: AppL10n.format(
                    "speech.error.unsupported_locale",
                    fallback: "Speech recognition locale '%@' is not supported by macOS.",
                    langName
                ),
                expectedResetEpoch: capturedResetEpoch
            )
            return
        }

        let stillCurrent = lock.withLock { state -> Bool in
            guard state.isRunning,
                  state.resetEpoch == capturedResetEpoch,
                  state.sourceLocaleId == localeId else {
                return false
            }
            state.recognizer = rec
            return true
        }
        guard stillCurrent else { return }

        AppLog.speech.info("[SpeechChannel \(self.channelName, privacy: .public)] Configured recognizer with locale '\(loc.identifier, privacy: .public)' (supportsOnDevice: \(rec.supportsOnDeviceRecognition, privacy: .public))")

        let authStatus = SFSpeechRecognizer.authorizationStatus()
        if authStatus == .denied || authStatus == .restricted {
            noteFailure(
                kind: .speechPermissionDenied,
                message: AppL10n.string(
                    "speech.error.access_required",
                    fallback: "Speech Recognition access required"
                ),
                expectedResetEpoch: capturedResetEpoch
            )
        } else if authStatus == .authorized && !rec.supportsOnDeviceRecognition {
            noteFailure(
                kind: .dictationAssetRequired,
                message: AppL10n.format(
                    "speech.error.dictation_required",
                    fallback: "Dictation language required: %@",
                    langName
                ),
                expectedResetEpoch: capturedResetEpoch
            )
        }
    }

    func startNewSession(forceReplace: Bool = false) {
        let startToken = UUID()
        let (canStart, capturedResetEpoch) = lock.withLock { state -> (Bool, UInt64) in
            state.restartWorkItem?.item.cancel()
            state.restartWorkItem = nil
            state.isRestartScheduled = false
            state.isRotationScheduled = false
            guard state.isRunning,
                  !state.isSuspended,
                  !state.isRequestingSpeechAuth,
                  state.sessionStartToken == nil else {
                return (false, state.resetEpoch)
            }
            if !forceReplace && state.request != nil {
                return (false, state.resetEpoch)
            }
            if state.request == nil && state.pendingPCMBuffers.isEmpty && !(forceReplace && !state.recentSessionBuffers.isEmpty) {
                return (false, state.resetEpoch)
            }
            state.sessionStartToken = startToken
            state.silenceCommitWorkItem?.item.cancel()
            state.silenceCommitWorkItem = nil
            state.noBufferWatchdogWorkItem?.item.cancel()
            state.noBufferWatchdogWorkItem = nil
            return (true, state.resetEpoch)
        }
        guard canStart else { return }
        defer {
            let shouldSchedulePendingRestart = lock.withLock { state -> Bool in
                if state.sessionStartToken == startToken {
                    state.sessionStartToken = nil
                }
                let now = ProcessInfo.processInfo.systemUptime
                let inBackoff = state.failureBackoffUntil > now
                let shouldRetry = state.isRunning
                    && !state.isSuspended
                    && !state.isStartingSession
                    && !state.isRestartScheduled
                    && !state.isRequestingSpeechAuth
                    && !inBackoff
                    && state.request == nil
                    && !state.pendingPCMBuffers.isEmpty
                if shouldRetry {
                    state.isRestartScheduled = true
                }
                return shouldRetry
            }
            if shouldSchedulePendingRestart {
                DispatchQueue.main.async { [weak self] in
                    self?.scheduleRestart(after: 0.03, forceReplace: false)
                }
            }
        }

        let authStatus = SFSpeechRecognizer.authorizationStatus()
        if authStatus == .notDetermined {
            let shouldRequest = lock.withLock { state -> Bool in
                guard !state.isRequestingSpeechAuth else { return false }
                state.isRequestingSpeechAuth = true
                return true
            }
            if shouldRequest {
                SFSpeechRecognizer.requestAuthorization { [weak self] status in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.lock.withLock { $0.isRequestingSpeechAuth = false }
                        if status == .authorized {
                            if self.isRunning {
                                self.scheduleRestart(after: 0.05, forceReplace: false)
                            }
                        } else {
                            self.noteFailure(
                                kind: .speechPermissionDenied,
                                message: AppL10n.string(
                                    "speech.error.access_required",
                                    fallback: "Speech Recognition access required"
                                )
                            )
                        }
                    }
                }
            }
            return
        } else if authStatus == .denied || authStatus == .restricted {
            noteFailure(
                kind: .speechPermissionDenied,
                message: AppL10n.string(
                    "speech.error.access_required",
                    fallback: "Speech Recognition access required"
                ),
                expectedResetEpoch: capturedResetEpoch
            )
            return
        }

        let needsSetup = lock.withLock { state -> Bool in
            guard state.isRunning, state.resetEpoch == capturedResetEpoch else { return false }
            return state.recognizer == nil || state.recognizer?.supportsOnDeviceRecognition == false
        }
        if needsSetup {
            setupRecognizer()
        }
        let (stillCurrentEpoch, recognizer, localeId, inBackoff) = lock.withLock { state -> (Bool, SFSpeechRecognizer?, String, Bool) in
            guard state.isRunning, state.resetEpoch == capturedResetEpoch else {
                return (false, nil, state.sourceLocaleId, false)
            }
            let backoff = state.failureBackoffUntil > ProcessInfo.processInfo.systemUptime
            return (true, state.recognizer, state.sourceLocaleId, backoff)
        }
        guard stillCurrentEpoch, let recognizer = recognizer else { return }

        let langCode = Self.baseLanguageCode(from: localeId)
        let langName = SupportedLanguages.item(forCode: langCode)?.localizedName ?? localeId

        if inBackoff {
            return
        }

        guard recognizer.supportsOnDeviceRecognition else {
            noteFailure(
                kind: .dictationAssetRequired,
                message: AppL10n.format(
                    "speech.error.dictation_required",
                    fallback: "Dictation language required: %@",
                    langName
                ),
                expectedResetEpoch: capturedResetEpoch
            )
            return
        }

        guard recognizer.isAvailable else {
            noteFailure(
                kind: .recognitionError,
                message: AppL10n.format(
                    "speech.error.unavailable",
                    fallback: "Speech recognition for %@ is temporarily unavailable. Try again in a moment.",
                    langName
                ),
                expectedResetEpoch: capturedResetEpoch
            )
            return
        }

        let (canRetire, oldReq, oldTask, drainId, pendingCommit) = lock.withLock { state -> (Bool, ManagedRequest?, SFSpeechRecognitionTask?, UInt64?, PendingCommit?) in
            guard state.isRunning, !state.isSuspended, state.resetEpoch == capturedResetEpoch else {
                return (false, nil, nil, nil, nil)
            }
            let r = state.request
            state.request = nil
            state.sessionTaskId &+= 1
            let hasText = !state.currentOriginal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let willReplayRecent = forceReplace && !hasText && state.pendingPCMBuffers.isEmpty && !state.recentSessionBuffers.isEmpty
            if willReplayRecent {
                // The recent audio is replayed into the new request, so the old
                // task must not also finalize it (that would duplicate words).
                let commit = Self.consumePendingCommit(&state)
                let t = state.task
                state.task = nil
                state.pendingPCMBuffers.removeAll(keepingCapacity: true)
                for buf in state.recentSessionBuffers.suffix(8) {
                    state.pendingPCMBuffers.append(buf)
                }
                return (true, r, t, nil, commit)
            }
            let (drainId, commit) = Self.retireTaskForDraining(&state)
            return (true, r, nil, drainId, commit)
        }
        guard canRetire else { return }

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
                fallbackTranslatedSource: commit.fallbackTranslatedSource,
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
            guard state.isRunning, !state.isSuspended, state.resetEpoch == capturedResetEpoch else {
                return (false, [], state.sessionTaskId)
            }
            let now = ProcessInfo.processInfo.systemUptime
            state.pendingPCMBuffers.removeAll { (now - $0.arrivalTime) > 8.0 }
            let pcms = state.pendingPCMBuffers.toArray()
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
                    let (oldReq, errCount, hasPending, isSusp, isRunningNow, hasPendingText) = self.lock.withLock { state -> (ManagedRequest?, Int, Bool, Bool, Bool, Bool) in
                        let r = state.request
                        state.request = nil
                        state.task = nil
                        state.noBufferWatchdogWorkItem?.item.cancel()
                        state.noBufferWatchdogWorkItem = nil
                        if state.isSuspended {
                            state.recentSessionBuffers.removeAll(keepingCapacity: true)
                            return (r, 0, false, true, state.isRunning, false)
                        }
                        state.consecutiveErrors += 1
                        let recentlyActive = (now - state.lastBufferArrivalTime) < 0.65
                        if knownCode == .retry && hadNoRecognizedText && recentlyActive && state.pendingPCMBuffers.isEmpty && !state.recentSessionBuffers.isEmpty && state.consecutiveErrors == 1 {
                            state.pendingPCMBuffers = state.recentSessionBuffers
                        }
                        state.recentSessionBuffers.removeAll(keepingCapacity: true)
                        let hasOrig = !state.currentOriginal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        return (r, state.consecutiveErrors, !state.pendingPCMBuffers.isEmpty, false, state.isRunning, hasOrig)
                    }
                    self.endManagedRequest(oldReq)

                    if isSusp { return }

                    switch knownCode {
                    case .notAuthorizedOrMissingAsset:
                        let currentAuth = SFSpeechRecognizer.authorizationStatus()
                        if currentAuth == .notDetermined {
                            let shouldRequest = self.lock.withLock { state -> Bool in
                                guard !state.isRequestingSpeechAuth else { return false }
                                state.isRequestingSpeechAuth = true
                                return true
                            }
                            if shouldRequest {
                                SFSpeechRecognizer.requestAuthorization { [weak self] status in
                                    DispatchQueue.main.async {
                                        guard let self = self else { return }
                                        self.lock.withLock { $0.isRequestingSpeechAuth = false }
                                        if status == .authorized && self.isRunning {
                                            self.scheduleRestart(after: 0.1, forceReplace: false)
                                        } else if status != .authorized {
                                            self.noteFailure(
                                                kind: .speechPermissionDenied,
                                                message: AppL10n.string(
                                                    "speech.error.access_required",
                                                    fallback: "Speech Recognition access required"
                                                )
                                            )
                                        }
                                    }
                                }
                            }
                        } else if currentAuth == .denied || currentAuth == .restricted {
                            self.noteFailure(
                                kind: .speechPermissionDenied,
                                message: AppL10n.string(
                                    "speech.error.access_required",
                                    fallback: "Speech Recognition access required"
                                ),
                                expectedResetEpoch: capturedResetEpoch
                            )
                        } else {
                            let langCode = Self.baseLanguageCode(from: taskLocaleId)
                            let langName = SupportedLanguages.item(forCode: langCode)?.localizedName ?? taskLocaleId
                            self.noteFailure(
                                kind: .dictationAssetRequired,
                                message: AppL10n.format(
                                    "speech.error.dictation_required",
                                    fallback: "Dictation language required: %@",
                                    langName
                                ),
                                expectedResetEpoch: capturedResetEpoch
                            )
                        }
                        return

                    case .dictationDisabled:
                        self.noteFailure(
                            kind: .dictationDisabled,
                            message: AppL10n.string(
                                "speech.error.dictation_disabled",
                                fallback: "Dictation is disabled in System Settings"
                            ),
                            expectedResetEpoch: capturedResetEpoch
                        )
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
                            self.noteFailure(
                                kind: .recognitionError,
                                message: AppL10n.format(
                                    "speech.error.generic",
                                    fallback: "Speech recognition error: %@",
                                    nsError.localizedDescription
                                ),
                                expectedResetEpoch: capturedResetEpoch
                            )
                        }
                        let delay = min(1.5, 0.20 * Double(errCount))
                        if isRunningNow && hasPending {
                            self.scheduleRestart(after: delay, forceReplace: false)
                        }
                        return
                    }
                }

                guard let text = text else { return }
                let shouldNotifyAuthHealthy = self.lock.withLock { state -> Bool in
                    let needsNotify = state.consecutiveErrors > 0
                        || state.failureCount > 0
                        || state.lastReportedFailure != nil
                        || state.lastFailureKind != nil
                        || !state.hasReportedAuthHealthy
                    state.consecutiveErrors = 0
                    state.failureCount = 0
                    state.failureBackoffUntil = 0
                    state.lastReportedFailure = nil
                    state.lastFailureReportTime = 0
                    state.lastFailureKind = nil
                    state.hasReportedAuthHealthy = true
                    return needsNotify
                }
                if shouldNotifyAuthHealthy {
                    self.onAuthSuccess?()
                    self.onAuthSuccessWithChannel?(self.channelName)
                }
                self.processRecognizedSessionText(text, isFinal: isFinal)
            }
        }

        // Flush any buffers that arrived while recognitionTask was spinning up and publish
        // `state.request` atomically with `state.task`. Maintain strict lock order: lock -> requestIOLock.
        let shouldCancelNewTask = lock.withLock { state -> Bool in
            guard state.isRunning,
                  !state.isSuspended,
                  state.resetEpoch == capturedResetEpoch,
                  state.sessionTaskId == currentTaskSession else {
                return true
            }
            let now = ProcessInfo.processInfo.systemUptime
            state.pendingPCMBuffers.removeAll { (now - $0.arrivalTime) > 8.0 }
            let extraPCMs = state.pendingPCMBuffers.toArray()
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

        scheduleNoBufferWatchdog(after: noBufferIdleTimeout, force: true)
    }

    private func noteFailure(kind: SpeechAuthIssueKind, message: String, expectedResetEpoch: UInt64? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        let (isValid, shouldReport) = lock.withLock { state -> (Bool, Bool) in
            if let expectedResetEpoch, (!state.isRunning || state.resetEpoch != expectedResetEpoch) {
                return (false, false)
            }
            state.failureCount += 1
            state.lastFailureKind = kind
            state.hasReportedAuthHealthy = false
            let exponent = min(5, max(1, state.failureCount))
            let delays: [TimeInterval] = [2, 5, 15, 60, 300, 300]
            state.failureBackoffUntil = now + delays[exponent - 1]
            let report = state.lastReportedFailure != message
                || (now - state.lastFailureReportTime) >= 60
            if report {
                state.lastReportedFailure = message
                state.lastFailureReportTime = now
            }
            return (true, report)
        }
        guard isValid else { return }
        AppLog.speech.warning("[SpeechChannel \(self.channelName, privacy: .public)] \(message, privacy: .public)")
        if shouldReport {
            onAuthError?(message)
            if let onIssueWithChannel {
                onIssueWithChannel(channelName, kind, message)
            } else {
                onAuthErrorWithChannel?(channelName, message)
            }
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

    private func scheduleSilenceCommitIfNeeded(delay: TimeInterval, force: Bool = false) {
        let work = SendableWorkItem(item: DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let (isRunningNow, lastActivity, lastBufferTime, requiredIdle) = self.lock.withLock { state -> (Bool, TimeInterval, TimeInterval, TimeInterval) in
                state.silenceCommitWorkItem = nil
                return (state.isRunning, state.lastSpeechActivityTime, state.lastBufferArrivalTime, state.requiredSilenceIdle)
            }
            guard isRunningNow else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let textIdle = now - lastActivity
            if textIdle < (requiredIdle - 0.08) {
                let remaining = max(0.15, requiredIdle - textIdle)
                self.scheduleSilenceCommitIfNeeded(delay: remaining, force: true)
                return
            }
            let minBufferIdle = self.noBufferIdleTimeout * 0.85
            let bufferIdle = now - lastBufferTime
            if lastBufferTime > 0 && bufferIdle < minBufferIdle {
                let remaining = max(0.15, minBufferIdle - bufferIdle)
                self.scheduleSilenceCommitIfNeeded(delay: remaining, force: true)
                return
            }
            self.commitSilenceThought()
        })
        let scheduled = lock.withLock { state -> Bool in
            guard state.isRunning else { return false }
            if !force && state.silenceCommitWorkItem != nil {
                return false
            }
            state.silenceCommitWorkItem?.item.cancel()
            state.silenceCommitWorkItem = work
            return true
        }
        guard scheduled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work.item)
    }

    private static func containsCJKCharacters(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v)
                || (0x3400...0x4DBF).contains(v)
                || (0x3040...0x30FF).contains(v)
                || (0xAC00...0xD7AF).contains(v) {
                return true
            }
        }
        return false
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

        let silenceInterval = isFinal ? pauseCommitInterval : dynamicPauseCommitInterval(for: trimmedFull)
        let now = ProcessInfo.processInfo.systemUptime
        let outcome = lock.withLock { state -> (
            shouldProcess: Bool,
            shrunkCommit: PendingCommit?,
            utteranceID: UUID,
            displayTrans: String,
            displayUntranslated: Bool,
            isSameLanguage: Bool,
            uiSourceCode: String,
            uiTargetCode: String,
            needsSilenceTimer: Bool
        ) in
            if trimmedFull == state.lastRawFullText && !isFinal {
                return (false, nil, UUID(), "", false, false, "", "", false)
            }

            if state.currentUtteranceID == nil {
                state.currentUtteranceID = UUID()
            }

            var shrunkCommit: PendingCommit? = nil
            let prevOrig = state.currentOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prevOrig.isEmpty {
                let prevLen = prevOrig.count
                let newLen = trimmedFull.count
                // Short-circuit before splitting/lowercasing/ITN scanning on growing or mildly revised partials (>99% of callbacks).
                if prevLen >= 4 && (newLen * 2 <= prevLen || prevLen - newLen >= 12) {
                    let srcBase = Self.baseLanguageCode(from: state.sourceLocaleId)
                    let isCJK = srcBase == "zh" || srcBase == "ja" || srcBase == "ko" || Self.containsCJKCharacters(prevOrig)
                    let minShrinkLen = isCJK ? 4 : 8
                    if prevLen >= minShrinkLen {
                        let prevWords = prevOrig.split(whereSeparator: { $0.isWhitespace })
                        let newWords = trimmedFull.split(whereSeparator: { $0.isWhitespace })
                        let rawPrefixShrink = prevOrig.lowercased().hasPrefix(trimmedFull.lowercased())
                        let isSevereCollapse = prevLen >= 20 && newLen * 3 <= prevLen
                        let isPrefixShrink = rawPrefixShrink && !isSevereCollapse
                        let candidateDramaticShrink =
                            (!isPrefixShrink && (newLen * 2 <= prevLen || (prevLen - newLen >= 12 && newWords.count + 2 <= prevWords.count))) ||
                            (prevWords.count >= 4 && newWords.count <= 1 && prevLen - newLen >= 14)
                        if candidateDramaticShrink && !Self.isLikelyInverseTextNormalization(previous: prevOrig, updated: trimmedFull) {
                            shrunkCommit = PendingCommit(
                                utteranceID: state.currentUtteranceID ?? UUID(),
                                original: prevOrig,
                                fallbackTranslated: state.currentTranslated,
                                fallbackUntranslated: state.currentIsUntranslated,
                                fallbackTranslatedSource: state.currentTranslatedSourceText,
                                sourceLocaleId: state.sourceLocaleId,
                                targetLangCode: state.targetLangCode
                            )
                            Self.resetSessionTrackingState(&state)
                            state.sessionEpoch &+= 1
                        }
                    }
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
                state.currentTranslatedSourceText = trimmedFull
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

            let needsSilenceTimer: Bool
            if isFinal {
                state.silenceCommitWorkItem?.item.cancel()
                state.silenceCommitWorkItem = nil
                needsSilenceTimer = false
            } else {
                state.requiredSilenceIdle = silenceInterval
                needsSilenceTimer = (state.silenceCommitWorkItem == nil)
            }

            return (true, shrunkCommit, utteranceID, displayTrans, displayUntranslated, isSameLanguage, uiSrc, uiTgt, needsSilenceTimer)
        }

        guard outcome.shouldProcess else { return }

        if let shrunkCommit = outcome.shrunkCommit {
            commitCompletedSentence(
                shrunkCommit.original,
                fallbackTranslated: shrunkCommit.fallbackTranslated,
                fallbackUntranslated: shrunkCommit.fallbackUntranslated,
                fallbackTranslatedSource: shrunkCommit.fallbackTranslatedSource,
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
            if outcome.needsSilenceTimer {
                scheduleSilenceCommitIfNeeded(delay: silenceInterval, force: false)
            }
        }
    }

    private static let cjkNumberScalars: Set<UnicodeScalar> = [
        "零", "〇", "一", "二", "两", "兩", "三", "四", "五", "六", "七", "八", "九", "十", "百", "千", "万", "萬", "亿", "億", "兆"
    ]

    private static func isLikelyInverseTextNormalization(previous: String, updated: String) -> Bool {
        let isKana: (UnicodeScalar) -> Bool = {
            (0x3040...0x309F).contains($0.value) || (0x30A0...0x30FF).contains($0.value) || (0xFF65...0xFF9F).contains($0.value)
        }
        let isKanji: (UnicodeScalar) -> Bool = {
            (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value)
        }

        // 1. Japanese kana -> kanji conversion rewrite (e.g., hiragana/katakana contracting into CJK Unified Ideographs)
        let prevKana = previous.unicodeScalars.filter(isKana).count
        let newKana = updated.unicodeScalars.filter(isKana).count
        let prevKanji = previous.unicodeScalars.filter(isKanji).count
        let newKanji = updated.unicodeScalars.filter(isKanji).count
        if newKanji > prevKanji && prevKana > 0 && newKana < prevKana {
            return true
        }

        // 2. All-caps acronym contraction (e.g., "United States of America" -> "USA", "artificial intelligence" -> "AI")
        let prevRawTokens = previous
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)
        let newRawTokens = updated
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)
        let prevRawSet = Set(prevRawTokens)
        let hasNewAcronym = newRawTokens.contains { token in
            guard !prevRawSet.contains(token) else { return false }
            let letterScalars = token.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            guard letterScalars.count >= 2 else { return false }
            return letterScalars.allSatisfy { CharacterSet.uppercaseLetters.contains($0) }
                && token.unicodeScalars.allSatisfy { CharacterSet.uppercaseLetters.contains($0) || CharacterSet.decimalDigits.contains($0) }
        }
        if hasNewAcronym && (prevRawTokens.count > newRawTokens.count || previous.count > updated.count) {
            return true
        }

        // 3. Spoken number words -> digits ITN
        let prevDigits = previous.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        let newDigits = updated.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        guard newDigits > prevDigits, newDigits > 0 else { return false }

        let prevCJKNums = previous.unicodeScalars.filter { cjkNumberScalars.contains($0) }.count
        let newCJKNums = updated.unicodeScalars.filter { cjkNumberScalars.contains($0) }.count
        if prevCJKNums > newCJKNums {
            return true
        }

        let fold: (String) -> String = {
            $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        }
        let prevWords = fold(previous)
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)
        let newWords = fold(updated)
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)

        let spokenCount = prevWords.filter { spokenNumberWords.contains($0) }.count
        if spokenCount >= 2 || (spokenCount >= 1 && newDigits >= 2) {
            return true
        }
        if let firstPrev = prevWords.first, let firstNew = newWords.first, firstPrev == firstNew {
            return true
        }
        let prevNonNumeric = Set(prevWords.filter { $0.unicodeScalars.allSatisfy { !CharacterSet.decimalDigits.contains($0) } })
        let hasSharedNonNumericWord = newWords.contains {
            !$0.isEmpty && $0.unicodeScalars.allSatisfy { !CharacterSet.decimalDigits.contains($0) } && prevNonNumeric.contains($0)
        }
        if hasSharedNonNumericWord && newDigits >= 2 {
            return true
        }
        return false
    }

    private enum PumpDecision: Sendable {
        case skip
        case throttle(delay: TimeInterval, work: SendableWorkItem)
        case start(
            taskId: UUID,
            text: String,
            sourceLocaleId: String,
            targetLangCode: String,
            sessionEpoch: UInt64,
            resetEpoch: UInt64,
            discardEpoch: UInt64
        )
    }

    private func isPartialTranslationStillCurrent(
        taskId: UUID,
        utteranceID: UUID,
        sessionEpoch: UInt64,
        resetEpoch: UInt64,
        discardEpoch: UInt64
    ) -> Bool {
        lock.withLock { state in
            state.isRunning
                && state.activeTranslationTaskId == taskId
                && state.currentUtteranceID == utteranceID
                && state.sessionEpoch == sessionEpoch
                && state.resetEpoch == resetEpoch
                && state.discardEpoch == discardEpoch
        }
    }

    private func pumpTranslationLoop(utteranceID: UUID, bypassThrottle: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        let candidateTaskId = UUID()
        let decision = lock.withLock { state -> PumpDecision in
            guard state.isRunning,
                  state.currentUtteranceID == utteranceID,
                  !state.isTranslating else {
                return .skip
            }
            guard let textToTranslate = state.pendingTailText, !textToTranslate.isEmpty else {
                return .skip
            }
            let trimmedCandidate = textToTranslate.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedCandidate == state.currentTranslatedSourceText && !state.currentTranslated.isEmpty && !state.currentIsUntranslated {
                state.pendingTailText = nil
                return .skip
            }
            let throttleInterval: TimeInterval
            if trimmedCandidate.count > 280 {
                throttleInterval = 0.40
            } else if trimmedCandidate.count > 120 {
                throttleInterval = 0.28
            } else {
                throttleInterval = Self.partialTranslationThrottleInterval
            }
            if !bypassThrottle && state.lastPartialTranslationStartTime > 0 {
                let elapsed = now - state.lastPartialTranslationStartTime
                if elapsed < throttleInterval {
                    if state.partialThrottleWorkItem != nil {
                        return .skip
                    }
                    let delay = max(0.01, throttleInterval - elapsed)
                    let capturedEpoch = state.sessionEpoch
                    let capturedResetEpoch = state.resetEpoch
                    let capturedDiscardEpoch = state.discardEpoch
                    let throttleWork = SendableWorkItem(item: DispatchWorkItem { [weak self] in
                        guard let self = self else { return }
                        let shouldPump = self.lock.withLock { s -> Bool in
                            s.partialThrottleWorkItem = nil
                            return s.isRunning
                                && s.sessionEpoch == capturedEpoch
                                && s.resetEpoch == capturedResetEpoch
                                && s.discardEpoch == capturedDiscardEpoch
                                && s.currentUtteranceID == utteranceID
                        }
                        if shouldPump {
                            self.pumpTranslationLoop(utteranceID: utteranceID, bypassThrottle: true)
                        }
                    })
                    state.partialThrottleWorkItem = throttleWork
                    return .throttle(delay: delay, work: throttleWork)
                }
            }
            state.partialThrottleWorkItem?.item.cancel()
            state.partialThrottleWorkItem = nil
            state.pendingTailText = nil
            state.isTranslating = true
            state.activeTranslationTaskId = candidateTaskId
            state.lastPartialTranslationStartTime = now
            return .start(
                taskId: candidateTaskId,
                text: textToTranslate,
                sourceLocaleId: state.sourceLocaleId,
                targetLangCode: state.targetLangCode,
                sessionEpoch: state.sessionEpoch,
                resetEpoch: state.resetEpoch,
                discardEpoch: state.discardEpoch
            )
        }

        switch decision {
        case .skip:
            return
        case .throttle(let delay, let work):
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work.item)
            return
        case .start(
            let taskId,
            let textToTranslate,
            let capturedSourceLocaleId,
            let capturedTargetLangCode,
            let capturedEpoch,
            let capturedResetEpoch,
            let capturedDiscardEpoch
        ):
            // Resolve language codes outside `lock` so bare-Chinese locale resolution never stalls audio threads.
            let transSrc = Self.translationLanguageCode(from: capturedSourceLocaleId)
            let transTgt = Self.translationLanguageCode(from: capturedTargetLangCode, resolveBareChinese: true)
            let uiSrc = Self.baseLanguageCode(from: capturedSourceLocaleId)
            let uiTgt = Self.baseLanguageCode(from: capturedTargetLangCode)

            reservePartialTranslationTask(id: taskId)
            let task = Task { [weak self] in
                defer {
                    if let self = self {
                        self.unregisterTranslationTask(id: taskId)
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
                guard let self = self,
                      !Task.isCancelled,
                      self.isPartialTranslationStillCurrent(
                          taskId: taskId,
                          utteranceID: utteranceID,
                          sessionEpoch: capturedEpoch,
                          resetEpoch: capturedResetEpoch,
                          discardEpoch: capturedDiscardEpoch
                      ) else {
                    return
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
                            state.currentTranslatedSourceText = textToTranslate.trimmingCharacters(in: .whitespacesAndNewlines)
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
            attachTranslationTask(task, id: taskId)
        }
    }

    private func commitCompletedSentence(
        _ orig: String,
        fallbackTranslated: String = "",
        fallbackUntranslated: Bool = false,
        fallbackTranslatedSource: String? = nil,
        utteranceID: UUID,
        sourceLocaleId: String? = nil,
        targetLangCode: String? = nil
    ) {
        let cleanOrig = orig.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanOrig.isEmpty else { return }

        let (effSrcLocale, effTgtCode, capturedDiscardEpoch, currentTranslatedSource) = lock.withLock { state -> (String, String, UInt64, String) in
            return (
                sourceLocaleId ?? state.sourceLocaleId,
                targetLangCode ?? state.targetLangCode,
                state.discardEpoch,
                state.currentTranslatedSourceText
            )
        }
        let uiSrc = Self.baseLanguageCode(from: effSrcLocale)
        let uiTgt = Self.baseLanguageCode(from: effTgtCode)

        if uiSrc == uiTgt {
            advanceFinalRevisionAndCancelPrior(for: utteranceID)
            onFinal?(utteranceID, cleanOrig, cleanOrig, false)
            onFinalWithLanguages?(utteranceID, cleanOrig, cleanOrig, uiSrc, uiTgt, false)
            return
        }

        let transSrc = Self.translationLanguageCode(from: effSrcLocale)
        let transTgt = Self.translationLanguageCode(from: effTgtCode, resolveBareChinese: true)

        let cleanFallback = fallbackTranslated.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchedSource = (fallbackTranslatedSource ?? currentTranslatedSource).trimmingCharacters(in: .whitespacesAndNewlines)
        let translatedSourceMatchesOrig = !cleanFallback.isEmpty && !fallbackUntranslated && (matchedSource == cleanOrig)

        if translatedSourceMatchesOrig {
            // The exact finalized text was already translated via the same TranslationSession API;
            // cancel any older final revision for this utterance, emit immediately, and promote into final cache.
            advanceFinalRevisionAndCancelPrior(for: utteranceID)
            onFinal?(utteranceID, cleanOrig, cleanFallback, false)
            onFinalWithLanguages?(utteranceID, cleanOrig, cleanFallback, uiSrc, uiTgt, false)
            Task {
                await TranslationEngine.shared.storeFinalCache(
                    text: cleanOrig,
                    translated: cleanFallback,
                    sourceCode: transSrc,
                    targetCode: transTgt
                )
            }
            return
        }

        let (taskId, revision) = reserveFinalTranslationTask(for: utteranceID)
        onFinal?(utteranceID, cleanOrig, cleanOrig, true)
        onFinalWithLanguages?(utteranceID, cleanOrig, cleanOrig, uiSrc, uiTgt, true)

        let task = Task { [weak self] in
            defer {
                self?.unregisterTranslationTask(id: taskId)
            }
            let translated = await TranslationEngine.shared.translate(
                text: cleanOrig,
                sourceCode: transSrc,
                targetCode: transTgt,
                isFinal: true
            )
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self = self,
                      !Task.isCancelled,
                      self.currentDiscardEpoch == capturedDiscardEpoch,
                      self.isLatestFinalRevision(revision, for: utteranceID) else {
                    return
                }
                if let translated = translated {
                    let cleanRefined = translated.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleanRefined.isEmpty {
                        self.onFinal?(utteranceID, cleanOrig, cleanRefined, false)
                        self.onFinalWithLanguages?(utteranceID, cleanOrig, cleanRefined, uiSrc, uiTgt, false)
                    }
                }
            }
        }
        attachTranslationTask(task, id: taskId)
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
            fallbackTranslatedSource: commit.fallbackTranslatedSource,
            utteranceID: commit.utteranceID,
            sourceLocaleId: commit.sourceLocaleId,
            targetLangCode: commit.targetLangCode
        )
        closeCurrentSession(alreadyCommitted: commit)
    }

    private func closeCurrentSession(alreadyCommitted: PendingCommit? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        let (pendingCommit, oldReq, drainId, shouldStartNext) = lock.withLock { state -> (PendingCommit?, ManagedRequest?, UInt64?, Bool) in
            state.sessionTaskId &+= 1
            Self.cancelWorkItems(&state)
            state.isRestartScheduled = false
            state.isRotationScheduled = false
            state.consecutiveErrors = 0
            let r = state.request
            state.request = nil
            let (dId, commit) = Self.retireTaskForDraining(&state, alreadyCommitted: alreadyCommitted)
            state.recentSessionBuffers.removeAll(keepingCapacity: true)
            state.pendingPCMBuffers.removeAll { (now - $0.arrivalTime) >= 0.6 }
            let hasFreshPending = state.isRunning && !state.isSuspended && !state.isStartingSession && !state.isRequestingSpeechAuth && !state.pendingPCMBuffers.isEmpty
            if hasFreshPending {
                state.isRestartScheduled = true
            }
            return (commit, r, dId, hasFreshPending)
        }

        if let commit = pendingCommit {
            commitCompletedSentence(
                commit.original,
                fallbackTranslated: commit.fallbackTranslated,
                fallbackUntranslated: commit.fallbackUntranslated,
                fallbackTranslatedSource: commit.fallbackTranslatedSource,
                utteranceID: commit.utteranceID,
                sourceLocaleId: commit.sourceLocaleId,
                targetLangCode: commit.targetLangCode
            )
        }

        endManagedRequest(oldReq)
        if let drainId = drainId {
            scheduleDrainTimeout(drainId)
        }
        onSessionClosed?()
        if shouldStartNext {
            scheduleRestart(after: 0.02, forceReplace: false)
        }
    }
}

final class SpeechRecognitionManager: NSObject, @unchecked Sendable {
    private struct WeakDelegateBox: @unchecked Sendable {
        weak var value: BidirectionalSpeechDelegate?
    }

    private struct DelegateRefBox: @unchecked Sendable {
        let value: BidirectionalSpeechDelegate?
    }

    private let delegateLock = OSAllocatedUnfairLock(initialState: WeakDelegateBox())

    var delegate: BidirectionalSpeechDelegate? {
        get { delegateLock.withLock { DelegateRefBox(value: $0.value) }.value }
        set {
            let box = DelegateRefBox(value: newValue)
            delegateLock.withLock { $0.value = box.value }
        }
    }

    let callerChannel = SingleSpeechChannel(name: "caller", sourceLocaleId: "es-ES", targetLangCode: "en")
    let micChannel = SingleSpeechChannel(name: "mic", sourceLocaleId: "en-US", targetLangCode: "es")

    private let managerLock = OSAllocatedUnfairLock()
    private var _isRunning: Bool = false
    private var micFloorHoldUntil: TimeInterval = 0
    private var micFloorTimerScheduled: Bool = false
    private var micFloorTimerToken: UInt64 = 0

    var isRunning: Bool {
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

    var isAcousticallyIsolated: Bool {
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

    override init() {
        super.init()
        setupCallbacks()
    }

    static func requestAuthorization(completion: @escaping @Sendable (Bool) -> Void) {
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
        callerChannel.onIssueWithChannel = { [weak self] chName, kind, msg in
            self?.delegate?.speechRecognitionDidEncounterIssue(channelName: chName, kind: kind, message: msg)
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
        micChannel.onIssueWithChannel = { [weak self] chName, kind, msg in
            self?.delegate?.speechRecognitionDidEncounterIssue(channelName: chName, kind: kind, message: msg)
        }
        micChannel.onAuthSuccessWithChannel = { [weak self] chName in
            self?.delegate?.speechRecognitionDidClearAuthError(channelName: chName)
        }
        micChannel.onSessionClosed = { [weak self] in
            guard let self = self else { return }
            self.callerChannel.resumeAfterMicPriority()
        }
    }

    func start(
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

        if isMicEnabled {
            micChannel.start(sourceLocaleId: micLocaleId, targetLangCode: micTargetLangCode)
        } else {
            micChannel.stop()
        }

        callerChannel.start(sourceLocaleId: callerLocaleId, targetLangCode: targetLangCode)
    }

    func stop() {
        cancelMicFloorReleaseWorkItem()
        managerLock.withLock {
            _isRunning = false
        }
        callerChannel.stop()
        micChannel.stop()
    }

    func discardInFlight() {
        callerChannel.discardInFlight()
        micChannel.discardInFlight()
    }

    func resetFailureState() {
        callerChannel.resetFailureState()
        micChannel.resetFailureState()
    }

    func revalidateAuthorizationAndStatus() {
        if micChannel.isRunning {
            micChannel.revalidateAuthorizationAndStatus()
        }
        callerChannel.revalidateAuthorizationAndStatus()
    }

    func setMicEnabled(_ enabled: Bool, micLocaleId: String, micTargetLangCode: String) {
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
    /// On open speakers the microphone speaker takes priority over the caller:
    /// while `userHasFloor` is true, `callerChannel` yields and stays suspended
    /// (stashing incoming caller audio) without interrupting `micChannel`.
    /// When the user is not speaking, `callerChannel` is active and suspends
    /// the idle `micChannel` on open speakers to prevent speaker bleed.
    func feedCallerAudioBuffer(_ buffer: AVAudioPCMBuffer, userHasFloor: Bool = false) {
        let isolated = isAcousticallyIsolated
        if isolated && micChannel.isSuspended {
            cancelMicFloorReleaseWorkItem()
            micChannel.resumeAfterMicPriority()
        }
        if !isolated && userHasFloor {
            cancelMicFloorReleaseWorkItem()
            if micChannel.isSuspended {
                micChannel.resumeAfterMicPriority()
            }
            _ = callerChannel.suspendForMicPriority()
            callerChannel.appendPCMBuffer(buffer, minimumStartDelay: 0.01)
            return
        }

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
    /// The microphone speaker is prioritized before the caller: when `isUserSpeaking`
    /// is true on open speakers, `micChannel` unsuspends immediately and `callerChannel`
    /// is suspended so the user's speech is transcribed without contention.
    func feedMicAudioBuffer(_ buffer: AVAudioPCMBuffer, isUserSpeaking: Bool = false) {
        let isolated = isAcousticallyIsolated
        if isolated && callerChannel.isSuspended {
            callerChannel.resumeAfterMicPriority()
        }
        if (isUserSpeaking || isolated) && micChannel.isSuspended {
            cancelMicFloorReleaseWorkItem()
            micChannel.resumeAfterMicPriority()
        }
        let toreDownCaller: Bool
        if !isolated && isUserSpeaking {
            cancelMicFloorReleaseWorkItem()
            toreDownCaller = callerChannel.suspendForMicPriority()
        } else if !isolated {
            toreDownCaller = callerChannel.finishIfIdleForPeerChannel()
        } else {
            toreDownCaller = false
        }
        micChannel.appendPCMBuffer(buffer, minimumStartDelay: toreDownCaller ? 0.035 : 0.01)
    }
}
