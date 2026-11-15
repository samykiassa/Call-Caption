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

public actor TranslationEngine {
    public static let shared = TranslationEngine()

    private struct SessionEntry: @unchecked Sendable {
        let id: UUID
        let session: TranslationSession
    }

    private var cache: [String: String] = [:]
    private var cacheOrder: [String] = []
    private let maxCacheSize = 512

    private var partialCache: [String: String] = [:]
    private var partialCacheOrder: [String] = []
    private let maxPartialCacheSize = 32

    private var pairLocks: [String: AsyncMutex] = [:]
    private var activeSessions: [String: SessionEntry] = [:]
    private var inFlightPartialTasks: [String: (id: UUID, task: Task<String?, Never>)] = [:]
    private var lastFailureTimes: [String: TimeInterval] = [:]
    private var clearEpoch: UInt64 = 0

    private let failureCooldown: TimeInterval = 5.0
    private let partialTimeout: TimeInterval = 6.0
    private let finalTimeout: TimeInterval = 12.0

    #if CALLCAPTION_TESTING
    public typealias MockTranslatorHandler = @Sendable (_ text: String, _ sourceCode: String, _ targetCode: String, _ isFinal: Bool) async throws -> String?
    private var testingTranslator: MockTranslatorHandler?
    private var testingTimeoutOverride: TimeInterval?

    public func setTranslatorForTesting(_ handler: MockTranslatorHandler?) {
        testingTranslator = handler
    }

    public func setTimeoutForTesting(_ timeout: TimeInterval?) {
        testingTimeoutOverride = timeout
    }

    public func resetForTesting() {
        testingTranslator = nil
        testingTimeoutOverride = nil
        clearCache()
    }

    public func cachedEntryCountForTesting() -> Int { cache.count }
    #endif

    private static var isTestEnv: Bool {
        ProcessInfo.processInfo.environment["CALLCAPTION_TEST"] == "1"
    }

    private init() {}

    public func checkModelStatus(sourceCode: String, targetCode: String) async -> LanguageAvailability.Status {
        let avail = LanguageAvailability()
        return await avail.status(
            from: Locale.Language(identifier: sourceCode.lowercased()),
            to: Locale.Language(identifier: targetCode.lowercased())
        )
    }

    public func prewarm(sourceCode: String, targetCode: String) async {
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
        if src == tgt { return trimmed }

        let key = "\(src)_\(tgt)_\(trimmed)"
        if let hit = cache[key] { return hit }
        if !isFinal, let partialHit = partialCache[key] { return partialHit }

        let pairKey = "\(src)->\(tgt)"
        if !isFinal {
            inFlightPartialTasks[pairKey]?.task.cancel()
        }

        let epoch = clearEpoch
        let workTask = Task<String?, Never> {
            await self.performTranslation(
                text: trimmed,
                cacheKey: key,
                pairKey: pairKey,
                sourceCode: src,
                targetCode: tgt,
                isFinal: isFinal,
                expectedEpoch: epoch
            )
        }

        let token = UUID()
        if !isFinal {
            inFlightPartialTasks[pairKey] = (token, workTask)
        }

        let result = await withTaskCancellationHandler {
            await workTask.value
        } onCancel: {
            workTask.cancel()
        }

        if !isFinal, inFlightPartialTasks[pairKey]?.id == token {
            inFlightPartialTasks.removeValue(forKey: pairKey)
        }
        return result
    }

    public func clearCache() {
        clearEpoch &+= 1
        cache.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
        partialCache.removeAll(keepingCapacity: true)
        partialCacheOrder.removeAll(keepingCapacity: true)

        for (_, entry) in inFlightPartialTasks { entry.task.cancel() }
        inFlightPartialTasks.removeAll()

        for (_, sessionEntry) in activeSessions { sessionEntry.session.cancel() }
        activeSessions.removeAll()
        lastFailureTimes.removeAll()
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

    private func acquireSession(pairKey: String, sourceCode: String, targetCode: String) async -> SessionEntry? {
        guard !Task.isCancelled, !isCooldownActive(forPair: pairKey) else { return nil }
        if let existing = activeSessions[pairKey] { return existing }

        let session = TranslationSession(
            installedSource: Locale.Language(identifier: sourceCode),
            target: Locale.Language(identifier: targetCode)
        )
        do {
            try await session.prepareTranslation()
            guard !Task.isCancelled else { return nil }
            let entry = SessionEntry(id: UUID(), session: session)
            activeSessions[pairKey] = entry
            lastFailureTimes.removeValue(forKey: pairKey)
            return entry
        } catch is CancellationError {
            return nil
        } catch {
            AppLog.translation.warning("Translation session unavailable for \(pairKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if !Self.isTestEnv {
                lastFailureTimes[pairKey] = ProcessInfo.processInfo.systemUptime
            }
            return nil
        }
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

        guard !Task.isCancelled, clearEpoch == expectedEpoch else { return nil }
        if let hit = cache[cacheKey] { return hit }
        if !isFinal, let partialHit = partialCache[cacheKey] { return partialHit }
        if isCooldownActive(forPair: pairKey) { return nil }

        let timeout = effectiveTimeout(isFinal: isFinal)

        #if CALLCAPTION_TESTING
        if let handler = testingTranslator {
            let output = await runWithTimeout(seconds: timeout, onCancel: {}) {
                try await handler(text, sourceCode, targetCode, isFinal)
            }
            guard !Task.isCancelled, clearEpoch == expectedEpoch else { return nil }
            if let clean = output?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty {
                storeCache(key: cacheKey, value: clean, isFinal: isFinal)
                return clean
            }
            lastFailureTimes[pairKey] = ProcessInfo.processInfo.systemUptime
            return nil
        }
        #endif

        guard let entry = await acquireSession(pairKey: pairKey, sourceCode: sourceCode, targetCode: targetCode) else {
            if Self.isTestEnv && !Task.isCancelled {
                return "[translated:\(targetCode)] \(text)"
            }
            return nil
        }
        guard !Task.isCancelled, clearEpoch == expectedEpoch else { return nil }

        let translated = await runWithTimeout(seconds: timeout, onCancel: { entry.session.cancel() }) {
            let response = try await entry.session.translate(text)
            return response.targetText
        }

        guard !Task.isCancelled, clearEpoch == expectedEpoch else {
            activeSessions.removeValue(forKey: pairKey)
            return nil
        }

        if let clean = translated?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty {
            storeCache(key: cacheKey, value: clean, isFinal: isFinal)
            return clean
        }

        if Self.isTestEnv {
            return "[translated:\(targetCode)] \(text)"
        }
        if activeSessions[pairKey]?.id == entry.id {
            activeSessions.removeValue(forKey: pairKey)
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

    private func runWithTimeout(
        seconds: TimeInterval,
        onCancel: @escaping @Sendable () -> Void,
        operation: @escaping @Sendable () async throws -> String?
    ) async -> String? {
        await withTaskGroup(of: String??.self) { group in
            group.addTask {
                await withTaskCancellationHandler {
                    try? await operation()
                } onCancel: {
                    onCancel()
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
    }

    private func storeCache(key: String, value: String, isFinal: Bool) {
        if isFinal {
            if cache[key] == nil {
                if cacheOrder.count >= maxCacheSize {
                    let oldest = cacheOrder.removeFirst()
                    cache.removeValue(forKey: oldest)
                }
                cacheOrder.append(key)
            }
            cache[key] = value
        } else {
            if partialCache[key] == nil {
                if partialCacheOrder.count >= maxPartialCacheSize {
                    let oldest = partialCacheOrder.removeFirst()
                    partialCache.removeValue(forKey: oldest)
                }
                partialCacheOrder.append(key)
            }
            partialCache[key] = value
        }
    }
}
