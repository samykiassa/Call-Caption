import Foundation
import AppKit

/// Represents a single spoken utterance in the transcription history.
///
/// `TranscriptEntry` encapsulates the speaker identity, timestamp, original text,
/// and the translated text for a specific piece of dialogue during the call.
public struct TranscriptEntry: Identifiable {
    /// The unique identifier for this transcript entry.
    public let id = UUID()
    
    /// The date and time when this utterance was recorded.
    public let timestamp: Date
    
    /// The name or identifier of the speaker (e.g., "Caller", "You").
    public let speaker: String
    
    /// The original text spoken by the speaker.
    public let original: String
    
    /// The translated version of the spoken text.
    public let translated: String
    
    /// A string representation of the `timestamp` formatted as "HH:mm:ss".
    public var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }
}

/// Manages the collection and storage of transcript entries for the duration of a session.
///
/// `TranscriptManager` acts as the central repository for all spoken dialogue,
/// handling the deduplication of rapid successive entries and limiting the total history
/// to a manageable size. It broadcasts notifications when the transcript updates.
public class TranscriptManager {
    /// The shared singleton instance of the transcript manager.
    public static let shared = TranscriptManager()
    
    /// The ordered list of transcript entries recorded so far.
    public private(set) var entries: [TranscriptEntry] = []
    
    // Internal lock to ensure thread-safe access to the `entries` array.
    private let lock = NSLock()
    
    /// A notification posted whenever new entries are added or the transcript is cleared.
    public static let EntriesUpdatedNotification = Notification.Name("TranscriptEntriesUpdated")
    
    private init() {}
    
    /// Adds a new dialogue entry to the transcript.
    ///
    /// This method sanitizes the input text, attempts to detect the speaker from the text prefix,
    /// removes formatting artifacts (such as arrows), and deduplicates identical rapid submissions.
    ///
    /// - Parameters:
    ///   - speaker: The default speaker name to use if one cannot be detected from the original string. Defaults to "Caller".
    ///   - original: The original spoken text.
    ///   - translated: The translated counterpart of the spoken text.
    public func addEntry(speaker: String = "Caller", original: String, translated: String) {
        var cleanOrig = original.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleanTrans = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        
        var detectedSpeaker = speaker
        if cleanOrig.starts(with: "Caller:") {
            detectedSpeaker = "Caller"
            cleanOrig = cleanOrig.replacingOccurrences(of: "Caller:", with: "").trimmingCharacters(in: .whitespaces)
        } else if cleanOrig.starts(with: "You:") {
            detectedSpeaker = "You"
            cleanOrig = cleanOrig.replacingOccurrences(of: "You:", with: "").trimmingCharacters(in: .whitespaces)
        }
        
        // Strip any leading arrow symbols from translated text
        while cleanTrans.starts(with: "➔") || cleanTrans.starts(with: "->") || cleanTrans.starts(with: "→") {
            if cleanTrans.starts(with: "➔") {
                cleanTrans = String(cleanTrans.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else if cleanTrans.starts(with: "->") {
                cleanTrans = String(cleanTrans.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if cleanTrans.starts(with: "→") {
                cleanTrans = String(cleanTrans.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
        }
        
        guard !cleanOrig.isEmpty || !cleanTrans.isEmpty else { return }
        
        let entry = TranscriptEntry(timestamp: Date(), speaker: detectedSpeaker, original: cleanOrig, translated: cleanTrans)
        
        lock.lock()
        // Deduplicate rapid duplicate submissions of identical text within 1.5 seconds
        if let last = entries.last,
           last.speaker == detectedSpeaker,
           last.original == cleanOrig,
           Date().timeIntervalSince(last.timestamp) < 1.5 {
            lock.unlock()
            return
        }
        
        entries.append(entry)
        // Keep last 1,000 entries
        if entries.count > 1000 {
            entries.removeFirst(entries.count - 1000)
        }
        lock.unlock()
        
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: TranscriptManager.EntriesUpdatedNotification, object: nil)
        }
    }
    
    /// Clears all existing entries from the transcript.
    public func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
        
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: TranscriptManager.EntriesUpdatedNotification, object: nil)
        }
    }
    
    /// Exports the entire transcript history as a formatted plain text string.
    ///
    /// - Returns: A multi-line string containing the timestamp, speaker, original, and translated text for all entries.
    public func exportAsText() -> String {
        lock.lock()
        defer { lock.unlock() }
        
        var lines: [String] = []
        lines.append("=== Live Call Translation Transcript ===")
        lines.append("Exported: \(Date())")
        lines.append("-------------------------------------------------")
        
        for entry in entries {
            lines.append("[\(entry.formattedTime)] \(entry.speaker):")
            lines.append("  Original:   \(entry.original)")
            lines.append("  Translated: \(entry.translated)")
            lines.append("")
        }
        
        return lines.joined(separator: "\n")
    }
    
    /// Copies the exported transcript text directly to the system clipboard.
    public func copyToClipboard() {
        let text = exportAsText()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
