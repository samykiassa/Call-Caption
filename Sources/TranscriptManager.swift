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
}

public final class TranscriptManager: @unchecked Sendable {
    public static let shared = TranscriptManager()

    private var _entries: [TranscriptEntry] = []
    private let lock = OSAllocatedUnfairLock()
    private let persistenceQueue = DispatchQueue(label: "com.callcaption.transcript.persistence", qos: .utility)
    private let maxEntries = 2500
    private let maxAutosaveBytes = 10 * 1024 * 1024

    public private(set) var restoredFromAutosave = false

    public var entries: [TranscriptEntry] {
        lock.withLock { _entries }
    }

    public static let EntriesUpdatedNotification = Notification.Name("TranscriptEntriesUpdated")

    public static var autosaveFileURL: URL? {
        AppPaths.autosaveFileURL
    }

    private init() {
        if AppSettings.shared.autosaveTranscripts {
            loadAutosavedSession()
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

        let (shouldNotify, isRefinement, postedEntry, snapshotForSave) = lock.withLock { () -> (Bool, Bool, TranscriptEntry, [TranscriptEntry]?) in
            var matchedIndex: Int?
            if let utteranceID {
                matchedIndex = _entries.indices.reversed().first(where: { _entries[$0].utteranceID == utteranceID })
            } else if let idx = _entries.indices.reversed().first(where: { _entries[$0].speaker == speaker }) {
                let prev = _entries[idx]
                if prev.original == cleanOrig && now.timeIntervalSince(prev.timestamp) < 10.0 {
                    matchedIndex = idx
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
                let updated = TranscriptEntry(
                    id: prev.id,
                    utteranceID: utteranceID ?? prev.utteranceID,
                    timestamp: prev.timestamp,
                    speaker: prev.speaker,
                    original: cleanOrig,
                    translated: effectiveTrans,
                    isUntranslated: isUntranslated,
                    sourceLangCode: mergedSourceLang,
                    targetLangCode: mergedTargetLang
                )
                _entries[idx] = updated
                let snap = AppSettings.shared.autosaveTranscripts ? _entries : nil
                return (true, true, updated, snap)
            }

            _entries.append(entry)
            if _entries.count > maxEntries {
                _entries.removeFirst(_entries.count - maxEntries)
            }
            let snap = AppSettings.shared.autosaveTranscripts ? _entries : nil
            return (true, false, entry, snap)
        }

        guard shouldNotify else { return }

        if let snapshot = snapshotForSave {
            scheduleAutosave(snapshot)
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
        }
        deleteSavedSession()

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: TranscriptManager.EntriesUpdatedNotification, object: nil)
        }
    }

    public func flushPersistence() {
        persistenceQueue.sync {}
    }

    public func deleteSavedSession() {
        restoredFromAutosave = false
        guard let url = Self.autosaveFileURL else { return }
        persistenceQueue.sync {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func scheduleAutosave(_ snapshot: [TranscriptEntry]) {
        guard let url = Self.autosaveFileURL else { return }
        persistenceQueue.async {
            do {
                try AppPaths.ensureDirectory(AppPaths.transcriptsDirectory)
                let data = try JSONEncoder().encode(snapshot)
                try AppPaths.writePrivateData(data, to: url)
            } catch {
                AppLog.transcript.error("Failed to autosave transcript: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func loadAutosavedSession() {
        guard let url = Self.autosaveFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if let size = values.fileSize, size > maxAutosaveBytes {
                AppLog.transcript.warning("Ignoring oversized autosaved transcript")
                return
            }
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([TranscriptEntry].self, from: data)
            lock.withLock {
                _entries = Array(decoded.suffix(maxEntries))
            }
            restoredFromAutosave = true
            try? AppPaths.ensureDirectory(AppPaths.transcriptsDirectory)
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: url.path
            )
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
            let localTime = entry.timestamp.formatted(date: .omitted, time: .standard)
            let isCaller = entry.speaker.lowercased().hasPrefix("caller")
            lines.append("[\(localTime)] \(entry.speaker):")
            if entry.isUntranslated {
                lines.append("  Original (Untranslated): \(entry.original)")
            } else if isCaller {
                lines.append("  Translated: \(entry.translated)")
                if !entry.original.isEmpty && entry.original.lowercased() != entry.translated.lowercased() {
                    lines.append("  Original:   \(entry.original)")
                }
            } else {
                lines.append("  Original:   \(entry.original)")
                if !entry.translated.isEmpty && entry.translated.lowercased() != entry.original.lowercased() {
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
