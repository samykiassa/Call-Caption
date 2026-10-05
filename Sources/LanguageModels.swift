import Foundation

public struct LanguageItem: Identifiable, Hashable {
    public let id: String
    public let code: String          // e.g. "es", "fr", "en"
    public let speechLocale: String  // e.g. "es-ES", "fr-FR", "en-US"
    public let name: String          // e.g. "Spanish"
    public let flag: String          // e.g. "🇪🇸"
    
    public var displayName: String {
        return "\(flag) \(name)"
    }
}

public struct SupportedLanguages {
    public static let all: [LanguageItem] = [
        LanguageItem(id: "es", code: "es", speechLocale: "es-ES", name: "Spanish", flag: "🇪🇸"),
        LanguageItem(id: "en", code: "en", speechLocale: "en-US", name: "English", flag: "🇬🇧"),
        LanguageItem(id: "fr", code: "fr", speechLocale: "fr-FR", name: "French", flag: "🇫🇷"),
        LanguageItem(id: "de", code: "de", speechLocale: "de-DE", name: "German", flag: "🇩🇪"),
        LanguageItem(id: "it", code: "it", speechLocale: "it-IT", name: "Italian", flag: "🇮🇹"),
        LanguageItem(id: "pt", code: "pt", speechLocale: "pt-BR", name: "Portuguese", flag: "🇧🇷"),
        LanguageItem(id: "ar", code: "ar", speechLocale: "ar-SA", name: "Arabic", flag: "🇸🇦"),
        LanguageItem(id: "zh", code: "zh", speechLocale: "zh-CN", name: "Chinese (Mandarin)", flag: "🇨🇳"),
        LanguageItem(id: "hi", code: "hi", speechLocale: "hi-IN", name: "Hindi", flag: "🇮🇳"),
        LanguageItem(id: "ru", code: "ru", speechLocale: "ru-RU", name: "Russian", flag: "🇷🇺"),
        LanguageItem(id: "ja", code: "ja", speechLocale: "ja-JP", name: "Japanese", flag: "🇯🇵"),
        LanguageItem(id: "ko", code: "ko", speechLocale: "ko-KR", name: "Korean", flag: "🇰🇷"),
        LanguageItem(id: "nl", code: "nl", speechLocale: "nl-NL", name: "Dutch", flag: "🇳🇱"),
        LanguageItem(id: "tr", code: "tr", speechLocale: "tr-TR", name: "Turkish", flag: "🇹🇷"),
        LanguageItem(id: "pl", code: "pl", speechLocale: "pl-PL", name: "Polish", flag: "🇵🇱"),
        LanguageItem(id: "uk", code: "uk", speechLocale: "uk-UA", name: "Ukrainian", flag: "🇺🇦"),
        LanguageItem(id: "vi", code: "vi", speechLocale: "vi-VN", name: "Vietnamese", flag: "🇻🇳"),
        LanguageItem(id: "th", code: "th", speechLocale: "th-TH", name: "Thai", flag: "🇹🇭"),
        LanguageItem(id: "id", code: "id", speechLocale: "id-ID", name: "Indonesian", flag: "🇮🇩"),
        LanguageItem(id: "sv", code: "sv", speechLocale: "sv-SE", name: "Swedish", flag: "🇸🇪")
    ]
    
    public static func item(forCode code: String) -> LanguageItem? {
        let clean = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first {
            $0.code.lowercased() == clean ||
            $0.speechLocale.lowercased() == clean ||
            $0.speechLocale.lowercased().starts(with: clean)
        }
    }
    
    public static func jsonArrayString() -> String {
        let dicts = all.map { [
            "code": $0.code,
            "speechLocale": $0.speechLocale,
            "name": $0.name,
            "flag": $0.flag,
            "displayName": $0.displayName
        ] }
        if let data = try? JSONSerialization.data(withJSONObject: dicts),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "[]"
    }
}
