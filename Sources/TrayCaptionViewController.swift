import AppKit
import os

private final class MainDelayTaskBox: Sendable {
    private struct Entry: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let activeEntry = OSAllocatedUnfairLock<Entry?>(initialState: nil)

    var isPending: Bool {
        activeEntry.withLock { $0 != nil }
    }

    @MainActor
    func schedule(delayNanoseconds: UInt64, operation: @escaping @MainActor @Sendable () -> Void) {
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            let stillActive = self?.activeEntry.withLock { entry -> Bool in
                guard entry?.id == id else { return false }
                entry = nil
                return true
            } ?? false
            guard stillActive else { return }
            operation()
        }
        let previous = activeEntry.withLock { entry -> Task<Void, Never>? in
            let prev = entry?.task
            entry = Entry(id: id, task: task)
            return prev
        }
        previous?.cancel()
    }

    func cancel() {
        let previous = activeEntry.withLock { entry -> Task<Void, Never>? in
            let prev = entry?.task
            entry = nil
            return prev
        }
        previous?.cancel()
    }
}

public enum SystemAlertActionType: Sendable {
    case none
    case audioCapture
    case screenRecording
    case speechRecognition
    case dictation
    case dictationDownload(String)
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

public final class TrayCaptionViewController: NSViewController, NSMenuDelegate {

    private struct SettingsSnapshot: Equatable {
        var appLanguageCode: String
        var foreignLanguageCode: String
        var mainLanguageCode: String
        var targetLanguageCode: String
        var subtitleFollowsMainLanguage: Bool
        var preferredForeignLocale: String?
        var preferredMainLocale: String?
        var isMicEnabled: Bool
        var isPinned: Bool
        var showOriginalText: Bool
        var captionFontSize: CGFloat

        static func current() -> SettingsSnapshot {
            let s = AppSettings.shared
            let foreign = s.foreignLanguageCode
            let main = s.mainLanguageCode
            return SettingsSnapshot(
                appLanguageCode: s.appLanguageCode,
                foreignLanguageCode: foreign,
                mainLanguageCode: main,
                targetLanguageCode: s.targetLanguageCode,
                subtitleFollowsMainLanguage: s.subtitleFollowsMainLanguage,
                preferredForeignLocale: s.preferredSpeechLocale(forCode: foreign),
                preferredMainLocale: s.preferredSpeechLocale(forCode: main),
                isMicEnabled: s.isMicEnabled,
                isPinned: s.isPinned,
                showOriginalText: s.showOriginalText,
                captionFontSize: s.captionFontSize
            )
        }
    }

    private struct LazyVariantSubmenuContext {
        let lang: LanguageItem
        let isSourceMenu: Bool
    }
    
    
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
            let isCaller = (speaker.caseInsensitiveCompare("caller") == .orderedSame)
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
               secondaryText.caseInsensitiveCompare(primaryText) != .orderedSame {
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
    private var paragraphRanges: [NSRange] = []
    private var lastFinalizedSpeaker: String? = nil
    private var currentParagraphSentenceCount: Int = 0
    private var currentParagraphWordCount: Int = 0
    private var lastFinalizedTime: Date = Date.distantPast
    
    private var liveCallerUtterance: LiveUtterance? = nil
    private var liveMicUtterance: LiveUtterance? = nil
    private var finalizedCharLength: Int = 0
    private var isUserScrolledUp: Bool = false
    private var isProgrammaticScrollOrLayout: Bool = false
    private var needsRender: Bool = false
    private var isDisappeared: Bool = false
    private var didShowRestoredTranscriptBanner: Bool = false

    private var isViewVisibleInWindow: Bool {
        guard isViewLoaded, let win = view.window else { return false }
        // Preserve rendering for offscreen unit-test windows that never receive `viewDidDisappear`.
        return win.isVisible || !isDisappeared
    }
    private let liveRenderDelayBox = MainDelayTaskBox()
    private var lastLiveRenderUptime: TimeInterval = 0
    private let liveRenderCoalesceInterval: TimeInterval = 0.04
    private let liveShareCopyResetBox = MainDelayTaskBox()
    private let copyTranscriptResetBox = MainDelayTaskBox()
    private var lazyVariantSubmenuContexts: [ObjectIdentifier: LazyVariantSubmenuContext] = [:]
    
    
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
    private var appLangBtn: HoverIconButton!
    
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
    private var cachedAttrAppLang: String = ""
    private var cachedCallerBadgeText: String = ""
    private var cachedYouBadgeText: String = ""
    private var cachedUntranslatedBadgeText: String = ""
    private var lastRenderedShowOriginal: Bool = AppSettings.shared.showOriginalText
    private var lastRenderedIsMicEnabled: Bool = AppSettings.shared.isMicEnabled
    private var lastRenderedAppLanguage: String = AppSettings.shared.appLanguageCode
    private var lastSettingsSnapshot: SettingsSnapshot?

    private var cachedFinalizedAttrsLTR: [NSAttributedString.Key: Any] = [:]
    private var cachedFinalizedAttrsRTL: [NSAttributedString.Key: Any] = [:]
    private var cachedFinalizedTightAttrsLTR: [NSAttributedString.Key: Any] = [:]
    private var cachedFinalizedTightAttrsRTL: [NSAttributedString.Key: Any] = [:]
    private var cachedLiveAttrsLTR: [NSAttributedString.Key: Any] = [:]
    private var cachedLiveAttrsRTL: [NSAttributedString.Key: Any] = [:]
    private var cachedLiveTightAttrsLTR: [NSAttributedString.Key: Any] = [:]
    private var cachedLiveTightAttrsRTL: [NSAttributedString.Key: Any] = [:]
    private var cachedOrigAttrsLTR: [NSAttributedString.Key: Any] = [:]
    private var cachedOrigAttrsRTL: [NSAttributedString.Key: Any] = [:]
    private var cachedLiveOrigAttrsLTR: [NSAttributedString.Key: Any] = [:]
    private var cachedLiveOrigAttrsRTL: [NSAttributedString.Key: Any] = [:]
    private var cachedCallerBadgeAttrsLTR: [NSAttributedString.Key: Any] = [:]
    private var cachedCallerBadgeAttrsRTL: [NSAttributedString.Key: Any] = [:]
    private var cachedCallerBadgeTightAttrsLTR: [NSAttributedString.Key: Any] = [:]
    private var cachedCallerBadgeTightAttrsRTL: [NSAttributedString.Key: Any] = [:]
    private var cachedYouBadgeAttrsLTR: [NSAttributedString.Key: Any] = [:]
    private var cachedYouBadgeAttrsRTL: [NSAttributedString.Key: Any] = [:]
    private var cachedYouBadgeTightAttrsLTR: [NSAttributedString.Key: Any] = [:]
    private var cachedYouBadgeTightAttrsRTL: [NSAttributedString.Key: Any] = [:]
    private var cachedUntranslatedBadgeNormalAttrsLTR: [NSAttributedString.Key: Any] = [:]
    private var cachedUntranslatedBadgeNormalAttrsRTL: [NSAttributedString.Key: Any] = [:]
    private var cachedUntranslatedBadgeTightAttrsLTR: [NSAttributedString.Key: Any] = [:]
    private var cachedUntranslatedBadgeTightAttrsRTL: [NSAttributedString.Key: Any] = [:]
    
    
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
            selector: #selector(handleTranscriptEntriesUpdated(_:)),
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
            selector: #selector(handleInFlightSpeechDiscarded),
            name: CaptionCoordinator.didDiscardInFlightSpeechNotification,
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
        updateAppLanguageButton()
        updateMicButtonState()
        updateLiveShareButtonState()
        updatePinButtonState()
        updatePauseResumeButtonState()
        updatePlaceholderText()
        updateLayout()
        lastSettingsSnapshot = SettingsSnapshot.current()

        if TranscriptManager.shared.restoredFromAutosave {
            didShowRestoredTranscriptBanner = true
            showAlertBanner(
                message: L10n.tr("tray.restoredTranscript", "Previous transcript restored. Clear it if this is a new call."),
                actionType: .clearRestoredTranscript
            )
        }
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        isDisappeared = false
        flushPendingRenderIfNeeded(force: true)
    }

    public override func viewDidDisappear() {
        super.viewDidDisappear()
        isDisappeared = true
        resetAudioLevelHighlights()
    }

    public func refreshLanguageIndicatorsIfLoaded() {
        guard isViewLoaded else { return }
        updateLanguageButtons()
    }
    
    deinit {
        liveRenderDelayBox.cancel()
        liveShareCopyResetBox.cancel()
        copyTranscriptResetBox.cancel()
        NotificationCenter.default.removeObserver(self)
    }
    
    
    private func setupHeader(width: CGFloat, height: CGFloat) {
        let headerH: CGFloat = 44
        headerView = NSView(frame: NSRect(x: 0, y: height - headerH, width: width, height: headerH))
        headerView.wantsLayer = true
        containerView.addSubview(headerView)
        
        sourceLangBtn = makePillButton(
            frame: NSRect(x: 10, y: 8, width: 108, height: 28),
            fontSize: 12,
            fontWeight: .medium,
            cornerRadius: 14,
            toolTip: L10n.tr("header.callerLanguage", "Caller Language"),
            action: #selector(showSourceLanguageMenu(_:))
        )
        headerView.addSubview(sourceLangBtn)
        
        swapLangBtn = makeIconButton(
            iconName: "arrow.left.arrow.right",
            frame: NSRect(x: 119, y: 10, width: 22, height: 24),
            toolTip: L10n.tr("header.swapLanguages", "Swap Languages"),
            tintColor: NSColor(white: 0.60, alpha: 1.0),
            action: #selector(swapLanguagesAction),
            pointSize: 10.5
        )
        headerView.addSubview(swapLangBtn)
        
        targetLangBtn = makePillButton(
            frame: NSRect(x: 142, y: 8, width: 108, height: 28),
            fontSize: 12,
            fontWeight: .medium,
            cornerRadius: 14,
            toolTip: L10n.tr("header.yourLanguage", "Your Language"),
            action: #selector(showTargetLanguageMenu(_:))
        )
        headerView.addSubview(targetLangBtn)
        
        let rightEdge = width - 10
        var xOffset = rightEdge
        
        closeBtn = makeIconButton(iconName: "xmark", frame: NSRect(x: xOffset - 26, y: 9, width: 26, height: 26), toolTip: L10n.tr("header.close", "Close"), tintColor: NSColor.secondaryLabelColor, action: #selector(closePopoverAction))
        headerView.addSubview(closeBtn)
        xOffset -= 28
        
        settingsBtn = makeIconButton(iconName: "gearshape", frame: NSRect(x: xOffset - 26, y: 9, width: 26, height: 26), toolTip: L10n.tr("header.settings", "Settings"), tintColor: NSColor.secondaryLabelColor, action: #selector(openSettingsAction))
        headerView.addSubview(settingsBtn)
        xOffset -= 28
        
        appLangBtn = makePillButton(
            frame: NSRect(x: xOffset - 56, y: 9, width: 56, height: 26),
            fontSize: 11,
            fontWeight: .semibold,
            cornerRadius: 13,
            toolTip: L10n.tr("menu.appLanguage", "App Language"),
            action: #selector(showAppLanguageMenu(_:)),
            bezelStyle: .regularSquare
        )
        appLangBtn.identifier = NSUserInterfaceItemIdentifier("trayAppLanguageButton")
        headerView.addSubview(appLangBtn)
        xOffset -= 58
        
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
    
    private func makePillButton(
        frame: NSRect,
        fontSize: CGFloat,
        fontWeight: NSFont.Weight,
        cornerRadius: CGFloat,
        toolTip: String,
        action: Selector,
        bezelStyle: NSButton.BezelStyle = .recessed
    ) -> HoverIconButton {
        let pillBg = NSColor.white.withAlphaComponent(0.06)
        let pillHover = NSColor.white.withAlphaComponent(0.12)
        let pillBorder = NSColor.white.withAlphaComponent(0.10).cgColor
        let btn = HoverIconButton(frame: frame)
        btn.bezelStyle = bezelStyle
        btn.isBordered = false
        btn.wantsLayer = true
        btn.cornerRadiusValue = cornerRadius
        btn.restingBackgroundColor = pillBg
        btn.hoverBackgroundColor = pillHover
        btn.layer?.cornerRadius = cornerRadius
        btn.layer?.backgroundColor = pillBg.cgColor
        btn.layer?.borderWidth = 1.0
        btn.layer?.borderColor = pillBorder
        btn.font = NSFont.systemFont(ofSize: fontSize, weight: fontWeight)
        btn.contentTintColor = NSColor(white: 0.94, alpha: 1.0)
        btn.lineBreakMode = .byTruncatingTail
        btn.toolTip = toolTip
        btn.setAccessibilityLabel(toolTip)
        btn.target = self
        btn.action = action
        return btn
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
        AppDelegate.sharedIfAvailable?.clearSystemAlertBanner()
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
        
        liveShareLabel = NSTextField(labelWithString: L10n.tr("tray.liveLink.startingBanner", "Live Link: Starting tunnel…"))
        liveShareLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        liveShareLabel.textColor = NSColor.white
        liveShareLabel.lineBreakMode = .byTruncatingMiddle
        liveShareLabel.frame = NSRect(x: 32, y: (bannerH - 16) / 2.0, width: width - 20 - 180, height: 16)
        liveShareBannerView.addSubview(liveShareLabel)
        
        liveShareCopyBtn = NSButton(title: L10n.tr("tray.copyLink", "Copy Link"), target: self, action: #selector(copyLiveShareLinkAction))
        liveShareCopyBtn.bezelStyle = .recessed
        liveShareCopyBtn.isBordered = false
        liveShareCopyBtn.wantsLayer = true
        liveShareCopyBtn.layer?.cornerRadius = 6
        liveShareCopyBtn.layer?.backgroundColor = NSColor(red: 0.15, green: 0.60, blue: 0.90, alpha: 0.42).cgColor
        liveShareCopyBtn.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        liveShareCopyBtn.contentTintColor = .white
        liveShareCopyBtn.frame = NSRect(x: width - 20 - 146, y: (bannerH - 22) / 2.0, width: 82, height: 22)
        liveShareCopyBtn.setAccessibilityLabel(L10n.tr("tray.copyLink", "Copy Link"))
        liveShareBannerView.addSubview(liveShareCopyBtn)
        
        liveShareStopBtn = NSButton(title: L10n.tr("tray.stop", "Stop"), target: self, action: #selector(stopLiveShareAction))
        liveShareStopBtn.bezelStyle = .recessed
        liveShareStopBtn.isBordered = false
        liveShareStopBtn.wantsLayer = true
        liveShareStopBtn.layer?.cornerRadius = 6
        liveShareStopBtn.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        liveShareStopBtn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        liveShareStopBtn.contentTintColor = NSColor(white: 0.85, alpha: 1.0)
        liveShareStopBtn.frame = NSRect(x: width - 20 - 58, y: (bannerH - 22) / 2.0, width: 52, height: 22)
        liveShareStopBtn.setAccessibilityLabel(L10n.tr("tray.stop", "Stop"))
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
        
        alertActionBtn = NSButton(title: L10n.tr("header.settings", "Settings"), target: self, action: #selector(alertActionClicked))
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
            toolTip: L10n.tr("tray.dismiss", "Dismiss"),
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
        let wasAutoFollowing = !isUserScrolledUp
        isProgrammaticScrollOrLayout = true
        scrollView.frame = NSRect(x: 10, y: scrollY, width: width - 20, height: scrollH)
        isProgrammaticScrollOrLayout = false
        
        placeholderView.frame = scrollView.frame
        let pW = placeholderView.bounds.width
        let pH = placeholderView.bounds.height
        let midY = round(pH / 2.0)
        placeholderBadgeView?.frame = NSRect(x: round((pW - 44) / 2.0), y: midY + 14, width: 44, height: 44)
        placeholderIconView?.frame = NSRect(x: 10, y: 10, width: 24, height: 24)
        placeholderTitle?.frame = NSRect(x: 24, y: midY - 14, width: pW - 48, height: 20)
        placeholderSubtitle?.frame = NSRect(x: 36, y: midY - 38, width: pW - 72, height: 20)

        if wasAutoFollowing
            && (!paragraphs.isEmpty || liveCallerUtterance != nil || liveMicUtterance != nil)
            && isViewVisibleInWindow {
            scrollToBottomSmooth()
        }
    }
    
    public func showAlertBanner(message: String, actionType: SystemAlertActionType) {
        loadViewIfNeeded()
        currentAlertActionType = actionType
        activeAlertMessage = message
        alertLabel.stringValue = message
        alertLabel.toolTip = message
        switch actionType {
        case .clearRestoredTranscript:
            alertActionBtn.title = L10n.tr("header.clear", "Clear")
        case .dictationDownload(let code):
            if SpeechAssetDownloader.shared.isDownloading(forCode: code) {
                alertActionBtn.title = L10n.tr("model.dictation", "Dictation…")
            } else {
                alertActionBtn.title = L10n.tr("model.download", "Download")
            }
        case .audioCapture, .screenRecording, .speechRecognition, .dictation, .translationSettings, .permissions, .none:
            alertActionBtn.title = L10n.tr("header.settings", "Settings")
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
        let wasLocalRestored: Bool
        if case .clearRestoredTranscript = currentAlertActionType {
            wasLocalRestored = true
        } else {
            wasLocalRestored = false
        }
        if wasLocalRestored {
            didShowRestoredTranscriptBanner = true
        }
        clearAlertBanner()
        if !wasLocalRestored {
            AppDelegate.sharedIfAvailable?.clearSystemAlertBanner()
        }
    }
    
    @objc private func alertActionClicked() {
        switch currentAlertActionType {
        case .clearRestoredTranscript:
            didShowRestoredTranscriptBanner = true
            clearAlertBanner()
            CaptionCoordinator.shared.clearTranscript()
            clearCaptionsUI()
        case .audioCapture, .screenRecording:
            PermissionHelper.shared.openAudioCaptureSettings()
        case .speechRecognition:
            PermissionHelper.shared.openSpeechRecognitionSettings()
        case .dictation:
            SpeechAssetDownloader.shared.ensureActiveLanguagesDownloaded(force: true)
            PermissionHelper.shared.openDictationSettings()
            AppDelegate.sharedIfAvailable?.openSettingsWindow(selectedTab: 0)
        case .dictationDownload(let code):
            if SpeechAssetDownloader.shared.isDownloading(forCode: code) {
                PermissionHelper.shared.openDictationSettings()
            } else {
                SpeechAssetDownloader.shared.ensureDownloaded(forCode: code, force: true)
            }
        case .translationSettings:
            PermissionHelper.shared.openTranslationSettings()
        case .permissions:
            AppDelegate.sharedIfAvailable?.openSettingsWindow(selectedTab: 2)
        case .none:
            AppDelegate.sharedIfAvailable?.openSettingsWindow(selectedTab: 0)
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
        liveShareCopyResetBox.cancel()
        liveShareCopyBtn.contentTintColor = .white
        liveShareBannerView.isHidden = true
        updateLiveShareButtonState()
        updateLayout()
    }
    
    private func updateLiveShareBannerText() {
        guard isViewLoaded else { return }
        let manager = LiveShareManager.shared
        let viewers = manager.activeClientCount
        let viewerSuffix: String
        if viewers == 1 {
            viewerSuffix = String(format: L10n.tr("tray.liveLink.viewerSingular", "  •  %d viewer"), viewers)
        } else if viewers > 1 {
            viewerSuffix = String(format: L10n.tr("tray.liveLink.viewerPlural", "  •  %d viewers"), viewers)
        } else {
            viewerSuffix = ""
        }
        let external = AppSettings.shared.liveShareUseExternalTunnel

        let targetCopyTitle: String
        let targetCopyEnabled: Bool

        if let publicURL = manager.publicShareURL {
            liveShareLabel.stringValue = String(format: L10n.tr("tray.liveLink.ready", "%@ • Live Link ready%@"), publicURL.host ?? L10n.tr("header.liveLink", "Live Link"), viewerSuffix)
            liveShareLabel.toolTip = L10n.tr("tray.liveLink.copyTooltip", "Use Copy Link to share. The full URL contains a secret session token and decryption key.")
            liveShareIconView.contentTintColor = greenPulse
            targetCopyEnabled = true
            targetCopyTitle = L10n.tr("tray.copyLink", "Copy Link")
        } else if let tunnelErr = manager.tunnelError {
            if let localURL = manager.localShareURL {
                liveShareLabel.stringValue = String(format: L10n.tr("tray.liveLink.localOnly", "%@ • Local only%@"), localURL.host ?? "127.0.0.1", viewerSuffix)
                liveShareLabel.toolTip = "\(tunnelErr)\n\(L10n.tr("tray.liveLink.copyLocalTooltip", "Use Copy Local to open/share the local link. The full URL contains the session key."))"
            } else {
                liveShareLabel.stringValue = tunnelErr
                liveShareLabel.toolTip = tunnelErr
            }
            liveShareIconView.contentTintColor = amberAccent
            targetCopyEnabled = manager.localShareURL != nil
            targetCopyTitle = L10n.tr("tray.copyLocal", "Copy Local")
        } else if let localURL = manager.localShareURL {
            if external {
                liveShareLabel.stringValue = String(format: L10n.tr("tray.liveLink.startingTunnelHost", "Starting public tunnel… (%@)%@"), localURL.host ?? "127.0.0.1", viewerSuffix)
                targetCopyEnabled = false
                targetCopyTitle = L10n.tr("tray.copyLink", "Copy Link")
            } else {
                liveShareLabel.stringValue = String(format: L10n.tr("tray.liveLink.localOnly", "%@ • Local only%@"), localURL.host ?? "127.0.0.1", viewerSuffix)
                targetCopyEnabled = true
                targetCopyTitle = L10n.tr("tray.copyLocal", "Copy Local")
            }
            liveShareLabel.toolTip = L10n.tr("tray.liveLink.copyLocalTooltip", "Use Copy Local to open/share the local link. The full URL contains the session key.")
            liveShareIconView.contentTintColor = cyanAccent
        } else {
            liveShareLabel.stringValue = L10n.tr("tray.liveLink.starting", "Starting Live Link…")
            liveShareLabel.toolTip = nil
            liveShareIconView.contentTintColor = cyanAccent
            targetCopyEnabled = false
            targetCopyTitle = L10n.tr("tray.copyLink", "Copy Link")
        }

        liveShareCopyBtn.isEnabled = targetCopyEnabled
        if !targetCopyEnabled {
            liveShareCopyResetBox.cancel()
            liveShareCopyBtn.contentTintColor = .white
            liveShareCopyBtn.title = targetCopyTitle
        } else if !liveShareCopyResetBox.isPending {
            liveShareCopyBtn.contentTintColor = .white
            liveShareCopyBtn.title = targetCopyTitle
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
            AppDelegate.sharedIfAvailable?.confirmAndStartLiveShare()
        }
    }
    
    @objc private func copyLiveShareLinkAction() {
        guard let url = LiveShareManager.shared.effectiveShareURL else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)

        liveShareCopyBtn.title = L10n.tr("common.copied", "Copied")
        liveShareCopyBtn.contentTintColor = greenPulse

        liveShareCopyResetBox.schedule(delayNanoseconds: 1_500_000_000) { [weak self] in
            guard let self = self, self.isViewLoaded else { return }
            self.liveShareCopyBtn.contentTintColor = .white
            self.updateLiveShareBannerText()
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
                            message: L10n.tr("tray.micRequired", "Microphone access required"),
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
        textView.layoutManager?.allowsNonContiguousLayout = true
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
        jumpToLatestBtn.title = L10n.tr("tray.latest", "Latest")
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

    public func flushPendingRenderIfNeeded(force: Bool = false) {
        guard isViewLoaded else { return }
        guard force || isViewVisibleInWindow else { return }
        guard needsRender, let storage = textView.textStorage else { return }

        needsRender = false
        liveRenderDelayBox.cancel()

        ensureCachedTextAttributesUpToDate()
        lastRenderedShowOriginal = AppSettings.shared.showOriginalText
        lastRenderedIsMicEnabled = AppSettings.shared.isMicEnabled
        textView.font = NSFont.systemFont(ofSize: cachedFontSize, weight: .regular)

        rebuildAllStorage(in: storage)
        lastLiveRenderUptime = ProcessInfo.processInfo.systemUptime

        if paragraphs.isEmpty && liveCallerUtterance == nil && liveMicUtterance == nil {
            updatePlaceholderText()
        } else {
            placeholderView?.isHidden = true
            scrollToBottomSmooth(forceWithoutWindow: force && !isViewVisibleInWindow)
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
        let isCaller = (speaker.caseInsensitiveCompare("caller") == .orderedSame)

        if !self.placeholderView.isHidden {
            self.placeholderView.isHidden = true
        }

        if isFinal {
            liveRenderDelayBox.cancel()
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

            if !isViewVisibleInWindow || needsRender {
                liveRenderDelayBox.cancel()
                needsRender = true
                return
            }

            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - lastLiveRenderUptime
            let isPending = liveRenderDelayBox.isPending
            if elapsed >= liveRenderCoalesceInterval && !isPending {
                lastLiveRenderUptime = now
                renderLiveSection()
            } else if !isPending {
                let remaining = max(0.005, liveRenderCoalesceInterval - elapsed)
                let delayNs = UInt64(remaining * 1_000_000_000)
                liveRenderDelayBox.schedule(delayNanoseconds: delayNs) { [weak self] in
                    guard let self = self, self.isViewLoaded else { return }
                    guard self.isViewVisibleInWindow, !self.needsRender else {
                        self.needsRender = true
                        return
                    }
                    self.lastLiveRenderUptime = ProcessInfo.processInfo.systemUptime
                    self.renderLiveSection()
                }
            }
        }
    }

    private func currentLiveBlocks() -> [ParagraphBlock] {
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
        return liveBlocks
    }

    private func buildLiveAttributedString(from liveBlocks: [ParagraphBlock]) -> NSAttributedString {
        let fullLiveAttr = NSMutableAttributedString()
        for (idx, block) in liveBlocks.enumerated() {
            if idx > 0 {
                fullLiveAttr.append(NSAttributedString(string: "\n", attributes: cachedLiveAttrsLTR))
            }
            fullLiveAttr.append(buildAttributedParagraph(block: block, isLive: true))
        }
        return fullLiveAttr
    }

    private func replaceLiveSectionInStorage(_ storage: NSTextStorage, liveBlocks: [ParagraphBlock]) {
        let totalLen = storage.length
        let safeFinalizedLen = min(finalizedCharLength, totalLen)
        let liveRange = NSRange(location: safeFinalizedLen, length: totalLen - safeFinalizedLen)
        if liveBlocks.isEmpty {
            if liveRange.length > 0 {
                storage.replaceCharacters(in: liveRange, with: "")
            }
        } else {
            let fullLiveAttr = buildLiveAttributedString(from: liveBlocks)
            storage.replaceCharacters(in: liveRange, with: fullLiveAttr)
        }
    }

    private func clearLiveUtterances() {
        let hadLive = (liveCallerUtterance != nil || liveMicUtterance != nil)
        liveRenderDelayBox.cancel()
        liveCallerUtterance = nil
        liveMicUtterance = nil
        if hadLive, isViewLoaded {
            renderLiveSection()
        }
    }

    @objc private func handleInFlightSpeechDiscarded() {
        clearLiveUtterances()
    }

    private func syncScrollStateAfterContentMutation() {
        guard isViewLoaded, let docView = scrollView.documentView else { return }
        let visibleRect = scrollView.contentView.bounds
        let docHeight = docView.bounds.height
        let isAtBottom = (visibleRect.maxY >= docHeight - 36.0) || (docHeight <= visibleRect.height)
        if isAtBottom {
            isUserScrolledUp = false
            jumpToLatestBtn.isHidden = true
        } else {
            jumpToLatestBtn.isHidden = !isUserScrolledUp
        }
    }

    private func rebuildAllStorage(in storage: NSTextStorage) {
        let fullDoc = buildFullAttributedDocumentRecordingRanges()
        finalizedCharLength = fullDoc.length
        let liveBlocks = currentLiveBlocks()
        if !liveBlocks.isEmpty {
            fullDoc.append(buildLiveAttributedString(from: liveBlocks))
        }
        isProgrammaticScrollOrLayout = true
        storage.beginEditing()
        storage.setAttributedString(fullDoc)
        storage.endEditing()
        isProgrammaticScrollOrLayout = false
        syncScrollStateAfterContentMutation()
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

        var modifiedIndex: Int? = nil
        var didAppendNewBlock = false
        let existingCountBeforeMutation = paragraphs.count

        for bIdx in paragraphs.indices.reversed() {
            if let sIdx = paragraphs[bIdx].sentences.firstIndex(where: { $0.id == utteranceID }) {
                paragraphs[bIdx].sentences[sIdx] = SentenceItem(
                    id: utteranceID,
                    translated: primaryTrans,
                    original: cleanOrig,
                    isUntranslated: isUntranslated
                )
                modifiedIndex = bIdx
                break
            }
        }

        if modifiedIndex == nil {
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
                let lastIdx = paragraphs.count - 1
                var lastBlock = paragraphs[lastIdx]
                lastBlock.sentences.append(SentenceItem(
                    id: utteranceID,
                    translated: primaryTrans,
                    original: cleanOrig,
                    isUntranslated: isUntranslated
                ))
                paragraphs[lastIdx] = lastBlock
                currentParagraphSentenceCount += 1
                currentParagraphWordCount += newWordCount
                modifiedIndex = lastIdx
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
                didAppendNewBlock = true
            }

            lastFinalizedTime = now
        }

        let dropCount = (didAppendNewBlock && paragraphs.count > 60) ? (paragraphs.count - 50) : 0

        if !isViewVisibleInWindow || needsRender {
            if dropCount > 0 {
                paragraphs.removeFirst(dropCount)
            }
            needsRender = true
            return
        }

        let attrsChanged = ensureCachedTextAttributesUpToDate()
        let liveBlocks = currentLiveBlocks()

        if attrsChanged || paragraphRanges.count != existingCountBeforeMutation {
            if dropCount > 0 {
                paragraphs.removeFirst(dropCount)
            }
            rebuildAllStorage(in: storage)
            lastLiveRenderUptime = ProcessInfo.processInfo.systemUptime
            scrollToBottomSmooth()
            return
        }

        if let bIdx = modifiedIndex {
            let oldRange = paragraphRanges[bIdx]
            if NSMaxRange(oldRange) <= finalizedCharLength && finalizedCharLength <= storage.length {
                let newParaAttr = buildAttributedParagraph(block: paragraphs[bIdx], isLive: false)
                let delta = newParaAttr.length - oldRange.length
                isProgrammaticScrollOrLayout = true
                storage.beginEditing()
                storage.replaceCharacters(in: oldRange, with: newParaAttr)
                paragraphRanges[bIdx] = NSRange(location: oldRange.location, length: newParaAttr.length)
                if delta != 0 {
                    for k in (bIdx + 1)..<paragraphRanges.count {
                        paragraphRanges[k].location += delta
                    }
                    finalizedCharLength += delta
                }
                replaceLiveSectionInStorage(storage, liveBlocks: liveBlocks)
                storage.endEditing()
                isProgrammaticScrollOrLayout = false
                syncScrollStateAfterContentMutation()
                lastLiveRenderUptime = ProcessInfo.processInfo.systemUptime
                scrollToBottomSmooth()
                return
            }
        } else if didAppendNewBlock {
            let newBlock = paragraphs[paragraphs.count - 1]
            let newParaAttr = buildAttributedParagraph(block: newBlock, isLive: false)

            var preservedRemovedHeight: CGFloat = 0
            if isUserScrolledUp && dropCount > 0 && dropCount < paragraphRanges.count {
                let trimEnd = paragraphRanges[dropCount].location
                if trimEnd > 0 && trimEnd <= storage.length,
                   let lm = textView.layoutManager,
                   let tc = textView.textContainer {
                    lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: trimEnd))
                    let glyphRange = lm.glyphRange(forCharacterRange: NSRange(location: 0, length: trimEnd), actualCharacterRange: nil)
                    if glyphRange.length > 0 {
                        preservedRemovedHeight = lm.boundingRect(forGlyphRange: glyphRange, in: tc).height
                    }
                }
            }

            let safeFinalizedLen = min(finalizedCharLength, storage.length)
            if safeFinalizedLen == finalizedCharLength {
                isProgrammaticScrollOrLayout = true
                storage.beginEditing()
                storage.replaceCharacters(in: NSRange(location: safeFinalizedLen, length: 0), with: newParaAttr)
                paragraphRanges.append(NSRange(location: safeFinalizedLen, length: newParaAttr.length))
                finalizedCharLength += newParaAttr.length

                if dropCount > 0 && dropCount < paragraphRanges.count {
                    let removeLen = paragraphRanges[dropCount].location
                    if removeLen > 0 && removeLen <= finalizedCharLength {
                        storage.replaceCharacters(in: NSRange(location: 0, length: removeLen), with: "")
                        paragraphs.removeFirst(dropCount)
                        paragraphRanges.removeFirst(dropCount)
                        for k in paragraphRanges.indices {
                            paragraphRanges[k].location -= removeLen
                        }
                        finalizedCharLength -= removeLen
                    }
                }

                replaceLiveSectionInStorage(storage, liveBlocks: liveBlocks)
                storage.endEditing()

                if isUserScrolledUp && preservedRemovedHeight > 0, let docView = scrollView.documentView {
                    if let lm = textView.layoutManager, let tc = textView.textContainer {
                        lm.ensureLayout(for: tc)
                    }
                    let maxY = max(0, docView.bounds.height - scrollView.contentView.bounds.height)
                    let currentY = scrollView.contentView.bounds.origin.y
                    let adjustedY = min(maxY, max(0, currentY - preservedRemovedHeight))
                    scrollView.contentView.scroll(to: NSPoint(x: 0, y: adjustedY))
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }

                isProgrammaticScrollOrLayout = false
                syncScrollStateAfterContentMutation()
                lastLiveRenderUptime = ProcessInfo.processInfo.systemUptime
                scrollToBottomSmooth()
                return
            }
        }

        if dropCount > 0 {
            paragraphs.removeFirst(dropCount)
        }
        rebuildAllStorage(in: storage)
        lastLiveRenderUptime = ProcessInfo.processInfo.systemUptime
        scrollToBottomSmooth()
    }
    
    private func renderLiveSection() {
        guard let storage = textView.textStorage else { return }
        let liveBlocks = currentLiveBlocks()

        if paragraphs.isEmpty && liveBlocks.isEmpty {
            if storage.length > 0 {
                isProgrammaticScrollOrLayout = true
                storage.beginEditing()
                storage.setAttributedString(NSAttributedString())
                storage.endEditing()
                isProgrammaticScrollOrLayout = false
                syncScrollStateAfterContentMutation()
            }
            finalizedCharLength = 0
            paragraphRanges.removeAll(keepingCapacity: true)
            updatePlaceholderText()
            return
        }

        placeholderView?.isHidden = true

        if !isViewVisibleInWindow || needsRender {
            needsRender = true
            return
        }

        isProgrammaticScrollOrLayout = true
        storage.beginEditing()
        replaceLiveSectionInStorage(storage, liveBlocks: liveBlocks)
        storage.endEditing()
        isProgrammaticScrollOrLayout = false
        syncScrollStateAfterContentMutation()

        scrollToBottomSmooth()
    }

    @discardableResult
    private func ensureCachedTextAttributesUpToDate() -> Bool {
        let fontSize = AppSettings.shared.captionFontSize
        let appLang = AppSettings.shared.appLanguageCode
        if !cachedFinalizedAttrsLTR.isEmpty && cachedFontSize == fontSize && cachedAttrAppLang == appLang {
            return false
        }
        updateCachedTextAttributes()
        return true
    }
    
    private func updateCachedTextAttributes() {
        let fontSize = AppSettings.shared.captionFontSize
        let appLang = AppSettings.shared.appLanguageCode
        cachedFontSize = fontSize
        cachedAttrAppLang = appLang

        cachedCallerBadgeText = "\u{2066}\(L10n.tr("tray.speaker.caller", "CALLER"))\u{2069}  "
        cachedYouBadgeText = "\u{2066}\(L10n.tr("tray.speaker.you", "YOU"))\u{2069}  "
        cachedUntranslatedBadgeText = "\u{2066}[\(L10n.tr("caption.untranslated", "Untranslated").uppercased())]\u{2069}  "

        let primaryKern: CGFloat = fontSize >= 18 ? -0.24 : -0.16
        let blockSpacing = round(fontSize * 0.72)

        func makeStyle(lineHeightMultiple: CGFloat, spacing: CGFloat, direction: NSWritingDirection) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = lineHeightMultiple
            style.paragraphSpacing = spacing
            style.baseWritingDirection = direction
            style.alignment = .natural
            return style
        }

        let normalStyleLTR = makeStyle(lineHeightMultiple: 1.26, spacing: blockSpacing, direction: .leftToRight)
        let normalStyleRTL = makeStyle(lineHeightMultiple: 1.26, spacing: blockSpacing, direction: .rightToLeft)
        let tightStyleLTR = makeStyle(lineHeightMultiple: 1.26, spacing: 3.0, direction: .leftToRight)
        let tightStyleRTL = makeStyle(lineHeightMultiple: 1.26, spacing: 3.0, direction: .rightToLeft)
        let subStyleLTR = makeStyle(lineHeightMultiple: 1.20, spacing: blockSpacing, direction: .leftToRight)
        let subStyleRTL = makeStyle(lineHeightMultiple: 1.20, spacing: blockSpacing, direction: .rightToLeft)

        let primaryFont = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        let subFont = NSFont.systemFont(ofSize: max(11.5, round(fontSize * 0.82)), weight: .regular)
        let badgeFont = NSFont.systemFont(ofSize: max(10.0, round(fontSize * 0.68)), weight: .semibold)

        let finalizedColor = NSColor(white: 0.96, alpha: 1.0)
        let callerColor = NSColor(red: 0.24, green: 0.90, blue: 0.56, alpha: 1.0)
        let youColor = NSColor(red: 0.28, green: 0.84, blue: 0.98, alpha: 1.0)

        cachedFinalizedAttrsLTR = [.font: primaryFont, .foregroundColor: finalizedColor, .kern: primaryKern, .paragraphStyle: normalStyleLTR]
        cachedFinalizedAttrsRTL = [.font: primaryFont, .foregroundColor: finalizedColor, .kern: primaryKern, .paragraphStyle: normalStyleRTL]
        cachedFinalizedTightAttrsLTR = [.font: primaryFont, .foregroundColor: finalizedColor, .kern: primaryKern, .paragraphStyle: tightStyleLTR]
        cachedFinalizedTightAttrsRTL = [.font: primaryFont, .foregroundColor: finalizedColor, .kern: primaryKern, .paragraphStyle: tightStyleRTL]

        cachedLiveAttrsLTR = [.font: primaryFont, .foregroundColor: liveTextColor, .kern: primaryKern, .paragraphStyle: normalStyleLTR]
        cachedLiveAttrsRTL = [.font: primaryFont, .foregroundColor: liveTextColor, .kern: primaryKern, .paragraphStyle: normalStyleRTL]
        cachedLiveTightAttrsLTR = [.font: primaryFont, .foregroundColor: liveTextColor, .kern: primaryKern, .paragraphStyle: tightStyleLTR]
        cachedLiveTightAttrsRTL = [.font: primaryFont, .foregroundColor: liveTextColor, .kern: primaryKern, .paragraphStyle: tightStyleRTL]

        cachedOrigAttrsLTR = [.font: subFont, .foregroundColor: origSubColor, .kern: -0.08, .paragraphStyle: subStyleLTR]
        cachedOrigAttrsRTL = [.font: subFont, .foregroundColor: origSubColor, .kern: -0.08, .paragraphStyle: subStyleRTL]
        cachedLiveOrigAttrsLTR = [.font: subFont, .foregroundColor: liveOrigSubColor, .kern: -0.08, .paragraphStyle: subStyleLTR]
        cachedLiveOrigAttrsRTL = [.font: subFont, .foregroundColor: liveOrigSubColor, .kern: -0.08, .paragraphStyle: subStyleRTL]

        cachedCallerBadgeAttrsLTR = [.font: badgeFont, .foregroundColor: callerColor, .kern: 0.6, .paragraphStyle: normalStyleLTR]
        cachedCallerBadgeAttrsRTL = [.font: badgeFont, .foregroundColor: callerColor, .kern: 0.6, .paragraphStyle: normalStyleRTL]
        cachedCallerBadgeTightAttrsLTR = [.font: badgeFont, .foregroundColor: callerColor, .kern: 0.6, .paragraphStyle: tightStyleLTR]
        cachedCallerBadgeTightAttrsRTL = [.font: badgeFont, .foregroundColor: callerColor, .kern: 0.6, .paragraphStyle: tightStyleRTL]

        cachedYouBadgeAttrsLTR = [.font: badgeFont, .foregroundColor: youColor, .kern: 0.6, .paragraphStyle: normalStyleLTR]
        cachedYouBadgeAttrsRTL = [.font: badgeFont, .foregroundColor: youColor, .kern: 0.6, .paragraphStyle: normalStyleRTL]
        cachedYouBadgeTightAttrsLTR = [.font: badgeFont, .foregroundColor: youColor, .kern: 0.6, .paragraphStyle: tightStyleLTR]
        cachedYouBadgeTightAttrsRTL = [.font: badgeFont, .foregroundColor: youColor, .kern: 0.6, .paragraphStyle: tightStyleRTL]

        cachedUntranslatedBadgeNormalAttrsLTR = [.font: badgeFont, .foregroundColor: amberAccent, .kern: 0.4, .paragraphStyle: normalStyleLTR]
        cachedUntranslatedBadgeNormalAttrsRTL = [.font: badgeFont, .foregroundColor: amberAccent, .kern: 0.4, .paragraphStyle: normalStyleRTL]
        cachedUntranslatedBadgeTightAttrsLTR = [.font: badgeFont, .foregroundColor: amberAccent, .kern: 0.4, .paragraphStyle: tightStyleLTR]
        cachedUntranslatedBadgeTightAttrsRTL = [.font: badgeFont, .foregroundColor: amberAccent, .kern: 0.4, .paragraphStyle: tightStyleRTL]
    }

    private func rerenderCaptionsPreservingLiveState() {
        guard isViewLoaded, let storage = textView.textStorage else { return }
        liveRenderDelayBox.cancel()
        ensureCachedTextAttributesUpToDate()
        lastRenderedShowOriginal = AppSettings.shared.showOriginalText
        lastRenderedIsMicEnabled = AppSettings.shared.isMicEnabled
        textView.font = NSFont.systemFont(ofSize: cachedFontSize, weight: .regular)

        if paragraphs.isEmpty && liveCallerUtterance == nil && liveMicUtterance == nil {
            paragraphRanges.removeAll(keepingCapacity: true)
            finalizedCharLength = 0
            needsRender = false
            isProgrammaticScrollOrLayout = true
            storage.beginEditing()
            storage.setAttributedString(NSAttributedString())
            storage.endEditing()
            isProgrammaticScrollOrLayout = false
            syncScrollStateAfterContentMutation()
            updatePlaceholderText()
            return
        }

        if !isViewVisibleInWindow {
            needsRender = true
            return
        }

        needsRender = false
        rebuildAllStorage(in: storage)
        lastLiveRenderUptime = ProcessInfo.processInfo.systemUptime
        placeholderView?.isHidden = true
        scrollToBottomSmooth()
    }

    public func buildAttributedParagraph(block: ParagraphBlock, isLive: Bool) -> NSAttributedString {
        ensureCachedTextAttributesUpToDate()
        let result = NSMutableAttributedString()

        let transText = block.sentences.map(\.translated).joined(separator: " ")
        let origText = block.sentences.map(\.original).filter { !$0.isEmpty }.joined(separator: " ")
        let hasUntranslated = block.sentences.contains(where: \.isUntranslated)
        let showOriginal = AppSettings.shared.showOriginalText
        let isMicEnabled = AppSettings.shared.isMicEnabled
        let isCaller = (block.speaker.caseInsensitiveCompare("caller") == .orderedSame)

        let primaryText = isCaller ? (hasUntranslated ? origText : transText) : (origText.isEmpty ? transText : origText)
        let secondaryText = isCaller ? origText : transText
        let primaryLangCode = isCaller ? (hasUntranslated ? block.sourceLangCode : block.targetLangCode) : block.sourceLangCode
        let secondaryLangCode = isCaller ? block.sourceLangCode : block.targetLangCode
        let hasSecondary = showOriginal
            && !secondaryText.isEmpty
            && secondaryText.caseInsensitiveCompare(primaryText) != .orderedSame

        let isPrimaryRTL = SupportedLanguages.isRTL(languageCode: primaryLangCode)
        let isSecondaryRTL = SupportedLanguages.isRTL(languageCode: secondaryLangCode)

        let primaryLineAttrs: [NSAttributedString.Key: Any]
        if isLive {
            if hasSecondary {
                primaryLineAttrs = isPrimaryRTL ? cachedLiveTightAttrsRTL : cachedLiveTightAttrsLTR
            } else {
                primaryLineAttrs = isPrimaryRTL ? cachedLiveAttrsRTL : cachedLiveAttrsLTR
            }
        } else {
            if hasSecondary {
                primaryLineAttrs = isPrimaryRTL ? cachedFinalizedTightAttrsRTL : cachedFinalizedTightAttrsLTR
            } else {
                primaryLineAttrs = isPrimaryRTL ? cachedFinalizedAttrsRTL : cachedFinalizedAttrsLTR
            }
        }

        if isMicEnabled || hasUntranslated {
            if isMicEnabled {
                let badgeAttrs: [NSAttributedString.Key: Any]
                if isCaller {
                    if hasSecondary {
                        badgeAttrs = isPrimaryRTL ? cachedCallerBadgeTightAttrsRTL : cachedCallerBadgeTightAttrsLTR
                    } else {
                        badgeAttrs = isPrimaryRTL ? cachedCallerBadgeAttrsRTL : cachedCallerBadgeAttrsLTR
                    }
                } else {
                    if hasSecondary {
                        badgeAttrs = isPrimaryRTL ? cachedYouBadgeTightAttrsRTL : cachedYouBadgeTightAttrsLTR
                    } else {
                        badgeAttrs = isPrimaryRTL ? cachedYouBadgeAttrsRTL : cachedYouBadgeAttrsLTR
                    }
                }
                let speakerBadge = isCaller ? cachedCallerBadgeText : cachedYouBadgeText
                result.append(NSAttributedString(string: speakerBadge, attributes: badgeAttrs))
            }

            if hasUntranslated {
                let untranslatedAttrs: [NSAttributedString.Key: Any]
                if hasSecondary {
                    untranslatedAttrs = isPrimaryRTL ? cachedUntranslatedBadgeTightAttrsRTL : cachedUntranslatedBadgeTightAttrsLTR
                } else {
                    untranslatedAttrs = isPrimaryRTL ? cachedUntranslatedBadgeNormalAttrsRTL : cachedUntranslatedBadgeNormalAttrsLTR
                }
                result.append(NSAttributedString(string: cachedUntranslatedBadgeText, attributes: untranslatedAttrs))
            }
        }

        result.append(NSAttributedString(string: "\u{2068}\(primaryText)\u{2069}", attributes: primaryLineAttrs))

        var lastParagraphAttrs = primaryLineAttrs
        if hasSecondary {
            let secondaryAttrs: [NSAttributedString.Key: Any]
            if isLive {
                secondaryAttrs = isSecondaryRTL ? cachedLiveOrigAttrsRTL : cachedLiveOrigAttrsLTR
            } else {
                secondaryAttrs = isSecondaryRTL ? cachedOrigAttrsRTL : cachedOrigAttrsLTR
            }
            lastParagraphAttrs = secondaryAttrs
            result.append(NSAttributedString(string: "\n\u{2068}\(secondaryText)\u{2069}", attributes: secondaryAttrs))
        }
        if !isLive {
            result.append(NSAttributedString(string: "\n", attributes: lastParagraphAttrs))
        }
        return result
    }

    private func buildFullAttributedDocumentRecordingRanges() -> NSMutableAttributedString {
        ensureCachedTextAttributesUpToDate()
        let fullAttr = NSMutableAttributedString()
        paragraphRanges.removeAll(keepingCapacity: true)
        paragraphRanges.reserveCapacity(paragraphs.count)
        for p in paragraphs {
            let start = fullAttr.length
            let paraAttr = buildAttributedParagraph(block: p, isLive: false)
            fullAttr.append(paraAttr)
            paragraphRanges.append(NSRange(location: start, length: paraAttr.length))
        }
        return fullAttr
    }

    private func resetAudioLevelHighlights() {
        if isCallerHighlighted {
            isCallerHighlighted = false
            sourceLangBtn?.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        }
        if isMicHighlighted {
            isMicHighlighted = false
            micToggleBtn?.contentTintColor = AppSettings.shared.isMicEnabled ? cyanAccent : NSColor.secondaryLabelColor
            targetLangBtn?.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        }
    }

    public func updateAudioLevels(callerLevel: Float, micLevel: Float) {
        guard isViewLoaded, view.window?.isVisible == true else { return }

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

        isUserScrolledUp = !isAtBottom
        jumpToLatestBtn.isHidden = isAtBottom
    }

    @objc private func handleUserLiveScroll() {
        guard let docView = scrollView.documentView else { return }
        let visibleRect = scrollView.contentView.bounds
        let docHeight = docView.bounds.height
        let isAtBottom = (visibleRect.maxY >= docHeight - 36.0) || (docHeight <= visibleRect.height)

        isUserScrolledUp = !isAtBottom
        jumpToLatestBtn.isHidden = isAtBottom
    }
    
    private func scrollToBottomSmooth(forceWithoutWindow: Bool = false) {
        guard !isUserScrolledUp else { return }
        guard forceWithoutWindow || isViewVisibleInWindow else { return }
        guard let docView = scrollView.documentView else { return }

        isProgrammaticScrollOrLayout = true
        defer { isProgrammaticScrollOrLayout = false }

        let len = textView.textStorage?.length ?? 0
        if len > 0 {
            textView.layoutManager?.ensureLayout(forCharacterRange: NSRange(location: len - 1, length: 1))
        }
        textView.scrollRangeToVisible(NSRange(location: len, length: 0))

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
        let foreignVariant = SupportedLanguages.activeVariant(forCode: foreign.code)
        let foreignFlag = foreignVariant?.flag ?? foreign.flag
        sourceLangBtn.title = "\(foreignFlag) \(foreign.localizedName) ▾"
        sourceLangBtn.setAccessibilityValue(foreign.localizedName)
        sourceLangBtn.setAccessibilityLabel(L10n.tr("header.callerLanguage", "Caller Language"))
        if let v = foreignVariant, SupportedLanguages.variants(forCode: foreign.code).count > 1 {
            sourceLangBtn.toolTip = "\(L10n.tr("header.callerLanguage", "Caller Language")): \(foreign.localizedName) (\(v.localizedRegionName))"
        } else {
            sourceLangBtn.toolTip = L10n.tr("header.callerLanguage", "Caller Language")
        }

        let useCustomTarget = !AppSettings.shared.isMicEnabled && !AppSettings.shared.subtitleFollowsMainLanguage
        if useCustomTarget {
            let target = AppSettings.shared.targetLanguageItem
            targetLangBtn.title = "\(target.flag) \(target.localizedName) ▾"
            targetLangBtn.setAccessibilityValue(target.localizedName)
            let tip = L10n.tr("settings.subtitleLanguage", "Subtitle Language")
            targetLangBtn.toolTip = tip
            targetLangBtn.setAccessibilityLabel(tip)
        } else {
            let main = AppSettings.shared.mainLanguageItem
            let mainVariant = SupportedLanguages.activeVariant(forCode: main.code)
            let mainFlag = mainVariant?.flag ?? main.flag
            targetLangBtn.title = "\(mainFlag) \(main.localizedName) ▾"
            targetLangBtn.setAccessibilityValue(main.localizedName)
            let baseTip = L10n.tr("header.yourLanguage", "Your Language")
            if let v = mainVariant, SupportedLanguages.variants(forCode: main.code).count > 1 {
                targetLangBtn.toolTip = "\(baseTip): \(main.localizedName) (\(v.localizedRegionName))"
            } else {
                targetLangBtn.toolTip = baseTip
            }
            targetLangBtn.setAccessibilityLabel(baseTip)
        }
        
        let swapIcon = AppSettings.shared.isMicEnabled ? "arrow.left.arrow.right" : "arrow.right"
        let swapTip = L10n.tr("header.swapLanguages", "Swap Languages")
        if let img = NSImage(systemSymbolName: swapIcon, accessibilityDescription: swapTip) {
            swapLangBtn.image = img.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold))
        }
        swapLangBtn.toolTip = swapTip
        swapLangBtn.setAccessibilityLabel(swapTip)
    }
    
    private func updateAppLanguageButton() {
        let currentCode = AppSettings.shared.appLanguageCode
        let entry = AppSettings.supportedAppLanguages.first(where: { $0.code == currentCode })
            ?? AppSettings.supportedAppLanguages[0]
        appLangBtn.title = "\(entry.flag) \(entry.code.uppercased()) ▾"
        appLangBtn.setAccessibilityValue(entry.name)
        let label = L10n.tr("menu.appLanguage", "App Language")
        appLangBtn.setAccessibilityLabel(label)
        appLangBtn.toolTip = "\(label): \(entry.name)"
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
            placeholderSubtitle.stringValue = "\(foreign.localizedName) ⇄ \(main.localizedName)"
        } else if foreign.code == target.code {
            placeholderSubtitle.stringValue = foreign.localizedName
        } else {
            placeholderSubtitle.stringValue = "\(foreign.localizedName) → \(target.localizedName)"
        }
        placeholderView.isHidden = false
    }
    
    private func loadExistingTranscript() {
        let existing = TranscriptManager.shared.entries
        guard !existing.isEmpty else {
            clearCaptionsUI()
            return
        }
        
        liveRenderDelayBox.cancel()
        paragraphs.removeAll()
        paragraphRanges.removeAll(keepingCapacity: true)
        
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
            let isCaller = (e.speaker.caseInsensitiveCompare("caller") == .orderedSame)
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
        
        liveCallerUtterance = nil
        liveMicUtterance = nil
        lastRenderedShowOriginal = settings.showOriginalText
        lastRenderedIsMicEnabled = settings.isMicEnabled

        guard isViewLoaded, let storage = textView.textStorage else {
            needsRender = !paragraphs.isEmpty
            return
        }

        if paragraphs.isEmpty {
            clearCaptionsUI()
            return
        }

        placeholderView?.isHidden = true

        if !isViewVisibleInWindow {
            needsRender = true
            return
        }

        needsRender = false
        rebuildAllStorage(in: storage)
        lastLiveRenderUptime = ProcessInfo.processInfo.systemUptime
        scrollToBottomSmooth()
    }
    
    @objc private func showSourceLanguageMenu(_ sender: NSButton) {
        SupportedLanguages.refreshCacheInBackground(forCodes: SupportedLanguages.all.map(\.code))
        let menu = NSMenu(title: L10n.tr("header.callerLanguage", "Caller Language"))
        let currentForeign = AppSettings.shared.foreignLanguageCode
        lazyVariantSubmenuContexts.removeAll(keepingCapacity: true)

        for lang in SupportedLanguages.all {
            let variants = SupportedLanguages.variants(forCode: lang.code)
            let hasMultipleVariants = variants.count > 1
            let activeVar = hasMultipleVariants ? SupportedLanguages.activeVariant(forCode: lang.code) : nil
            let flag = activeVar?.flag ?? lang.flag
            var title = "\(flag)  \(lang.localizedName)"
            if let activeVar = activeVar, lang.code == currentForeign {
                title += " (\(activeVar.localizedRegionName))"
            }
            if SpeechAssetDownloader.shared.isDownloading(forCode: lang.code) {
                let pct = SpeechAssetDownloader.shared.progressPercent(forCode: lang.code)
                title += pct > 0 ? "  (\(pct)%)" : "  (…)"
            }
            let item = NSMenuItem(title: title, action: #selector(didSelectSourceLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = lang.code
            item.state = (lang.code == currentForeign) ? .on : .off
            if hasMultipleVariants || SupportedLanguages.isOnDeviceDownloaded(forCode: lang.code) {
                let sub = NSMenu(title: lang.localizedName)
                sub.delegate = self
                lazyVariantSubmenuContexts[ObjectIdentifier(sub)] = LazyVariantSubmenuContext(lang: lang, isSourceMenu: true)
                item.submenu = sub
            }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY - 4), in: sender)
        lazyVariantSubmenuContexts.removeAll(keepingCapacity: false)
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard let ctx = lazyVariantSubmenuContexts[ObjectIdentifier(menu)] else { return }
        menu.removeAllItems()
        populateVariantSubmenu(menu, for: ctx.lang, isSourceMenu: ctx.isSourceMenu)
    }

    private func populateVariantSubmenu(_ sub: NSMenu, for lang: LanguageItem, isSourceMenu: Bool) {
        let variants = SupportedLanguages.variants(forCode: lang.code)
        let activeLocaleId = SupportedLanguages.activeVariant(forCode: lang.code)?.localeId.lowercased()
        let isCurrentLang = isSourceMenu
            ? (AppSettings.shared.foreignLanguageCode == lang.code)
            : (AppSettings.shared.mainLanguageCode == lang.code)

        let downloadedText = L10n.tr("model.downloaded", "Downloaded")
        let downloadText = L10n.tr("model.download", "Download")

        for v in variants {
            let isDown = SupportedLanguages.isLocaleDownloaded(v.localeId)
            var vTitle = "\(v.flag)  \(v.localizedRegionName) (\(v.localeId))"
            if isDown {
                vTitle += "  •  \(downloadedText)"
            } else {
                vTitle += "  •  \(downloadText)"
            }
            let vItem = NSMenuItem(
                title: vTitle,
                action: isSourceMenu ? #selector(didSelectSourceVariant(_:)) : #selector(didSelectTargetVariant(_:)),
                keyEquivalent: ""
            )
            vItem.target = self
            vItem.representedObject = "\(lang.code)|\(v.localeId)"
            vItem.state = (isCurrentLang && v.localeId.lowercased() == activeLocaleId) ? .on : .off
            sub.addItem(vItem)
        }

        let anyInstalled = variants.contains { SupportedLanguages.isLocaleDownloaded($0.localeId) }
            || SupportedLanguages.isOnDeviceDownloaded(forCode: lang.code)
        if anyInstalled {
            sub.addItem(NSMenuItem.separator())
            for v in variants where SupportedLanguages.isLocaleDownloaded(v.localeId) {
                let delTitle = variants.count > 1
                    ? String(format: L10n.tr("model.deleteRegionFormat", "Delete %@ (%@) Model"), v.localizedRegionName, v.localeId)
                    : String(format: L10n.tr("model.deleteLanguageFormat", "Delete Downloaded %@ Model"), lang.localizedName)
                let delItem = NSMenuItem(
                    title: delTitle,
                    action: #selector(didSelectDeleteLanguageAsset(_:)),
                    keyEquivalent: ""
                )
                delItem.target = self
                delItem.representedObject = "\(lang.code)|\(v.localeId)"
                sub.addItem(delItem)
            }
        }
    }

    @objc private func didSelectSourceVariant(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let parts = raw.components(separatedBy: "|")
        guard let code = parts.first, !code.isEmpty else { return }
        let localeId = parts.count > 1 ? parts[1] : nil
        clearAlertBanner()
        AppDelegate.sharedIfAvailable?.clearSystemAlertBanner()
        let wasKnownDownloaded = localeId.map { SupportedLanguages.isLocaleDownloaded($0) } ?? false
        if let localeId = localeId {
            AppSettings.shared.setPreferredSpeechLocale(localeId, forCode: code)
        }
        AppSettings.shared.foreignLanguageCode = code
        updateLanguageButtons()
        if !AppPaths.isTestEnvironment, let localeId = localeId, !wasKnownDownloaded {
            SpeechAssetDownloader.shared.ensureDownloaded(forCode: code, preferredLocaleId: localeId, force: false)
        }
    }

    @objc private func didSelectTargetVariant(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let parts = raw.components(separatedBy: "|")
        guard let code = parts.first, !code.isEmpty else { return }
        let localeId = parts.count > 1 ? parts[1] : nil
        clearAlertBanner()
        AppDelegate.sharedIfAvailable?.clearSystemAlertBanner()
        let wasKnownDownloaded = localeId.map { SupportedLanguages.isLocaleDownloaded($0) } ?? false
        if let localeId = localeId {
            AppSettings.shared.setPreferredSpeechLocale(localeId, forCode: code)
        }
        if !AppSettings.shared.isMicEnabled && !AppSettings.shared.subtitleFollowsMainLanguage {
            AppSettings.shared.targetLanguageCode = code
        } else {
            AppSettings.shared.setMainAndTargetLanguage(code)
            if !AppPaths.isTestEnvironment, let localeId = localeId, !wasKnownDownloaded {
                SpeechAssetDownloader.shared.ensureDownloaded(forCode: code, preferredLocaleId: localeId, force: false)
            }
        }
        updateLanguageButtons()
    }

    @objc private func didSelectDeleteLanguageAsset(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let parts = raw.components(separatedBy: "|")
        guard let code = parts.first, !code.isEmpty else { return }
        let localeId = parts.count > 1 ? parts[1] : nil
        SpeechAssetDownloader.shared.deleteDownloadedAsset(forCode: code, localeId: localeId)
    }
    
    @objc private func didSelectSourceLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        clearAlertBanner()
        AppDelegate.sharedIfAvailable?.clearSystemAlertBanner()
        AppSettings.shared.foreignLanguageCode = code
    }
    
    @objc private func showTargetLanguageMenu(_ sender: NSButton) {
        SupportedLanguages.refreshCacheInBackground(forCodes: SupportedLanguages.all.map(\.code))
        let useCustomTarget = !AppSettings.shared.isMicEnabled && !AppSettings.shared.subtitleFollowsMainLanguage
        let menuTitle = useCustomTarget
            ? L10n.tr("settings.subtitleLanguage", "Subtitle Language")
            : L10n.tr("header.yourLanguage", "Your Language")
        let menu = NSMenu(title: menuTitle)
        let currentCode = useCustomTarget
            ? AppSettings.shared.targetLanguageCode
            : AppSettings.shared.mainLanguageCode
        lazyVariantSubmenuContexts.removeAll(keepingCapacity: true)

        for lang in SupportedLanguages.all {
            let variants = SupportedLanguages.variants(forCode: lang.code)
            let hasMultipleVariants = variants.count > 1
            let activeVar = (!useCustomTarget && hasMultipleVariants) ? SupportedLanguages.activeVariant(forCode: lang.code) : nil
            let flag = activeVar?.flag ?? lang.flag
            var title = "\(flag)  \(lang.localizedName)"
            if !useCustomTarget, let activeVar = activeVar, lang.code == currentCode {
                title += " (\(activeVar.localizedRegionName))"
            }
            if SpeechAssetDownloader.shared.isDownloading(forCode: lang.code) {
                let pct = SpeechAssetDownloader.shared.progressPercent(forCode: lang.code)
                title += pct > 0 ? "  (\(pct)%)" : "  (…)"
            }
            let item = NSMenuItem(title: title, action: #selector(didSelectTargetLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = lang.code
            item.state = (lang.code == currentCode) ? .on : .off
            if !useCustomTarget && (hasMultipleVariants || SupportedLanguages.isOnDeviceDownloaded(forCode: lang.code)) {
                let sub = NSMenu(title: lang.localizedName)
                sub.delegate = self
                lazyVariantSubmenuContexts[ObjectIdentifier(sub)] = LazyVariantSubmenuContext(lang: lang, isSourceMenu: false)
                item.submenu = sub
            }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY - 4), in: sender)
        lazyVariantSubmenuContexts.removeAll(keepingCapacity: false)
    }
    
    @objc private func didSelectTargetLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        clearAlertBanner()
        AppDelegate.sharedIfAvailable?.clearSystemAlertBanner()
        if !AppSettings.shared.isMicEnabled && !AppSettings.shared.subtitleFollowsMainLanguage {
            AppSettings.shared.targetLanguageCode = code
        } else {
            AppSettings.shared.setMainAndTargetLanguage(code)
        }
    }

    @objc private func showAppLanguageMenu(_ sender: NSButton) {
        let menuTitle = L10n.tr("menu.appLanguage", "App Language")
        let menu = NSMenu(title: menuTitle)
        let headerItem = NSMenuItem(title: menuTitle, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        let currentCode = AppSettings.shared.appLanguageCode
        for lang in AppSettings.supportedAppLanguages {
            let item = NSMenuItem(
                title: "\(lang.flag)  \(lang.name)",
                action: #selector(didSelectAppLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = lang.code
            item.state = (lang.code == currentCode) ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY - 4), in: sender)
    }

    @objc private func didSelectAppLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        AppSettings.shared.appLanguageCode = code
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
            
            copyTranscriptResetBox.schedule(delayNanoseconds: 1_200_000_000) { [weak self] in
                guard let self = self, self.isViewLoaded else { return }
                if let docImg = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy") {
                    self.copyBtn.image = docImg.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12.5, weight: .medium))
                    self.copyBtn.contentTintColor = NSColor.secondaryLabelColor
                }
            }
        }
    }
    
    public func clearCaptionsUI() {
        liveRenderDelayBox.cancel()
        paragraphs.removeAll()
        paragraphRanges.removeAll(keepingCapacity: true)
        lastFinalizedSpeaker = nil
        currentParagraphSentenceCount = 0
        currentParagraphWordCount = 0
        lastFinalizedTime = Date.distantPast
        liveCallerUtterance = nil
        liveMicUtterance = nil
        finalizedCharLength = 0
        needsRender = false
        isUserScrolledUp = false
        
        guard isViewLoaded else { return }
        jumpToLatestBtn.isHidden = true
        
        isProgrammaticScrollOrLayout = true
        textView.textStorage?.beginEditing()
        textView.textStorage?.setAttributedString(NSAttributedString())
        textView.textStorage?.endEditing()
        isProgrammaticScrollOrLayout = false
        
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
        alert.addButton(withTitle: L10n.tr("common.cancel", "Cancel"))
        AppDelegate.sharedIfAvailable?.setPopoverModalConfirmationActive(true)
        if let win = view.window, win.isVisible {
            alert.beginSheetModal(for: win) { [weak self] response in
                Task { @MainActor in
                    AppDelegate.sharedIfAvailable?.setPopoverModalConfirmationActive(false)
                    guard let self = self, response == .alertFirstButtonReturn else { return }
                    CaptionCoordinator.shared.clearTranscript()
                    self.clearCaptionsUI()
                }
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            AppDelegate.sharedIfAvailable?.setPopoverModalConfirmationActive(false)
            if response == .alertFirstButtonReturn {
                CaptionCoordinator.shared.clearTranscript()
                clearCaptionsUI()
            }
        }
    }
    
    @objc private func handleTranscriptEntriesUpdated(_ notification: Notification) {
        if TranscriptManager.shared.entries.isEmpty {
            clearCaptionsUI()
            return
        }
        let userInfo = notification.userInfo
        let isRestoredBulkLoad = (userInfo?["restoredFromAutosave"] as? Bool == true)
            || (userInfo?["newEntry"] == nil && userInfo?["refinedEntry"] == nil)
        if isRestoredBulkLoad && paragraphs.isEmpty && liveCallerUtterance == nil && liveMicUtterance == nil {
            loadExistingTranscript()
            if TranscriptManager.shared.restoredFromAutosave && !didShowRestoredTranscriptBanner {
                didShowRestoredTranscriptBanner = true
                showAlertBanner(
                    message: L10n.tr("tray.restoredTranscript", "Previous transcript restored. Clear it if this is a new call."),
                    actionType: .clearRestoredTranscript
                )
            }
        }
    }
    
    @objc private func togglePinAction() {
        AppSettings.shared.isPinned.toggle()
        updatePinButtonState()
    }
    
    @objc private func openSettingsAction() {
        AppDelegate.sharedIfAvailable?.openSettingsWindow()
    }
    
    @objc private func closePopoverAction() {
        AppDelegate.sharedIfAvailable?.closeTrayPopover()
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
        if CaptionCoordinator.shared.isPaused {
            clearLiveUtterances()
        }
        updatePauseResumeButtonState()
        updatePlaceholderText()
    }
    
    @objc private func togglePauseResumeAction() {
        CaptionCoordinator.shared.togglePauseResume()
    }
    
    private func refreshLocalizedStaticChrome() {
        closeBtn?.toolTip = L10n.tr("header.close", "Close")
        closeBtn?.setAccessibilityLabel(L10n.tr("header.close", "Close"))
        settingsBtn?.toolTip = L10n.tr("header.settings", "Settings")
        settingsBtn?.setAccessibilityLabel(L10n.tr("header.settings", "Settings"))
        copyBtn?.toolTip = L10n.tr("header.copy", "Copy")
        copyBtn?.setAccessibilityLabel(L10n.tr("header.copy", "Copy"))
        clearBtn?.toolTip = L10n.tr("header.clear", "Clear")
        clearBtn?.setAccessibilityLabel(L10n.tr("header.clear", "Clear"))
        jumpToLatestBtn?.title = L10n.tr("tray.latest", "Latest")
        liveShareStopBtn?.title = L10n.tr("tray.stop", "Stop")
        liveShareStopBtn?.setAccessibilityLabel(L10n.tr("tray.stop", "Stop"))
        alertCloseBtn?.toolTip = L10n.tr("tray.dismiss", "Dismiss")
        alertCloseBtn?.setAccessibilityLabel(L10n.tr("tray.dismiss", "Dismiss"))
        if !liveShareBannerView.isHidden {
            updateLiveShareBannerText()
        }
        if !alertBannerView.isHidden, let msg = activeAlertMessage {
            let localizedMsg: String
            if case .clearRestoredTranscript = currentAlertActionType {
                localizedMsg = L10n.tr("tray.restoredTranscript", "Previous transcript restored. Clear it if this is a new call.")
            } else {
                localizedMsg = msg
            }
            showAlertBanner(message: localizedMsg, actionType: currentAlertActionType)
        }
    }

    @objc private func handleSettingsChanged() {
        let current = SettingsSnapshot.current()
        let previous = lastSettingsSnapshot
        if current == previous {
            return
        }
        lastSettingsSnapshot = current

        let appLangChanged = (previous == nil)
            || (current.appLanguageCode != previous?.appLanguageCode)
            || (current.appLanguageCode != lastRenderedAppLanguage)
        if appLangChanged {
            lastRenderedAppLanguage = current.appLanguageCode
            refreshLocalizedStaticChrome()
            updateAppLanguageButton()
        }

        let micChanged = (previous == nil) || (current.isMicEnabled != previous?.isMicEnabled)
        let langButtonsChanged = appLangChanged
            || micChanged
            || (current.foreignLanguageCode != previous?.foreignLanguageCode)
            || (current.mainLanguageCode != previous?.mainLanguageCode)
            || (current.targetLanguageCode != previous?.targetLanguageCode)
            || (current.subtitleFollowsMainLanguage != previous?.subtitleFollowsMainLanguage)
            || (current.preferredForeignLocale != previous?.preferredForeignLocale)
            || (current.preferredMainLocale != previous?.preferredMainLocale)

        if langButtonsChanged {
            updateLanguageButtons()
        }
        if micChanged || appLangChanged {
            updateMicButtonState()
        }
        if appLangChanged {
            updateLiveShareButtonState()
            updatePauseResumeButtonState()
        }
        if appLangChanged || (current.isPinned != previous?.isPinned) {
            updatePinButtonState()
        }
        if langButtonsChanged || micChanged || appLangChanged {
            updatePlaceholderText()
        }

        let clearedMicUtterance = micChanged && !current.isMicEnabled && liveMicUtterance != nil
        if micChanged && !current.isMicEnabled {
            liveMicUtterance = nil
        }

        let needsRerender = (
            appLangChanged ||
            current.captionFontSize != cachedFontSize ||
            current.showOriginalText != lastRenderedShowOriginal ||
            current.isMicEnabled != lastRenderedIsMicEnabled
        )
        if needsRerender {
            rerenderCaptionsPreservingLiveState()
        } else if clearedMicUtterance, isViewLoaded {
            renderLiveSection()
        }
    }
}
