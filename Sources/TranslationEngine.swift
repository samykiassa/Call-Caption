import Foundation
@preconcurrency import Translation
import os

private actor AsyncMutex {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var locked = false
    private var waiters: [Waiter] = []

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

public actor TranslationEngine {
    public static let shared = TranslationEngine()

    private var cache: [String: String] = [:]
    private var cacheKeys: [String] = []
    private var cacheRingIndex: Int = 0
    private let maxCacheSize = 2048

    private var inFlightPartialTasks: [String: Task<String?, Never>] = [:]
    private var inFlightFinalTasks: [UUID: Task<String?, Never>] = [:]
    private var pairLocks: [String: AsyncMutex] = [:]

    private var activeSessions: [String: TranslationSession] = [:]
    private var preparingTasks: [String: Task<TranslationSession?, Never>] = [:]
    private var lastFailureTimes: [String: TimeInterval] = [:]
    private let failureCooldownInterval: TimeInterval = 5.0
    private let partialTimeout: TimeInterval = 6.0
    private let finalTimeout: TimeInterval = 12.0

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

    private init() {
        cache.reserveCapacity(maxCacheSize)
        cacheKeys.reserveCapacity(maxCacheSize)
    }

    public func prewarm(sourceCode: String = "es", targetCode: String = "en") {
        let src = sourceCode.lowercased()
        let tgt = targetCode.lowercased()
        guard src != tgt else { return }

        Task {
            _ = await self.getOrCreateSession(sourceCode: src, targetCode: tgt)
        }
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

        let pairKey = "\(src)->\(tgt)"

        inFlightPartialTasks[pairKey]?.cancel()

        let currentTask = Task { () -> String? in
            if Task.isCancelled { return nil }
            return await self.performTranslation(
                text: trimmed,
                cacheKey: cacheKey,
                sourceCode: src,
                targetCode: tgt,
                isFinal: isFinal
            )
        }

        if isFinal {
            let finalTaskID = UUID()
            inFlightFinalTasks[finalTaskID] = currentTask
            let result = await currentTask.value
            inFlightFinalTasks.removeValue(forKey: finalTaskID)
            return result
        } else {
            inFlightPartialTasks[pairKey] = currentTask
            return await currentTask.value
        }
    }

    private func performTranslation(
        text: String,
        cacheKey: String,
        sourceCode: String,
        targetCode: String,
        isFinal: Bool
    ) async -> String? {
        if let cached = cache[cacheKey] {
            return cached
        }

        guard let translated = await translateWithAppleSession(
            text: text,
            sourceCode: sourceCode,
            targetCode: targetCode,
            isFinal: isFinal
        ), !translated.isEmpty else {
            return nil
        }

        storeInCache(key: cacheKey, value: translated)
        return translated
    }

    private func storeInCache(key: String, value: String) {
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
    }

    private func lockForPair(_ pairKey: String) -> AsyncMutex {
        if let existing = pairLocks[pairKey] {
            return existing
        }
        let newLock = AsyncMutex()
        pairLocks[pairKey] = newLock
        return newLock
    }

    private func getOrCreateSession(sourceCode: String, targetCode: String) async -> TranslationSession? {
        let pairKey = "\(sourceCode)->\(targetCode)"
        if let existing = activeSessions[pairKey] {
            return existing
        }

        if let inFlightPrepare = preparingTasks[pairKey] {
            return await inFlightPrepare.value
        }

        let now = ProcessInfo.processInfo.systemUptime
        if let lastFail = lastFailureTimes[pairKey], (now - lastFail) < failureCooldownInterval {
            return nil
        }

        let prepTask = Task { () -> TranslationSession? in
            let sourceLang = Locale.Language(identifier: sourceCode)
            let targetLang = Locale.Language(identifier: targetCode)
            let newSession = TranslationSession(installedSource: sourceLang, target: targetLang)
            do {
                try await newSession.prepareTranslation()
                self.finishPreparingSession(pairKey: pairKey, session: newSession)
                return newSession
            } catch {
                AppLog.translation.warning("Failed to prepare translation session for \(pairKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
                self.finishPreparingSession(pairKey: pairKey, session: nil)
                return nil
            }
        }
        preparingTasks[pairKey] = prepTask
        return await prepTask.value
    }

    private func finishPreparingSession(pairKey: String, session: TranslationSession?) {
        preparingTasks.removeValue(forKey: pairKey)
        if let session = session {
            activeSessions[pairKey] = session
            lastFailureTimes.removeValue(forKey: pairKey)
        } else {
            activeSessions.removeValue(forKey: pairKey)
            lastFailureTimes[pairKey] = ProcessInfo.processInfo.systemUptime
        }
    }

    private func translateWithAppleSession(
        text: String,
        sourceCode: String,
        targetCode: String,
        isFinal: Bool
    ) async -> String? {
        let pairKey = "\(sourceCode)->\(targetCode)"
        guard let session = await getOrCreateSession(sourceCode: sourceCode, targetCode: targetCode) else {
            if ProcessInfo.processInfo.environment["CALLCAPTION_TEST"] == "1" {
                return "[translated:\(targetCode)] \(text)"
            }
            return nil
        }

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

        let work = Task<SessionTranslateOutcome, Never> {
            if Task.isCancelled { return .cancelled }
            do {
                let response = try await session.translate(text)
                return .success(response.targetText.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch is CancellationError {
                return .cancelled
            } catch {
                if Task.isCancelled { return .cancelled }
                if ProcessInfo.processInfo.environment["CALLCAPTION_TEST"] == "1" {
                    return .success("[translated:\(targetCode)] \(text)")
                }
                return .failed
            }
        }

        let timeout = isFinal ? finalTimeout : partialTimeout
        let outcome: TranslationRace = await withTaskGroup(of: TranslationRace.self) { group in
            group.addTask {
                .finished(await work.value)
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(timeout))
                    return .timedOut
                } catch {
                    return .cancelled
                }
            }
            let first = await group.next() ?? (Task.isCancelled ? .cancelled : .timedOut)
            group.cancelAll()
            return first
        }

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
                activeSessions.removeValue(forKey: pairKey)
                lastFailureTimes[pairKey] = ProcessInfo.processInfo.systemUptime
                await mutex.unlock()
                return nil
            }
        case .timedOut:
            AppLog.translation.warning("Translation timed out for \(pairKey, privacy: .public)")
            session.cancel()
            _ = await work.value
            activeSessions.removeValue(forKey: pairKey)
            lastFailureTimes[pairKey] = ProcessInfo.processInfo.systemUptime
            await mutex.unlock()
            return nil
        case .cancelled:
            work.cancel()
            let completed = await work.value
            if case .success(let value) = completed, !value.isEmpty {
                storeInCache(key: "\(sourceCode)_\(targetCode)_\(text)", value: value)
            }
            await mutex.unlock()
            return nil
        }
    }

    public func resetFailureCooldowns() {
        lastFailureTimes.removeAll()
    }

    public func clearCache() {
        cache.removeAll(keepingCapacity: true)
        cacheKeys.removeAll(keepingCapacity: true)
        cacheRingIndex = 0

        for (_, task) in preparingTasks {
            task.cancel()
        }
        preparingTasks.removeAll()

        for (_, task) in inFlightPartialTasks {
            task.cancel()
        }
        inFlightPartialTasks.removeAll()

        for task in inFlightFinalTasks.values {
            task.cancel()
        }
        inFlightFinalTasks.removeAll()

        for (_, session) in activeSessions {
            session.cancel()
        }
        activeSessions.removeAll()
        lastFailureTimes.removeAll()
    }
}
