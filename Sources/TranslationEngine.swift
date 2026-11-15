import Foundation
@preconcurrency import Translation
import os

private actor AsyncMutexCore {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var locked = false
    private var waiters: [Waiter] = []

    var isLocked: Bool { locked }
    var waiterCount: Int { waiters.count }

    deinit {
        for waiter in waiters {
            waiter.continuation.resume(throwing: CancellationError())
        }
        waiters.removeAll()
    }

    func lock() async throws {
        if Task.isCancelled {
            throw CancellationError()
        }
        if !locked {
            locked = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler(
            operation: { () async throws -> Void in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        waiters.append(Waiter(id: id, continuation: continuation))
                    }
                }
            },
            onCancel: {
                Task { [weak self] in
                    await self?.cancelWaiter(id: id)
                }
            }
        )
    }

    private func cancelWaiter(id: UUID) {
        if let idx = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: idx)
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    func unlock() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.continuation.resume()
        } else {
            locked = false
        }
    }
}

#if CALLCAPTION_TESTING
public actor AsyncMutex {
    private let core = AsyncMutexCore()

    public init() {}

    public var isLocked: Bool {
        get async { await core.isLocked }
    }

    public var waiterCount: Int {
        get async { await core.waiterCount }
    }

    public func lock() async throws {
        try await core.lock()
    }

    public func unlock() async {
        await core.unlock()
    }
}
#else
private typealias AsyncMutex = AsyncMutexCore
#endif

public actor TranslationEngine {
    public static let shared = TranslationEngine()

    private struct CachedSession: @unchecked Sendable {
        let id: UUID
        let session: TranslationSession
    }

    private struct PartialTaskEntry {
        let id: UUID
        let task: Task<String?, Never>
    }

    private struct PreparingEntry {
        let id: UUID
        let task: Task<CachedSession?, Never>
    }

    private enum SessionAcquireResult {
        case ready(CachedSession)
        case cooldownActive
        case cancelled
        case unavailable
    }

    private var cache: [String: String] = [:]
    private var cacheKeys: [String] = []
    private var cacheRingIndex: Int = 0
    private let maxCacheSize = 2048

    private var partialCache: [String: String] = [:]
    private var partialCacheKeys: [String] = []
    private var partialCacheRingIndex: Int = 0
    private let maxPartialCacheSize = 64

    private var inFlightPartialTasks: [String: PartialTaskEntry] = [:]
    private var inFlightFinalTasks: [UUID: Task<String?, Never>] = [:]
    private var pairLocks: [String: AsyncMutex] = [:]

    private var activeSessions: [String: CachedSession] = [:]
    private var preparingTasks: [String: PreparingEntry] = [:]
    private var prewarmTasks: [String: Task<Void, Never>] = [:]
    private var clearEpoch: UInt64 = 0
    private var lastFailureTimes: [String: TimeInterval] = [:]
    private let failureCooldownInterval: TimeInterval = 5.0
    private let partialTimeout: TimeInterval = 6.0
    private let finalTimeout: TimeInterval = 12.0

    #if CALLCAPTION_TESTING
    public typealias MockTranslatorHandler = @Sendable (_ text: String, _ sourceCode: String, _ targetCode: String, _ isFinal: Bool) async throws -> String?
    private var testingTranslator: MockTranslatorHandler?
    private var testingTimeoutOverride: TimeInterval?
    #endif

    private enum SessionTranslateOutcome: Sendable {
        case success(String)
        case cancelled
        case failed
    }

    private enum TranslationRace: Sendable {
        case finished(SessionTranslateOutcome)
        case timedOut
        case cancelled
    }

    private final class RaceCoordinator: @unchecked Sendable {
        private struct State {
            var settled = false
            var continuation: CheckedContinuation<TranslationRace, Never>?
            var earlyResult: TranslationRace?
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        func tryClaimSettlement() -> Bool {
            state.withLock { box in
                guard !box.settled else { return false }
                box.settled = true
                return true
            }
        }

        func installContinuation(_ cont: CheckedContinuation<TranslationRace, Never>) {
            let early = state.withLock { box -> TranslationRace? in
                if let result = box.earlyResult {
                    box.earlyResult = nil
                    return result
                }
                box.continuation = cont
                return nil
            }
            if let early = early {
                cont.resume(returning: early)
            }
        }

        func resumeSettledContinuation(_ result: TranslationRace) {
            let cont = state.withLock { box -> CheckedContinuation<TranslationRace, Never>? in
                if let c = box.continuation {
                    box.continuation = nil
                    return c
                }
                box.earlyResult = result
                return nil
            }
            cont?.resume(returning: result)
        }
    }

    private init() {
        cache.reserveCapacity(maxCacheSize)
        cacheKeys.reserveCapacity(maxCacheSize)
        partialCache.reserveCapacity(maxPartialCacheSize)
        partialCacheKeys.reserveCapacity(maxPartialCacheSize)
    }

    public func prewarm(sourceCode: String = "es", targetCode: String = "en") async {
        let src = sourceCode.lowercased()
        let tgt = targetCode.lowercased()
        guard src != tgt else { return }
        let pairKey = "\(src)->\(tgt)"
        prewarmTasks[pairKey]?.cancel()
        let epoch = clearEpoch
        let prewarmID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.prewarmWithLock(sourceCode: src, targetCode: tgt, expectedEpoch: epoch)
        }
        prewarmTasks[pairKey] = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if clearEpoch == epoch {
            _ = prewarmID
            prewarmTasks.removeValue(forKey: pairKey)
        }
    }

    private func prewarmWithLock(sourceCode: String, targetCode: String, expectedEpoch: UInt64) async {
        guard !Task.isCancelled, clearEpoch == expectedEpoch else { return }
        let pairKey = "\(sourceCode)->\(targetCode)"
        let mutex = lockForPair(pairKey)
        do {
            try await mutex.lock()
        } catch {
            return
        }
        if !Task.isCancelled && clearEpoch == expectedEpoch {
            _ = await self.getOrCreateSession(sourceCode: sourceCode, targetCode: targetCode)
        }
        await mutex.unlock()
    }

    public func checkModelStatus(sourceCode: String, targetCode: String) async -> LanguageAvailability.Status {
        let avail = LanguageAvailability()
        let sourceLang = Locale.Language(identifier: sourceCode.lowercased())
        let targetLang = Locale.Language(identifier: targetCode.lowercased())
        return await avail.status(from: sourceLang, to: targetLang)
    }

    public func translate(
        text: String,
        sourceCode: String,
        targetCode: String,
        isFinal: Bool = false
    ) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let src = sourceCode.lowercased()
        let tgt = targetCode.lowercased()

        if src == tgt {
            return trimmed
        }

        let cacheKey = "\(src)_\(tgt)_\(trimmed)"
        if let cached = cache[cacheKey] {
            return cached
        }
        if !isFinal, let cachedPartial = partialCache[cacheKey] {
            return cachedPartial
        }
        if isFinal, shouldPromotePartialCache(), let cachedPartial = partialCache[cacheKey] {
            storeInCache(key: cacheKey, value: cachedPartial, isFinal: true)
            return cachedPartial
        }

        let pairKey = "\(src)->\(tgt)"

        // Only supersede prior partial translations with newer partials so a final
        // drain for a completed utterance does not abort an active partial on the next sentence.
        if !isFinal {
            inFlightPartialTasks[pairKey]?.task.cancel()
        }

        let requestEpoch = clearEpoch
        let currentTask = Task { () -> String? in
            if Task.isCancelled { return nil }
            return await self.performTranslation(
                text: trimmed,
                cacheKey: cacheKey,
                sourceCode: src,
                targetCode: tgt,
                isFinal: isFinal,
                expectedEpoch: requestEpoch
            )
        }

        if isFinal {
            let finalTaskID = UUID()
            inFlightFinalTasks[finalTaskID] = currentTask
            let result = await withTaskCancellationHandler {
                await currentTask.value
            } onCancel: {
                currentTask.cancel()
            }
            inFlightFinalTasks.removeValue(forKey: finalTaskID)
            return result
        } else {
            let partialTaskID = UUID()
            inFlightPartialTasks[pairKey] = PartialTaskEntry(id: partialTaskID, task: currentTask)
            let result = await withTaskCancellationHandler {
                await currentTask.value
            } onCancel: {
                currentTask.cancel()
            }
            if inFlightPartialTasks[pairKey]?.id == partialTaskID {
                inFlightPartialTasks.removeValue(forKey: pairKey)
            }
            return result
        }
    }

    private func shouldPromotePartialCache() -> Bool {
        #if CALLCAPTION_TESTING
        return testingTranslator == nil
        #else
        return true
        #endif
    }

    private func performTranslation(
        text: String,
        cacheKey: String,
        sourceCode: String,
        targetCode: String,
        isFinal: Bool,
        expectedEpoch: UInt64
    ) async -> String? {
        guard clearEpoch == expectedEpoch else { return nil }
        if let cached = cache[cacheKey] {
            return cached
        }
        if !isFinal, let cachedPartial = partialCache[cacheKey] {
            return cachedPartial
        }
        if isFinal, shouldPromotePartialCache(), let cachedPartial = partialCache[cacheKey] {
            storeInCache(key: cacheKey, value: cachedPartial, isFinal: true)
            return cachedPartial
        }

        guard let translated = await translateWithAppleSession(
            text: text,
            sourceCode: sourceCode,
            targetCode: targetCode,
            isFinal: isFinal,
            expectedEpoch: expectedEpoch
        ), !translated.isEmpty else {
            return nil
        }

        guard !Task.isCancelled, clearEpoch == expectedEpoch else {
            return nil
        }
        storeInCache(key: cacheKey, value: translated, isFinal: isFinal)
        return translated
    }

    private func storeInCache(key: String, value: String, isFinal: Bool) {
        if isFinal {
            if cache[key] == nil {
                if cacheKeys.count < maxCacheSize {
                    cacheKeys.append(key)
                } else {
                    let evictedKey = cacheKeys[cacheRingIndex]
                    cache.removeValue(forKey: evictedKey)
                    cacheKeys[cacheRingIndex] = key
                    cacheRingIndex = (cacheRingIndex + 1) % maxCacheSize
                }
            }
            cache[key] = value
        } else {
            if partialCache[key] == nil {
                if partialCacheKeys.count < maxPartialCacheSize {
                    partialCacheKeys.append(key)
                } else {
                    let evictedKey = partialCacheKeys[partialCacheRingIndex]
                    partialCache.removeValue(forKey: evictedKey)
                    partialCacheKeys[partialCacheRingIndex] = key
                    partialCacheRingIndex = (partialCacheRingIndex + 1) % maxPartialCacheSize
                }
            }
            partialCache[key] = value
        }
    }

    private func lockForPair(_ pairKey: String) -> AsyncMutex {
        if let existing = pairLocks[pairKey] {
            return existing
        }
        let newLock = AsyncMutex()
        pairLocks[pairKey] = newLock
        return newLock
    }

    private func isCooldownActive(forPair pairKey: String) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let lastFail = lastFailureTimes[pairKey] {
            if (now - lastFail) < failureCooldownInterval {
                return true
            }
            lastFailureTimes.removeValue(forKey: pairKey)
        }
        return false
    }

    private func getOrCreateSession(sourceCode: String, targetCode: String) async -> SessionAcquireResult {
        if Task.isCancelled {
            return .cancelled
        }

        let pairKey = "\(sourceCode)->\(targetCode)"
        if isCooldownActive(forPair: pairKey) {
            return .cooldownActive
        }

        if let existing = activeSessions[pairKey] {
            return .ready(existing)
        }

        if let inFlightPrepare = preparingTasks[pairKey] {
            if let prepared = await inFlightPrepare.task.value {
                if Task.isCancelled { return .cancelled }
                if isCooldownActive(forPair: pairKey) { return .cooldownActive }
                if let current = activeSessions[pairKey] {
                    return .ready(current)
                }
                return .ready(prepared)
            }
            if Task.isCancelled { return .cancelled }
            if isCooldownActive(forPair: pairKey) { return .cooldownActive }
            return .unavailable
        }

        let prepID = UUID()
        let prepTask = Task<CachedSession?, Never> {
            if Task.isCancelled { return nil }
            let sourceLang = Locale.Language(identifier: sourceCode)
            let targetLang = Locale.Language(identifier: targetCode)
            let newSession = TranslationSession(installedSource: sourceLang, target: targetLang)
            do {
                try await newSession.prepareTranslation()
                let entry = CachedSession(id: UUID(), session: newSession)
                let accepted = self.finishPreparingSession(
                    pairKey: pairKey,
                    prepID: prepID,
                    entry: entry,
                    failed: false,
                    cancelled: Task.isCancelled
                )
                return accepted ? entry : nil
            } catch is CancellationError {
                _ = self.finishPreparingSession(
                    pairKey: pairKey,
                    prepID: prepID,
                    entry: nil,
                    failed: false,
                    cancelled: true
                )
                return nil
            } catch {
                let wasCancelled = Task.isCancelled
                if !wasCancelled {
                    AppLog.translation.warning("Failed to prepare translation session for \(pairKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                _ = self.finishPreparingSession(
                    pairKey: pairKey,
                    prepID: prepID,
                    entry: nil,
                    failed: !wasCancelled,
                    cancelled: wasCancelled
                )
                return nil
            }
        }
        preparingTasks[pairKey] = PreparingEntry(id: prepID, task: prepTask)
        let prepared = await prepTask.value
        if Task.isCancelled { return .cancelled }
        if isCooldownActive(forPair: pairKey) { return .cooldownActive }
        if let prepared = prepared, activeSessions[pairKey]?.id == prepared.id {
            return .ready(prepared)
        }
        if let active = activeSessions[pairKey] {
            return .ready(active)
        }
        return .unavailable
    }

    @discardableResult
    private func finishPreparingSession(
        pairKey: String,
        prepID: UUID,
        entry: CachedSession?,
        failed: Bool,
        cancelled: Bool
    ) -> Bool {
        // Ignore stale completion if clearCache() removed or superseded this preparation task.
        guard preparingTasks[pairKey]?.id == prepID else {
            return false
        }
        preparingTasks.removeValue(forKey: pairKey)

        if cancelled {
            return false
        }

        if let entry = entry {
            activeSessions[pairKey] = entry
            lastFailureTimes.removeValue(forKey: pairKey)
            return true
        }

        activeSessions.removeValue(forKey: pairKey)
        // Only record prep failure cooldown outside the synthetic unit-test environment so missing
        // on-device packs under CALLCAPTION_TEST=1 still allow synthetic fallback without poisoning subsequent calls.
        if failed && !AppPaths.isTestEnvironment {
            lastFailureTimes[pairKey] = ProcessInfo.processInfo.systemUptime
        }
        return false
    }

    private func effectiveTimeout(isFinal: Bool) -> TimeInterval {
        #if CALLCAPTION_TESTING
        if let override = testingTimeoutOverride {
            return override
        }
        #endif
        return isFinal ? finalTimeout : partialTimeout
    }

    nonisolated private static func raceTranslationWork(
        timeout: TimeInterval,
        onTimeoutOrCancel: @escaping @Sendable () -> Void,
        operation: @escaping @Sendable () async -> SessionTranslateOutcome
    ) async -> TranslationRace {
        if Task.isCancelled {
            return .cancelled
        }

        let coordinator = RaceCoordinator()
        let workTask = Task<Void, Never> {
            let result = await operation()
            if coordinator.tryClaimSettlement() {
                coordinator.resumeSettledContinuation(.finished(result))
            }
        }

        let timerTask = Task<Void, Never> {
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            if coordinator.tryClaimSettlement() {
                onTimeoutOrCancel()
                workTask.cancel()
                coordinator.resumeSettledContinuation(.timedOut)
            }
        }

        let race = await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation { (cont: CheckedContinuation<TranslationRace, Never>) in
                    if Task.isCancelled, coordinator.tryClaimSettlement() {
                        onTimeoutOrCancel()
                        workTask.cancel()
                        timerTask.cancel()
                        cont.resume(returning: .cancelled)
                        return
                    }
                    coordinator.installContinuation(cont)
                }
            },
            onCancel: {
                if coordinator.tryClaimSettlement() {
                    onTimeoutOrCancel()
                    workTask.cancel()
                    timerTask.cancel()
                    coordinator.resumeSettledContinuation(.cancelled)
                }
            }
        )

        timerTask.cancel()
        return race
    }

    private func translateWithAppleSession(
        text: String,
        sourceCode: String,
        targetCode: String,
        isFinal: Bool,
        expectedEpoch: UInt64
    ) async -> String? {
        let pairKey = "\(sourceCode)->\(targetCode)"
        let mutex = lockForPair(pairKey)
        do {
            try await mutex.lock()
        } catch {
            return nil
        }

        if Task.isCancelled {
            await mutex.unlock()
            return nil
        }

        // Enforce failure cooldown BEFORE test fallback so CALLCAPTION_TEST respects cooldowns.
        if isCooldownActive(forPair: pairKey) {
            await mutex.unlock()
            return nil
        }

        let timeout = effectiveTimeout(isFinal: isFinal)

        #if CALLCAPTION_TESTING
        if let handler = testingTranslator {
            let race = await Self.raceTranslationWork(
                timeout: timeout,
                onTimeoutOrCancel: {},
                operation: {
                    if Task.isCancelled { return .cancelled }
                    do {
                        if let output = try await handler(text, sourceCode, targetCode, isFinal) {
                            let clean = output.trimmingCharacters(in: .whitespacesAndNewlines)
                            return clean.isEmpty ? .failed : .success(clean)
                        }
                        return Task.isCancelled ? .cancelled : .failed
                    } catch is CancellationError {
                        return .cancelled
                    } catch {
                        return Task.isCancelled ? .cancelled : .failed
                    }
                }
            )
            await mutex.unlock()
            switch race {
            case .finished(.success(let val)):
                return val
            case .finished(.cancelled), .cancelled:
                return nil
            case .finished(.failed), .timedOut:
                lastFailureTimes[pairKey] = ProcessInfo.processInfo.systemUptime
                return nil
            }
        }
        #endif

        let acquireResult = await getOrCreateSession(sourceCode: sourceCode, targetCode: targetCode)
        let sessionEntry: CachedSession
        switch acquireResult {
        case .ready(let entry):
            sessionEntry = entry
        case .cooldownActive, .cancelled:
            await mutex.unlock()
            return nil
        case .unavailable:
            await mutex.unlock()
            if AppPaths.isTestEnvironment {
                return Task.isCancelled ? nil : "[translated:\(targetCode)] \(text)"
            }
            return nil
        }

        if Task.isCancelled {
            await mutex.unlock()
            return nil
        }

        let sessionID = sessionEntry.id
        let cacheKey = "\(sourceCode)_\(targetCode)_\(text)"

        let outcome = await Self.raceTranslationWork(
            timeout: timeout,
            onTimeoutOrCancel: {
                sessionEntry.session.cancel()
            },
            operation: { [weak self] () -> SessionTranslateOutcome in
                if Task.isCancelled { return .cancelled }
                do {
                    let response = try await sessionEntry.session.translate(text)
                    let trimmed = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if Task.isCancelled {
                        if !trimmed.isEmpty {
                            await self?.storeLateTranslationIfNeeded(
                                key: cacheKey,
                                value: trimmed,
                                isFinal: isFinal,
                                expectedEpoch: expectedEpoch
                            )
                        }
                        return .cancelled
                    }
                    return .success(trimmed)
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    if Task.isCancelled { return .cancelled }
                    if AppPaths.isTestEnvironment {
                        return .success("[translated:\(targetCode)] \(text)")
                    }
                    return .failed
                }
            }
        )

        switch outcome {
        case .finished(let workOutcome):
            switch workOutcome {
            case .success(let value) where !value.isEmpty:
                await mutex.unlock()
                return value
            case .cancelled:
                await mutex.unlock()
                return nil
            case .success, .failed:
                if Task.isCancelled {
                    await mutex.unlock()
                    return nil
                }
                if activeSessions[pairKey]?.id == sessionID {
                    activeSessions.removeValue(forKey: pairKey)
                }
                lastFailureTimes[pairKey] = ProcessInfo.processInfo.systemUptime
                await mutex.unlock()
                return nil
            }
        case .timedOut:
            AppLog.translation.warning("Translation timed out for \(pairKey, privacy: .public)")
            sessionEntry.session.cancel()
            if activeSessions[pairKey]?.id == sessionID {
                activeSessions.removeValue(forKey: pairKey)
            }
            lastFailureTimes[pairKey] = ProcessInfo.processInfo.systemUptime
            await mutex.unlock()
            return nil
        case .cancelled:
            sessionEntry.session.cancel()
            if activeSessions[pairKey]?.id == sessionID {
                activeSessions.removeValue(forKey: pairKey)
            }
            await mutex.unlock()
            return nil
        }
    }

    private func storeLateTranslationIfNeeded(key: String, value: String, isFinal: Bool, expectedEpoch: UInt64) {
        guard isFinal, !value.isEmpty, clearEpoch == expectedEpoch else { return }
        storeInCache(key: key, value: value, isFinal: true)
    }

    public func resetFailureCooldowns() {
        lastFailureTimes.removeAll()
    }

    public func clearCache() {
        clearEpoch &+= 1

        cache.removeAll(keepingCapacity: true)
        cacheKeys.removeAll(keepingCapacity: true)
        cacheRingIndex = 0

        partialCache.removeAll(keepingCapacity: true)
        partialCacheKeys.removeAll(keepingCapacity: true)
        partialCacheRingIndex = 0

        for task in prewarmTasks.values {
            task.cancel()
        }
        prewarmTasks.removeAll()

        for (_, entry) in preparingTasks {
            entry.task.cancel()
        }
        preparingTasks.removeAll()

        for (_, entry) in inFlightPartialTasks {
            entry.task.cancel()
        }
        inFlightPartialTasks.removeAll()

        for task in inFlightFinalTasks.values {
            task.cancel()
        }
        inFlightFinalTasks.removeAll()

        for (_, entry) in activeSessions {
            entry.session.cancel()
        }
        activeSessions.removeAll()
        lastFailureTimes.removeAll()
    }

    #if CALLCAPTION_TESTING
    public func setTranslatorForTesting(_ handler: MockTranslatorHandler?) {
        testingTranslator = handler
    }

    public func setTranslationTimeoutForTesting(_ timeout: TimeInterval?) {
        testingTimeoutOverride = timeout
    }

    public func setFailureCooldownForTesting(sourceCode: String, targetCode: String, systemUptime: TimeInterval? = nil) {
        let pairKey = "\(sourceCode.lowercased())->\(targetCode.lowercased())"
        lastFailureTimes[pairKey] = systemUptime ?? ProcessInfo.processInfo.systemUptime
    }

    public func isInFailureCooldownForTesting(sourceCode: String, targetCode: String) -> Bool {
        let pairKey = "\(sourceCode.lowercased())->\(targetCode.lowercased())"
        return isCooldownActive(forPair: pairKey)
    }

    public func cachedEntryCountForTesting() -> Int {
        cache.count
    }

    public func partialCachedEntryCountForTesting() -> Int {
        partialCache.count
    }

    public func cachedValueForTesting(text: String, sourceCode: String, targetCode: String) -> String? {
        let key = "\(sourceCode.lowercased())_\(targetCode.lowercased())_\(text.trimmingCharacters(in: .whitespacesAndNewlines))"
        return cache[key]
    }

    public func activeSessionCountForTesting() -> Int {
        activeSessions.count
    }

    public func inFlightTaskCountsForTesting() -> (partials: Int, finals: Int, preparing: Int) {
        (inFlightPartialTasks.count, inFlightFinalTasks.count, preparingTasks.count)
    }

    public func resetForTesting() {
        testingTranslator = nil
        testingTimeoutOverride = nil
        clearCache()
    }
    #endif
}
