import Foundation

extension AppL10n {
    static func string(_ key: String, fallback: String, bundle: Bundle?) -> String {
        (bundle ?? resourceBundle).localizedString(forKey: key, value: fallback, table: nil)
    }
}

struct ReceiverWebAppHTML {
    private struct WebL10nStrings: Codable {
        let title: String
        let statusConnecting: String
        let statusLive: String
        let statusOffline: String
        let statusPaused: String
        let statusReconnecting: String
        let statusSessionEnded: String
        let statusLinkError: String
        let filterAll: String
        let filterHost: String
        let filterAllA11y: String
        let filterHostA11y: String
        let origToggle: String
        let origA11y: String
        let fontDecrease: String
        let fontIncrease: String
        let fontDecreaseA11y: String
        let fontIncreaseA11y: String
        let copy: String
        let copyA11y: String
        let copied: String
        let copyFailed: String
        let copyCopiedAnnouncement: String
        let emptyListening: String
        let emptyHostOnly: String
        let emptyPaused: String
        let emptySessionEnded: String
        let emptyLinkError: String
        let errorCryptoUnavailable: String
        let autoscroll: String
        let jumpLatest: String
        let speakerHost: String
        let speakerCaller: String
        let speakerHostLabel: String
        let speakerCallerLabel: String
        let badgeUntranslated: String
        let timeLive: String
        let viewersOne: String
        let viewersOther: String

        static func localized(bundle: Bundle? = nil) -> WebL10nStrings {
            WebL10nStrings(
                title: AppL10n.string("web.title", fallback: "Call Caption", bundle: bundle),
                statusConnecting: AppL10n.string("web.status.connecting", fallback: "Connecting", bundle: bundle),
                statusLive: AppL10n.string("web.status.live", fallback: "Live", bundle: bundle),
                statusOffline: AppL10n.string("web.status.offline", fallback: "Offline", bundle: bundle),
                statusPaused: AppL10n.string("web.status.paused", fallback: "Paused", bundle: bundle),
                statusReconnecting: AppL10n.string("web.status.reconnecting", fallback: "Reconnecting", bundle: bundle),
                statusSessionEnded: AppL10n.string("web.status.session_ended", fallback: "Session ended", bundle: bundle),
                statusLinkError: AppL10n.string("web.status.link_error", fallback: "Link error", bundle: bundle),
                filterAll: AppL10n.string("web.filter.all", fallback: "All", bundle: bundle),
                filterHost: AppL10n.string("web.filter.host", fallback: "Host", bundle: bundle),
                filterAllA11y: AppL10n.string("web.filter.all_a11y", fallback: "Filter speakers: showing all", bundle: bundle),
                filterHostA11y: AppL10n.string("web.filter.host_a11y", fallback: "Filter speakers: showing host only", bundle: bundle),
                origToggle: AppL10n.string("web.orig.toggle", fallback: "Original", bundle: bundle),
                origA11y: AppL10n.string("web.orig.a11y", fallback: "Show original text", bundle: bundle),
                fontDecrease: AppL10n.string("web.font.decrease", fallback: "A-", bundle: bundle),
                fontIncrease: AppL10n.string("web.font.increase", fallback: "A+", bundle: bundle),
                fontDecreaseA11y: AppL10n.string("web.font.decrease_a11y", fallback: "Decrease font size", bundle: bundle),
                fontIncreaseA11y: AppL10n.string("web.font.increase_a11y", fallback: "Increase font size", bundle: bundle),
                copy: AppL10n.string("web.copy", fallback: "Copy", bundle: bundle),
                copyA11y: AppL10n.string("web.copy_a11y", fallback: "Copy transcript", bundle: bundle),
                copied: AppL10n.string("web.copied", fallback: "Copied", bundle: bundle),
                copyFailed: AppL10n.string("web.copy_failed", fallback: "Copy failed", bundle: bundle),
                copyCopiedAnnouncement: AppL10n.string("web.copy.copied_announcement", fallback: "Transcript copied to clipboard.", bundle: bundle),
                emptyListening: AppL10n.string("web.empty.listening", fallback: "Listening…", bundle: bundle),
                emptyHostOnly: AppL10n.string("web.empty.host_only", fallback: "No host captions yet…", bundle: bundle),
                emptyPaused: AppL10n.string("web.empty.paused", fallback: "Captions are paused", bundle: bundle),
                emptySessionEnded: AppL10n.string("web.empty.session_ended", fallback: "Live Link session ended", bundle: bundle),
                emptyLinkError: AppL10n.string("web.empty.link_error", fallback: "This Live Link is incomplete or corrupted. Copy the full link including the #k= key fragment.", bundle: bundle),
                errorCryptoUnavailable: AppL10n.string("web.error.crypto_unavailable", fallback: "End-to-end encryption requires HTTPS or localhost in this browser.", bundle: bundle),
                autoscroll: AppL10n.string("web.autoscroll", fallback: "Auto-Scroll", bundle: bundle),
                jumpLatest: AppL10n.string("web.jump_latest", fallback: "↓ Latest", bundle: bundle),
                speakerHost: AppL10n.string("web.speaker.host", fallback: "HOST", bundle: bundle),
                speakerCaller: AppL10n.string("web.speaker.caller", fallback: "CALLER", bundle: bundle),
                speakerHostLabel: AppL10n.string("web.speaker.host_label", fallback: "Host", bundle: bundle),
                speakerCallerLabel: AppL10n.string("web.speaker.caller_label", fallback: "Caller", bundle: bundle),
                badgeUntranslated: AppL10n.string("web.badge.untranslated", fallback: "[Untranslated]", bundle: bundle),
                timeLive: AppL10n.string("web.time.live", fallback: "Live", bundle: bundle),
                viewersOne: AppL10n.string("web.viewers.one", fallback: "1 viewer", bundle: bundle),
                viewersOther: AppL10n.string("web.viewers.other", fallback: "%d viewers", bundle: bundle)
            )
        }
    }

    private static func loadLprojBundle(forLanguage baseLang: String, from baseBundle: Bundle) -> Bundle? {
        if let lprojURL = baseBundle.url(forResource: baseLang, withExtension: "lproj"),
           let lprojBundle = Bundle(url: lprojURL) {
            return lprojBundle
        }
        if baseBundle.bundleURL.pathExtension == "lproj" {
            let currentLang = baseBundle.bundleURL.deletingPathExtension().lastPathComponent.lowercased()
            if currentLang == baseLang {
                return baseBundle
            }
            let siblingURL = baseBundle.bundleURL.deletingLastPathComponent().appendingPathComponent("\(baseLang).lproj", isDirectory: true)
            if let siblingBundle = Bundle(url: siblingURL) {
                return siblingBundle
            }
        }
        if let mainLprojURL = Bundle.main.url(forResource: baseLang, withExtension: "lproj"),
           let mainLprojBundle = Bundle(url: mainLprojURL) {
            return mainLprojBundle
        }
        return nil
    }

    private static func parseSupportedAcceptLanguages(_ acceptLanguage: String?) -> [String] {
        guard let rawAccept = acceptLanguage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawAccept.isEmpty else {
            return []
        }
        struct WeightedLang {
            let base: String
            let q: Double
            let index: Int
        }
        var candidates: [WeightedLang] = []
        for (idx, rawItem) in rawAccept.split(separator: ",").enumerated() {
            let parts = rawItem.split(separator: ";")
            guard let firstPart = parts.first else { continue }
            let tag = firstPart.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { continue }
            var q = 1.0
            var validQ = true
            for param in parts.dropFirst() {
                let trimmedParam = param.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if trimmedParam.hasPrefix("q=") {
                    let qValStr = trimmedParam.dropFirst(2)
                    if let parsedQ = Double(qValStr), parsedQ.isFinite, parsedQ >= 0.0, parsedQ <= 1.0 {
                        q = parsedQ
                    } else {
                        validQ = false
                    }
                }
            }
            guard validQ, q > 0.0 else { continue }
            let base = tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
            guard base == "es" || base == "en" else { continue }
            candidates.append(WeightedLang(base: base, q: q, index: idx))
        }
        candidates.sort { lhs, rhs in
            if lhs.q != rhs.q { return lhs.q > rhs.q }
            return lhs.index < rhs.index
        }
        var ordered: [String] = []
        for cand in candidates where !ordered.contains(cand.base) {
            ordered.append(cand.base)
        }
        return ordered
    }

    internal static func resolvedLanguageKey(acceptLanguage: String?) -> String {
        let supported = parseSupportedAcceptLanguages(acceptLanguage)
        let bundlePath = AppL10n.resourceBundle.bundlePath
        if !supported.isEmpty {
            return "accept:\(supported.joined(separator: ",")):\(bundlePath)"
        }
        return "default:\(bundlePath)"
    }

    static func resolveViewerLocalization(acceptLanguage: String?) -> (bundle: Bundle, htmlLang: String) {
        let baseBundle = AppL10n.resourceBundle
        for base in parseSupportedAcceptLanguages(acceptLanguage) {
            if let matchedBundle = loadLprojBundle(forLanguage: base, from: baseBundle) {
                return (matchedBundle, base)
            }
        }

        let preferredLang = baseBundle.preferredLocalizations.first
            ?? AppL10n.effectiveUILocale.identifier
        let trimmedLang = preferredLang.trimmingCharacters(in: .whitespacesAndNewlines)
        let htmlLang = trimmedLang.isEmpty ? "en" : trimmedLang
        let baseLang = htmlLang.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? "en"
        if (baseLang == "es" || baseLang == "en"),
           let matchedBundle = loadLprojBundle(forLanguage: baseLang, from: baseBundle) {
            return (matchedBundle, htmlLang)
        }
        return (baseBundle, htmlLang)
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func encodeJSONForInlineScript<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value),
              var json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        json = json
            .replacingOccurrences(of: "<", with: "\\u003C")
            .replacingOccurrences(of: ">", with: "\\u003E")
            .replacingOccurrences(of: "&", with: "\\u0026")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return json
    }

    private enum TemplatePlaceholder: Int, CaseIterable {
        case sessionBasePath
        case payloadEncrypted
        case htmlLang
        case htmlDir
        case webTitle
        case webStatusConnecting
        case webFilterAll
        case webFilterAllA11y
        case webOrigToggle
        case webOrigA11y
        case webFontDec
        case webFontDecA11y
        case webFontInc
        case webFontIncA11y
        case webCopy
        case webCopyA11y
        case webEmptyListening
        case webAutoscroll
        case webJumpLatest
        case webL10nJSON

        var token: String {
            switch self {
            case .sessionBasePath: return "__SESSION_BASE_PATH__"
            case .payloadEncrypted: return "__PAYLOAD_ENCRYPTED__"
            case .htmlLang: return "__HTML_LANG__"
            case .htmlDir: return "__HTML_DIR__"
            case .webTitle: return "__WEB_TITLE__"
            case .webStatusConnecting: return "__WEB_STATUS_CONNECTING__"
            case .webFilterAll: return "__WEB_FILTER_ALL__"
            case .webFilterAllA11y: return "__WEB_FILTER_ALL_A11Y__"
            case .webOrigToggle: return "__WEB_ORIG_TOGGLE__"
            case .webOrigA11y: return "__WEB_ORIG_A11Y__"
            case .webFontDec: return "__WEB_FONT_DEC__"
            case .webFontDecA11y: return "__WEB_FONT_DEC_A11Y__"
            case .webFontInc: return "__WEB_FONT_INC__"
            case .webFontIncA11y: return "__WEB_FONT_INC_A11Y__"
            case .webCopy: return "__WEB_COPY__"
            case .webCopyA11y: return "__WEB_COPY_A11Y__"
            case .webEmptyListening: return "__WEB_EMPTY_LISTENING__"
            case .webAutoscroll: return "__WEB_AUTOSCROLL__"
            case .webJumpLatest: return "__WEB_JUMP_LATEST__"
            case .webL10nJSON: return "__WEB_L10N_JSON__"
            }
        }
    }

    private enum TemplateSegment: Sendable {
        case literal(String)
        case placeholder(TemplatePlaceholder)
    }

    private static let compiledTemplate: (segments: [TemplateSegment], baseByteCount: Int) = {
        var lookup: [String: TemplatePlaceholder] = [:]
        var maxTokenLen = 0
        for p in TemplatePlaceholder.allCases {
            let t = p.token
            lookup[t] = p
            if t.count > maxTokenLen { maxTokenLen = t.count }
        }

        var segments: [TemplateSegment] = []
        var baseByteCount = 0
        var literalStart = content.startIndex
        var cursor = content.startIndex

        while cursor < content.endIndex {
            guard let openRange = content.range(of: "__", range: cursor..<content.endIndex) else {
                break
            }
            let afterOpen = openRange.upperBound
            let searchLimit = content.index(openRange.lowerBound, offsetBy: maxTokenLen, limitedBy: content.endIndex) ?? content.endIndex
            if let closeRange = content.range(of: "__", range: afterOpen..<searchLimit) {
                let candidate = String(content[openRange.lowerBound..<closeRange.upperBound])
                if let placeholder = lookup[candidate] {
                    if literalStart < openRange.lowerBound {
                        let lit = String(content[literalStart..<openRange.lowerBound])
                        baseByteCount += lit.utf8.count
                        segments.append(.literal(lit))
                    }
                    segments.append(.placeholder(placeholder))
                    literalStart = closeRange.upperBound
                    cursor = closeRange.upperBound
                    continue
                }
            }
            cursor = afterOpen
        }

        if literalStart < content.endIndex {
            let tail = String(content[literalStart..<content.endIndex])
            baseByteCount += tail.utf8.count
            segments.append(.literal(tail))
        }
        return (segments, baseByteCount)
    }()

    static func html(forToken token: String, encryptPayloads: Bool, acceptLanguage: String? = nil) -> String {
        let resolved = resolveViewerLocalization(acceptLanguage: acceptLanguage)
        let l10n = WebL10nStrings.localized(bundle: resolved.bundle)
        let htmlLang = resolved.htmlLang
        let baseLang = htmlLang.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? "en"
        let htmlDir = SupportedLanguages.rtlLanguageCodes.contains(baseLang) ? "rtl" : "ltr"

        let sessionBasePath = "/s/\(token)"
        let payloadEncrypted = encryptPayloads ? "true" : "false"
        let escapedLang = escapeHTML(htmlLang)
        let escapedTitle = escapeHTML(l10n.title)
        let escapedStatusConnecting = escapeHTML(l10n.statusConnecting)
        let escapedFilterAll = escapeHTML(l10n.filterAll)
        let escapedFilterAllA11y = escapeHTML(l10n.filterAllA11y)
        let escapedOrigToggle = escapeHTML(l10n.origToggle)
        let escapedOrigA11y = escapeHTML(l10n.origA11y)
        let escapedFontDec = escapeHTML(l10n.fontDecrease)
        let escapedFontDecA11y = escapeHTML(l10n.fontDecreaseA11y)
        let escapedFontInc = escapeHTML(l10n.fontIncrease)
        let escapedFontIncA11y = escapeHTML(l10n.fontIncreaseA11y)
        let escapedCopy = escapeHTML(l10n.copy)
        let escapedCopyA11y = escapeHTML(l10n.copyA11y)
        let escapedEmptyListening = escapeHTML(l10n.emptyListening)
        let escapedAutoscroll = escapeHTML(l10n.autoscroll)
        let escapedJumpLatest = escapeHTML(l10n.jumpLatest)
        let l10nJSON = encodeJSONForInlineScript(l10n)

        var output = ""
        output.reserveCapacity(compiledTemplate.baseByteCount + l10nJSON.utf8.count + 1024)
        for segment in compiledTemplate.segments {
            switch segment {
            case .literal(let literal):
                output.append(literal)
            case .placeholder(let placeholder):
                switch placeholder {
                case .sessionBasePath: output.append(sessionBasePath)
                case .payloadEncrypted: output.append(payloadEncrypted)
                case .htmlLang: output.append(escapedLang)
                case .htmlDir: output.append(htmlDir)
                case .webTitle: output.append(escapedTitle)
                case .webStatusConnecting: output.append(escapedStatusConnecting)
                case .webFilterAll: output.append(escapedFilterAll)
                case .webFilterAllA11y: output.append(escapedFilterAllA11y)
                case .webOrigToggle: output.append(escapedOrigToggle)
                case .webOrigA11y: output.append(escapedOrigA11y)
                case .webFontDec: output.append(escapedFontDec)
                case .webFontDecA11y: output.append(escapedFontDecA11y)
                case .webFontInc: output.append(escapedFontInc)
                case .webFontIncA11y: output.append(escapedFontIncA11y)
                case .webCopy: output.append(escapedCopy)
                case .webCopyA11y: output.append(escapedCopyA11y)
                case .webEmptyListening: output.append(escapedEmptyListening)
                case .webAutoscroll: output.append(escapedAutoscroll)
                case .webJumpLatest: output.append(escapedJumpLatest)
                case .webL10nJSON: output.append(l10nJSON)
                }
            }
        }
        return output
    }

    static let content = """
    <!DOCTYPE html>
    <html lang="__HTML_LANG__" dir="__HTML_DIR__">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">
        <title>__WEB_TITLE__</title>
        <style>
            :root {
                --bg: #0b0d12;
                --header-bg: rgba(11, 13, 18, 0.84);
                --floating-bg: rgba(16, 19, 26, 0.90);
                --card-bg: rgba(255, 255, 255, 0.045);
                --card-host-bg: rgba(52, 211, 153, 0.085);
                --card-border: rgba(255, 255, 255, 0.09);
                --btn-bg: rgba(255, 255, 255, 0.06);
                --btn-hover: rgba(255, 255, 255, 0.12);
                --accent-blue: #38bdf8;
                --accent-green: #34d399;
                --accent-amber: #fbbf24;
                --accent-red: #f87171;
                --text-main: #f8fafc;
                --text-sub: #94a3b8;
                --text-orig: rgba(148, 163, 184, 0.82);
                --font-size: 18px;
            }
            @media (prefers-color-scheme: light) {
                :root {
                    --bg: #f5f5f7;
                    --header-bg: rgba(245, 245, 247, 0.82);
                    --floating-bg: rgba(255, 255, 255, 0.88);
                    --card-bg: rgba(255, 255, 255, 0.86);
                    --card-host-bg: rgba(5, 150, 105, 0.09);
                    --card-border: rgba(15, 23, 42, 0.09);
                    --btn-bg: rgba(15, 23, 42, 0.05);
                    --btn-hover: rgba(15, 23, 42, 0.10);
                    --accent-blue: #075985;
                    --accent-green: #065f46;
                    --accent-amber: #92400e;
                    --accent-red: #991b1b;
                    --text-main: #0f172a;
                    --text-sub: #475569;
                    --text-orig: rgba(51, 65, 85, 0.92);
                }
            }
            * { box-sizing: border-box; margin: 0; padding: 0; }
            html, body {
                background: var(--bg);
                color: var(--text-main);
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "SF Pro Display", system-ui, sans-serif;
                -webkit-font-smoothing: antialiased;
                -moz-osx-font-smoothing: grayscale;
                text-rendering: optimizeLegibility;
                min-height: 100vh;
                min-height: 100dvh;
                overflow-x: clip;
            }
            @media (prefers-contrast: more) {
                :root {
                    --card-border: rgba(255, 255, 255, 0.34);
                    --text-sub: #cbd5e1;
                    --text-orig: #cbd5e1;
                }
            }
            @media (prefers-color-scheme: light) and (prefers-contrast: more) {
                :root {
                    --card-border: rgba(15, 23, 42, 0.36);
                    --text-sub: #1e293b;
                    --text-orig: #1e293b;
                }
            }
            body { display: flex; flex-direction: column; }
            .sr-only {
                position: absolute;
                width: 1px;
                height: 1px;
                padding: 0;
                margin: -1px;
                overflow: hidden;
                clip: rect(0, 0, 0, 0);
                white-space: nowrap;
                border: 0;
            }
            header {
                position: sticky;
                top: 0;
                background: var(--header-bg);
                backdrop-filter: blur(20px) saturate(180%);
                -webkit-backdrop-filter: blur(20px) saturate(180%);
                border-bottom: 1px solid var(--card-border);
                padding: calc(12px + env(safe-area-inset-top, 0px)) calc(20px + env(safe-area-inset-right, 0px)) 12px calc(20px + env(safe-area-inset-left, 0px));
                display: flex;
                align-items: center;
                justify-content: space-between;
                flex-wrap: wrap;
                gap: 10px;
                z-index: 20;
            }
            .brand { display: flex; align-items: center; gap: 10px; }
            .brand-logo {
                width: 26px;
                height: 26px;
                background: linear-gradient(135deg, #0284c7, #38bdf8);
                border-radius: 7px;
                display: flex;
                align-items: center;
                justify-content: center;
                font-weight: 700;
                font-size: 11.5px;
                letter-spacing: -0.02em;
                color: white;
            }
            .brand-title {
                font-weight: 600;
                font-size: 14.5px;
                letter-spacing: -0.015em;
            }
            .status-pill {
                display: inline-flex;
                align-items: center;
                gap: 6px;
                padding: 3px 9px;
                border-radius: 999px;
                font-size: 11px;
                font-weight: 500;
                background: rgba(52, 211, 153, 0.14);
                color: var(--accent-green);
                border: 1px solid rgba(52, 211, 153, 0.28);
                word-break: break-word;
            }
            .status-pill.connecting {
                background: rgba(56, 189, 248, 0.14);
                color: var(--accent-blue);
                border-color: rgba(56, 189, 248, 0.30);
            }
            .status-pill.offline {
                background: rgba(239, 68, 68, 0.14);
                color: var(--accent-red);
                border-color: rgba(239, 68, 68, 0.28);
            }
            .status-pill.paused {
                background: rgba(251, 191, 36, 0.14);
                color: var(--accent-amber);
                border-color: rgba(251, 191, 36, 0.30);
            }
            .viewer-count {
                color: var(--text-sub);
                font-size: 11px;
                font-variant-numeric: tabular-nums;
                min-width: 0;
            }
            @keyframes pulse-ring {
                0%, 100% { transform: scale(1); opacity: 1; }
                50% { transform: scale(1.35); opacity: 0.45; }
            }
            .pulse-dot {
                width: 6px;
                height: 6px;
                background: currentColor;
                border-radius: 50%;
                animation: pulse-ring 1.8s ease-in-out infinite;
            }
            .status-pill.offline .pulse-dot,
            .status-pill.paused .pulse-dot {
                animation: none;
            }
            .controls { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
            .btn {
                background: var(--btn-bg);
                border: 1px solid var(--card-border);
                color: var(--text-main);
                padding: 5px 10px;
                border-radius: 8px;
                font-size: 12px;
                font-weight: 500;
                cursor: pointer;
                transition: background-color 0.15s ease, border-color 0.15s ease, color 0.15s ease;
            }
            .btn:hover:not(:disabled) { background: var(--btn-hover); }
            .btn:focus-visible,
            .jump-latest-btn:focus-visible,
            #autoscroll-toggle:focus-visible {
                outline: 2px solid var(--accent-blue);
                outline-offset: 2px;
            }
            .btn:disabled {
                opacity: 0.45;
                cursor: not-allowed;
            }
            .btn.active {
                background: rgba(2, 132, 199, 0.15);
                border-color: rgba(2, 132, 199, 0.36);
                color: var(--accent-blue);
            }
            main {
                flex: 1;
                width: 100%;
                padding: 20px calc(20px + env(safe-area-inset-right, 0px)) calc(90px + env(safe-area-inset-bottom, 0px)) calc(20px + env(safe-area-inset-left, 0px));
                display: flex;
                flex-direction: column;
                align-items: center;
            }
            .caption-stream {
                width: 100%;
                max-width: 720px;
                display: flex;
                flex-direction: column;
                gap: 10px;
            }
            .empty-state {
                margin: 18vh auto;
                margin: 18dvh auto;
                text-align: center;
                padding: 32px 20px;
                color: var(--text-sub);
            }
            .empty-state-title {
                font-size: 14px;
                font-weight: 500;
                letter-spacing: -0.01em;
                color: var(--text-sub);
            }
            @keyframes card-enter {
                from { opacity: 0; transform: translateY(6px); }
                to { opacity: 1; transform: translateY(0); }
            }
            .card {
                background: var(--card-bg);
                border: 1px solid var(--card-border);
                border-radius: 12px;
                padding: 13px 15px;
                transition: border-color 0.2s ease;
            }
            .card.untranslated {
                border-style: dashed;
            }
            .card.animate-in {
                animation: card-enter 0.2s cubic-bezier(0.22, 1, 0.36, 1) both;
            }
            .card[data-speaker="You"] {
                background: var(--card-host-bg);
            }
            .card[data-speaker="Caller"].live {
                border-color: rgba(56, 189, 248, 0.42);
            }
            .card[data-speaker="You"].live {
                border-color: rgba(52, 211, 153, 0.42);
            }
            .card-meta {
                display: flex;
                align-items: center;
                justify-content: space-between;
                margin-bottom: 6px;
                font-size: 11px;
            }
            .speaker-badge {
                font-weight: 700;
                text-transform: uppercase;
                letter-spacing: 0.04em;
                font-size: 10.5px;
            }
            .speaker-host { color: var(--accent-green); }
            .speaker-caller { color: var(--accent-blue); }
            .untranslated-badge {
                color: var(--accent-amber);
                font-size: 10px;
                margin-inline-start: 6px;
                font-weight: 500;
                word-break: break-word;
            }
            .time-label {
                color: var(--text-sub);
                font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
                font-variant-numeric: tabular-nums;
            }
            .translated-text {
                font-size: var(--font-size);
                font-weight: 400;
                line-height: 1.38;
                letter-spacing: -0.012em;
                color: var(--text-main);
                word-break: break-word;
                overflow-wrap: anywhere;
            }
            .card.live .translated-text {
                color: var(--text-sub);
            }
            .original-text {
                margin-top: 4px;
                font-size: calc(var(--font-size) * 0.82);
                font-weight: 400;
                line-height: 1.34;
                color: var(--text-orig);
                word-break: break-word;
                overflow-wrap: anywhere;
                display: none;
            }
            body.show-orig .original-text { display: block; }
            .floating-bottom {
                position: fixed;
                bottom: calc(14px + env(safe-area-inset-bottom, 0px));
                left: 50%;
                transform: translateX(-50%);
                width: max-content;
                max-width: calc(100vw - 24px - env(safe-area-inset-left, 0px) - env(safe-area-inset-right, 0px));
                white-space: nowrap;
                overflow-x: auto;
                scrollbar-width: none;
                background: var(--floating-bg);
                border: 1px solid var(--card-border);
                backdrop-filter: blur(18px) saturate(180%);
                -webkit-backdrop-filter: blur(18px) saturate(180%);
                border-radius: 999px;
                padding: 6px 14px;
                display: flex;
                align-items: center;
                gap: 10px;
                z-index: 30;
                user-select: none;
                box-shadow: 0 8px 24px rgba(0, 0, 0, 0.14);
            }
            .floating-bottom[hidden] { display: none; }
            .floating-bottom::-webkit-scrollbar { display: none; }
            .autoscroll-label {
                display: inline-flex;
                align-items: center;
                font-size: 11.5px;
                color: var(--text-sub);
                cursor: pointer;
            }
            .jump-latest-btn {
                background: rgba(2, 132, 199, 0.18);
                border: 1px solid rgba(2, 132, 199, 0.42);
                color: var(--accent-blue);
                border-radius: 999px;
                padding: 2px 10px;
                font-size: 11px;
                font-weight: 600;
                cursor: pointer;
                display: none;
            }
            .jump-latest-btn.visible {
                display: inline-flex;
                align-items: center;
                gap: 4px;
            }
            @media (max-width: 640px) {
                header {
                    padding: calc(8px + env(safe-area-inset-top, 0px)) calc(12px + env(safe-area-inset-right, 0px)) 8px calc(12px + env(safe-area-inset-left, 0px));
                    gap: 8px;
                }
                main {
                    padding: 14px calc(14px + env(safe-area-inset-right, 0px)) calc(96px + env(safe-area-inset-bottom, 0px)) calc(14px + env(safe-area-inset-left, 0px));
                }
                .btn, .jump-latest-btn, .autoscroll-label {
                    min-height: 44px;
                }
                #font-dec-btn, #font-inc-btn {
                    min-width: 44px;
                }
                .floating-bottom {
                    min-height: 44px;
                }
            }
            @media (prefers-reduced-motion: reduce) {
                *, *::before, *::after {
                    animation: none !important;
                    transition: none !important;
                    scroll-behavior: auto !important;
                }
            }
        </style>
    </head>
    <body class="show-orig">
        <header>
            <div class="brand">
                <div class="brand-logo" aria-hidden="true">CC</div>
                <h1 class="brand-title">__WEB_TITLE__</h1>
                <div id="conn-pill" class="status-pill connecting" role="status" aria-live="polite">
                    <span class="pulse-dot" aria-hidden="true"></span>
                    <span id="conn-label">__WEB_STATUS_CONNECTING__</span>
                </div>
            </div>
            <div class="controls">
                <span id="viewer-count" class="viewer-count" aria-live="polite"></span>
                <button id="view-mode-btn" class="btn" aria-pressed="false" aria-label="__WEB_FILTER_ALL_A11Y__">__WEB_FILTER_ALL__</button>
                <button id="orig-toggle-btn" class="btn active" aria-pressed="true" aria-label="__WEB_ORIG_A11Y__">__WEB_ORIG_TOGGLE__</button>
                <button id="font-dec-btn" class="btn" aria-label="__WEB_FONT_DEC_A11Y__">__WEB_FONT_DEC__</button>
                <button id="font-inc-btn" class="btn" aria-label="__WEB_FONT_INC_A11Y__">__WEB_FONT_INC__</button>
                <button id="copy-transcript-btn" class="btn" aria-label="__WEB_COPY_A11Y__" disabled>__WEB_COPY__</button>
            </div>
        </header>

        <main id="main-scroll">
            <div id="empty-state" class="empty-state">
                <h2 class="empty-state-title">__WEB_EMPTY_LISTENING__</h2>
            </div>
            <div id="caption-stream" class="caption-stream"></div>
            <div id="sr-live-announcer" class="sr-only" aria-live="polite" aria-atomic="true"></div>
        </main>

        <div class="floating-bottom" id="autoscroll-pill">
            <label for="autoscroll-toggle" class="autoscroll-label">__WEB_AUTOSCROLL__</label>
            <input type="checkbox" id="autoscroll-toggle" checked style="accent-color: var(--accent-blue); cursor: pointer;">
            <button id="jump-latest-btn" class="jump-latest-btn" type="button">__WEB_JUMP_LATEST__</button>
        </div>

        <script>
            const BASE_PATH = "__SESSION_BASE_PATH__";
            const PAYLOAD_ENCRYPTED = __PAYLOAD_ENCRYPTED__;
            const L10N = __WEB_L10N_JSON__;
            const SESSION_KEY = (() => {
                const match = location.hash.match(/[#&]k=([A-Za-z0-9_-]+)/);
                return match ? match[1] : null;
            })();
            const VIEWER_ID = (() => {
                if (window.crypto && typeof window.crypto.randomUUID === 'function') {
                    return window.crypto.randomUUID();
                }
                return 'v_' + Math.random().toString(36).slice(2, 12) + Date.now().toString(36);
            })();
            const RTL_LANGS = new Set(['ar', 'he', 'fa', 'ur']);

            let sessionCryptoKey = null;
            let appInitialized = false;
            let decryptChain = Promise.resolve();
            let linkErrorShown = false;
            let sessionEnded = false;
            let hasDecryptedSuccessfully = false;
            let hasHydratedInitialSnapshot = false;
            let lastSseSeq = 0;
            let lastStateSeq = 0;
            let lastClearEpoch = 0;
            let currentFontSize = 18;
            let showOriginal = true;
            let hostFocusMode = false;
            let autoScroll = true;
            var userDisabledAutoScroll = false;
            let isProgrammaticScroll = false;
            let programmaticClearTimer = null;
            let scrollScheduled = false;
            let pendingScrollInstant = false;
            let ignoreScrollPauseUntil = 0;
            let lastScrollY = window.scrollY || 0;
            let touchStartY = null;
            let touchMoved = false;
            let hostPaused = false;
            let lastSSEAttemptMs = 0;
            let consecutivePollFailures = 0;
            let srToggleZeroWidth = false;

            const streamContainer = document.getElementById('caption-stream');
            const srAnnouncer = document.getElementById('sr-live-announcer');
            const emptyState = document.getElementById('empty-state');
            const emptyStateLabel = emptyState.querySelector('.empty-state-title');
            const connPill = document.getElementById('conn-pill');
            const connLabel = document.getElementById('conn-label');
            const viewerCountEl = document.getElementById('viewer-count');
            const autoscrollPill = document.getElementById('autoscroll-pill');
            const autoscrollToggle = document.getElementById('autoscroll-toggle');
            const jumpLatestBtn = document.getElementById('jump-latest-btn');
            const copyTranscriptBtn = document.getElementById('copy-transcript-btn');
            const viewModeBtn = document.getElementById('view-mode-btn');
            const fontDecBtn = document.getElementById('font-dec-btn');
            const fontIncBtn = document.getElementById('font-inc-btn');
            const origBtn = document.getElementById('orig-toggle-btn');
            let copyBtnTimer = null;
            const liveSlots = { 'You': null, 'Caller': null };

            function readStoredPref(key) {
                try {
                    return window.localStorage ? window.localStorage.getItem(key) : null;
                } catch (err) {
                    return null;
                }
            }

            function writeStoredPref(key, value) {
                try {
                    if (window.localStorage) window.localStorage.setItem(key, String(value));
                } catch (err) {}
            }

            function applyFontSize() {
                currentFontSize = Math.min(30, Math.max(14, currentFontSize));
                if (currentFontSize % 2 !== 0) {
                    currentFontSize = Math.min(30, Math.max(14, currentFontSize + 1));
                }
                document.documentElement.style.setProperty('--font-size', currentFontSize + 'px');
                if (fontDecBtn) fontDecBtn.disabled = (currentFontSize <= 14);
                if (fontIncBtn) fontIncBtn.disabled = (currentFontSize >= 30);
                writeStoredPref('currentFontSize', currentFontSize);
            }

            function applyShowOriginal() {
                document.body.classList.toggle('show-orig', showOriginal);
                if (origBtn) {
                    origBtn.classList.toggle('active', showOriginal);
                    origBtn.setAttribute('aria-pressed', showOriginal ? 'true' : 'false');
                }
                writeStoredPref('showOriginal', showOriginal ? 'true' : 'false');
            }

            function applySpeakerFilter() {
                if (viewModeBtn) {
                    viewModeBtn.textContent = hostFocusMode ? L10N.filterHost : L10N.filterAll;
                    viewModeBtn.classList.toggle('active', hostFocusMode);
                    viewModeBtn.setAttribute('aria-pressed', hostFocusMode ? 'true' : 'false');
                    viewModeBtn.setAttribute('aria-label', hostFocusMode ? L10N.filterHostA11y : L10N.filterAllA11y);
                }
                const children = streamContainer.children;
                for (let i = 0; i < children.length; i++) {
                    const c = children[i];
                    if (c.classList && !c.classList.contains('card')) continue;
                    const spk = c._speaker || c.getAttribute('data-speaker');
                    c.style.display = (hostFocusMode && spk === 'Caller') ? 'none' : 'block';
                }
                writeStoredPref('speakerFilter', hostFocusMode ? 'host' : 'all');
            }

            function restorePreferences() {
                const savedFont = parseInt(readStoredPref('currentFontSize') || '', 10);
                if (Number.isFinite(savedFont)) {
                    currentFontSize = savedFont;
                }
                const savedOrig = readStoredPref('showOriginal');
                if (savedOrig === 'false' || savedOrig === '0') {
                    showOriginal = false;
                } else if (savedOrig === 'true' || savedOrig === '1') {
                    showOriginal = true;
                }
                const savedFilter = readStoredPref('speakerFilter');
                if (savedFilter === 'host' || savedFilter === 'true' || savedFilter === '1') {
                    hostFocusMode = true;
                } else if (savedFilter === 'all' || savedFilter === 'false' || savedFilter === '0') {
                    hostFocusMode = false;
                }
                applyFontSize();
                applyShowOriginal();
                applySpeakerFilter();
            }

            function suppressScrollPause(ms = 260) {
                ignoreScrollPauseUntil = Math.max(ignoreScrollPauseUntil, performance.now() + ms);
            }

            function textDirForLang(langCode) {
                if (!langCode || typeof langCode !== 'string') return 'auto';
                const base = langCode.trim().toLowerCase().split(/[-_]/)[0];
                if (!base) return 'auto';
                return RTL_LANGS.has(base) ? 'rtl' : 'ltr';
            }

            function speakerLabelText(speaker) {
                return speaker === 'You' ? L10N.speakerHostLabel : L10N.speakerCallerLabel;
            }

            function formatFinalTimestamp(ev) {
                if (ev && typeof ev.timestampMs === 'number' && Number.isFinite(ev.timestampMs) && ev.timestampMs > 0) {
                    try {
                        const formatted = new Date(ev.timestampMs).toLocaleTimeString([], {
                            hour: '2-digit',
                            minute: '2-digit',
                            second: '2-digit'
                        });
                        if (formatted) return formatted;
                    } catch (err) {}
                }
                return (ev && ev.timestamp) ? ev.timestamp : '';
            }

            function isNearBottom(threshold = 36) {
                const docEl = document.scrollingElement || document.documentElement;
                return (docEl.scrollHeight - ((window.scrollY || 0) + window.innerHeight)) <= threshold;
            }

            function finishProgrammaticScroll() {
                isProgrammaticScroll = false;
                if (programmaticClearTimer) {
                    clearTimeout(programmaticClearTimer);
                    programmaticClearTimer = null;
                }
                lastScrollY = window.scrollY || 0;
            }

            function userPausedAutoScroll() {
                autoScroll = false;
                autoscrollToggle.checked = false;
                jumpLatestBtn.classList.add('visible');
            }

            function resumeAutoScroll() {
                autoScroll = true;
                autoscrollToggle.checked = true;
                jumpLatestBtn.classList.remove('visible');
            }

            function scrollToBottom(instant = false) {
                if (!autoScroll) return;
                if (instant) pendingScrollInstant = true;
                if (scrollScheduled) return;
                scrollScheduled = true;
                isProgrammaticScroll = true;
                requestAnimationFrame(() => {
                    scrollScheduled = false;
                    const useInstant = pendingScrollInstant;
                    pendingScrollInstant = false;
                    if (!autoScroll) {
                        isProgrammaticScroll = false;
                        return;
                    }
                    const el = document.scrollingElement || document.documentElement;
                    const maxTop = Math.max(el.scrollHeight, document.body.scrollHeight);
                    const targetTop = Math.max(0, maxTop - window.innerHeight);
                    if (targetTop <= (window.scrollY || 0) + 1) {
                        finishProgrammaticScroll();
                        return;
                    }
                    const prefersReduced = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
                    const useAuto = useInstant || prefersReduced;
                    window.scrollTo({
                        top: maxTop,
                        behavior: useAuto ? 'auto' : 'smooth'
                    });
                    if (programmaticClearTimer) clearTimeout(programmaticClearTimer);
                    programmaticClearTimer = setTimeout(finishProgrammaticScroll, useAuto ? 80 : 500);
                });
            }

            window.addEventListener('scrollend', () => {
                if (isProgrammaticScroll) finishProgrammaticScroll();
            }, { passive: true });

            window.addEventListener('scroll', () => {
                const currentY = window.scrollY || 0;
                const docEl = document.scrollingElement || document.documentElement;
                const maxScrollY = Math.max(0, docEl.scrollHeight - window.innerHeight);
                if (performance.now() < ignoreScrollPauseUntil) {
                    lastScrollY = currentY;
                    return;
                }
                const deltaY = currentY - lastScrollY;
                lastScrollY = currentY;
                if (isProgrammaticScroll) {
                    if (deltaY < -2 && currentY < maxScrollY - 4) {
                        finishProgrammaticScroll();
                        userPausedAutoScroll();
                    } else if (isNearBottom(36)) {
                        finishProgrammaticScroll();
                    }
                    return;
                }
                if (deltaY < -2 && currentY > 0 && currentY < maxScrollY - 4) {
                    userPausedAutoScroll();
                } else if (isNearBottom(36) && !userDisabledAutoScroll) {
                    resumeAutoScroll();
                } else if (!autoScroll) {
                    jumpLatestBtn.classList.add('visible');
                }
            }, { passive: true });

            window.addEventListener('wheel', (e) => {
                if (e.deltaY < -4) {
                    finishProgrammaticScroll();
                    userPausedAutoScroll();
                }
            }, { passive: true });

            window.addEventListener('touchstart', (e) => {
                touchMoved = false;
                if (e.touches && e.touches.length === 1) {
                    touchStartY = e.touches[0].clientY;
                } else {
                    touchStartY = null;
                }
            }, { passive: true });

            window.addEventListener('touchmove', (e) => {
                if (!e.touches || e.touches.length !== 1) return;
                const currentTouchY = e.touches[0].clientY;
                if (touchStartY !== null && Math.abs(currentTouchY - touchStartY) > 6) {
                    touchMoved = true;
                }
                if (touchStartY !== null && (currentTouchY - touchStartY) > 14 && (window.scrollY || 0) > 2) {
                    finishProgrammaticScroll();
                    userPausedAutoScroll();
                }
            }, { passive: true });

            window.addEventListener('touchend', () => {
                const didTouchMove = touchMoved;
                touchStartY = null;
                touchMoved = false;
                if (didTouchMove && !autoScroll && !userDisabledAutoScroll && isNearBottom(36)) {
                    resumeAutoScroll();
                }
            }, { passive: true });
            window.addEventListener('touchcancel', () => {
                touchStartY = null;
                touchMoved = false;
            }, { passive: true });

            jumpLatestBtn.addEventListener('click', (e) => {
                e.stopPropagation();
                userDisabledAutoScroll = false;
                resumeAutoScroll();
                scrollToBottom(false);
            });

            function base64urlToBytes(value) {
                let base64 = value.replace(/-/g, '+').replace(/_/g, '/');
                while (base64.length % 4 !== 0) base64 += '=';
                const binary = atob(base64);
                const bytes = new Uint8Array(binary.length);
                for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
                return bytes;
            }

            async function initSessionCrypto() {
                if (!PAYLOAD_ENCRYPTED) return 'ok';
                if (!window.crypto || !window.crypto.subtle) return 'no_crypto';
                if (!SESSION_KEY) return 'invalid_link';
                try {
                    const raw = base64urlToBytes(SESSION_KEY);
                    if (raw.length !== 32) return 'invalid_link';
                    sessionCryptoKey = await window.crypto.subtle.importKey(
                        'raw', raw, { name: 'AES-GCM' }, false, ['decrypt']
                    );
                    return 'ok';
                } catch (err) {
                    return 'invalid_link';
                }
            }

            function makeReplayError(message) {
                const err = new Error(message);
                err.name = 'ReplayError';
                return err;
            }

            async function decryptEnvelope(payload, expectedType, isSSE = false) {
                const envelope = typeof payload === 'string' ? JSON.parse(payload) : payload;
                if (!envelope || envelope.v !== 1 || typeof envelope.d !== 'string') {
                    throw new Error('Unsupported envelope');
                }
                const hasMeta = envelope.t !== undefined || envelope.s !== undefined;
                let additionalData;
                if (hasMeta || expectedType || isSSE) {
                    if (typeof envelope.t !== 'string' || typeof envelope.s !== 'number' || !Number.isSafeInteger(envelope.s) || envelope.s < 0) {
                        throw new Error('Invalid envelope metadata');
                    }
                    if (expectedType && envelope.t !== expectedType) {
                        throw new Error('Unexpected envelope type');
                    }
                    if (isSSE) {
                        if (envelope.s <= lastSseSeq) throw makeReplayError('Stale SSE sequence');
                    } else if (expectedType === 'state') {
                        if (envelope.s <= lastStateSeq) throw makeReplayError('Stale state sequence');
                    }
                    additionalData = new TextEncoder().encode(`v1:${envelope.t}:${envelope.s}`);
                }
                const combined = base64urlToBytes(envelope.d);
                if (combined.length < 28) throw new Error('Invalid envelope');
                const iv = combined.slice(0, 12);
                const ciphertext = combined.slice(12);
                const params = additionalData
                    ? { name: 'AES-GCM', iv, additionalData }
                    : { name: 'AES-GCM', iv };
                const plaintext = await window.crypto.subtle.decrypt(
                    params, sessionCryptoKey, ciphertext
                );
                if (hasMeta) {
                    if (isSSE) lastSseSeq = envelope.s;
                    else if (expectedType === 'state') lastStateSeq = envelope.s;
                }
                return new TextDecoder().decode(plaintext);
            }

            function showLinkError(customMessage) {
                if (linkErrorShown) return;
                linkErrorShown = true;
                clearSSEWatchdog();
                stopPollingFallback();
                if (eventSource) { eventSource.close(); eventSource = null; }
                emptyState.style.display = '';
                emptyStateLabel.textContent = customMessage || L10N.emptyLinkError;
                connPill.className = 'status-pill offline';
                if (connLabel.textContent !== L10N.statusLinkError) connLabel.textContent = L10N.statusLinkError;
                copyTranscriptBtn.disabled = true;
                if (autoscrollPill) autoscrollPill.hidden = true;
            }

            function handleSessionEnded() {
                if (sessionEnded || linkErrorShown) return;
                sessionEnded = true;
                clearSSEWatchdog();
                stopPollingFallback();
                if (eventSource) { eventSource.close(); eventSource = null; }
                ['Caller', 'You'].forEach(sp => {
                    if (liveSlots[sp]) {
                        liveSlots[sp].classList.remove('live');
                        const timeEl = liveSlots[sp].querySelector('.time-label');
                        if (timeEl) timeEl.textContent = L10N.statusSessionEnded;
                    }
                    liveSlots[sp] = null;
                });
                updateViewerCount(0);
                connPill.className = 'status-pill offline';
                if (connLabel.textContent !== L10N.statusSessionEnded) connLabel.textContent = L10N.statusSessionEnded;
                if (autoscrollPill) autoscrollPill.hidden = true;
                syncEmptyStateAndCopy();
            }

            function enqueueDecrypted(payload, handler, expectedType) {
                if (!PAYLOAD_ENCRYPTED) {
                    try { handler(JSON.parse(payload)); } catch (err) {}
                    return;
                }
                decryptChain = decryptChain
                    .then(async () => {
                        const text = await decryptEnvelope(payload, expectedType, true);
                        hasDecryptedSuccessfully = true;
                        try {
                            handler(JSON.parse(text));
                        } catch (handlerErr) {}
                    })
                    .catch((err) => {
                        if (err && err.name === 'ReplayError') return;
                        if (!hasDecryptedSuccessfully) showLinkError();
                    });
            }

            function setConnectionState(online, label) {
                if (linkErrorShown || sessionEnded) return;
                let nextClass;
                let text;
                if (online && hostPaused) {
                    nextClass = 'status-pill paused';
                    text = L10N.statusPaused;
                } else {
                    nextClass = online ? 'status-pill' : 'status-pill offline';
                    text = label || (online ? L10N.statusLive : L10N.statusOffline);
                }
                if (connPill.className !== nextClass) connPill.className = nextClass;
                if (connLabel.textContent !== text) connLabel.textContent = text;
            }

            function updateViewerCount(count) {
                if (typeof count !== 'number') return;
                let label = '';
                if (count === 1) {
                    label = L10N.viewersOne;
                } else if (count > 1) {
                    label = L10N.viewersOther
                        .replace('%ld', String(count))
                        .replace('%d', String(count))
                        .replace('{count}', String(count));
                }
                if (viewerCountEl.textContent !== label) viewerCountEl.textContent = label;
            }

            function getVisibleCards() {
                const visible = [];
                const children = streamContainer.children;
                for (let i = 0; i < children.length; i++) {
                    const card = children[i];
                    if (card.classList && !card.classList.contains('card')) continue;
                    if (card.style.display !== 'none') visible.push(card);
                }
                return visible;
            }

            function syncEmptyStateAndCopy() {
                if (linkErrorShown) {
                    copyTranscriptBtn.disabled = true;
                    return;
                }
                const children = streamContainer.children;
                let totalCards = 0;
                let visibleCount = 0;
                let hasCopyableText = false;
                for (let i = 0; i < children.length; i++) {
                    const card = children[i];
                    if (card.classList && !card.classList.contains('card')) continue;
                    totalCards += 1;
                    if (card.style.display !== 'none') {
                        visibleCount += 1;
                        if (!hasCopyableText) {
                            if (typeof card._hasText === 'boolean') {
                                if (card._hasText) hasCopyableText = true;
                            } else {
                                const t = ((card._transEl || card.querySelector('.translated-text'))?.textContent || '').trim();
                                if (t.length > 0) hasCopyableText = true;
                            }
                        }
                    }
                }
                if (visibleCount === 0) {
                    emptyState.style.display = '';
                    const hasHiddenCallerCards = hostFocusMode && totalCards > 0;
                    emptyStateLabel.textContent = sessionEnded
                        ? L10N.emptySessionEnded
                        : (hostPaused
                            ? L10N.emptyPaused
                            : (hasHiddenCallerCards ? L10N.emptyHostOnly : L10N.emptyListening));
                    copyTranscriptBtn.disabled = true;
                } else {
                    emptyState.style.display = 'none';
                    copyTranscriptBtn.disabled = !hasCopyableText;
                }
            }

            function clearRenderedCards() {
                suppressScrollPause(300);
                streamContainer.innerHTML = '';
                renderedIds.clear();
                finalizedCardsById.clear();
                liveSlots['You'] = null;
                liveSlots['Caller'] = null;
                syncEmptyStateAndCopy();
            }

            function handleStatusEvent(status) {
                if (!status || typeof status !== 'object' || sessionEnded) return;
                if (typeof status.clearEpoch === 'number' && status.clearEpoch > lastClearEpoch) {
                    lastClearEpoch = status.clearEpoch;
                    if (!status.clearAll && !status.clearCaller) {
                        clearRenderedCards();
                    }
                }
                if (typeof status.paused === 'boolean') {
                    hostPaused = status.paused;
                    if (hostPaused) {
                        ['Caller', 'You'].forEach(sp => {
                            if (liveSlots[sp]) {
                                if (document.body.contains(liveSlots[sp])) {
                                    liveSlots[sp].remove();
                                }
                                liveSlots[sp] = null;
                            }
                        });
                    }
                    setConnectionState(true, hostPaused ? L10N.statusPaused : L10N.statusLive);
                    syncEmptyStateAndCopy();
                }
                if (typeof status.viewerCount === 'number') updateViewerCount(status.viewerCount);
                if (status.clearCaller) {
                    streamContainer.querySelectorAll('[data-speaker="Caller"]').forEach(card => {
                        const evictedId = card.getAttribute('data-event-id');
                        if (evictedId) {
                            finalizedCardsById.delete(evictedId);
                            renderedIds.delete(evictedId);
                        }
                        card.remove();
                    });
                    liveSlots['Caller'] = null;
                    syncEmptyStateAndCopy();
                }
                if (status.clearAll) {
                    clearRenderedCards();
                }
            }

            fontIncBtn.addEventListener('click', () => {
                suppressScrollPause(300);
                currentFontSize = Math.min(30, currentFontSize + 2);
                applyFontSize();
                if (autoScroll) scrollToBottom(true);
            });
            fontDecBtn.addEventListener('click', () => {
                suppressScrollPause(300);
                currentFontSize = Math.max(14, currentFontSize - 2);
                applyFontSize();
                if (autoScroll) scrollToBottom(true);
            });
            origBtn.addEventListener('click', () => {
                suppressScrollPause(300);
                showOriginal = !showOriginal;
                applyShowOriginal();
                if (autoScroll) scrollToBottom(true);
            });
            viewModeBtn.addEventListener('click', () => {
                suppressScrollPause(300);
                hostFocusMode = !hostFocusMode;
                applySpeakerFilter();
                syncEmptyStateAndCopy();
                if (autoScroll) scrollToBottom(true);
            });
            autoscrollToggle.addEventListener('change', (e) => {
                if (e.target.checked) {
                    userDisabledAutoScroll = false;
                    resumeAutoScroll();
                    scrollToBottom(false);
                } else {
                    userDisabledAutoScroll = true;
                    userPausedAutoScroll();
                }
            });

            function fallbackCopyText(text) {
                const textarea = document.createElement('textarea');
                textarea.value = text;
                textarea.setAttribute('readonly', '');
                textarea.style.position = 'fixed';
                textarea.style.top = '0';
                textarea.style.left = '0';
                textarea.style.width = '1px';
                textarea.style.height = '1px';
                textarea.style.fontSize = '16px';
                textarea.style.opacity = '0';
                document.body.appendChild(textarea);
                const selection = document.getSelection();
                const previousRange = (selection && selection.rangeCount > 0) ? selection.getRangeAt(0) : null;
                textarea.focus({ preventScroll: true });
                textarea.select();
                textarea.setSelectionRange(0, textarea.value.length);
                let ok = false;
                try {
                    ok = document.execCommand('copy');
                } catch (err) {
                    ok = false;
                }
                document.body.removeChild(textarea);
                if (previousRange && selection) {
                    selection.removeAllRanges();
                    selection.addRange(previousRange);
                }
                return ok;
            }

            function announceToScreenReader(text) {
                if (!srAnnouncer || !text) return;
                const currentRaw = (srAnnouncer.textContent || '').replace(/\\u200B+$/g, '');
                if (currentRaw === text || srAnnouncer.textContent === text) {
                    srToggleZeroWidth = !srToggleZeroWidth;
                    srAnnouncer.textContent = srToggleZeroWidth ? (text + '\\u200B') : text;
                } else {
                    srToggleZeroWidth = false;
                    srAnnouncer.textContent = text;
                }
            }

            copyTranscriptBtn.addEventListener('click', async () => {
                const lines = [];
                getVisibleCards().forEach(card => {
                    const speaker = speakerLabelText(card._speaker || card.getAttribute('data-speaker'));
                    const trans = ((card._transEl || card.querySelector('.translated-text'))?.textContent || '').trim();
                    const orig = ((card._origEl || card.querySelector('.original-text'))?.textContent || '').trim();
                    if (!trans) return;
                    lines.push(showOriginal && orig && orig.toLowerCase() !== trans.toLowerCase()
                        ? `[${speaker}] ${trans}\\n(${orig})`
                        : `[${speaker}] ${trans}`);
                });
                const payload = lines.join('\\n\\n');
                if (!payload) {
                    syncEmptyStateAndCopy();
                    return;
                }
                let copied = false;
                if (navigator.clipboard && typeof navigator.clipboard.writeText === 'function') {
                    try {
                        await navigator.clipboard.writeText(payload);
                        copied = true;
                    } catch (err) {
                        copied = false;
                    }
                }
                if (!copied) {
                    copied = fallbackCopyText(payload);
                }
                copyTranscriptBtn.textContent = copied ? L10N.copied : L10N.copyFailed;
                if (copied && L10N.copyCopiedAnnouncement) {
                    announceToScreenReader(L10N.copyCopiedAnnouncement);
                } else if (!copied && L10N.copyFailed) {
                    announceToScreenReader(L10N.copyFailed);
                }
                if (copyBtnTimer) clearTimeout(copyBtnTimer);
                copyBtnTimer = setTimeout(() => { copyTranscriptBtn.textContent = L10N.copy; }, 1500);
            });

            function createCardElement(speaker, isLive, animateIn = true) {
                emptyState.style.display = 'none';
                const card = document.createElement('div');
                card.className = (isLive ? 'card live' : 'card') + (animateIn ? ' animate-in' : '');
                card.setAttribute('data-speaker', speaker);
                const isHost = (speaker === 'You');

                const meta = document.createElement('div');
                meta.className = 'card-meta';

                const badgeGroup = document.createElement('div');
                const speakerBadge = document.createElement('span');
                speakerBadge.className = 'speaker-badge ' + (isHost ? 'speaker-host' : 'speaker-caller');
                speakerBadge.textContent = isHost ? L10N.speakerHost : L10N.speakerCaller;

                const untransBadge = document.createElement('span');
                untransBadge.className = 'untranslated-badge';
                untransBadge.style.display = 'none';
                untransBadge.textContent = L10N.badgeUntranslated;

                badgeGroup.appendChild(speakerBadge);
                badgeGroup.appendChild(untransBadge);

                const timeLabel = document.createElement('span');
                timeLabel.className = 'time-label';
                timeLabel.textContent = L10N.timeLive;

                meta.appendChild(badgeGroup);
                meta.appendChild(timeLabel);

                const translatedDiv = document.createElement('div');
                translatedDiv.className = 'translated-text';
                translatedDiv.setAttribute('dir', 'auto');

                const origDiv = document.createElement('div');
                origDiv.className = 'original-text';
                origDiv.setAttribute('dir', 'auto');

                card.appendChild(meta);
                card.appendChild(translatedDiv);
                card.appendChild(origDiv);

                card._speaker = speaker;
                card._transEl = translatedDiv;
                card._origEl = origDiv;
                card._timeEl = timeLabel;
                card._untransBadge = untransBadge;
                card._hasText = false;

                if (hostFocusMode && speaker === 'Caller') card.style.display = 'none';
                return card;
            }

            function evictOldCardsIfNeeded() {
                if (streamContainer.children.length <= 80) return;
                const shouldCompensate = !autoScroll;
                const prevHeight = shouldCompensate ? streamContainer.offsetHeight : 0;
                const containerTop = shouldCompensate ? streamContainer.getBoundingClientRect().top : 0;
                let evictedAny = false;
                let cursor = streamContainer.firstElementChild;
                while (streamContainer.children.length > 80 && cursor) {
                    const next = cursor.nextElementSibling;
                    if (!cursor.classList.contains('live')) {
                        const evictedId = cursor._eventId || cursor.getAttribute('data-event-id');
                        if (evictedId) finalizedCardsById.delete(evictedId);
                        streamContainer.removeChild(cursor);
                        evictedAny = true;
                    }
                    cursor = next;
                }
                if (shouldCompensate && evictedAny && containerTop < 0) {
                    const removedHeight = prevHeight - streamContainer.offsetHeight;
                    if (removedHeight > 0) {
                        suppressScrollPause(300);
                        const targetY = Math.max(0, (window.scrollY || 0) - removedHeight);
                        window.scrollTo({ top: targetY, behavior: 'auto' });
                        lastScrollY = window.scrollY || 0;
                    }
                }
            }

            function getOrCreateLiveCard(speaker, animateIn = true) {
                if (liveSlots[speaker] && document.body.contains(liveSlots[speaker])) return liveSlots[speaker];
                const card = createCardElement(speaker, true, animateIn);
                streamContainer.appendChild(card);
                evictOldCardsIfNeeded();
                liveSlots[speaker] = card;
                return card;
            }

            const renderedIds = new Set();
            const finalizedCardsById = new Map();

            function populateCardContent(card, ev) {
                const rawTranslated = ev.translatedText || ev.translated || '';
                const nextTranslated = rawTranslated || ev.originalText || '';
                const nextOriginal = (!ev.isUntranslated && ev.originalText && ev.originalText.toLowerCase() !== rawTranslated.toLowerCase()) ? ev.originalText : '';
                const nextUntrans = !!ev.isUntranslated;
                const nextFinal = !!ev.isFinal;
                const nextTime = nextFinal ? formatFinalTimestamp(ev) : L10N.timeLive;

                const transEl = card._transEl || card.querySelector('.translated-text');
                const origEl = card._origEl || card.querySelector('.original-text');
                const timeEl = card._timeEl || card.querySelector('.time-label');
                const untransBadge = card._untransBadge || card.querySelector('.untranslated-badge');

                const prevTranslated = transEl.textContent || '';
                const prevOriginal = origEl.textContent || '';
                const prevFinal = !card.classList.contains('live');
                const prevUntrans = untransBadge ? (untransBadge.style.display !== 'none') : false;
                const prevTime = timeEl ? (timeEl.textContent || '') : '';

                const changed = (prevTranslated !== nextTranslated)
                    || (prevOriginal !== nextOriginal)
                    || (prevFinal !== nextFinal)
                    || (prevUntrans !== nextUntrans)
                    || (prevTime !== nextTime);

                if (!changed) return false;

                if (untransBadge) {
                    untransBadge.style.display = nextUntrans ? 'inline' : 'none';
                }
                card.classList.toggle('untranslated', nextUntrans);
                transEl.textContent = nextTranslated;
                const transLang = nextUntrans
                    ? (ev.sourceLangCode || '')
                    : (rawTranslated ? (ev.targetLangCode || ev.sourceLangCode || '') : (ev.sourceLangCode || ''));
                transEl.setAttribute('dir', textDirForLang(transLang));
                if (transLang) transEl.setAttribute('lang', transLang); else transEl.removeAttribute('lang');

                origEl.textContent = nextOriginal;
                const origLang = ev.sourceLangCode || '';
                origEl.setAttribute('dir', textDirForLang(origLang));
                if (origLang && nextOriginal) origEl.setAttribute('lang', origLang); else origEl.removeAttribute('lang');

                card._eventId = ev.id || '';
                card._hasText = (nextTranslated.trim().length > 0);
                card.setAttribute('data-orig', ev.originalText || '');
                card.setAttribute('data-event-id', ev.id || '');
                if (nextFinal) {
                    card.classList.remove('live');
                    timeEl.textContent = nextTime;
                } else {
                    card.classList.add('live');
                    timeEl.textContent = L10N.timeLive;
                }
                return true;
            }

            function formatAnnouncement(ev) {
                if (!ev || !ev.isFinal) return '';
                if (hostFocusMode && ev.speaker === 'Caller') return '';
                const text = (ev.translatedText || ev.translated || ev.originalText || '').trim();
                if (!text) return '';
                return `${speakerLabelText(ev.speaker)}: ${text}`;
            }

            function announceFinalForScreenReader(ev) {
                const line = formatAnnouncement(ev);
                if (line) announceToScreenReader(line);
            }

            function announceFinalBatchForScreenReader(events) {
                if (!Array.isArray(events) || events.length === 0) return;
                const lines = events.map(formatAnnouncement).filter(Boolean);
                if (lines.length > 0) announceToScreenReader(lines.join(' — '));
            }

            function handleCaptionEvent(ev, isBatchHistory = false) {
                if (!ev || (!ev.translatedText && !ev.translated && !ev.originalText)) return false;
                if (ev.id && renderedIds.has(ev.id)) {
                    if (ev.isFinal) {
                        const existingCard = finalizedCardsById.get(ev.id);
                        if (existingCard && document.body.contains(existingCard)) {
                            const prevTranslated = ((existingCard._transEl || existingCard.querySelector('.translated-text'))?.textContent || '');
                            const nextTranslated = ev.translatedText || ev.translated || ev.originalText || '';
                            const updated = populateCardContent(existingCard, ev);
                            if (updated) {
                                if (!isBatchHistory) syncEmptyStateAndCopy();
                                if (!ev.isUntranslated && prevTranslated !== nextTranslated) {
                                    announceFinalForScreenReader(ev);
                                    if (!isBatchHistory) scrollToBottom(false);
                                }
                            }
                            return updated;
                        }
                    }
                    return false;
                }
                if (ev.isFinal && ev.id) {
                    renderedIds.add(ev.id);
                    if (renderedIds.size > 200) {
                        const oldest = renderedIds.values().next().value;
                        renderedIds.delete(oldest);
                        finalizedCardsById.delete(oldest);
                    }
                }
                let changed = false;
                if (ev.isFinal) {
                    const activeLive = liveSlots[ev.speaker];
                    let card = null;
                    if (activeLive && document.body.contains(activeLive)) {
                        const liveId = activeLive._eventId || activeLive.getAttribute('data-event-id') || '';
                        if (ev.id && liveId && liveId === ev.id) {
                            card = activeLive;
                            liveSlots[ev.speaker] = null;
                        } else {
                            card = createCardElement(ev.speaker, false, !isBatchHistory);
                            streamContainer.insertBefore(card, activeLive);
                            changed = true;
                        }
                    } else {
                        card = createCardElement(ev.speaker, false, !isBatchHistory);
                        streamContainer.appendChild(card);
                        changed = true;
                    }
                    if (populateCardContent(card, ev)) changed = true;
                    if (ev.id) finalizedCardsById.set(ev.id, card);
                    evictOldCardsIfNeeded();
                    if (!isBatchHistory) announceFinalForScreenReader(ev);
                } else {
                    const hadSlot = !!(liveSlots[ev.speaker] && document.body.contains(liveSlots[ev.speaker]));
                    const liveCard = getOrCreateLiveCard(ev.speaker, !isBatchHistory);
                    if (!hadSlot) changed = true;
                    if (populateCardContent(liveCard, ev)) changed = true;
                }
                if (!isBatchHistory) {
                    const liveSlot = liveSlots[ev.speaker];
                    const canSkipLiveSync = !ev.isFinal
                        && emptyState.style.display === 'none'
                        && !copyTranscriptBtn.disabled
                        && !!liveSlot
                        && liveSlot.style.display !== 'none'
                        && !!liveSlot._hasText;
                    if (!canSkipLiveSync) {
                        syncEmptyStateAndCopy();
                    }
                    if (changed) scrollToBottom(!ev.isFinal);
                }
                return changed;
            }

            const SSE_WATCHDOG_TIMEOUT_MS = 40000;
            const POLL_FETCH_TIMEOUT_MS = 6000;
            const SSE_RECONNECT_BASE_MS = 5000;
            const SSE_RECONNECT_MAX_MS = 60000;
            let eventSource = null;
            let sseWatchdogTimer = null;
            let pollTimeout = null;
            let isPollingActive = false;
            let pollDelayMs = 1500;
            let sseReconnectDelayMs = SSE_RECONNECT_BASE_MS;
            let pollCycleToken = 0;

            function clearSSEWatchdog() {
                if (sseWatchdogTimer) {
                    clearTimeout(sseWatchdogTimer);
                    sseWatchdogTimer = null;
                }
            }

            function resetSSEWatchdog() {
                clearSSEWatchdog();
                if (linkErrorShown || sessionEnded || !eventSource) return;
                sseWatchdogTimer = setTimeout(() => {
                    sseWatchdogTimer = null;
                    if (!eventSource || linkErrorShown || sessionEnded) return;
                    try { eventSource.close(); } catch (err) {}
                    eventSource = null;
                    setConnectionState(false, L10N.statusReconnecting);
                    startPollingFallback();
                }, SSE_WATCHDOG_TIMEOUT_MS);
            }

            function scheduleNextPoll(token) {
                if (!isPollingActive || token !== pollCycleToken || sessionEnded) return;
                if (pollTimeout) clearTimeout(pollTimeout);
                pollTimeout = setTimeout(() => {
                    pollTimeout = null;
                    runPollCycle(token);
                }, pollDelayMs);
            }

            async function runPollCycle(token) {
                if (!isPollingActive || token !== pollCycleToken || sessionEnded) return;
                const shouldContinue = await pollState(token);
                if (shouldContinue && isPollingActive && token === pollCycleToken && !sessionEnded) {
                    scheduleNextPoll(token);
                }
            }

            function startPollingFallback() {
                if (isPollingActive || linkErrorShown || sessionEnded) return;
                isPollingActive = true;
                pollDelayMs = 1500;
                pollCycleToken += 1;
                runPollCycle(pollCycleToken);
            }

            function stopPollingFallback() {
                isPollingActive = false;
                pollCycleToken += 1;
                if (pollTimeout) { clearTimeout(pollTimeout); pollTimeout = null; }
            }

            function connectSSE() {
                if (linkErrorShown || sessionEnded) return;
                clearSSEWatchdog();
                if (eventSource) {
                    eventSource.close();
                    eventSource = null;
                }
                lastSSEAttemptMs = Date.now();
                eventSource = new EventSource(BASE_PATH + '/events?viewer=' + encodeURIComponent(VIEWER_ID));
                resetSSEWatchdog();
                eventSource.onopen = () => {
                    consecutivePollFailures = 0;
                    sseReconnectDelayMs = SSE_RECONNECT_BASE_MS;
                    resetSSEWatchdog();
                    stopPollingFallback();
                    setConnectionState(true, L10N.statusLive);
                };
                eventSource.addEventListener('ping', () => {
                    resetSSEWatchdog();
                });
                eventSource.addEventListener('history', (e) => {
                    resetSSEWatchdog();
                    enqueueDecrypted(e.data, (history) => {
                        ['Caller', 'You'].forEach(sp => {
                            if (liveSlots[sp] && document.body.contains(liveSlots[sp])) {
                                liveSlots[sp].remove();
                            }
                            liveSlots[sp] = null;
                        });
                        if (history && history.length > 0) {
                            history.forEach(item => handleCaptionEvent(item, true));
                            if (autoScroll) scrollToBottom(true);
                        }
                        hasHydratedInitialSnapshot = true;
                        syncEmptyStateAndCopy();
                    }, 'history');
                });
                eventSource.addEventListener('caption', (e) => {
                    resetSSEWatchdog();
                    enqueueDecrypted(e.data, (ev) => {
                        hasHydratedInitialSnapshot = true;
                        handleCaptionEvent(ev, false);
                    }, 'caption');
                });
                eventSource.addEventListener('status', (e) => {
                    resetSSEWatchdog();
                    enqueueDecrypted(e.data, handleStatusEvent, 'status');
                });
                eventSource.addEventListener('ended', (e) => {
                    resetSSEWatchdog();
                    enqueueDecrypted(e.data || '{}', () => handleSessionEnded(), 'ended');
                });
                eventSource.onerror = () => {
                    if (!eventSource || linkErrorShown || sessionEnded) return;
                    if (eventSource.readyState === EventSource.CLOSED) {
                        clearSSEWatchdog();
                    }
                    if (!(isPollingActive && consecutivePollFailures === 0)) {
                        setConnectionState(false, L10N.statusReconnecting);
                    }
                    startPollingFallback();
                };
            }

            async function pollState(token) {
                if (sessionEnded || linkErrorShown) return false;
                let envelope;
                const abortController = (typeof AbortController === 'function') ? new AbortController() : null;
                const fetchTimer = abortController ? setTimeout(() => {
                    try { abortController.abort(); } catch (err) {}
                }, POLL_FETCH_TIMEOUT_MS) : null;
                try {
                    const fetchOptions = { cache: 'no-store' };
                    if (abortController) fetchOptions.signal = abortController.signal;
                    const res = await fetch(BASE_PATH + '/api/state?viewer=' + encodeURIComponent(VIEWER_ID), fetchOptions);
                    if (!isPollingActive || token !== pollCycleToken || sessionEnded) return false;
                    if (res.status === 403 || res.status === 404 || res.status === 410) {
                        handleSessionEnded();
                        return false;
                    }
                    if (!res.ok) {
                        consecutivePollFailures += 1;
                        setConnectionState(false, consecutivePollFailures >= 5 ? L10N.statusOffline : L10N.statusReconnecting);
                        pollDelayMs = Math.min(15000, pollDelayMs * 2);
                        return true;
                    }
                    envelope = await res.json();
                    if (!isPollingActive || token !== pollCycleToken || sessionEnded) return false;
                } catch (e) {
                    if (!isPollingActive || token !== pollCycleToken || sessionEnded) return false;
                    consecutivePollFailures += 1;
                    setConnectionState(false, consecutivePollFailures >= 5 ? L10N.statusOffline : L10N.statusReconnecting);
                    pollDelayMs = Math.min(15000, pollDelayMs * 2);
                    return true;
                } finally {
                    if (fetchTimer) clearTimeout(fetchTimer);
                }
                let data;
                if (PAYLOAD_ENCRYPTED) {
                    try {
                        data = JSON.parse(await decryptEnvelope(envelope, 'state', false));
                        hasDecryptedSuccessfully = true;
                        if (!isPollingActive || token !== pollCycleToken || sessionEnded) return false;
                    } catch (e) {
                        if (e && e.name === 'ReplayError') {
                            consecutivePollFailures = 0;
                            return true;
                        }
                        if (!hasDecryptedSuccessfully) showLinkError();
                        return !hasDecryptedSuccessfully ? false : true;
                    }
                } else {
                    data = envelope;
                }
                consecutivePollFailures = 0;
                pollDelayMs = 1500;
                hostPaused = !!data.isPaused;
                setConnectionState(true, L10N.statusLive);

                let didContentChange = false;
                if (typeof data.clearEpoch === 'number' && data.clearEpoch > lastClearEpoch) {
                    lastClearEpoch = data.clearEpoch;
                    clearRenderedCards();
                    didContentChange = true;
                }
                const newlyFinalized = [];
                if (Array.isArray(data.history) && data.history.length > 0) {
                    data.history.forEach(item => {
                        const wasKnown = !!(item && item.id && renderedIds.has(item.id));
                        if (handleCaptionEvent(item, true)) {
                            didContentChange = true;
                            if (hasHydratedInitialSnapshot && item && item.isFinal && !wasKnown) {
                                newlyFinalized.push(item);
                            }
                        }
                    });
                }
                if (data.callerPartial) {
                    if (handleCaptionEvent(data.callerPartial, true)) didContentChange = true;
                } else if (liveSlots['Caller']) {
                    if (document.body.contains(liveSlots['Caller'])) liveSlots['Caller'].remove();
                    liveSlots['Caller'] = null;
                    didContentChange = true;
                }
                if (data.micPartial) {
                    if (handleCaptionEvent(data.micPartial, true)) didContentChange = true;
                } else if (liveSlots['You']) {
                    if (document.body.contains(liveSlots['You'])) liveSlots['You'].remove();
                    liveSlots['You'] = null;
                    didContentChange = true;
                }
                hasHydratedInitialSnapshot = true;
                if (newlyFinalized.length > 0) {
                    announceFinalBatchForScreenReader(newlyFinalized);
                }
                handleStatusEvent({ paused: !!data.isPaused, viewerCount: data.viewerCount });
                syncEmptyStateAndCopy();
                if (didContentChange) scrollToBottom(false);

                const nowMs = Date.now();
                const retryMinWaitMs = Math.max(15000, sseReconnectDelayMs);
                if (!linkErrorShown && !sessionEnded && (
                    !eventSource
                    || eventSource.readyState === EventSource.CLOSED
                    || (eventSource.readyState === EventSource.CONNECTING && (nowMs - lastSSEAttemptMs) >= retryMinWaitMs)
                )) {
                    if ((nowMs - lastSSEAttemptMs) >= sseReconnectDelayMs) {
                        sseReconnectDelayMs = Math.min(SSE_RECONNECT_MAX_MS, sseReconnectDelayMs * 2);
                        connectSSE();
                    }
                }
                return true;
            }

            function handleForegroundOrOnline() {
                if (!appInitialized || linkErrorShown || sessionEnded) return;
                if (document.visibilityState === 'hidden') return;
                consecutivePollFailures = 0;
                pollDelayMs = 1500;
                sseReconnectDelayMs = SSE_RECONNECT_BASE_MS;
                if (!eventSource || eventSource.readyState === EventSource.CLOSED) {
                    connectSSE();
                }
                if (isPollingActive) {
                    if (pollTimeout) {
                        clearTimeout(pollTimeout);
                        pollTimeout = null;
                    }
                    pollCycleToken += 1;
                    runPollCycle(pollCycleToken);
                } else if (!eventSource || eventSource.readyState !== EventSource.OPEN) {
                    startPollingFallback();
                }
            }

            document.addEventListener('visibilitychange', () => {
                if (document.visibilityState === 'visible') {
                    handleForegroundOrOnline();
                }
            });
            window.addEventListener('pageshow', (e) => {
                if (e && e.persisted) {
                    handleForegroundOrOnline();
                }
            });
            window.addEventListener('online', () => {
                handleForegroundOrOnline();
            });

            (async () => {
                restorePreferences();
                syncEmptyStateAndCopy();
                const cryptoStatus = await initSessionCrypto();
                if (cryptoStatus !== 'ok') {
                    showLinkError(cryptoStatus === 'no_crypto' ? L10N.errorCryptoUnavailable : L10N.emptyLinkError);
                    return;
                }
                appInitialized = true;
                connectSSE();
            })();
        </script>
    </body>
    </html>
    """
}
