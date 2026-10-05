import Foundation
import AppKit

public struct TranscriptEntry: Identifiable {
    public let id = UUID()
    public let timestamp: Date
    public let speaker: String
    public let original: String
    public let translated: String
    
    public var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }
}

public class TranscriptManager {
    public static let shared = TranscriptManager()
    
    public private(set) var entries: [TranscriptEntry] = []
    private let lock = NSLock()
    
    public var onEntriesUpdated: (([TranscriptEntry]) -> Void)?
    
    private init() {}
    
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
        let current = entries
        lock.unlock()
        
        DispatchQueue.main.async { [weak self] in
            self?.onEntriesUpdated?(current)
        }
    }
    
    public func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
        
        DispatchQueue.main.async { [weak self] in
            self?.onEntriesUpdated?([])
        }
    }
    
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
    
    public func copyToClipboard() {
        let text = exportAsText()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
