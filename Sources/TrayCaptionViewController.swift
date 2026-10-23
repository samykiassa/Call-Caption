import AppKit

public enum SystemAlertActionType: Sendable {
    case none
    case audioCapture
    case screenRecording
    case speechRecognition
    case dictation
    case translationSettings
    case permissions
    case clearRestoredTranscript
}

private final class HoverIconButton: NSButton {
    private var trackingArea: NSTrackingArea?
    var restingBackgroundColor: NSColor = .clear {
        didSet {
            if !isHovered {
                layer?.backgroundColor = restingBackgroundColor.cgColor
            }
        }
    }
    var hoverBackgroundColor: NSColor = NSColor.white.withAlphaComponent(0.10)
    var cornerRadiusValue: CGFloat = 6
    private var isHovered: Bool = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        wantsLayer = true
        layer?.cornerRadius = cornerRadiusValue
        layer?.backgroundColor = hoverBackgroundColor.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        layer?.backgroundColor = restingBackgroundColor.cgColor
    }
}

public final class TrayCaptionViewController: NSViewController {
    
    
    public struct SentenceItem: Sendable, Equatable {
        public let id: UUID?
        public let translated: String
        public let original: String
        public let isUntranslated: Bool

        public init(id: UUID? = nil, translated: String, original: String, isUntranslated: Bool = false) {
            self.id = id
            self.translated = translated
            self.original = original
            self.isUntranslated = isUntranslated
        }
    }
    
    public struct ParagraphBlock: Sendable {
        public let speaker: String
        public let sourceLangCode: String
        public let targetLangCode: String
        public var sentences: [SentenceItem]

        public init(
            speaker: String,
            sourceLangCode: String,
            targetLangCode: String,
            sentences: [SentenceItem]
        ) {
            self.speaker = speaker
            self.sourceLangCode = sourceLangCode
            self.targetLangCode = targetLangCode
            self.sentences = sentences
        }

        public init(
            speaker: String,
            sourceLangCode: String,
            targetLangCode: String,
            sentences: [(translated: String, original: String)]
        ) {
            self.speaker = speaker
            self.sourceLangCode = sourceLangCode
            self.targetLangCode = targetLangCode
            self.sentences = sentences.map { SentenceItem(translated: $0.translated, original: $0.original, isUntranslated: false) }
        }

        public func plainText(showOriginal: Bool, isMicEnabled: Bool) -> String {
            let isCaller = (speaker.lowercased() == "caller")
            let prefix = isMicEnabled ? (isCaller ? "Caller: " : "You: ") : ""
            let hasUntranslated = sentences.contains(where: \.isUntranslated)
            let untranslatedPrefix = hasUntranslated
                ? "[\(L10n.tr("caption.untranslated", "Untranslated"))] "
                : ""
            let translatedText = sentences.map(\.translated).joined(separator: " ")
            let originalText = sentences.map(\.original).filter { !$0.isEmpty }.joined(separator: " ")
            let primaryText = isCaller ? translatedText : (originalText.isEmpty ? translatedText : originalText)
            let secondaryText = isCaller ? originalText : translatedText
            if showOriginal,
               !secondaryText.isEmpty,
               secondaryText.lowercased() != primaryText.lowercased() {
                return "\(prefix)\(untranslatedPrefix)\(primaryText)\n\(secondaryText)"
            }
            return "\(prefix)\(untranslatedPrefix)\(primaryText)"
        }
    }

    private struct LiveUtterance: Sendable {
        let id: UUID
        let speaker: String
        let translated: String
        let original: String
        let sourceLangCode: String
        let targetLangCode: String
        let isUntranslated: Bool
    }
    
    private var paragraphs: [ParagraphBlock] = []
    private var lastFinalizedSpeaker: String? = nil
    private var currentParagraphSentenceCount: Int = 0
    private var currentParagraphWordCount: Int = 0
    private var lastFinalizedTime: Date = Date.distantPast
    
    private var liveCallerUtterance: LiveUtterance? = nil
    private var liveMicUtterance: LiveUtterance? = nil
    private var finalizedCharLength: Int = 0
    private var isUserScrolledUp: Bool = false
    private var isProgrammaticScrollOrLayout: Bool = false
    
    
    private var containerView: NSVisualEffectView!
    private var headerView: NSView!
    
    private var alertBannerView: NSView!
    private var alertIconView: NSImageView!
    private var alertLabel: NSTextField!
    private var alertActionBtn: NSButton!
    private var alertCloseBtn: NSButton!
    private var currentAlertActionType: SystemAlertActionType = .none
    private var activeAlertMessage: String?
    
    private var liveShareBannerView: NSView!
    private var liveShareIconView: NSImageView!
    private var liveShareLabel: NSTextField!
    private var liveShareCopyBtn: NSButton!
    private var liveShareStopBtn: NSButton!
    
    private var sourceLangBtn: HoverIconButton!
    private var swapLangBtn: HoverIconButton!
    private var targetLangBtn: HoverIconButton!
    
    private var micToggleBtn: HoverIconButton!
    private var liveShareBtn: HoverIconButton!
    private var pauseResumeBtn: HoverIconButton!
    private var copyBtn: HoverIconButton!
    private var clearBtn: HoverIconButton!
    private var pinBtn: HoverIconButton!
    private var settingsBtn: HoverIconButton!
    private var closeBtn: HoverIconButton!
    
    private var scrollView: NSScrollView!
    private var textView: NSTextView!
    private var placeholderView: NSView!
    private var placeholderBadgeView: NSView!
    private var placeholderIconView: NSImageView!
    private var placeholderTitle: NSTextField!
    private var placeholderSubtitle: NSTextField!
    private var jumpToLatestBtn: NSButton!
    
    private let amberAccent = NSColor(red: 0.98, green: 0.72, blue: 0.28, alpha: 1.0)
    private let greenPulse = NSColor(red: 0.24, green: 0.90, blue: 0.56, alpha: 1.0)
    private let cyanAccent = NSColor(red: 0.28, green: 0.84, blue: 0.98, alpha: 1.0)
    private let liveTextColor = NSColor(red: 0.76, green: 0.92, blue: 1.0, alpha: 1.0)
    private let origSubColor = NSColor(red: 0.62, green: 0.66, blue: 0.74, alpha: 0.88)
    private let liveOrigSubColor = NSColor(red: 0.56, green: 0.68, blue: 0.80, alpha: 0.78)
    
    private var isCallerHighlighted: Bool = false
    private var isMicHighlighted: Bool = false
    
    private var cachedFontSize: CGFloat = 0
    private var lastRenderedShowOriginal: Bool = AppSettings.shared.showOriginalText
    private var lastRenderedIsMicEnabled: Bool = AppSettings.shared.isMicEnabled
    private var cachedFinalizedAttrs: [NSAttributedString.Key: Any] = [:]
    private var cachedFinalizedTightAttrs: [NSAttributedString.Key: Any] = [:]
    private var cachedLiveAttrs: [NSAttributedString.Key: Any] = [:]
    private var cachedLiveTightAttrs: [NSAttributedString.Key: Any] = [:]
    private var cachedOrigAttrs: [NSAttributedString.Key: Any] = [:]
    private var cachedLiveOrigAttrs: [NSAttributedString.Key: Any] = [:]
    private var cachedCallerBadgeAttrs: [NSAttributedString.Key: Any] = [:]
    private var cachedCallerBadgeTightAttrs: [NSAttributedString.Key: Any] = [:]
    private var cachedYouBadgeAttrs: [NSAttributedString.Key: Any] = [:]
    private var cachedYouBadgeTightAttrs: [NSAttributedString.Key: Any] = [:]
    private var cachedUntranslatedBadgeAttrs: [NSAttributedString.Key: Any] = [:]
    
    
    public override func loadView() {
        let width: CGFloat = 560
        let height: CGFloat = 380
        
        containerView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        containerView.material = .hudWindow
        containerView.blendingMode = .behindWindow
        containerView.state = .active
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = 14
        containerView.layer?.masksToBounds = true
        containerView.layer?.borderWidth = 1.0
        containerView.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        
        setupHeader(width: width, height: height)
        setupLiveShareBanner(width: width, height: height)
        setupAlertBanner(width: width, height: height)
        setupCaptionsScrollView(width: width, height: height)
        setupPlaceholder(width: width, height: height)
        setupJumpToLatestButton(width: width)
        
        self.view = containerView
    }
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChanged),
            name: AppSettings.didChangeNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTranscriptEntriesUpdated),
            name: TranscriptManager.EntriesUpdatedNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePauseStateChanged),
            name: CaptionCoordinator.pauseStateDidChangeNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLiveShareStateChanged),
            name: LiveShareManager.stateDidChangeNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLiveShareURLUpdated),
            name: LiveShareManager.urlDidUpdateNotification,
            object: nil
        )
        
        updateCachedTextAttributes()
        loadExistingTranscript()
        updateLanguageButtons()
        updateMicButtonState()
        updateLiveShareButtonState()
        updatePinButtonState()
        updatePauseResumeButtonState()
        updatePlaceholderText()
        updateLayout()

        if TranscriptManager.shared.restoredFromAutosave {
            showAlertBanner(
                message: "Previous transcript restored. Clear it if this is a new call.",
                actionType: .clearRestoredTranscript
            )
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    
    private func setupHeader(width: CGFloat, height: CGFloat) {
        let headerH: CGFloat = 44
        headerView = NSView(frame: NSRect(x: 0, y: height - headerH, width: width, height: headerH))
        headerView.wantsLayer = true
        containerView.addSubview(headerView)
        
        let pillBg = NSColor.white.withAlphaComponent(0.06)
        let pillHover = NSColor.white.withAlphaComponent(0.12)
        let pillBorder = NSColor.white.withAlphaComponent(0.10).cgColor
        
        sourceLangBtn = HoverIconButton(frame: NSRect(x: 10, y: 8, width: 130, height: 28))
        sourceLangBtn.bezelStyle = .recessed
        sourceLangBtn.isBordered = false
        sourceLangBtn.wantsLayer = true
        sourceLangBtn.cornerRadiusValue = 14
        sourceLangBtn.restingBackgroundColor = pillBg
        sourceLangBtn.hoverBackgroundColor = pillHover
        sourceLangBtn.layer?.cornerRadius = 14
        sourceLangBtn.layer?.backgroundColor = pillBg.cgColor
        sourceLangBtn.layer?.borderWidth = 1.0
        sourceLangBtn.layer?.borderColor = pillBorder
        sourceLangBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        sourceLangBtn.contentTintColor = NSColor(white: 0.94, alpha: 1.0)
        sourceLangBtn.lineBreakMode = .byTruncatingTail
        sourceLangBtn.toolTip = L10n.tr("header.callerLanguage", "Caller Language")
        sourceLangBtn.setAccessibilityLabel(L10n.tr("header.callerLanguage", "Caller Language"))
        sourceLangBtn.target = self
        sourceLangBtn.action = #selector(showSourceLanguageMenu(_:))
        headerView.addSubview(sourceLangBtn)
        
        swapLangBtn = makeIconButton(
            iconName: "arrow.left.arrow.right",
            frame: NSRect(x: 142, y: 10, width: 24, height: 24),
            toolTip: L10n.tr("header.swapLanguages", "Swap Languages"),
            tintColor: NSColor(white: 0.60, alpha: 1.0),
            action: #selector(swapLanguagesAction),
            pointSize: 10.5
        )
        headerView.addSubview(swapLangBtn)
        
        targetLangBtn = HoverIconButton(frame: NSRect(x: 168, y: 8, width: 130, height: 28))
        targetLangBtn.bezelStyle = .recessed
        targetLangBtn.isBordered = false
        targetLangBtn.wantsLayer = true
        targetLangBtn.cornerRadiusValue = 14
        targetLangBtn.restingBackgroundColor = pillBg
        targetLangBtn.hoverBackgroundColor = pillHover
        targetLangBtn.layer?.cornerRadius = 14
        targetLangBtn.layer?.backgroundColor = pillBg.cgColor
        targetLangBtn.layer?.borderWidth = 1.0
        targetLangBtn.layer?.borderColor = pillBorder
        targetLangBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        targetLangBtn.contentTintColor = NSColor(white: 0.94, alpha: 1.0)
        targetLangBtn.lineBreakMode = .byTruncatingTail
        targetLangBtn.toolTip = L10n.tr("header.yourLanguage", "Your Language")
        targetLangBtn.setAccessibilityLabel(L10n.tr("header.yourLanguage", "Your Language"))
        targetLangBtn.target = self
        targetLangBtn.action = #selector(showTargetLanguageMenu(_:))
        headerView.addSubview(targetLangBtn)
        
        let rightEdge = width - 10
        var xOffset = rightEdge
        
        closeBtn = makeIconButton(iconName: "xmark", frame: NSRect(x: xOffset - 26, y: 9, width: 26, height: 26), toolTip: L10n.tr("header.close", "Close"), tintColor: NSColor.secondaryLabelColor, action: #selector(closePopoverAction))
        headerView.addSubview(closeBtn)
        xOffset -= 28
        
        settingsBtn = makeIconButton(iconName: "gearshape", frame: NSRect(x: xOffset - 26, y: 9, width: 26, height: 26), toolTip: L10n.tr("header.settings", "Settings"), tintColor: NSColor.secondaryLabelColor, action: #selector(openSettingsAction))
        headerView.addSubview(settingsBtn)
        xOffset -= 28
        
        pinBtn = makeIconButton(iconName: "pin", frame: NSRect(x: xOffset - 26, y: 9, width: 26, height: 26), toolTip: L10n.tr("header.pin", "Pin"), tintColor: NSColor.secondaryLabelColor, action: #selector(togglePinAction))
        headerView.addSubview(pinBtn)
        xOffset -= 28
        
        copyBtn = makeIconButton(iconName: "doc.on.doc", frame: NSRect(x: xOffset - 26, y: 9, width: 26, height: 26), toolTip: L10n.tr("header.copy", "Copy"), tintColor: NSColor.secondaryLabelColor, action: #selector(copyTranscriptAction))
        headerView.addSubview(copyBtn)
        xOffset -= 28
        
        clearBtn = makeIconButton(iconName: "trash", frame: NSRect(x: xOffset - 26, y: 9, width: 26, height: 26), toolTip: L10n.tr("header.clear", "Clear"), tintColor: NSColor.secondaryLabelColor, action: #selector(clearCaptionsAction))
        headerView.addSubview(clearBtn)
        xOffset -= 30
        
        let groupSep = NSView(frame: NSRect(x: xOffset - 1, y: 14, width: 1, height: 16))
        groupSep.wantsLayer = true
        groupSep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        headerView.addSubview(groupSep)
        xOffset -= 7
        
        let isPaused = CaptionCoordinator.shared.isPaused
        let pauseIcon = isPaused ? "play.fill" : "pause.fill"
        let pauseTip = isPaused ? L10n.tr("header.resume", "Resume") : L10n.tr("header.pause", "Pause")
        let pauseColor = isPaused ? amberAccent : NSColor.secondaryLabelColor
        pauseResumeBtn = makeIconButton(iconName: pauseIcon, frame: NSRect(x: xOffset - 26, y: 9, width: 26, height: 26), toolTip: pauseTip, tintColor: pauseColor, action: #selector(togglePauseResumeAction))
        headerView.addSubview(pauseResumeBtn)
        xOffset -= 28
        
        let isMic = AppSettings.shared.isMicEnabled
        let micIcon = isMic ? "mic.fill" : "mic.slash.fill"
        let micColor = isMic ? cyanAccent : NSColor.secondaryLabelColor
        micToggleBtn = makeIconButton(iconName: micIcon, frame: NSRect(x: xOffset - 26, y: 9, width: 26, height: 26), toolTip: L10n.tr("header.microphone", "Microphone"), tintColor: micColor, action: #selector(toggleMicAction))
        headerView.addSubview(micToggleBtn)
        xOffset -= 28
        
        let isSharing = LiveShareManager.shared.isSharing
        let shareColor = isSharing ? greenPulse : NSColor.secondaryLabelColor
        liveShareBtn = makeIconButton(iconName: "link", frame: NSRect(x: xOffset - 26, y: 9, width: 26, height: 26), toolTip: L10n.tr("header.liveLink", "Live Link"), tintColor: shareColor, action: #selector(toggleLiveShareAction))
        headerView.addSubview(liveShareBtn)
        
        let divider = NSView(frame: NSRect(x: 10, y: 0, width: width - 20, height: 1))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        headerView.addSubview(divider)
    }
    
    private func makeIconButton(iconName: String, frame: NSRect, toolTip: String, tintColor: NSColor, action: Selector, pointSize: CGFloat = 12.5) -> HoverIconButton {
        let btn = HoverIconButton(frame: frame)
        btn.isBordered = false
        btn.bezelStyle = .regularSquare
        btn.imagePosition = .imageOnly
        btn.cornerRadiusValue = 6
        if let img = NSImage(systemSymbolName: iconName, accessibilityDescription: toolTip) {
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            btn.image = img.withSymbolConfiguration(config)
        }
        btn.contentTintColor = tintColor
        btn.target = self
        btn.action = action
        btn.toolTip = toolTip
        btn.setAccessibilityLabel(toolTip)
        return btn
    }
    
    @objc private func swapLanguagesAction() {
        clearAlertBanner()
        AppDelegate.shared.clearSystemAlertBanner()
        AppSettings.shared.swapLanguages()
    }
    
    
    private func setupLiveShareBanner(width: CGFloat, height: CGFloat) {
        let bannerH: CGFloat = 34
        let headerH: CGFloat = 44
        let bannerY = height - headerH - bannerH - 4
        
        liveShareBannerView = NSView(frame: NSRect(x: 10, y: bannerY, width: width - 20, height: bannerH))
        liveShareBannerView.wantsLayer = true
        liveShareBannerView.layer?.cornerRadius = 8
        liveShareBannerView.layer?.backgroundColor = NSColor(red: 0.05, green: 0.35, blue: 0.55, alpha: 0.25).cgColor
        liveShareBannerView.layer?.borderWidth = 1.0
        liveShareBannerView.layer?.borderColor = NSColor(red: 0.20, green: 0.70, blue: 1.0, alpha: 0.45).cgColor
        liveShareBannerView.isHidden = true
        
        liveShareIconView = NSImageView(frame: NSRect(x: 10, y: (bannerH - 16) / 2.0, width: 16, height: 16))
        if let icon = NSImage(systemSymbolName: "globe", accessibilityDescription: "Live Share") {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            liveShareIconView.image = icon.withSymbolConfiguration(config)
            liveShareIconView.contentTintColor = cyanAccent
        }
        liveShareBannerView.addSubview(liveShareIconView)
        
        liveShareLabel = NSTextField(labelWithString: "Live Link: Starting tunnel…")
        liveShareLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        liveShareLabel.textColor = NSColor.white
        liveShareLabel.lineBreakMode = .byTruncatingMiddle
        liveShareLabel.frame = NSRect(x: 32, y: (bannerH - 16) / 2.0, width: width - 20 - 180, height: 16)
        liveShareBannerView.addSubview(liveShareLabel)
        
        liveShareCopyBtn = NSButton(title: "Copy Link", target: self, action: #selector(copyLiveShareLinkAction))
        liveShareCopyBtn.bezelStyle = .recessed
        liveShareCopyBtn.isBordered = false
        liveShareCopyBtn.wantsLayer = true
        liveShareCopyBtn.layer?.cornerRadius = 6
        liveShareCopyBtn.layer?.backgroundColor = NSColor(red: 0.15, green: 0.60, blue: 0.90, alpha: 0.42).cgColor
        liveShareCopyBtn.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        liveShareCopyBtn.contentTintColor = .white
        liveShareCopyBtn.frame = NSRect(x: width - 20 - 136, y: (bannerH - 22) / 2.0, width: 76, height: 22)
        liveShareCopyBtn.setAccessibilityLabel("Copy Live Link")
        liveShareBannerView.addSubview(liveShareCopyBtn)
        
        liveShareStopBtn = NSButton(title: "Stop", target: self, action: #selector(stopLiveShareAction))
        liveShareStopBtn.bezelStyle = .recessed
        liveShareStopBtn.isBordered = false
        liveShareStopBtn.wantsLayer = true
        liveShareStopBtn.layer?.cornerRadius = 6
        liveShareStopBtn.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        liveShareStopBtn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        liveShareStopBtn.contentTintColor = NSColor(white: 0.85, alpha: 1.0)
        liveShareStopBtn.frame = NSRect(x: width - 20 - 54, y: (bannerH - 22) / 2.0, width: 46, height: 22)
        liveShareStopBtn.setAccessibilityLabel("Stop Live Link")
        liveShareBannerView.addSubview(liveShareStopBtn)
        
        containerView.addSubview(liveShareBannerView)
    }
    
    
    private func setupAlertBanner(width: CGFloat, height: CGFloat) {
        let bannerH: CGFloat = 34
        let headerH: CGFloat = 44
        let bannerY = height - headerH - bannerH - 4
        
        alertBannerView = NSView(frame: NSRect(x: 10, y: bannerY, width: width - 20, height: bannerH))
        alertBannerView.wantsLayer = true
        alertBannerView.layer?.cornerRadius = 8
        alertBannerView.layer?.backgroundColor = NSColor(red: 0.95, green: 0.35, blue: 0.15, alpha: 0.20).cgColor
        alertBannerView.layer?.borderWidth = 1.0
        alertBannerView.layer?.borderColor = NSColor(red: 0.98, green: 0.50, blue: 0.20, alpha: 0.50).cgColor
        alertBannerView.isHidden = true
        
        alertIconView = NSImageView(frame: NSRect(x: 10, y: (bannerH - 16) / 2.0, width: 16, height: 16))
        if let icon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning") {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            alertIconView.image = icon.withSymbolConfiguration(config)
            alertIconView.contentTintColor = NSColor(red: 1.0, green: 0.60, blue: 0.20, alpha: 1.0)
        }
        alertBannerView.addSubview(alertIconView)
        
        alertLabel = NSTextField(labelWithString: "")
        alertLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        alertLabel.textColor = NSColor(white: 0.95, alpha: 1.0)
        alertLabel.lineBreakMode = .byTruncatingTail
        alertLabel.frame = NSRect(x: 32, y: (bannerH - 16) / 2.0, width: width - 20 - 150, height: 16)
        alertBannerView.addSubview(alertLabel)
        
        alertActionBtn = NSButton(title: "Settings", target: self, action: #selector(alertActionClicked))
        if let extIcon = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil) {
            alertActionBtn.image = extIcon.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9.5, weight: .semibold))
            alertActionBtn.imagePosition = .imageTrailing
        }
        alertActionBtn.bezelStyle = .recessed
        alertActionBtn.isBordered = false
        alertActionBtn.wantsLayer = true
        alertActionBtn.layer?.cornerRadius = 6
        alertActionBtn.layer?.backgroundColor = NSColor(red: 1.0, green: 0.50, blue: 0.15, alpha: 0.40).cgColor
        alertActionBtn.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        alertActionBtn.contentTintColor = .white
        alertActionBtn.frame = NSRect(x: width - 20 - 108, y: (bannerH - 22) / 2.0, width: 80, height: 22)
        alertBannerView.addSubview(alertActionBtn)
        
        alertCloseBtn = makeIconButton(
            iconName: "xmark",
            frame: NSRect(x: width - 20 - 24, y: (bannerH - 16) / 2.0, width: 16, height: 16),
            toolTip: "Dismiss",
            tintColor: NSColor(white: 0.70, alpha: 1.0),
            action: #selector(dismissAlertBanner)
        )
        alertBannerView.addSubview(alertCloseBtn)
        
        containerView.addSubview(alertBannerView)
    }
    
    
    public func updateLayout() {
        guard isViewLoaded else { return }
        
        let width = containerView.bounds.width
        let height = containerView.bounds.height
        let headerH: CGFloat = 44
        let bannerH: CGFloat = 34
        let bottomPad: CGFloat = 10
        let bannerSpacing: CGFloat = 6
        
        var currentY = height - headerH - 6
        
        if !liveShareBannerView.isHidden {
            currentY -= bannerH
            liveShareBannerView.frame = NSRect(x: 10, y: currentY, width: width - 20, height: bannerH)
            currentY -= bannerSpacing
        }
        
        if !alertBannerView.isHidden {
            currentY -= bannerH
            alertBannerView.frame = NSRect(x: 10, y: currentY, width: width - 20, height: bannerH)
            currentY -= bannerSpacing
        }
        
        let scrollY = bottomPad
        let scrollH = max(80, currentY - scrollY)
        scrollView.frame = NSRect(x: 10, y: scrollY, width: width - 20, height: scrollH)
        
        placeholderView.frame = scrollView.frame
        let pW = placeholderView.bounds.width
        let pH = placeholderView.bounds.height
        let midY = round(pH / 2.0)
        placeholderBadgeView?.frame = NSRect(x: round((pW - 44) / 2.0), y: midY + 14, width: 44, height: 44)
        placeholderIconView?.frame = NSRect(x: 10, y: 10, width: 24, height: 24)
        placeholderTitle?.frame = NSRect(x: 24, y: midY - 14, width: pW - 48, height: 20)
        placeholderSubtitle?.frame = NSRect(x: 36, y: midY - 38, width: pW - 72, height: 20)
    }
    
    public func showAlertBanner(message: String, actionType: SystemAlertActionType) {
        loadViewIfNeeded()
        currentAlertActionType = actionType
        activeAlertMessage = message
        alertLabel.stringValue = message
        alertLabel.toolTip = message
        switch actionType {
        case .clearRestoredTranscript:
            alertActionBtn.title = "Clear"
        case .audioCapture, .screenRecording, .speechRecognition, .dictation, .translationSettings, .permissions, .none:
            alertActionBtn.title = "Settings"
        }
        alertBannerView.isHidden = false
        updateLayout()
        
        if paragraphs.isEmpty {
            updatePlaceholderText()
        }
    }
    
    public func clearAlertBanner() {
        currentAlertActionType = .none
        activeAlertMessage = nil
        guard isViewLoaded else { return }
        alertBannerView.isHidden = true
        updateLayout()
        
        if paragraphs.isEmpty {
            updatePlaceholderText()
        }
    }
    
    @objc private func dismissAlertBanner() {
        clearAlertBanner()
        AppDelegate.shared.clearSystemAlertBanner()
    }
    
    @objc private func alertActionClicked() {
        switch currentAlertActionType {
        case .clearRestoredTranscript:
            CaptionCoordinator.shared.clearTranscript()
            clearCaptionsUI()
        case .audioCapture, .screenRecording:
            PermissionHelper.shared.openAudioCaptureSettings()
        case .speechRecognition:
            PermissionHelper.shared.openSpeechRecognitionSettings()
        case .dictation:
            PermissionHelper.shared.openDictationSettings()
            AppDelegate.shared.openSettingsWindow(selectedTab: 0)
        case .translationSettings:
            PermissionHelper.shared.openTranslationSettings()
        case .permissions:
            AppDelegate.shared.openSettingsWindow(selectedTab: 2)
        case .none:
            AppDelegate.shared.openSettingsWindow(selectedTab: 0)
        }
    }
    
    
    public func showLiveShareBanner() {
        loadViewIfNeeded()
        liveShareBannerView.isHidden = false
        updateLiveShareBannerText()
        updateLiveShareButtonState()
        updateLayout()
    }
    
    public func hideLiveShareBanner() {
        guard isViewLoaded else { return }
        liveShareBannerView.isHidden = true
        updateLiveShareButtonState()
        updateLayout()
    }
    
    private func updateLiveShareBannerText() {
        guard isViewLoaded else { return }
        let manager = LiveShareManager.shared
        let viewers = manager.activeClientCount
        let viewerSuffix = viewers > 0 ? "  •  \(viewers) viewer\(viewers == 1 ? "" : "s")" : ""
        let external = AppSettings.shared.liveShareUseExternalTunnel

        if let publicURL = manager.publicShareURL {
            liveShareLabel.stringValue = "\(publicURL.host ?? "Live Link") • Live Link ready\(viewerSuffix)"
            liveShareLabel.toolTip = "Use Copy Link to share. The full URL contains a secret session token and decryption key."
            liveShareIconView.contentTintColor = greenPulse
            liveShareCopyBtn.isEnabled = true
            liveShareCopyBtn.title = "Copy Link"
        } else if let tunnelErr = manager.tunnelError {
            if let localURL = manager.localShareURL {
                liveShareLabel.stringValue = "\(localURL.host ?? "127.0.0.1") • Local only\(viewerSuffix)"
                liveShareLabel.toolTip = "\(tunnelErr)\nUse Copy Local to open/share the local link."
            } else {
                liveShareLabel.stringValue = tunnelErr
                liveShareLabel.toolTip = tunnelErr
            }
            liveShareIconView.contentTintColor = amberAccent
            liveShareCopyBtn.isEnabled = manager.localShareURL != nil
            liveShareCopyBtn.title = "Copy Local"
        } else if let localURL = manager.localShareURL {
            if external {
                liveShareLabel.stringValue = "Starting public tunnel… (\(localURL.host ?? "127.0.0.1"))\(viewerSuffix)"
                liveShareCopyBtn.isEnabled = false
                liveShareCopyBtn.title = "Copy Link"
            } else {
                liveShareLabel.stringValue = "\(localURL.host ?? "127.0.0.1") • Local only\(viewerSuffix)"
                liveShareCopyBtn.isEnabled = true
                liveShareCopyBtn.title = "Copy Local"
            }
            liveShareLabel.toolTip = "Use Copy Local to open/share the local link. The full URL contains the session key."
            liveShareIconView.contentTintColor = cyanAccent
        } else {
            liveShareLabel.stringValue = "Starting Live Link…"
            liveShareLabel.toolTip = nil
            liveShareIconView.contentTintColor = cyanAccent
            liveShareCopyBtn.isEnabled = false
            liveShareCopyBtn.title = "Copy Link"
        }
    }
    
    @objc public func toggleLiveShareAction() {
        if LiveShareManager.shared.isSharing {
            if liveShareBannerView.isHidden {
                showLiveShareBanner()
            } else {
                stopLiveShareAction()
            }
        } else {
            AppDelegate.shared.confirmAndStartLiveShare()
        }
    }
    
    @objc private func copyLiveShareLinkAction() {
        guard let url = LiveShareManager.shared.effectiveShareURL else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)
        
        let oldTitle = liveShareCopyBtn.title
        liveShareCopyBtn.title = "Copied"
        liveShareCopyBtn.contentTintColor = greenPulse
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.liveShareCopyBtn.title = oldTitle
            self?.liveShareCopyBtn.contentTintColor = .white
        }
    }
    
    @objc private func stopLiveShareAction() {
        LiveShareManager.shared.stopSharing()
        hideLiveShareBanner()
    }
    
    @objc private func handleLiveShareStateChanged() {
        updateLiveShareButtonState()
        if LiveShareManager.shared.isSharing {
            showLiveShareBanner()
        } else {
            hideLiveShareBanner()
        }
    }
    
    @objc private func handleLiveShareURLUpdated() {
        updateLiveShareBannerText()
    }
    
    private func updateLiveShareButtonState() {
        guard liveShareBtn != nil else { return }
        let isSharing = LiveShareManager.shared.isSharing
        liveShareBtn.contentTintColor = isSharing ? greenPulse : NSColor.secondaryLabelColor
        liveShareBtn.toolTip = L10n.tr("header.liveLink", "Live Link")
        liveShareBtn.setAccessibilityValue(isSharing ? "Active" : "Off")
    }
    
    
    @objc private func toggleMicAction() {
        if AppSettings.shared.isMicEnabled {
            AppSettings.shared.isMicEnabled = false
            updateMicButtonState()
            updatePlaceholderText()
        } else {
            if PermissionHelper.shared.hasMicrophoneAccess {
                AppSettings.shared.isMicEnabled = true
                updateMicButtonState()
                updatePlaceholderText()
            } else {
                PermissionHelper.shared.requestMicrophoneAccess { [weak self] granted in
                    if granted {
                        AppSettings.shared.isMicEnabled = true
                        self?.clearAlertBanner()
                    } else {
                        AppSettings.shared.isMicEnabled = false
                        self?.showAlertBanner(
                            message: "Microphone access required",
                            actionType: .permissions
                        )
                    }
                    self?.updateMicButtonState()
                    self?.updatePlaceholderText()
                }
            }
        }
    }
    
    private func updateMicButtonState() {
        guard micToggleBtn != nil else { return }
        let isMic = AppSettings.shared.isMicEnabled
        let iconName = isMic ? "mic.fill" : "mic.slash.fill"
        if let img = NSImage(systemSymbolName: iconName, accessibilityDescription: "Microphone") {
            micToggleBtn.image = img.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12.5, weight: .medium))
        }
        micToggleBtn.contentTintColor = isMic ? cyanAccent : NSColor.secondaryLabelColor
        micToggleBtn.toolTip = L10n.tr("header.microphone", "Microphone")
        micToggleBtn.setAccessibilityValue(isMic ? "On" : "Muted")
        if !isMic && isMicHighlighted {
            isMicHighlighted = false
            targetLangBtn?.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        }
    }
    
    
    private func setupCaptionsScrollView(width: CGFloat, height: CGFloat) {
        let headerH: CGFloat = 44
        let bottomPad: CGFloat = 10
        let scrollY = bottomPad
        let scrollH = height - headerH - bottomPad - 6
        let scrollW = width - 20
        
        scrollView = NSScrollView(frame: NSRect(x: 10, y: scrollY, width: scrollW, height: scrollH))
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 11
        scrollView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        scrollView.layer?.borderWidth = 1.0
        scrollView.layer?.borderColor = NSColor.white.withAlphaComponent(0.07).cgColor
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        
        let contentSize = scrollView.contentSize
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height))
        textView.minSize = NSSize(width: 0.0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 18, height: 16)
        
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = .white
        textView.font = NSFont.systemFont(ofSize: AppSettings.shared.captionFontSize, weight: .regular)
        textView.setAccessibilityLabel("Live Call Captions")
        
        scrollView.documentView = textView
        containerView.addSubview(scrollView)
        
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScrollPositionChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleUserLiveScroll),
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )
    }
    
    private func setupPlaceholder(width: CGFloat, height: CGFloat) {
        let headerH: CGFloat = 44
        let cardH = height - headerH - 16
        
        placeholderView = NSView(frame: NSRect(x: 10, y: 10, width: width - 20, height: cardH))
        placeholderView.wantsLayer = true
        
        placeholderBadgeView = NSView(frame: NSRect(x: (width - 20 - 44) / 2.0, y: cardH / 2.0 + 14, width: 44, height: 44))
        placeholderBadgeView.wantsLayer = true
        placeholderBadgeView.layer?.cornerRadius = 22
        placeholderBadgeView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        placeholderBadgeView.layer?.borderWidth = 1.0
        placeholderBadgeView.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        placeholderView.addSubview(placeholderBadgeView)
        
        placeholderIconView = NSImageView(frame: NSRect(x: 10, y: 10, width: 24, height: 24))
        if let icon = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            placeholderIconView.image = icon.withSymbolConfiguration(config)
            placeholderIconView.contentTintColor = NSColor(white: 0.72, alpha: 1.0)
        }
        placeholderBadgeView.addSubview(placeholderIconView)
        
        placeholderTitle = NSTextField(labelWithString: "")
        placeholderTitle.font = NSFont.systemFont(ofSize: 13.5, weight: .medium)
        placeholderTitle.textColor = NSColor(white: 0.88, alpha: 1.0)
        placeholderTitle.alignment = .center
        placeholderTitle.frame = NSRect(x: 24, y: cardH / 2.0 - 14, width: width - 68, height: 20)
        placeholderView.addSubview(placeholderTitle)
        
        placeholderSubtitle = NSTextField(labelWithString: "")
        placeholderSubtitle.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        placeholderSubtitle.textColor = NSColor(white: 0.50, alpha: 1.0)
        placeholderSubtitle.alignment = .center
        placeholderSubtitle.cell?.wraps = true
        placeholderSubtitle.cell?.lineBreakMode = .byWordWrapping
        placeholderSubtitle.frame = NSRect(x: 36, y: cardH / 2.0 - 38, width: width - 92, height: 20)
        placeholderView.addSubview(placeholderSubtitle)
        
        containerView.addSubview(placeholderView)
    }
    
    private func setupJumpToLatestButton(width: CGFloat) {
        let btnW: CGFloat = 92
        let btnH: CGFloat = 26
        let btnX = (width - btnW) / 2.0
        let btnY: CGFloat = 20
        
        jumpToLatestBtn = NSButton(frame: NSRect(x: btnX, y: btnY, width: btnW, height: btnH))
        jumpToLatestBtn.title = "Latest"
        if let downIcon = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil) {
            jumpToLatestBtn.image = downIcon.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .bold))
            jumpToLatestBtn.imagePosition = .imageLeading
        }
        jumpToLatestBtn.bezelStyle = .recessed
        jumpToLatestBtn.isBordered = false
        jumpToLatestBtn.wantsLayer = true
        jumpToLatestBtn.layer?.cornerRadius = 13
        jumpToLatestBtn.layer?.backgroundColor = NSColor(red: 0.12, green: 0.15, blue: 0.22, alpha: 0.95).cgColor
        jumpToLatestBtn.layer?.borderWidth = 1.0
        jumpToLatestBtn.layer?.borderColor = cyanAccent.withAlphaComponent(0.35).cgColor
        jumpToLatestBtn.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        jumpToLatestBtn.contentTintColor = .white
        jumpToLatestBtn.target = self
        jumpToLatestBtn.action = #selector(jumpToLatestAction)
        jumpToLatestBtn.setAccessibilityLabel("Jump to latest caption")
        jumpToLatestBtn.isHidden = true
        containerView.addSubview(jumpToLatestBtn)
    }
    
    
    public func updateCaption(
        utteranceID: UUID = UUID(),
        speaker: String = "Caller",
        translated: String,
        original: String,
        sourceLangCode: String = "es",
        targetLangCode: String = "en",
        isFinal: Bool,
        isUntranslated: Bool = false
    ) {
        if Thread.isMainThread {
            self.performUpdateCaption(
                utteranceID: utteranceID,
                speaker: speaker,
                translated: translated,
                original: original,
                sourceLangCode: sourceLangCode,
                targetLangCode: targetLangCode,
                isFinal: isFinal,
                isUntranslated: isUntranslated
            )
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.performUpdateCaption(
                    utteranceID: utteranceID,
                    speaker: speaker,
                    translated: translated,
                    original: original,
                    sourceLangCode: sourceLangCode,
                    targetLangCode: targetLangCode,
                    isFinal: isFinal,
                    isUntranslated: isUntranslated
                )
            }
        }
    }
    
    private func performUpdateCaption(
        utteranceID: UUID,
        speaker: String,
        translated: String,
        original: String,
        sourceLangCode: String,
        targetLangCode: String,
        isFinal: Bool,
        isUntranslated: Bool
    ) {
        loadViewIfNeeded()
        let cleanTrans = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanOrig = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTrans.isEmpty || !cleanOrig.isEmpty else { return }

        let primaryTrans = cleanTrans.isEmpty ? cleanOrig : cleanTrans
        let isCaller = (speaker.lowercased() == "caller")

        if !self.placeholderView.isHidden {
            self.placeholderView.isHidden = true
        }

        if isFinal {
            if isCaller, liveCallerUtterance?.id == utteranceID {
                liveCallerUtterance = nil
            } else if !isCaller, liveMicUtterance?.id == utteranceID {
                liveMicUtterance = nil
            }
            commitFinalizedSentence(
                utteranceID: utteranceID,
                speaker: speaker,
                primaryTrans: primaryTrans,
                cleanOrig: cleanOrig,
                sourceLangCode: sourceLangCode,
                targetLangCode: targetLangCode,
                isUntranslated: isUntranslated
            )
        } else {
            let utterance = LiveUtterance(
                id: utteranceID,
                speaker: speaker,
                translated: primaryTrans,
                original: cleanOrig,
                sourceLangCode: sourceLangCode,
                targetLangCode: targetLangCode,
                isUntranslated: isUntranslated
            )
            if isCaller {
                liveCallerUtterance = utterance
            } else {
                liveMicUtterance = utterance
            }
            renderLiveSection()
        }
    }

    private func commitFinalizedSentence(
        utteranceID: UUID,
        speaker: String,
        primaryTrans: String,
        cleanOrig: String,
        sourceLangCode: String,
        targetLangCode: String,
        isUntranslated: Bool
    ) {
        guard let storage = textView.textStorage else { return }
        placeholderView?.isHidden = true

        var updatedInPlace = false
        for bIdx in paragraphs.indices.reversed() {
            if let sIdx = paragraphs[bIdx].sentences.firstIndex(where: { $0.id == utteranceID }) {
                paragraphs[bIdx].sentences[sIdx] = SentenceItem(
                    id: utteranceID,
                    translated: primaryTrans,
                    original: cleanOrig,
                    isUntranslated: isUntranslated
                )
                updatedInPlace = true
                break
            }
        }

        var didFastIncrementalAppend = false

        if !updatedInPlace {
            let newWordCount = primaryTrans.split(whereSeparator: { $0.isWhitespace }).count
            let now = Date()
            let timeSinceLast = now.timeIntervalSince(lastFinalizedTime)

            let canAppendToCurrent = (
                !paragraphs.isEmpty &&
                lastFinalizedSpeaker == speaker &&
                paragraphs[paragraphs.count - 1].sourceLangCode == sourceLangCode &&
                paragraphs[paragraphs.count - 1].targetLangCode == targetLangCode &&
                timeSinceLast < 4.0 &&
                currentParagraphSentenceCount < 3 &&
                (currentParagraphWordCount + newWordCount) <= 45
            )

            if canAppendToCurrent {
                var lastBlock = paragraphs[paragraphs.count - 1]
                lastBlock.sentences.append(SentenceItem(
                    id: utteranceID,
                    translated: primaryTrans,
                    original: cleanOrig,
                    isUntranslated: isUntranslated
                ))
                paragraphs[paragraphs.count - 1] = lastBlock
                currentParagraphSentenceCount += 1
                currentParagraphWordCount += newWordCount
            } else {
                let newBlock = ParagraphBlock(
                    speaker: speaker,
                    sourceLangCode: sourceLangCode,
                    targetLangCode: targetLangCode,
                    sentences: [SentenceItem(
                        id: utteranceID,
                        translated: primaryTrans,
                        original: cleanOrig,
                        isUntranslated: isUntranslated
                    )]
                )
                paragraphs.append(newBlock)
                lastFinalizedSpeaker = speaker
                currentParagraphSentenceCount = 1
                currentParagraphWordCount = newWordCount

                if paragraphs.count <= 60 {
                    let blockAttr = NSMutableAttributedString()
                    if finalizedCharLength > 0 {
                        blockAttr.append(NSAttributedString(string: "\n", attributes: cachedFinalizedAttrs))
                    }
                    blockAttr.append(buildAttributedParagraph(block: newBlock, isLive: false))

                    let totalLen = storage.length
                    let safeFinalizedLen = min(finalizedCharLength, totalLen)
                    let liveRange = NSRange(location: safeFinalizedLen, length: totalLen - safeFinalizedLen)

                    isProgrammaticScrollOrLayout = true
                    storage.beginEditing()
                    storage.replaceCharacters(in: liveRange, with: blockAttr)
                    storage.endEditing()
                    isProgrammaticScrollOrLayout = false

                    finalizedCharLength = storage.length
                    didFastIncrementalAppend = true
                }
            }

            lastFinalizedTime = now

            if paragraphs.count > 60 {
                paragraphs.removeFirst(paragraphs.count - 50)
            }
        }

        if !didFastIncrementalAppend {
            let finalizedAttr = buildFullAttributedDocument()
            isProgrammaticScrollOrLayout = true
            storage.beginEditing()
            storage.setAttributedString(finalizedAttr)
            storage.endEditing()
            isProgrammaticScrollOrLayout = false
            finalizedCharLength = storage.length
        }

        renderLiveSection()
    }
    
    private func renderLiveSection() {
        guard let storage = textView.textStorage else { return }
        placeholderView?.isHidden = true

        var liveBlocks: [ParagraphBlock] = []
        if let caller = liveCallerUtterance {
            liveBlocks.append(ParagraphBlock(
                speaker: caller.speaker,
                sourceLangCode: caller.sourceLangCode,
                targetLangCode: caller.targetLangCode,
                sentences: [SentenceItem(
                    id: caller.id,
                    translated: caller.translated,
                    original: caller.original,
                    isUntranslated: caller.isUntranslated
                )]
            ))
        }
        if let mic = liveMicUtterance {
            liveBlocks.append(ParagraphBlock(
                speaker: mic.speaker,
                sourceLangCode: mic.sourceLangCode,
                targetLangCode: mic.targetLangCode,
                sentences: [SentenceItem(
                    id: mic.id,
                    translated: mic.translated,
                    original: mic.original,
                    isUntranslated: mic.isUntranslated
                )]
            ))
        }

        let totalLen = storage.length
        let safeFinalizedLen = min(finalizedCharLength, totalLen)
        let liveLen = totalLen - safeFinalizedLen
        let liveRange = NSRange(location: safeFinalizedLen, length: liveLen)

        if liveBlocks.isEmpty {
            if liveLen > 0 {
                isProgrammaticScrollOrLayout = true
                storage.beginEditing()
                storage.replaceCharacters(in: liveRange, with: "")
                storage.endEditing()
                isProgrammaticScrollOrLayout = false
            }
            scrollToBottomSmooth()
            return
        }

        let fullLiveAttr = NSMutableAttributedString()
        if finalizedCharLength > 0 {
            fullLiveAttr.append(NSAttributedString(string: "\n", attributes: cachedLiveAttrs))
        }
        for (idx, block) in liveBlocks.enumerated() {
            if idx > 0 {
                fullLiveAttr.append(NSAttributedString(string: "\n", attributes: cachedLiveAttrs))
            }
            fullLiveAttr.append(buildAttributedParagraph(block: block, isLive: true))
        }

        isProgrammaticScrollOrLayout = true
        storage.beginEditing()
        storage.replaceCharacters(in: liveRange, with: fullLiveAttr)
        storage.endEditing()
        isProgrammaticScrollOrLayout = false

        scrollToBottomSmooth()
    }
    
    private func updateCachedTextAttributes() {
        let fontSize = AppSettings.shared.captionFontSize
        cachedFontSize = fontSize
        let primaryKern: CGFloat = fontSize >= 18 ? -0.24 : -0.16
        let blockSpacing = round(fontSize * 0.72)

        let normalStyle = NSMutableParagraphStyle()
        normalStyle.lineHeightMultiple = 1.26
        normalStyle.paragraphSpacing = blockSpacing
        normalStyle.baseWritingDirection = .natural
        normalStyle.alignment = .natural

        let tightStyle = NSMutableParagraphStyle()
        tightStyle.lineHeightMultiple = 1.26
        tightStyle.paragraphSpacing = 3.0
        tightStyle.baseWritingDirection = .natural
        tightStyle.alignment = .natural

        let subStyle = NSMutableParagraphStyle()
        subStyle.lineHeightMultiple = 1.20
        subStyle.paragraphSpacing = blockSpacing
        subStyle.baseWritingDirection = .natural
        subStyle.alignment = .natural

        let primaryFont = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        let subFont = NSFont.systemFont(ofSize: max(11.5, round(fontSize * 0.82)), weight: .regular)
        let badgeFont = NSFont.systemFont(ofSize: max(10.0, round(fontSize * 0.68)), weight: .semibold)

        let callerColor = NSColor(red: 0.24, green: 0.90, blue: 0.56, alpha: 1.0)
        let youColor = NSColor(red: 0.28, green: 0.84, blue: 0.98, alpha: 1.0)

        cachedFinalizedAttrs = [
            .font: primaryFont,
            .foregroundColor: NSColor(white: 0.96, alpha: 1.0),
            .kern: primaryKern,
            .paragraphStyle: normalStyle
        ]
        cachedFinalizedTightAttrs = [
            .font: primaryFont,
            .foregroundColor: NSColor(white: 0.96, alpha: 1.0),
            .kern: primaryKern,
            .paragraphStyle: tightStyle
        ]
        cachedLiveAttrs = [
            .font: primaryFont,
            .foregroundColor: liveTextColor,
            .kern: primaryKern,
            .paragraphStyle: normalStyle
        ]
        cachedLiveTightAttrs = [
            .font: primaryFont,
            .foregroundColor: liveTextColor,
            .kern: primaryKern,
            .paragraphStyle: tightStyle
        ]
        cachedOrigAttrs = [
            .font: subFont,
            .foregroundColor: origSubColor,
            .kern: -0.08,
            .paragraphStyle: subStyle
        ]
        cachedLiveOrigAttrs = [
            .font: subFont,
            .foregroundColor: liveOrigSubColor,
            .kern: -0.08,
            .paragraphStyle: subStyle
        ]
        cachedCallerBadgeAttrs = [
            .font: badgeFont,
            .foregroundColor: callerColor,
            .kern: 0.6,
            .paragraphStyle: normalStyle
        ]
        cachedCallerBadgeTightAttrs = [
            .font: badgeFont,
            .foregroundColor: callerColor,
            .kern: 0.6,
            .paragraphStyle: tightStyle
        ]
        cachedYouBadgeAttrs = [
            .font: badgeFont,
            .foregroundColor: youColor,
            .kern: 0.6,
            .paragraphStyle: normalStyle
        ]
        cachedYouBadgeTightAttrs = [
            .font: badgeFont,
            .foregroundColor: youColor,
            .kern: 0.6,
            .paragraphStyle: tightStyle
        ]
        cachedUntranslatedBadgeAttrs = [
            .font: badgeFont,
            .foregroundColor: amberAccent,
            .kern: 0.4,
            .paragraphStyle: tightStyle
        ]
    }

    private func rerenderCaptionsPreservingLiveState() {
        guard isViewLoaded, let storage = textView.textStorage else { return }
        updateCachedTextAttributes()
        lastRenderedShowOriginal = AppSettings.shared.showOriginalText
        lastRenderedIsMicEnabled = AppSettings.shared.isMicEnabled
        textView.font = NSFont.systemFont(ofSize: cachedFontSize, weight: .regular)

        isProgrammaticScrollOrLayout = true
        if !paragraphs.isEmpty {
            let attr = buildFullAttributedDocument()
            storage.beginEditing()
            storage.setAttributedString(attr)
            storage.endEditing()
            finalizedCharLength = storage.length
        } else {
            storage.beginEditing()
            storage.setAttributedString(NSAttributedString())
            storage.endEditing()
            finalizedCharLength = 0
        }
        isProgrammaticScrollOrLayout = false
        renderLiveSection()
    }

    public func buildAttributedParagraph(block: ParagraphBlock, isLive: Bool) -> NSAttributedString {
        if cachedFinalizedAttrs.isEmpty || cachedFontSize != AppSettings.shared.captionFontSize {
            updateCachedTextAttributes()
        }
        let result = NSMutableAttributedString()

        let transText = block.sentences.map(\.translated).joined(separator: " ")
        let origText = block.sentences.map(\.original).filter { !$0.isEmpty }.joined(separator: " ")
        let hasUntranslated = block.sentences.contains(where: \.isUntranslated)
        let showOriginal = AppSettings.shared.showOriginalText
        let isMicEnabled = AppSettings.shared.isMicEnabled
        let isCaller = (block.speaker.lowercased() == "caller")

        let primaryText = isCaller ? (hasUntranslated ? origText : transText) : (origText.isEmpty ? transText : origText)
        let secondaryText = isCaller ? origText : transText
        let primaryLangCode = isCaller ? (hasUntranslated ? block.sourceLangCode : block.targetLangCode) : block.sourceLangCode
        let secondaryLangCode = isCaller ? block.sourceLangCode : block.targetLangCode
        let hasSecondary = showOriginal
            && !secondaryText.isEmpty
            && secondaryText.lowercased() != primaryText.lowercased()

        let isPrimaryRTL = SupportedLanguages.isRTL(languageCode: primaryLangCode)
        let isSecondaryRTL = SupportedLanguages.isRTL(languageCode: secondaryLangCode)

        var primaryLineAttrs = isLive
            ? (hasSecondary ? cachedLiveTightAttrs : cachedLiveAttrs)
            : (hasSecondary ? cachedFinalizedTightAttrs : cachedFinalizedAttrs)

        if let baseStyle = (primaryLineAttrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
            baseStyle.baseWritingDirection = isPrimaryRTL ? .rightToLeft : .leftToRight
            baseStyle.alignment = .natural
            primaryLineAttrs[.paragraphStyle] = baseStyle
        }

        if isMicEnabled || hasUntranslated {
            var badgeAttrs: [NSAttributedString.Key: Any]
            if isCaller {
                badgeAttrs = hasSecondary ? cachedCallerBadgeTightAttrs : cachedCallerBadgeAttrs
            } else {
                badgeAttrs = hasSecondary ? cachedYouBadgeTightAttrs : cachedYouBadgeAttrs
            }
            if let badgeStyle = (badgeAttrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
                badgeStyle.baseWritingDirection = isPrimaryRTL ? .rightToLeft : .leftToRight
                badgeStyle.alignment = .natural
                badgeAttrs[.paragraphStyle] = badgeStyle
            }

            if isMicEnabled {
                let speakerBadge = isCaller ? "\u{2066}CALLER\u{2069}  " : "\u{2066}YOU\u{2069}  "
                result.append(NSAttributedString(string: speakerBadge, attributes: badgeAttrs))
            }

            if hasUntranslated {
                var untranslatedAttrs = cachedUntranslatedBadgeAttrs
                untranslatedAttrs[.paragraphStyle] = primaryLineAttrs[.paragraphStyle]
                let untranslatedLabel = L10n.tr("caption.untranslated", "Untranslated").uppercased()
                result.append(NSAttributedString(string: "\u{2066}[\(untranslatedLabel)]\u{2069}  ", attributes: untranslatedAttrs))
            }
        }

        result.append(NSAttributedString(string: "\u{2068}\(primaryText)\u{2069}", attributes: primaryLineAttrs))

        if hasSecondary {
            var secondaryAttrs = isLive ? cachedLiveOrigAttrs : cachedOrigAttrs
            if let secondaryStyle = (secondaryAttrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
                secondaryStyle.baseWritingDirection = isSecondaryRTL ? .rightToLeft : .leftToRight
                secondaryStyle.alignment = .natural
                secondaryAttrs[.paragraphStyle] = secondaryStyle
            }
            result.append(NSAttributedString(string: "\n\u{2068}\(secondaryText)\u{2069}", attributes: secondaryAttrs))
        }
        return result
    }

    private func buildFullAttributedDocument() -> NSAttributedString {
        if cachedFinalizedAttrs.isEmpty || cachedFontSize != AppSettings.shared.captionFontSize {
            updateCachedTextAttributes()
        }
        let fullAttr = NSMutableAttributedString()
        for (idx, p) in paragraphs.enumerated() {
            if idx > 0 {
                fullAttr.append(NSAttributedString(string: "\n", attributes: cachedFinalizedAttrs))
            }
            fullAttr.append(buildAttributedParagraph(block: p, isLive: false))
        }
        return fullAttr
    }

    public func updateAudioLevels(callerLevel: Float, micLevel: Float) {
        guard isViewLoaded else { return }

        let callerActive = callerLevel > 0.035
        if callerActive != isCallerHighlighted {
            isCallerHighlighted = callerActive
            sourceLangBtn?.layer?.borderColor = callerActive
                ? greenPulse.withAlphaComponent(0.60).cgColor
                : NSColor.white.withAlphaComponent(0.10).cgColor
        }

        guard AppSettings.shared.isMicEnabled else { return }
        let micActive = micLevel > 0.035
        if micActive != isMicHighlighted {
            isMicHighlighted = micActive
            micToggleBtn?.contentTintColor = micActive
                ? NSColor(red: 0.42, green: 0.96, blue: 1.0, alpha: 1.0)
                : cyanAccent
            targetLangBtn?.layer?.borderColor = micActive
                ? cyanAccent.withAlphaComponent(0.60).cgColor
                : NSColor.white.withAlphaComponent(0.10).cgColor
        }
    }
    
    @objc private func handleScrollPositionChanged() {
        guard !isProgrammaticScrollOrLayout else { return }
        guard let docView = scrollView.documentView else { return }
        let visibleRect = scrollView.contentView.bounds
        let docHeight = docView.bounds.height
        let isAtBottom = (visibleRect.maxY >= docHeight - 36.0) || (docHeight <= visibleRect.height)
        
        if isAtBottom {
            isUserScrolledUp = false
            jumpToLatestBtn.isHidden = true
        }
    }

    @objc private func handleUserLiveScroll() {
        guard let docView = scrollView.documentView else { return }
        let visibleRect = scrollView.contentView.bounds
        let docHeight = docView.bounds.height
        let isAtBottom = (visibleRect.maxY >= docHeight - 36.0) || (docHeight <= visibleRect.height)

        if isAtBottom {
            isUserScrolledUp = false
            jumpToLatestBtn.isHidden = true
        } else {
            isUserScrolledUp = true
            jumpToLatestBtn.isHidden = false
        }
    }
    
    private func scrollToBottomSmooth() {
        guard !isUserScrolledUp else { return }
        guard let docView = scrollView.documentView else { return }

        isProgrammaticScrollOrLayout = true
        defer { isProgrammaticScrollOrLayout = false }

        if let lm = textView.layoutManager, let tc = textView.textContainer {
            lm.ensureLayout(for: tc)
        }
        textView.layoutSubtreeIfNeeded()

        let docHeight = docView.bounds.height
        let clipHeight = scrollView.contentView.bounds.height
        if docHeight > clipHeight {
            let targetY = max(0, docHeight - clipHeight)
            if abs(scrollView.contentView.bounds.origin.y - targetY) > 0.5 {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }
    
    @objc private func jumpToLatestAction() {
        isUserScrolledUp = false
        jumpToLatestBtn.isHidden = true
        scrollToBottomSmooth()
    }
    
    private func updateLanguageButtons() {
        let foreign = AppSettings.shared.foreignLanguageItem
        sourceLangBtn.title = "\(foreign.flag) \(foreign.name) ▾"
        sourceLangBtn.setAccessibilityValue(foreign.name)

        let useCustomTarget = !AppSettings.shared.isMicEnabled && !AppSettings.shared.subtitleFollowsMainLanguage
        if useCustomTarget {
            let target = AppSettings.shared.targetLanguageItem
            targetLangBtn.title = "\(target.flag) \(target.name) ▾"
            targetLangBtn.setAccessibilityValue(target.name)
            let tip = L10n.tr("settings.subtitleLanguage", "Subtitle Language")
            targetLangBtn.toolTip = tip
            targetLangBtn.setAccessibilityLabel(tip)
        } else {
            let main = AppSettings.shared.mainLanguageItem
            targetLangBtn.title = "\(main.flag) \(main.name) ▾"
            targetLangBtn.setAccessibilityValue(main.name)
            let tip = L10n.tr("header.yourLanguage", "Your Language")
            targetLangBtn.toolTip = tip
            targetLangBtn.setAccessibilityLabel(tip)
        }
        
        let swapIcon = AppSettings.shared.isMicEnabled ? "arrow.left.arrow.right" : "arrow.right"
        if let img = NSImage(systemSymbolName: swapIcon, accessibilityDescription: "Swap Languages") {
            swapLangBtn.image = img.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold))
        }
    }
    
    private func updatePinButtonState() {
        let isPinned = AppSettings.shared.isPinned
        pinBtn.contentTintColor = isPinned ? amberAccent : NSColor.secondaryLabelColor
        pinBtn.toolTip = isPinned ? L10n.tr("header.unpin", "Unpin") : L10n.tr("header.pin", "Pin")
        pinBtn.setAccessibilityValue(isPinned ? "Pinned" : "Unpinned")
    }
    
    private func updatePlaceholderText() {
        if !paragraphs.isEmpty || liveCallerUtterance != nil || liveMicUtterance != nil {
            placeholderView.isHidden = true
            return
        }
        if let alertMsg = activeAlertMessage {
            placeholderTitle.stringValue = L10n.tr("status.setupRequired", "Setup Required")
            placeholderTitle.textColor = NSColor(red: 0.98, green: 0.64, blue: 0.24, alpha: 1.0)
            placeholderSubtitle.stringValue = alertMsg
            if let icon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil) {
                placeholderIconView.image = icon.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .regular))
                placeholderIconView.contentTintColor = NSColor(red: 0.98, green: 0.64, blue: 0.24, alpha: 1.0)
            }
            placeholderView.isHidden = false
            return
        }
        if CaptionCoordinator.shared.isPaused {
            placeholderTitle.stringValue = L10n.tr("status.paused", "Paused")
            placeholderTitle.textColor = NSColor(white: 0.85, alpha: 1.0)
            placeholderSubtitle.stringValue = ""
            if let icon = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil) {
                placeholderIconView.image = icon.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .regular))
                placeholderIconView.contentTintColor = amberAccent
            }
            placeholderView.isHidden = false
            return
        }
        if let icon = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) {
            placeholderIconView.image = icon.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .regular))
            placeholderIconView.contentTintColor = NSColor(white: 0.72, alpha: 1.0)
        }
        placeholderTitle.textColor = NSColor(white: 0.88, alpha: 1.0)
        let foreign = AppSettings.shared.foreignLanguageItem
        let target = AppSettings.shared.targetLanguageItem
        let main = AppSettings.shared.mainLanguageItem
        placeholderTitle.stringValue = L10n.tr("status.listening", "Listening")
        if AppSettings.shared.isMicEnabled {
            placeholderSubtitle.stringValue = "\(foreign.name) ⇄ \(main.name)"
        } else if foreign.code == target.code {
            placeholderSubtitle.stringValue = foreign.name
        } else {
            placeholderSubtitle.stringValue = "\(foreign.name) → \(target.name)"
        }
        placeholderView.isHidden = false
    }
    
    private func loadExistingTranscript() {
        let existing = TranscriptManager.shared.entries
        guard !existing.isEmpty else {
            clearCaptionsUI()
            return
        }
        
        paragraphs.removeAll()
        
        var lastSpeaker: String? = nil
        var lastTime = Date.distantPast
        var currentSentences: Int = 0
        var currentWords: Int = 0
        
        let settings = AppSettings.shared
        let foreignCode = settings.foreignLanguageCode.lowercased()
        let mainCode = settings.mainLanguageCode.lowercased()
        let targetCode = settings.targetLanguageCode.lowercased()
        
        for e in existing {
            let cleanTrans = e.translated.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanOrig = e.original.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanTrans.isEmpty || !cleanOrig.isEmpty else { continue }
            let primary = cleanTrans.isEmpty ? cleanOrig : cleanTrans
            let newWordCount = primary.split(whereSeparator: { $0.isWhitespace }).count
            let isCaller = (e.speaker.lowercased() == "caller")
            let entrySourceCode = (e.sourceLangCode ?? (isCaller ? foreignCode : mainCode)).lowercased()
            let entryTargetCode = (e.targetLangCode ?? (isCaller ? targetCode : foreignCode)).lowercased()
            
            let canMerge = (
                !paragraphs.isEmpty &&
                lastSpeaker == e.speaker &&
                paragraphs[paragraphs.count - 1].sourceLangCode == entrySourceCode &&
                paragraphs[paragraphs.count - 1].targetLangCode == entryTargetCode &&
                e.timestamp.timeIntervalSince(lastTime) < 4.0 &&
                currentSentences < 3 &&
                (currentWords + newWordCount) <= 45
            )
            
            if canMerge {
                var lastP = paragraphs[paragraphs.count - 1]
                lastP.sentences.append(SentenceItem(id: e.utteranceID, translated: primary, original: cleanOrig, isUntranslated: e.isUntranslated))
                paragraphs[paragraphs.count - 1] = lastP
                currentSentences += 1
                currentWords += newWordCount
            } else {
                let block = ParagraphBlock(
                    speaker: e.speaker,
                    sourceLangCode: entrySourceCode,
                    targetLangCode: entryTargetCode,
                    sentences: [SentenceItem(id: e.utteranceID, translated: primary, original: cleanOrig, isUntranslated: e.isUntranslated)]
                )
                paragraphs.append(block)
                lastSpeaker = e.speaker
                currentSentences = 1
                currentWords = newWordCount
            }
            lastTime = e.timestamp
        }
        lastFinalizedSpeaker = lastSpeaker
        lastFinalizedTime = lastTime
        currentParagraphSentenceCount = currentSentences
        currentParagraphWordCount = currentWords
        
        if paragraphs.count > 60 {
            paragraphs.removeFirst(paragraphs.count - 50)
        }
        
        lastRenderedShowOriginal = settings.showOriginalText
        lastRenderedIsMicEnabled = settings.isMicEnabled
        let attr = buildFullAttributedDocument()
        
        textView.textStorage?.beginEditing()
        textView.textStorage?.setAttributedString(attr)
        textView.textStorage?.endEditing()
        
        finalizedCharLength = textView.textStorage?.length ?? 0
        liveCallerUtterance = nil
        liveMicUtterance = nil
        placeholderView.isHidden = !paragraphs.isEmpty
        scrollToBottomSmooth()
    }
    
    @objc private func showSourceLanguageMenu(_ sender: NSButton) {
        let menu = NSMenu(title: "Caller Language")
        let currentForeign = AppSettings.shared.foreignLanguageCode
        for lang in SupportedLanguages.all {
            let item = NSMenuItem(title: "\(lang.flag)  \(lang.name)", action: #selector(didSelectSourceLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = lang.code
            item.state = (lang.code == currentForeign) ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY - 4), in: sender)
    }
    
    @objc private func didSelectSourceLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        clearAlertBanner()
        AppDelegate.shared.clearSystemAlertBanner()
        AppSettings.shared.foreignLanguageCode = code
    }
    
    @objc private func showTargetLanguageMenu(_ sender: NSButton) {
        let useCustomTarget = !AppSettings.shared.isMicEnabled && !AppSettings.shared.subtitleFollowsMainLanguage
        let menuTitle = useCustomTarget
            ? L10n.tr("settings.subtitleLanguage", "Subtitle Language")
            : L10n.tr("header.yourLanguage", "Your Language")
        let menu = NSMenu(title: menuTitle)
        let currentCode = useCustomTarget
            ? AppSettings.shared.targetLanguageCode
            : AppSettings.shared.mainLanguageCode
        for lang in SupportedLanguages.all {
            let item = NSMenuItem(title: "\(lang.flag)  \(lang.name)", action: #selector(didSelectTargetLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = lang.code
            item.state = (lang.code == currentCode) ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY - 4), in: sender)
    }
    
    @objc private func didSelectTargetLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        clearAlertBanner()
        (NSApp?.delegate as? AppDelegate)?.clearSystemAlertBanner()
        if !AppSettings.shared.isMicEnabled && !AppSettings.shared.subtitleFollowsMainLanguage {
            AppSettings.shared.targetLanguageCode = code
        } else {
            AppSettings.shared.setMainAndTargetLanguage(code)
        }
    }
    
    @objc private func copyTranscriptAction() {
        guard !paragraphs.isEmpty else { return }
        let showOrig = AppSettings.shared.showOriginalText
        let isMic = AppSettings.shared.isMicEnabled
        let fullText = paragraphs.map { $0.plainText(showOriginal: showOrig, isMicEnabled: isMic) }.joined(separator: "\n\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(fullText, forType: .string)
        
        if let checkImg = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied") {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
            copyBtn.image = checkImg.withSymbolConfiguration(config)
            copyBtn.contentTintColor = greenPulse
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self = self else { return }
                if let docImg = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy") {
                    self.copyBtn.image = docImg.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12.5, weight: .medium))
                    self.copyBtn.contentTintColor = NSColor.secondaryLabelColor
                }
            }
        }
    }
    
    public func clearCaptionsUI() {
        paragraphs.removeAll()
        lastFinalizedSpeaker = nil
        currentParagraphSentenceCount = 0
        currentParagraphWordCount = 0
        lastFinalizedTime = Date.distantPast
        liveCallerUtterance = nil
        liveMicUtterance = nil
        finalizedCharLength = 0
        isUserScrolledUp = false
        
        guard isViewLoaded else { return }
        jumpToLatestBtn.isHidden = true
        
        textView.textStorage?.beginEditing()
        textView.textStorage?.setAttributedString(NSAttributedString())
        textView.textStorage?.endEditing()
        
        updatePlaceholderText()
        placeholderView.isHidden = false
    }
    
    @objc private func clearCaptionsAction() {
        guard !paragraphs.isEmpty || !TranscriptManager.shared.entries.isEmpty else {
            clearCaptionsUI()
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.tr("transcript.clearConfirm.title", "Clear Transcript?")
        alert.informativeText = L10n.tr("transcript.clearConfirm.message", "This will permanently remove all caption history from the current session.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("header.clear", "Clear"))
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            CaptionCoordinator.shared.clearTranscript()
            clearCaptionsUI()
        }
    }
    
    @objc private func handleTranscriptEntriesUpdated() {
        if TranscriptManager.shared.entries.isEmpty {
            clearCaptionsUI()
        }
    }
    
    @objc private func togglePinAction() {
        AppSettings.shared.isPinned.toggle()
        updatePinButtonState()
    }
    
    @objc private func openSettingsAction() {
        AppDelegate.shared.openSettingsWindow()
    }
    
    @objc private func closePopoverAction() {
        AppDelegate.shared.closeTrayPopover()
    }
    
    private func updatePauseResumeButtonState() {
        guard pauseResumeBtn != nil else { return }
        let isPaused = CaptionCoordinator.shared.isPaused
        let iconName = isPaused ? "play.fill" : "pause.fill"
        let toolTip = isPaused ? L10n.tr("header.resume", "Resume") : L10n.tr("header.pause", "Pause")
        let tintColor = isPaused ? amberAccent : NSColor.secondaryLabelColor
        
        if let img = NSImage(systemSymbolName: iconName, accessibilityDescription: toolTip) {
            let config = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .medium)
            pauseResumeBtn.image = img.withSymbolConfiguration(config)
        }
        pauseResumeBtn.contentTintColor = tintColor
        pauseResumeBtn.toolTip = toolTip
        pauseResumeBtn.setAccessibilityLabel(toolTip)
        pauseResumeBtn.setAccessibilityValue(isPaused ? "Paused" : "Listening")
    }
    
    @objc private func handlePauseStateChanged() {
        updatePauseResumeButtonState()
        updatePlaceholderText()
    }
    
    @objc private func togglePauseResumeAction() {
        CaptionCoordinator.shared.togglePauseResume()
    }
    
    @objc private func handleSettingsChanged() {
        updateLanguageButtons()
        updateMicButtonState()
        updateLiveShareButtonState()
        updatePinButtonState()
        updatePauseResumeButtonState()
        updatePlaceholderText()
        
        let needsRerender = (
            AppSettings.shared.captionFontSize != cachedFontSize ||
            AppSettings.shared.showOriginalText != lastRenderedShowOriginal ||
            AppSettings.shared.isMicEnabled != lastRenderedIsMicEnabled
        )
        if needsRerender {
            rerenderCaptionsPreservingLiveState()
        }
    }
}
