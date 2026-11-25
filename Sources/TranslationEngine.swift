import Foundation
@preconcurrency import Translation
import os

private final class AsyncMutex: @unchecked Sendable {
    private struct State {
        var locked = false
        var waiters: [(id: UUID, cont: CheckedContinuation<Void, any Error>)] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    deinit {
        let pending = state.withLock { s -> [CheckedContinuation<Void, any Error>] in
            let list = s.waiters.map(\.cont)
            s.waiters.removeAll()
            return list
        }
        for cont in pending {
            cont.resume(throwing: CancellationError())
        }
    }

    func lock() async throws {
        if Task.isCancelled { throw CancellationError() }
        let acquired = state.withLock { s -> Bool in
            if !s.locked {
                s.locked = true
                return true
            }
            return false
        }
        if acquired { return }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                enum Action { case queued, immediate, cancelled }
                let action = state.withLock { s -> Action in
                    if Task.isCancelled { return .cancelled }
                    if !s.locked {
                        s.locked = true
                        return .immediate
                    }
                    s.waiters.append((id, cont))
                    return .queued
                }
                switch action {
                case .queued:
                    break
                case .immediate:
                    cont.resume()
                case .cancelled:
                    cont.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let cont = self.state.withLock { s -> CheckedContinuation<Void, any Error>? in
                guard let idx = s.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return s.waiters.remove(at: idx).cont
            }
            cont?.resume(throwing: CancellationError())
        }
    }

    func unlock() {
        let next = state.withLock { s -> CheckedContinuation<Void, any Error>? in
            if !s.waiters.isEmpty {
                return s.waiters.removeFirst().cont
            }
            s.locked = false
            return nil
        }
        next?.resume()
    }
}

actor TranslationEngine {
    static let shared = TranslationEngine()

    private struct SessionEntry: @unchecked Sendable {
        let id: UUID
        let session: TranslationSession
        let sessionEpoch: UInt64
    }

    private struct TimeoutWorkItem: @unchecked Sendable {
        let item: DispatchWorkItem
    }

    private var cache = LRUCache<String, String>(maxCapacity: 512)
    private var partialCache = LRUCache<String, String>(maxCapacity: 32)

    private var pairLocks: [String: AsyncMutex] = [:]
    private var activeSessions: [String: SessionEntry] = [:]
    private var inFlightPartialTasks: [String: (id: UUID, task: Task<String?, Never>)] = [:]
    private var lastFailureTimes: [String: TimeInterval] = [:]
    private var clearEpoch: UInt64 = 0
    private var partialClearEpoch: UInt64 = 0
    private var sessionClearEpoch: UInt64 = 0

    private let failureCooldown: TimeInterval = 5.0
    private let partialTimeout: TimeInterval = 6.0
    private let finalTimeout: TimeInterval = 12.0

    #if CALLCAPTION_TESTING
    typealias MockTranslatorHandler = @Sendable (_ text: String, _ sourceCode: String, _ targetCode: String, _ isFinal: Bool) async throws -> String?
    private var testingTranslator: MockTranslatorHandler?
    private var testingTimeoutOverride: TimeInterval?

    func setTranslatorForTesting(_ handler: MockTranslatorHandler?) {
        testingTranslator = handler
    }

    func setTimeoutForTesting(_ timeout: TimeInterval?) {
        testingTimeoutOverride = timeout
    }

    func resetForTesting() {
        testingTranslator = nil
        testingTimeoutOverride = nil
        clearCache()
    }

    func cachedEntryCountForTesting() -> Int { cache.count }

    func testRunWithTimeoutForTesting<T: Sendable>(
        seconds: TimeInterval,
        onCancel: @escaping @Sendable () -> Void,
        operation: @escaping @Sendable () async throws -> T?
    ) async -> T? {
        await runWithTimeout(seconds: seconds, onCancel: onCancel, operation: operation)
    }
    #endif

    private static var isTestEnv: Bool {
        ProcessInfo.processInfo.environment["CALLCAPTION_TEST"] == "1"
    }

    private init() {}

    func checkModelStatus(sourceCode: String, targetCode: String) async -> LanguageAvailability.Status {
        let avail = LanguageAvailability()
        return await avail.status(
            from: Locale.Language(identifier: sourceCode.lowercased()),
            to: Locale.Language(identifier: targetCode.lowercased())
        )
    }

    func prewarm(sourceCode: String, targetCode: String) async {
        let src = sourceCode.lowercased()
        let tgt = targetCode.lowercased()
        guard src != tgt else { return }
        let pairKey = "\(src)->\(tgt)"
        let mutex = lockForPair(pairKey)
        guard (try? await mutex.lock()) != nil else { return }
        if !Task.isCancelled {
            _ = await acquireSession(pairKey: pairKey, sourceCode: src, targetCode: tgt)
        }
        mutex.unlock()
    }

    func translate(
        text: String,
        sourceCode: String,
        targetCode: String,
        isFinal: Bool = false
    ) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let src = sourceCode.lowercased()
        let tgt = targetCode.lowercased()
        if src == tgt { return trimmed }

        let key = "\(src)_\(tgt)_\(trimmed)"
        if let hit = cache.get(key) { return hit }
        if let partialHit = partialCache.get(key) {
            if isFinal {
                storeCache(key: key, value: partialHit, isFinal: true)
            }
            return partialHit
        }

        let pairKey = "\(src)->\(tgt)"
        let epoch = isFinal ? clearEpoch : partialClearEpoch
        if isFinal {
            return await performTranslation(
                text: trimmed,
                cacheKey: key,
                pairKey: pairKey,
                sourceCode: src,
                targetCode: tgt,
                isFinal: true,
                expectedEpoch: epoch
            )
        }

        inFlightPartialTasks[pairKey]?.task.cancel()
        let workTask = Task<String?, Never> {
            await self.performTranslation(
                text: trimmed,
                cacheKey: key,
                pairKey: pairKey,
                sourceCode: src,
                targetCode: tgt,
                isFinal: false,
                expectedEpoch: epoch
            )
        }

        let token = UUID()
        inFlightPartialTasks[pairKey] = (token, workTask)

        let result = await withTaskCancellationHandler {
            await workTask.value
        } onCancel: {
            workTask.cancel()
        }

        if inFlightPartialTasks[pairKey]?.id == token {
            inFlightPartialTasks.removeValue(forKey: pairKey)
        }
        return result
    }

    func storeFinalCache(text: String, translated: String, sourceCode: String, targetCode: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTranslated = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !cleanTranslated.isEmpty else { return }
        let src = sourceCode.lowercased()
        let tgt = targetCode.lowercased()
        guard src != tgt else { return }
        let key = "\(src)_\(tgt)_\(trimmed)"
        storeCache(key: key, value: cleanTranslated, isFinal: true)
    }

    func clearCache(invalidateFinals: Bool = true, invalidateSessions: Bool? = nil) {
        let shouldInvalidateSessions = invalidateSessions ?? invalidateFinals
        partialClearEpoch &+= 1
        partialCache.removeAll(keepingCapacity: true)

        for (_, entry) in inFlightPartialTasks { entry.task.cancel() }
        inFlightPartialTasks.removeAll()
        lastFailureTimes.removeAll()

        if invalidateFinals {
            clearEpoch &+= 1
            cache.removeAll(keepingCapacity: true)
        }
        if shouldInvalidateSessions {
            sessionClearEpoch &+= 1
            for (_, sessionEntry) in activeSessions { sessionEntry.session.cancel() }
            activeSessions.removeAll()
        }
    }

    func resetFailureCooldown(sourceCode: String? = nil, targetCode: String? = nil) {
        if let sourceCode, let targetCode {
            let pairKey = "\(sourceCode.lowercased())->\(targetCode.lowercased())"
            lastFailureTimes.removeValue(forKey: pairKey)
        } else {
            lastFailureTimes.removeAll()
        }
    }

    private func lockForPair(_ pairKey: String) -> AsyncMutex {
        if let existing = pairLocks[pairKey] { return existing }
        let created = AsyncMutex()
        pairLocks[pairKey] = created
        return created
    }

    private func isCooldownActive(forPair pairKey: String) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard let lastFail = lastFailureTimes[pairKey] else { return false }
        if (now - lastFail) < failureCooldown { return true }
        lastFailureTimes.removeValue(forKey: pairKey)
        return false
    }

    private func isEpochValid(isFinal: Bool, expectedEpoch: UInt64) -> Bool {
        expectedEpoch == (isFinal ? clearEpoch : partialClearEpoch)
    }

    private enum PrepareOutcome: Sendable {
        case ready
        case cancelled
        case failed(String)
    }

    private func acquireSession(pairKey: String, sourceCode: String, targetCode: String, ignoreCooldown: Bool = false) async -> SessionEntry? {
        guard !Task.isCancelled, (ignoreCooldown || !isCooldownActive(forPair: pairKey)) else { return nil }
        if let existing = activeSessions[pairKey] { return existing }

        let capturedSessionEpoch = sessionClearEpoch
        let session = TranslationSession(
            installedSource: Locale.Language(identifier: sourceCode),
            target: Locale.Language(identifier: targetCode)
        )
        let entry = SessionEntry(id: UUID(), session: session, sessionEpoch: capturedSessionEpoch)
        let prepareTimeout = effectiveTimeout(isFinal: true)
        let outcome = await runWithTimeout(
            seconds: prepareTimeout,
            onCancel: { entry.session.cancel() }
        ) {
            do {
                try await entry.session.prepareTranslation()
                return PrepareOutcome.ready
            } catch is CancellationError {
                return PrepareOutcome.cancelled
            } catch {
                return PrepareOutcome.failed(error.localizedDescription)
            }
        }

        guard !Task.isCancelled, sessionClearEpoch == capturedSessionEpoch else {
            entry.session.cancel()
            return nil
        }

        switch outcome {
        case .ready:
            activeSessions[pairKey] = entry
            lastFailureTimes.removeValue(forKey: pairKey)
            return entry
        case .cancelled:
            entry.session.cancel()
            return nil
        case .failed(let message):
            entry.session.cancel()
            AppLog.translation.warning("Translation session unavailable for \(pairKey, privacy: .public): \(message, privacy: .public)")
            if !Self.isTestEnv {
                lastFailureTimes[pairKey] = ProcessInfo.processInfo.systemUptime
            }
            return nil
        case nil:
            entry.session.cancel()
            AppLog.translation.warning("Translation session prepare timed out for \(pairKey, privacy: .public)")
            if !Self.isTestEnv {
                lastFailureTimes[pairKey] = ProcessInfo.processInfo.systemUptime
            }
            return nil
        }
    }

    private static func isNothingToTranslateError(_ error: any Error) -> Bool {
        if let transErr = error as? TranslationError, case .nothingToTranslate = transErr {
            return true
        }
        let nsError = error as NSError
        let desc = "\(nsError.domain) \(nsError.localizedDescription) \(String(describing: error))".lowercased()
        return desc.contains("nothingtotranslate") || desc.contains("nothing to translate")
    }

    private static func isAlreadyCancelledError(_ error: any Error) -> Bool {
        if let transErr = error as? TranslationError, case .alreadyCancelled = transErr {
            return true
        }
        let nsError = error as NSError
        let desc = "\(nsError.domain) \(nsError.localizedDescription) \(String(describing: error))".lowercased()
        return desc.contains("alreadycancelled") || desc.contains("already cancelled")
    }

    private func performTranslation(
        text: String,
        cacheKey: String,
        pairKey: String,
        sourceCode: String,
        targetCode: String,
        isFinal: Bool,
        expectedEpoch: UInt64
    ) async -> String? {
        let mutex = lockForPair(pairKey)
        do {
            try await mutex.lock()
        } catch {
            return nil
        }

        let result = await performLockedTranslation(
            text: text,
            cacheKey: cacheKey,
            pairKey: pairKey,
            sourceCode: sourceCode,
            targetCode: targetCode,
            isFinal: isFinal,
            expectedEpoch: expectedEpoch
        )
        mutex.unlock()
        return result
    }

    private func performLockedTranslation(
        text: String,
        cacheKey: String,
        pairKey: String,
        sourceCode: String,
        targetCode: String,
        isFinal: Bool,
        expectedEpoch: UInt64
    ) async -> String? {

        guard !Task.isCancelled, isEpochValid(isFinal: isFinal, expectedEpoch: expectedEpoch) else { return nil }
        if let hit = cache.get(cacheKey) { return hit }
        if let partialHit = partialCache.get(cacheKey) {
            if isFinal {
                storeCache(key: cacheKey, value: partialHit, isFinal: true)
            }
            return partialHit
        }
        if !isFinal, isCooldownActive(forPair: pairKey) { return nil }

        let timeout = effectiveTimeout(isFinal: isFinal)

        #if CALLCAPTION_TESTING
        if let handler = testingTranslator {
            for attempt in 0..<2 {
                let outcome = await runWithTimeoutOutcome(seconds: timeout, onCancel: {}) {
                    try await handler(text, sourceCode, targetCode, isFinal)
                }
                guard !Task.isCancelled, isEpochValid(isFinal: isFinal, expectedEpoch: expectedEpoch) else { return nil }
                switch outcome {
                case .success(let output):
                    if let clean = output?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty {
                        lastFailureTimes.removeValue(forKey: pairKey)
                        storeCache(key: cacheKey, value: clean, isFinal: isFinal)
                        return clean
                    }
                case .failure(let error):
                    if Self.isNothingToTranslateError(error) {
                        return text
                    }
                    if attempt == 0 && (error is CancellationError || Self.isAlreadyCancelledError(error)) {
                        continue
                    }
                    AppLog.translation.error("Mock translation error for \(pairKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
                case .timedOut, .callerCancelled:
                    break
                }
                break
            }
            lastFailureTimes[pairKey] = ProcessInfo.processInfo.systemUptime
            return nil
        }
        #endif

        let hadCachedSession = (activeSessions[pairKey] != nil)
        guard let entry = await acquireSession(pairKey: pairKey, sourceCode: sourceCode, targetCode: targetCode, ignoreCooldown: isFinal) else {
            if Self.isTestEnv && !Task.isCancelled {
                return "[translated:\(targetCode)] \(text)"
            }
            return nil
        }
        guard !Task.isCancelled, isEpochValid(isFinal: isFinal, expectedEpoch: expectedEpoch) else { return nil }

        let outcome = await runWithTimeoutOutcome(
            seconds: timeout,
            cancelOnCallerCancellation: isFinal,
            onCancel: { entry.session.cancel() }
        ) {
            let response = try await entry.session.translate(text)
            return response.targetText
        }

        guard sessionClearEpoch == entry.sessionEpoch else {
            return nil
        }

        if case .success(let translated) = outcome,
           let clean = translated?.trimmingCharacters(in: .whitespacesAndNewlines),
           !clean.isEmpty {
            if isEpochValid(isFinal: isFinal, expectedEpoch: expectedEpoch) {
                lastFailureTimes.removeValue(forKey: pairKey)
                storeCache(key: cacheKey, value: clean, isFinal: isFinal)
            }
            if !Task.isCancelled && isEpochValid(isFinal: isFinal, expectedEpoch: expectedEpoch) {
                return clean
            }
            // Keep warm session alive across superseded/cancelled calls that nonetheless completed cleanly.
            return nil
        }

        if case .callerCancelled = outcome, !isFinal {
            return nil
        }

        if Task.isCancelled || !isEpochValid(isFinal: isFinal, expectedEpoch: expectedEpoch) {
            if isFinal || outcome.didTerminateSession {
                entry.session.cancel()
                if activeSessions[pairKey]?.id == entry.id {
                    activeSessions.removeValue(forKey: pairKey)
                }
            }
            return nil
        }

        var sessionWasCancelledExternally = false
        switch outcome {
        case .success:
            break
        case .failure(let error):
            if Self.isNothingToTranslateError(error) {
                return text
            }
            if error is CancellationError || Self.isAlreadyCancelledError(error) {
                // Task.isCancelled is false here; the cached/active TranslationSession was cancelled externally.
                sessionWasCancelledExternally = true
                AppLog.translation.warning("Translation session cancelled externally for \(pairKey, privacy: .public); retrying with fresh session")
            } else {
                AppLog.translation.error("Translation failed for \(pairKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        case .timedOut, .callerCancelled:
            AppLog.translation.error("Translation timed out for \(pairKey, privacy: .public)")
        }

        entry.session.cancel()
        if activeSessions[pairKey]?.id == entry.id {
            activeSessions.removeValue(forKey: pairKey)
        }

        let shouldRetryWithFreshSession = (hadCachedSession || sessionWasCancelledExternally)
        if shouldRetryWithFreshSession && !Task.isCancelled && isEpochValid(isFinal: isFinal, expectedEpoch: expectedEpoch) {
            if let retryEntry = await acquireSession(pairKey: pairKey, sourceCode: sourceCode, targetCode: targetCode, ignoreCooldown: true),
               !Task.isCancelled,
               isEpochValid(isFinal: isFinal, expectedEpoch: expectedEpoch) {
                let retryOutcome = await runWithTimeoutOutcome(
                    seconds: timeout,
                    cancelOnCallerCancellation: isFinal,
                    onCancel: { retryEntry.session.cancel() }
                ) {
                    let response = try await retryEntry.session.translate(text)
                    return response.targetText
                }
                guard sessionClearEpoch == retryEntry.sessionEpoch else {
                    return nil
                }
                if case .success(let retryTranslated) = retryOutcome,
                   let clean = retryTranslated?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !clean.isEmpty {
                    if isEpochValid(isFinal: isFinal, expectedEpoch: expectedEpoch) {
                        lastFailureTimes.removeValue(forKey: pairKey)
                        storeCache(key: cacheKey, value: clean, isFinal: isFinal)
                    }
                    if !Task.isCancelled && isEpochValid(isFinal: isFinal, expectedEpoch: expectedEpoch) {
                        return clean
                    }
                    return nil
                }
                if case .callerCancelled = retryOutcome, !isFinal {
                    return nil
                }
                if Task.isCancelled || !isEpochValid(isFinal: isFinal, expectedEpoch: expectedEpoch) {
                    if isFinal || retryOutcome.didTerminateSession {
                        retryEntry.session.cancel()
                        if activeSessions[pairKey]?.id == retryEntry.id {
                            activeSessions.removeValue(forKey: pairKey)
                        }
                    }
                    return nil
                }
                switch retryOutcome {
                case .success:
                    break
                case .failure(let retryError):
                    if Self.isNothingToTranslateError(retryError) {
                        return text
                    }
                    if retryError is CancellationError || Self.isAlreadyCancelledError(retryError) {
                        AppLog.translation.warning("Translation retry session cancelled externally for \(pairKey, privacy: .public)")
                    } else {
                        AppLog.translation.error("Translation retry failed for \(pairKey, privacy: .public): \(retryError.localizedDescription, privacy: .public)")
                    }
                case .timedOut, .callerCancelled:
                    AppLog.translation.error("Translation retry timed out for \(pairKey, privacy: .public)")
                }
                retryEntry.session.cancel()
                if activeSessions[pairKey]?.id == retryEntry.id {
                    activeSessions.removeValue(forKey: pairKey)
                }
            }
        }

        if Self.isTestEnv {
            return "[translated:\(targetCode)] \(text)"
        }
        lastFailureTimes[pairKey] = ProcessInfo.processInfo.systemUptime
        return nil
    }

    private func effectiveTimeout(isFinal: Bool) -> TimeInterval {
        #if CALLCAPTION_TESTING
        if let override = testingTimeoutOverride { return override }
        #endif
        return isFinal ? finalTimeout : partialTimeout
    }

    private enum TimeoutOutcome<T: Sendable>: Sendable {
        case success(T?)
        case failure(any Error)
        case timedOut
        case callerCancelled

        var didTerminateSession: Bool {
            switch self {
            case .timedOut, .failure:
                return true
            case .success, .callerCancelled:
                return false
            }
        }
    }

    private enum TimeoutSetupResult: Sendable {
        case started
        case alreadyResolved
        case newlyCancelled
    }

    private struct TimeoutState<T: Sendable>: @unchecked Sendable {
        var done = false
        var opTask: Task<Void, Never>?
        var timerWork: TimeoutWorkItem?
        var continuation: CheckedContinuation<TimeoutOutcome<T>, Never>?
    }

    private func runWithTimeout<T: Sendable>(
        seconds: TimeInterval,
        onCancel: @escaping @Sendable () -> Void,
        operation: @escaping @Sendable () async throws -> T?
    ) async -> T? {
        let outcome = await runWithTimeoutOutcome(seconds: seconds, onCancel: onCancel, operation: operation)
        switch outcome {
        case .success(let value):
            return value
        case .failure, .timedOut, .callerCancelled:
            return nil
        }
    }

    private func runWithTimeoutOutcome<T: Sendable>(
        seconds: TimeInterval,
        cancelOnCallerCancellation: Bool = true,
        onCancel: @escaping @Sendable () -> Void,
        operation: @escaping @Sendable () async throws -> T?
    ) async -> TimeoutOutcome<T> {
        if Task.isCancelled {
            if cancelOnCallerCancellation {
                onCancel()
            }
            return .callerCancelled
        }

        let box = OSAllocatedUnfairLock(initialState: TimeoutState<T>())

        @Sendable func resolve(_ outcome: TimeoutOutcome<T>, cancelOperation: Bool) {
            let (didResolve, cont, op, timer) = box.withLock { state -> (Bool, CheckedContinuation<TimeoutOutcome<T>, Never>?, Task<Void, Never>?, TimeoutWorkItem?) in
                guard !state.done else { return (false, nil, nil, nil) }
                state.done = true
                let c = state.continuation
                state.continuation = nil
                let o = state.opTask
                state.opTask = nil
                let t = state.timerWork
                state.timerWork = nil
                return (true, c, o, t)
            }
            guard didResolve else { return }
            timer?.item.cancel()
            if cancelOperation {
                op?.cancel()
                onCancel()
            }
            cont?.resume(returning: outcome)
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let setupResult = box.withLock { state -> TimeoutSetupResult in
                    if state.done {
                        return .alreadyResolved
                    }
                    if Task.isCancelled {
                        state.done = true
                        return .newlyCancelled
                    }
                    state.continuation = continuation
                    state.opTask = Task.detached(priority: .userInitiated) {
                        do {
                            let result = try await operation()
                            resolve(.success(result), cancelOperation: false)
                        } catch {
                            resolve(.failure(error), cancelOperation: false)
                        }
                    }
                    let timerWork = TimeoutWorkItem(item: DispatchWorkItem {
                        resolve(.timedOut, cancelOperation: true)
                    })
                    state.timerWork = timerWork
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(
                        deadline: .now() + seconds,
                        execute: timerWork.item
                    )
                    return .started
                }
                switch setupResult {
                case .started:
                    break
                case .alreadyResolved:
                    continuation.resume(returning: .timedOut)
                case .newlyCancelled:
                    if cancelOnCallerCancellation {
                        onCancel()
                    }
                    continuation.resume(returning: .callerCancelled)
                }
            }
        } onCancel: {
            if cancelOnCallerCancellation {
                resolve(.callerCancelled, cancelOperation: true)
            }
        }
    }

    private func storeCache(key: String, value: String, isFinal: Bool) {
        if isFinal {
            cache.put(key, value: value)
        } else {
            partialCache.put(key, value: value)
        }
    }
}
