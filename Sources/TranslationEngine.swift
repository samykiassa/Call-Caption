import Foundation
import Translation

public actor TranslationEngine {
    public static let shared = TranslationEngine()
    
    // In-memory cache: "sourceCode_targetCode_text" -> translatedText
    private var cache: [String: String] = [:]
    private var cacheKeys: [String] = []
    
    // Cached native TranslationSession per language pair
    private var activeSessions: [String: Any] = [:]
    
    private init() {}
    
    // MARK: - Public Translation API
    
    public func translate(
        text: String,
        sourceCode: String,
        targetCode: String
    ) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        
        // If source and target are the same language, no translation needed
        if sourceCode.lowercased() == targetCode.lowercased() {
            return trimmed
        }
        
        // Check cache
        let cacheKey = "\(sourceCode)_\(targetCode)_\(trimmed)"
        if let cached = cache[cacheKey] {
            return cached
        }
        
        var result: String? = nil
        
        // 1. Try Apple's Native On-Device TranslationSession (macOS 15+)
        if #available(macOS 15.0, iOS 18.0, *) {
            result = await translateWithAppleSession(trimmed, sourceCode: sourceCode, targetCode: targetCode)
        }
        
        // 2. Fallback to Cloud Translation if native session didn't return a result
        if result == nil || result!.isEmpty {
            result = await translateWithCloudFallback(trimmed, sourceCode: sourceCode, targetCode: targetCode)
        }
        
        let finalTranslation = result ?? trimmed
        
        // Cache the successful translation
        if cache[cacheKey] == nil {
            if cacheKeys.count >= 500 {
                let numToRemove = 100
                let keysToRemove = cacheKeys.prefix(numToRemove)
                for key in keysToRemove {
                    cache.removeValue(forKey: key)
                }
                cacheKeys.removeFirst(numToRemove)
            }
            cacheKeys.append(cacheKey)
        }
        cache[cacheKey] = finalTranslation
        
        return finalTranslation
    }
    
    // MARK: - Apple TranslationSession
    
    @available(macOS 15.0, iOS 18.0, *)
    private func translateWithAppleSession(_ text: String, sourceCode: String, targetCode: String) async -> String? {
        let pairKey = "\(sourceCode)->\(targetCode)"
        
        var session = activeSessions[pairKey] as? TranslationSession
        if session == nil {
            let sourceLang = Locale.Language(identifier: sourceCode)
            let targetLang = Locale.Language(identifier: targetCode)
            let newSession = TranslationSession(installedSource: sourceLang, target: targetLang)
            activeSessions[pairKey] = newSession
            session = newSession
        }
        
        guard let validSession = session else { return nil }
        
        do {
            let response = try await validSession.translate(text)
            let translated = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !translated.isEmpty {
                return translated
            }
        } catch {
            NSLog("[TranslationEngine] Apple TranslationSession error for \(pairKey): \(error)")
        }
        
        return nil
    }
    
    // MARK: - Cloud Translation Fallback (Google Translate Web API)
    
    private func translateWithCloudFallback(_ text: String, sourceCode: String, targetCode: String) async -> String? {
        guard let encodedText = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        
        let urlString = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=\(sourceCode)&tl=\(targetCode)&dt=t&q=\(encodedText)"
        guard let url = URL(string: urlString) else { return nil }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 3.0
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            
            // Response format: [[[ "translatedText", "sourceText", ... ]], ...]
            if let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
               let sentences = json.first as? [Any] {
                var translatedBuilder = ""
                for item in sentences {
                    if let part = item as? [Any], let piece = part.first as? String {
                        translatedBuilder += piece
                    }
                }
                let clean = translatedBuilder.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty {
                    return clean
                }
            }
        } catch {
            NSLog("[TranslationEngine] Cloud fallback error: \(error)")
        }
        
        return nil
    }
    
    public func clearCache() {
        cache.removeAll()
        cacheKeys.removeAll()
    }
}
