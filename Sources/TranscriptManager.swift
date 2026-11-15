import Foundation
import AppKit
import os

public struct TranscriptEntry: Identifiable, Codable, Sendable, Equatable {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    private static let formatterLock = OSAllocatedUnfairLock()

    public let id: UUID
    public let utteranceID: UUID?
    public let timestamp: Date
    public let speaker: String
    public let original: String
    public let translated: String
    public let isUntranslated: Bool
    public let sourceLangCode: String?
    public let targetLangCode: String?
    public let formattedTime: String

    public init(
        id: UUID = UUID(),
        utteranceID: UUID? = nil,
        timestamp: Date = Date(),
        speaker: String,
        original: String,
        translated: String,
        isUntranslated: Bool = false,
        sourceLangCode: String? = nil,
        targetLangCode: String? = nil
    ) {
        self.id = id
        self.utteranceID = utteranceID
        self.timestamp = timestamp
        self.speaker = speaker
        self.original = original
        self.translated = translated
        self.isUntranslated = isUntranslated
        self.sourceLangCode = sourceLangCode
        self.targetLangCode = targetLangCode
        self.formattedTime = Self.formatterLock.withLock {
            Self.timeFormatter.string(from: timestamp)
        }
    }

    fileprivate init(
        id: UUID,
        utteranceID: UUID?,
        timestamp: Date,
        speaker: String,
        original: String,
        translated: String,
        isUntranslated: Bool,
        sourceLangCode: String?,
        targetLangCode: String?,
        formattedTime: String
    ) {
        self.id = id
        self.utteranceID = utteranceID
        self.timestamp = timestamp
        self.speaker = speaker
        self.original = original
        self.translated = translated
        self.isUntranslated = isUntranslated
        self.sourceLangCode = sourceLangCode
        self.targetLangCode = targetLangCode
        self.formattedTime = formattedTime
    }
}

public final class TranscriptManager: @unchecked Sendable {
    public static let shared = TranscriptManager()

    private var _entries: [TranscriptEntry] = []
    private var utteranceVirtualIndexByID: [UUID: Int] = [:]
    private var baseIndexOffset: Int = 0
    private var _restoredFromAutosave = false

    private var autosaveScheduled = false
    private var dirtyGeneration: UInt64 = 0
    private var persistedGeneration: UInt64 = 0
    private var deleteGeneration: UInt64 = 0

    private let lock = OSAllocatedUnfairLock()
    private let persistenceQueue = DispatchQueue(label: "com.callcaption.transcript.persistence", qos: .utility)
    private let autosaveEncoder = JSONEncoder()
    private let maxEntries = 2500
    private let maxAutosaveBytes = 10 * 1024 * 1024
    private let autosaveCoalesceInterval: TimeInterval = 0.25

    public var restoredFromAutosave: Bool {
        lock.withLock { _restoredFromAutosave }
    }

    public var entries: [TranscriptEntry] {
        lock.withLock { _entries }
    }

    public static let EntriesUpdatedNotification = Notification.Name("TranscriptEntriesUpdated")

    public static var autosaveFileURL: URL? {
        AppPaths.autosaveFileURL
    }

    private init() {
        if AppSettings.shared.autosaveTranscripts {
            let expectedGen = lock.withLock { deleteGeneration }
            persistenceQueue.async { [weak self] in
                self?.loadAutosavedSession(expectedDeleteGen: expectedGen)
            }
        }
    }

    public func addEntry(
        speaker: String = "Caller",
        original: String,
        translated: String,
        isUntranslated: Bool = false,
        utteranceID: UUID? = nil,
        sourceLangCode: String? = nil,
        targetLangCode: String? = nil
    ) {
        let cleanOrig = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTrans = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanOrig.isEmpty || !cleanTrans.isEmpty else { return }

        let now = Date()
        let effectiveTrans = cleanTrans.isEmpty ? cleanOrig : cleanTrans
        let autosaveEnabled = AppSettings.shared.autosaveTranscripts

        let (shouldNotify, isRefinement, postedEntry, scheduleDeleteGen) = lock.withLock { () -> (Bool, Bool, TranscriptEntry, UInt64?) in
            var matchedIndex: Int?
            if let utteranceID, let virtualIdx = utteranceVirtualIndexByID[utteranceID] {
                let candidate = virtualIdx - baseIndexOffset
                if candidate >= 0 && candidate < _entries.count && _entries[candidate].utteranceID == utteranceID {
                    matchedIndex = candidate
                }
            } else if utteranceID == nil {
                // Bounded reverse scan stopping once timestamps exceed the 10-second dedup window.
                let tailFloor = max(0, _entries.count - 32)
                for idx in stride(from: _entries.count - 1, through: tailFloor, by: -1) {
                    let prev = _entries[idx]
                    if now.timeIntervalSince(prev.timestamp) >= 10.0 {
                        break
                    }
                    if prev.speaker == speaker {
                        if prev.original == cleanOrig {
                            matchedIndex = idx
                        }
                        break
                    }
                }
            }

            if let idx = matchedIndex {
                let prev = _entries[idx]
                let mergedSourceLang = sourceLangCode ?? prev.sourceLangCode
                let mergedTargetLang = targetLangCode ?? prev.targetLangCode
                if prev.original == cleanOrig,
                   prev.translated == effectiveTrans,
                   prev.isUntranslated == isUntranslated,
                   prev.sourceLangCode == mergedSourceLang,
                   prev.targetLangCode == mergedTargetLang,
                   (utteranceID == nil || prev.utteranceID == utteranceID) {
                    return (false, true, prev, nil)
                }
                let updatedID = utteranceID ?? prev.utteranceID
                let updated = TranscriptEntry(
                    id: prev.id,
                    utteranceID: updatedID,
                    timestamp: prev.timestamp,
                    speaker: prev.speaker,
                    original: cleanOrig,
                    translated: effectiveTrans,
                    isUntranslated: isUntranslated,
                    sourceLangCode: mergedSourceLang,
                    targetLangCode: mergedTargetLang,
                    formattedTime: prev.formattedTime
                )
                _entries[idx] = updated
                if let uid = updatedID {
                    utteranceVirtualIndexByID[uid] = idx + baseIndexOffset
                }

                var genToSchedule: UInt64?
                if autosaveEnabled {
                    dirtyGeneration &+= 1
                    if !autosaveScheduled {
                        autosaveScheduled = true
                        genToSchedule = deleteGeneration
                    }
                }
                return (true, true, updated, genToSchedule)
            }

            let entry = TranscriptEntry(
                utteranceID: utteranceID,
                timestamp: now,
                speaker: speaker,
                original: cleanOrig,
                translated: effectiveTrans,
                isUntranslated: isUntranslated,
                sourceLangCode: sourceLangCode,
                targetLangCode: targetLangCode
            )
            let virtualIdx = baseIndexOffset + _entries.count
            _entries.append(entry)
            if let uid = utteranceID {
                utteranceVirtualIndexByID[uid] = virtualIdx
            }
            if _entries.count > maxEntries {
                let overflow = _entries.count - maxEntries
                for i in 0..<overflow {
                    if let evictedUID = _entries[i].utteranceID,
                       let mappedVirtual = utteranceVirtualIndexByID[evictedUID],
                       mappedVirtual == (baseIndexOffset + i) {
                        utteranceVirtualIndexByID.removeValue(forKey: evictedUID)
                    }
                }
                _entries.removeFirst(overflow)
                baseIndexOffset += overflow
            }

            var genToSchedule: UInt64?
            if autosaveEnabled {
                dirtyGeneration &+= 1
                if !autosaveScheduled {
                    autosaveScheduled = true
                    genToSchedule = deleteGeneration
                }
            }
            return (true, false, entry, genToSchedule)
        }

        guard shouldNotify else { return }

        if let expectedDeleteGen = scheduleDeleteGen {
            scheduleCoalescedAutosave(expectedDeleteGen: expectedDeleteGen)
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: TranscriptManager.EntriesUpdatedNotification,
                object: nil,
                userInfo: isRefinement ? ["refinedEntry": postedEntry] : ["newEntry": postedEntry]
            )
        }
    }

    public func clear() {
        lock.withLock {
            _entries.removeAll()
            utteranceVirtualIndexByID.removeAll()
            baseIndexOffset = 0
        }
        deleteSavedSession()

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: TranscriptManager.EntriesUpdatedNotification, object: nil)
        }
    }

    public func flushPersistence() {
        persistenceQueue.sync {
            writeLatestAutosaveIfDirty(expectedDeleteGen: nil)
        }
    }

    public func scheduleAutosaveForExistingEntriesIfNeeded() {
        guard AppSettings.shared.autosaveTranscripts else { return }
        let genToSchedule = lock.withLock { () -> UInt64? in
            guard !_entries.isEmpty else { return nil }
            dirtyGeneration &+= 1
            if !autosaveScheduled {
                autosaveScheduled = true
                return deleteGeneration
            }
            return nil
        }
        if let expectedDeleteGen = genToSchedule {
            scheduleCoalescedAutosave(expectedDeleteGen: expectedDeleteGen)
        }
    }

    public func deleteSavedSession() {
        let capturedDeleteGen = lock.withLock { () -> UInt64 in
            _restoredFromAutosave = false
            deleteGeneration &+= 1
            persistedGeneration = dirtyGeneration
            autosaveScheduled = false
            return deleteGeneration
        }
        guard let url = Self.autosaveFileURL else { return }
        persistenceQueue.async { [weak self] in
            guard let self = self else { return }
            let isCurrent = self.lock.withLock { self.deleteGeneration == capturedDeleteGen }
            guard isCurrent else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func scheduleCoalescedAutosave(expectedDeleteGen: UInt64) {
        guard Self.autosaveFileURL != nil else { return }
        persistenceQueue.asyncAfter(deadline: .now() + autosaveCoalesceInterval) { [weak self] in
            self?.runCoalescedAutosave(expectedDeleteGen: expectedDeleteGen)
        }
    }

    private func runCoalescedAutosave(expectedDeleteGen: UInt64) {
        lock.withLock {
            autosaveScheduled = false
        }
        writeLatestAutosaveIfDirty(expectedDeleteGen: expectedDeleteGen)
    }

    private func writeLatestAutosaveIfDirty(expectedDeleteGen: UInt64?) {
        guard let url = Self.autosaveFileURL else { return }
        let autosaveEnabled = AppSettings.shared.autosaveTranscripts
        guard autosaveEnabled else { return }

        let work = lock.withLock { () -> (snapshot: [TranscriptEntry], dirtyGen: UInt64, delGen: UInt64)? in
            if let expectedDeleteGen, deleteGeneration != expectedDeleteGen {
                return nil
            }
            guard dirtyGeneration != persistedGeneration, !_entries.isEmpty else {
                return nil
            }
            return (_entries, dirtyGeneration, deleteGeneration)
        }
        guard let work else { return }

        do {
            let data = try autosaveEncoder.encode(work.snapshot)
            let stillCurrent = lock.withLock { deleteGeneration == work.delGen }
            guard stillCurrent else { return }
            try AppPaths.writePrivateData(data, to: url)

            let rescheduleGen = lock.withLock { () -> UInt64? in
                guard deleteGeneration == work.delGen else { return nil }
                if persistedGeneration < work.dirtyGen {
                    persistedGeneration = work.dirtyGen
                }
                if dirtyGeneration != persistedGeneration && !autosaveScheduled && AppSettings.shared.autosaveTranscripts {
                    autosaveScheduled = true
                    return deleteGeneration
                }
                return nil
            }
            if let rescheduleGen {
                scheduleCoalescedAutosave(expectedDeleteGen: rescheduleGen)
            }
        } catch {
            AppLog.transcript.error("Failed to autosave transcript: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadAutosavedSession(expectedDeleteGen: UInt64) {
        let shouldAttemptLoad = lock.withLock {
            deleteGeneration == expectedDeleteGen && !_restoredFromAutosave
        }
        guard shouldAttemptLoad,
              let url = Self.autosaveFileURL else { return }
        var st = Darwin.stat()
        guard Darwin.lstat(url.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG else { return }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if let size = values.fileSize, size > maxAutosaveBytes {
                AppLog.transcript.warning("Ignoring oversized autosaved transcript")
                return
            }
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([TranscriptEntry].self, from: data)
            let (applied, genToSchedule) = lock.withLock { () -> (Bool, UInt64?) in
                guard deleteGeneration == expectedDeleteGen, !_restoredFromAutosave else {
                    return (false, nil)
                }
                let sliced = Array(decoded.suffix(maxEntries))
                guard !sliced.isEmpty else {
                    return (false, nil)
                }
                let hadEarlyEntries = !_entries.isEmpty
                let combined = sliced + _entries
                let finalEntries = combined.count > maxEntries ? Array(combined.suffix(maxEntries)) : combined
                _entries = finalEntries
                baseIndexOffset = 0
                utteranceVirtualIndexByID.removeAll(keepingCapacity: true)
                for (idx, item) in finalEntries.enumerated() {
                    if let uid = item.utteranceID {
                        utteranceVirtualIndexByID[uid] = idx
                    }
                }
                _restoredFromAutosave = true
                var gen: UInt64?
                if hadEarlyEntries && AppSettings.shared.autosaveTranscripts {
                    dirtyGeneration &+= 1
                    if !autosaveScheduled {
                        autosaveScheduled = true
                        gen = deleteGeneration
                    }
                }
                return (true, gen)
            }
            if applied {
                let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
                if fd >= 0 {
                    _ = Darwin.fchmod(fd, mode_t(0o600))
                    Darwin.close(fd)
                }
                if let expectedGen = genToSchedule {
                    scheduleCoalescedAutosave(expectedDeleteGen: expectedGen)
                }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: TranscriptManager.EntriesUpdatedNotification,
                        object: nil,
                        userInfo: ["restoredFromAutosave": true]
                    )
                }
            }
        } catch {
            AppLog.transcript.warning("Failed to load autosaved transcript: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func exportAsText() -> String {
        let snapshot = entries
        var lines: [String] = []
        lines.reserveCapacity(snapshot.count * 4 + 4)
        lines.append("=== Call Caption Transcript ===")
        let formattedDate = Date().formatted(date: .abbreviated, time: .standard)
        lines.append("Exported: \(formattedDate)")
        lines.append("-------------------------------------------------")

        for entry in snapshot {
            let localTime = entry.formattedTime
            let isCaller = entry.speaker.range(of: "caller", options: [.caseInsensitive, .anchored]) != nil
            lines.append("[\(localTime)] \(entry.speaker):")
            if entry.isUntranslated {
                lines.append("  Original (Untranslated): \(entry.original)")
            } else if isCaller {
                lines.append("  Translated: \(entry.translated)")
                if !entry.original.isEmpty && entry.original.caseInsensitiveCompare(entry.translated) != .orderedSame {
                    lines.append("  Original:   \(entry.original)")
                }
            } else {
                lines.append("  Original:   \(entry.original)")
                if !entry.translated.isEmpty && entry.translated.caseInsensitiveCompare(entry.original) != .orderedSame {
                    lines.append("  Translated: \(entry.translated)")
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    public func copyToClipboard() {
        let text = exportAsText()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
