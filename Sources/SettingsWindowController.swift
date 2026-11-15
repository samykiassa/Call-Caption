import AppKit
import Speech
import AVFoundation


public enum StatusBadgeStyle: Sendable {
    case neutral
    case positive
    case warning
    case negative
}

public final class StatusBadgeView: NSView {
    public var title: String = "Checking" {
        didSet {
            guard title != oldValue else { return }
            needsDisplay = true
        }
    }
    public var isGranted: Bool = false {
        didSet {
            guard isGranted != oldValue else { return }
            style = isGranted ? .positive : Self.legacyStyle(for: title)
            needsDisplay = true
        }
    }
    public var style: StatusBadgeStyle = .warning {
        didSet {
            guard style != oldValue else { return }
            needsDisplay = true
        }
    }
    public var statusContextLabel: String?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func legacyStyle(for title: String) -> StatusBadgeStyle {
        let lower = title.lowercased()
        if lower.contains("denied") || lower.contains("denegado")
            || lower.contains("restricted") || lower.contains("restringido")
            || lower.contains("failed") || lower.contains("error") {
            return .negative
        }
        return .warning
    }

    public func setStatus(isGranted: Bool, title: String) {
        let resolved: StatusBadgeStyle = isGranted ? .positive : Self.legacyStyle(for: title)
        setStatus(resolved, title: title)
    }

    public func setStatus(_ style: StatusBadgeStyle, title: String) {
        let granted = (style == .positive)
        guard self.style != style || self.title != title || self.isGranted != granted else { return }
        self.style = style
        self.isGranted = granted
        self.title = title
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let textColor: NSColor
        let bgColor: NSColor
        let borderColor: NSColor

        switch style {
        case .positive:
            textColor = NSColor(red: 0.24, green: 0.90, blue: 0.56, alpha: 1.0)
            bgColor = NSColor(red: 0.08, green: 0.30, blue: 0.18, alpha: 0.45)
            borderColor = NSColor(red: 0.24, green: 0.90, blue: 0.56, alpha: 0.28)
        case .negative:
            textColor = NSColor(red: 0.98, green: 0.42, blue: 0.42, alpha: 1.0)
            bgColor = NSColor(red: 0.38, green: 0.12, blue: 0.12, alpha: 0.45)
            borderColor = NSColor(red: 0.98, green: 0.42, blue: 0.42, alpha: 0.28)
        case .warning:
            textColor = NSColor(red: 0.96, green: 0.72, blue: 0.28, alpha: 1.0)
            bgColor = NSColor(red: 0.36, green: 0.24, blue: 0.08, alpha: 0.45)
            borderColor = NSColor(red: 0.96, green: 0.72, blue: 0.28, alpha: 0.28)
        case .neutral:
            textColor = NSColor(red: 0.72, green: 0.76, blue: 0.84, alpha: 1.0)
            bgColor = NSColor(red: 0.20, green: 0.23, blue: 0.28, alpha: 0.55)
            borderColor = NSColor(red: 0.72, green: 0.76, blue: 0.84, alpha: 0.22)
        }

        let cornerRadius = bounds.height / 2.0
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        bgColor.setFill()
        path.fill()
        borderColor.setStroke()
        path.lineWidth = 1.0
        path.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail

        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .kern: -0.1,
            .paragraphStyle: paragraph
        ]
        let text = title as NSString
        let textSize = text.size(withAttributes: attrs)

        let dotSize: CGFloat = 6.0
        let spacing: CGFloat = 5.0
        let maxTextWidth = max(0, bounds.width - 14.0 - dotSize - spacing)
        let drawWidth = min(ceil(textSize.width), maxTextWidth)
        let totalWidth = dotSize + spacing + drawWidth
        let startX = max(7.0, round((bounds.width - totalWidth) / 2.0))
        let centerY = bounds.height / 2.0

        let textY = round(centerY - (textSize.height / 2.0))
        let dotY = round(centerY - dotSize / 2.0)

        let dotRect = NSRect(x: startX, y: dotY, width: dotSize, height: dotSize)
        textColor.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        let textRect = NSRect(x: startX + dotSize + spacing, y: textY, width: drawWidth, height: ceil(textSize.height))
        text.draw(in: textRect, withAttributes: attrs)
    }

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    public override func accessibilityLabel() -> String? {
        if let statusContextLabel, !statusContextLabel.isEmpty {
            return "\(statusContextLabel): \(title)"
        }
        return title
    }
}


public final class AudioLevelMeterView: NSView {
    private var lastDrawnLevel: Float = -1.0
    private var lastDrawnPeak: Float = -1.0
    private var lastDrawnThreshold: Float = -1.0

    public var level: Float = 0.0 {
        didSet {
            let clamped = min(1.0, max(0.0, level.isFinite ? level : 0.0))
            if level != clamped {
                level = clamped
                return
            }
            if abs(clamped - lastDrawnLevel) >= 0.004 || (clamped == 0.0 && lastDrawnLevel > 0.0) {
                needsDisplay = true
            }
        }
    }

    public var peakLevel: Float = 0.0 {
        didSet {
            let clamped = min(1.0, max(0.0, peakLevel.isFinite ? peakLevel : 0.0))
            if peakLevel != clamped {
                peakLevel = clamped
                return
            }
            if abs(clamped - lastDrawnPeak) >= 0.004 || (clamped == 0.0 && lastDrawnPeak > 0.0) {
                needsDisplay = true
            }
        }
    }

    public var thresholdNormalized: Float = 0.06 {
        didSet {
            let clamped = min(0.90, max(0.02, thresholdNormalized.isFinite ? thresholdNormalized : 0.06))
            if thresholdNormalized != clamped {
                thresholdNormalized = clamped
                return
            }
            if abs(clamped - lastDrawnThreshold) >= 0.004 {
                needsDisplay = true
            }
        }
    }

    public var accentColor: NSColor = NSColor(red: 0.24, green: 0.90, blue: 0.56, alpha: 1.0)
    public var meterAccessibilityLabel: String = "Audio Level"

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        lastDrawnLevel = level
        lastDrawnPeak = peakLevel
        lastDrawnThreshold = thresholdNormalized

        let rect = bounds.insetBy(dx: 0.5, dy: 2.0)
        let radius = rect.height / 2.0
        let trackPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.white.withAlphaComponent(0.07).setFill()
        trackPath.fill()

        // Optimal target zone highlight (20% - 78%)
        let optStart = rect.minX + rect.width * 0.20
        let optWidth = rect.width * 0.58
        let optRect = NSRect(x: optStart, y: rect.minY + 1.0, width: optWidth, height: rect.height - 2.0)
        NSColor.white.withAlphaComponent(0.04).setFill()
        NSBezierPath(rect: optRect).fill()

        if level > 0.005 {
            let fillW = max(radius * 2.0, rect.width * CGFloat(min(1.0, level)))
            let fillRect = NSRect(x: rect.minX, y: rect.minY, width: min(rect.width, fillW), height: rect.height)
            let fillColor: NSColor
            if level > 0.88 {
                fillColor = NSColor(red: 0.98, green: 0.42, blue: 0.42, alpha: 0.95)
            } else if level < thresholdNormalized {
                fillColor = NSColor(red: 0.96, green: 0.72, blue: 0.28, alpha: 0.80)
            } else {
                fillColor = accentColor.withAlphaComponent(0.92)
            }
            fillColor.setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
        }

        // Speech detection threshold tick mark
        let threshX = round(rect.minX + rect.width * CGFloat(thresholdNormalized))
        let threshRect = NSRect(x: threshX, y: rect.minY, width: 1.5, height: rect.height)
        NSColor.white.withAlphaComponent(0.45).setFill()
        NSBezierPath(rect: threshRect).fill()

        // Peak hold marker
        if peakLevel > 0.02 {
            let peakX = min(rect.maxX - 2.0, max(rect.minX + 2.0, round(rect.minX + rect.width * CGFloat(peakLevel))))
            let peakRect = NSRect(x: peakX, y: rect.minY + 1.0, width: 2.0, height: rect.height - 2.0)
            NSColor.white.withAlphaComponent(0.88).setFill()
            NSBezierPath(rect: peakRect).fill()
        }

        NSColor.white.withAlphaComponent(0.12).setStroke()
        trackPath.lineWidth = 1.0
        trackPath.stroke()
    }

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .levelIndicator }
    public override func accessibilityLabel() -> String? { meterAccessibilityLabel }
    public override func accessibilityValue() -> Any? { Int(round(level * 100)) }
}

private final class UncheckedTimerRef: @unchecked Sendable {
    let timer: Timer
    init(_ timer: Timer) { self.timer = timer }
}

private final class AudioCheckTimerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var timer: Timer?

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timer != nil
    }

    func replace(with newTimer: Timer) {
        lock.lock()
        let old = timer
        timer = newTimer
        lock.unlock()
        if let old {
            Self.invalidateTimer(old)
        }
    }

    func invalidate() {
        lock.lock()
        let current = timer
        timer = nil
        lock.unlock()
        if let current {
            Self.invalidateTimer(current)
        }
    }

    private static func invalidateTimer(_ t: Timer) {
        if Thread.isMainThread {
            t.invalidate()
        } else {
            let ref = UncheckedTimerRef(t)
            DispatchQueue.main.async {
                ref.timer.invalidate()
            }
        }
    }
}


public final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    private static let followMainSentinel = "__follow_main__"

    private var tabView: NSTabView!
    private var segmentedControl: NSSegmentedControl!

    private var foreignLangPopup: NSPopUpButton!
    private var mainLangPopup: NSPopUpButton!
    private var targetLangPopup: NSPopUpButton!
    private var appLangPopup: NSPopUpButton!
    private var lastRenderedAppLanguage: String = AppSettings.shared.appLanguageCode
    private var needsReloadOnShow = false
    private var lastRenderedTargetMainCode: String = AppSettings.shared.mainLanguageCode
    private var lastDictationPriorityPair: (foreign: String, main: String)?
    private var cachedLocaleDownloadedById: [String: Bool] = [:]
    private var dictationProbeGeneration: Int = 0
    private var wasDownloadingDictation = false
    private var deletedFeedbackBanner: (until: Date, message: String)?
    private var dictationVariantPopup: NSPopUpButton!
    private var dictationStatusBadge: StatusBadgeView!
    private var dictationStatusLabel: NSTextField!
    private var downloadDictationBtn: NSButton!
    private var deleteDictationBtn: NSButton!

    private var micEnabledSwitch: NSSwitch!
    private var shareBothSwitch: NSSwitch!
    private var allowLANShareSwitch: NSSwitch!
    private var externalTunnelSwitch: NSSwitch!
    private var pauseOnLockSwitch: NSSwitch!
    private var showOriginalSwitch: NSSwitch!
    private var autosaveSwitch: NSSwitch!
    private var autoPopupSwitch: NSSwitch!
    private var autoHideDelayPopup: NSPopUpButton!
    private var fontSizeSegmented: NSSegmentedControl!

    private var screenPermBadge: StatusBadgeView!
    private var micPermBadge: StatusBadgeView!
    private var speechPermBadge: StatusBadgeView!
    private var screenActionBtn: NSButton!
    private var micActionBtn: NSButton!
    private var speechActionBtn: NSButton!

    private var callerCheckBadge: StatusBadgeView!
    private var callerDetailLabel: NSTextField!
    private var callerMeterView: AudioLevelMeterView!
    private var callerLevelValueLabel: NSTextField!
    private var callerGainSlider: NSSlider!
    private var callerGainValueLabel: NSTextField!

    private var micCheckBadge: StatusBadgeView!
    private var micDetailLabel: NSTextField!
    private var micMeterView: AudioLevelMeterView!
    private var micLevelValueLabel: NSTextField!
    private var micGainSlider: NSSlider!
    private var micGainValueLabel: NSTextField!

    private var autoGainSwitch: NSSwitch!
    private var calibrationStatusLabel: NSTextField!
    private var calibrateNowBtn: NSButton!
    private var resetCalibrationBtn: NSButton!
    private var checkAudioBtn: NSButton!
    private var soundSettingsBtn: NSButton!
    private var acousticModeLabel: NSTextField!
    private let audioCheckTimerBox = AudioCheckTimerBox()

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.tr("settings.title", "Settings")
        window.isReleasedWhenClosed = false
        window.center()
        window.level = .normal
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0)

        super.init(window: window)
        window.delegate = self
        setupUI()
        refreshSettingsValues()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePermissionStateChanged),
            name: PermissionHelper.permissionStateDidChangeNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppSettingsChanged),
            name: AppSettings.didChangeNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioGainChanged),
            name: AppSettings.audioGainDidChangeNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSpeechAssetStateChanged),
            name: SpeechAssetDownloader.stateDidChangeNotification,
            object: nil
        )
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        audioCheckTimerBox.invalidate()
    }

    public override func showWindow(_ sender: Any?) {
        if needsReloadOnShow {
            needsReloadOnShow = false
            rebuildLocalizedUI()
        }
        super.showWindow(sender)
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        if needsReloadOnShow {
            needsReloadOnShow = false
            rebuildLocalizedUI()
        } else {
            refreshSettingsValues()
        }
        startAudioCheckTimerIfNeeded()
        SupportedLanguages.refreshCacheInBackground { [weak self] in
            guard let self, self.window?.isVisible == true else { return }
            self.scheduleDictationStatusRefresh()
        }
    }

    public func windowWillClose(_ notification: Notification) {
        stopAudioCheckTimer()
    }

    public func windowDidMiniaturize(_ notification: Notification) {
        stopAudioCheckTimer()
    }

    public func windowDidDeminiaturize(_ notification: Notification) {
        startAudioCheckTimerIfNeeded()
    }

    @objc private func handlePermissionStateChanged() {
        guard window?.isVisible == true else { return }
        switch segmentedControl?.selectedSegment {
        case 2:
            refreshPermissions()
        case 3:
            refreshAudioDiagnostics()
        default:
            break
        }
    }

    @objc private func handleAppSettingsChanged() {
        let currentAppLang = AppSettings.shared.appLanguageCode
        if currentAppLang != lastRenderedAppLanguage {
            lastRenderedAppLanguage = currentAppLang
            guard window?.isVisible == true else {
                needsReloadOnShow = true
                return
            }
            needsReloadOnShow = false
            rebuildLocalizedUI()
            return
        }
        guard window?.isVisible == true else { return }
        syncSettingsControlsFromStore()
        if segmentedControl?.selectedSegment == 3 {
            refreshAudioGainControls()
        } else if segmentedControl?.selectedSegment == 0 {
            refreshDictationModelsStatus(rebuildPopupIfNeeded: true)
        }
    }

    @objc private func handleAudioGainChanged() {
        guard window?.isVisible == true, segmentedControl?.selectedSegment == 3 else { return }
        refreshAudioGainControls()
    }

    @objc private func handleSpeechAssetStateChanged() {
        guard window?.isVisible == true, segmentedControl?.selectedSegment == 0 else { return }
        scheduleDictationStatusRefresh()
    }

    private func rebuildLocalizedUI() {
        let selectedIdx = segmentedControl?.selectedSegment ?? 0
        window?.title = L10n.tr("settings.title", "Settings")
        lastDictationPriorityPair = nil
        setupUI()
        refreshSettingsValues()
        selectTab(selectedIdx)
    }

    public func selectTab(_ index: Int) {
        guard index >= 0 && index < 4 else { return }
        segmentedControl?.selectedSegment = index
        tabView?.selectTabViewItem(at: index)
        if index != 3 {
            stopAudioCheckTimer()
        }
        if index == 0 {
            refreshDictationModelsStatus(rebuildPopupIfNeeded: false)
        } else if index == 2 {
            refreshPermissions()
        } else if index == 3 {
            refreshAudioGainControls()
            refreshAudioDiagnostics()
            startAudioCheckTimerIfNeeded()
        }
    }


    private func makeRowLabel(_ text: String, frame: NSRect) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.frame = frame
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor(white: 0.92, alpha: 1.0),
            .kern: -0.12
        ]
        label.attributedStringValue = NSAttributedString(string: text, attributes: attrs)
        return label
    }

    private func makeCard(frame: NSRect) -> NSBox {
        let card = NSBox(frame: frame)
        card.boxType = .custom
        card.cornerRadius = 10
        card.fillColor = NSColor.white.withAlphaComponent(0.035)
        card.borderColor = NSColor.white.withAlphaComponent(0.07)
        card.borderWidth = 1.0
        card.contentViewMargins = .zero
        return card
    }

    private func makeDivider(width: CGFloat, y: CGFloat) -> NSView {
        let div = NSView(frame: NSRect(x: 16, y: y, width: width - 32, height: 1))
        div.wantsLayer = true
        div.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        return div
    }

    private func setupUI() {
        guard let window = self.window else { return }

        let contentBounds = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 620, height: 520)
        let root = NSView(frame: contentBounds)
        root.wantsLayer = true
        root.autoresizingMask = [.width, .height]
        root.layer?.backgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0).cgColor
        window.contentView = root

        let width = root.bounds.width
        let height = root.bounds.height

        segmentedControl = NSSegmentedControl(
            labels: [
                L10n.tr("settings.tab.languages", "Languages"),
                L10n.tr("settings.tab.general", "General"),
                L10n.tr("settings.tab.permissions", "Permissions"),
                L10n.tr("settings.tab.audio", "Audio")
            ],
            trackingMode: .selectOne,
            target: self,
            action: #selector(tabChanged(_:))
        )
        segmentedControl.selectedSegment = 0
        segmentedControl.segmentStyle = .texturedSquare
        segmentedControl.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let segW = max(376, min(width - 40, ceil(segmentedControl.fittingSize.width) + 24))
        segmentedControl.frame = NSRect(x: round((width - segW) / 2.0), y: height - 42, width: segW, height: 26)
        segmentedControl.setAccessibilityLabel(L10n.tr("settings.title", "Settings"))
        root.addSubview(segmentedControl)

        let topDivider = NSView(frame: NSRect(x: 0, y: height - 54, width: width, height: 1))
        topDivider.wantsLayer = true
        topDivider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        root.addSubview(topDivider)

        tabView = NSTabView(frame: NSRect(x: 20, y: 16, width: width - 40, height: height - 78))
        tabView.tabViewType = .noTabsNoBorder
        root.addSubview(tabView)

        let langTab = NSTabViewItem(identifier: "languages")
        langTab.view = createLanguagesTabView(frame: tabView.bounds)
        tabView.addTabViewItem(langTab)

        let genTab = NSTabViewItem(identifier: "general")
        genTab.view = createGeneralTabView(frame: tabView.bounds)
        tabView.addTabViewItem(genTab)

        let permTab = NSTabViewItem(identifier: "permissions")
        permTab.view = createPermissionsTabView(frame: tabView.bounds)
        tabView.addTabViewItem(permTab)

        let audioTab = NSTabViewItem(identifier: "audio")
        audioTab.view = createAudioTabView(frame: tabView.bounds)
        tabView.addTabViewItem(audioTab)
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        selectTab(sender.selectedSegment)
    }


    private func createLanguagesTabView(frame: NSRect) -> NSView {
        let view = NSView(frame: frame)
        let cardW = frame.width
        let rowH: CGFloat = 44
        let cardH: CGFloat = rowH * 4

        let card = makeCard(frame: NSRect(x: 0, y: frame.height - cardH - 8, width: cardW, height: cardH))

        let r1Y = cardH - rowH
        let callerLabel = L10n.tr("header.callerLanguage", "Caller Language")
        card.addSubview(makeRowLabel(callerLabel, frame: NSRect(x: 16, y: r1Y + 13, width: 240, height: 18)))
        foreignLangPopup = NSPopUpButton(frame: NSRect(x: cardW - 236, y: r1Y + 9, width: 220, height: 26))
        foreignLangPopup.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        populateLanguagePopup(foreignLangPopup)
        foreignLangPopup.target = self
        foreignLangPopup.action = #selector(foreignLanguageChanged(_:))
        foreignLangPopup.setAccessibilityLabel(callerLabel)
        card.addSubview(foreignLangPopup)
        card.addSubview(makeDivider(width: cardW, y: r1Y))

        let r2Y = cardH - rowH * 2
        let yourLabel = L10n.tr("header.yourLanguage", "Your Language")
        card.addSubview(makeRowLabel(yourLabel, frame: NSRect(x: 16, y: r2Y + 13, width: 240, height: 18)))
        mainLangPopup = NSPopUpButton(frame: NSRect(x: cardW - 236, y: r2Y + 9, width: 220, height: 26))
        mainLangPopup.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        populateLanguagePopup(mainLangPopup)
        mainLangPopup.target = self
        mainLangPopup.action = #selector(mainLanguageChanged(_:))
        mainLangPopup.setAccessibilityLabel(yourLabel)
        card.addSubview(mainLangPopup)
        card.addSubview(makeDivider(width: cardW, y: r2Y))

        let r3Y = cardH - rowH * 3
        let subLabel = L10n.tr("settings.subtitleLanguage", "Subtitle Language")
        card.addSubview(makeRowLabel(subLabel, frame: NSRect(x: 16, y: r3Y + 13, width: 240, height: 18)))
        targetLangPopup = NSPopUpButton(frame: NSRect(x: cardW - 236, y: r3Y + 9, width: 220, height: 26))
        targetLangPopup.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        populateTargetLanguagePopup(targetLangPopup)
        targetLangPopup.target = self
        targetLangPopup.action = #selector(targetLanguageChanged(_:))
        targetLangPopup.setAccessibilityLabel(subLabel)
        card.addSubview(targetLangPopup)
        card.addSubview(makeDivider(width: cardW, y: r3Y))

        let r4Y: CGFloat = 0
        let appLangLabel = L10n.tr("settings.appLanguage", "App Language")
        card.addSubview(makeRowLabel(appLangLabel, frame: NSRect(x: 16, y: r4Y + 13, width: 240, height: 18)))
        appLangPopup = NSPopUpButton(frame: NSRect(x: cardW - 236, y: r4Y + 9, width: 220, height: 26))
        appLangPopup.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        populateAppLanguagePopup(appLangPopup)
        appLangPopup.target = self
        appLangPopup.action = #selector(appLanguageChanged(_:))
        appLangPopup.setAccessibilityLabel(appLangLabel)
        card.addSubview(appLangPopup)

        view.addSubview(card)

        let dictCardH: CGFloat = 132
        let dictCardY = frame.height - cardH - 8 - dictCardH - 12
        let dictCard = makeCard(frame: NSRect(x: 0, y: dictCardY, width: cardW, height: dictCardH))

        let dictationModelsTitle = L10n.tr("settings.dictationModels", "On-Device Dictation Models")
        dictCard.addSubview(makeRowLabel(
            dictationModelsTitle,
            frame: NSRect(x: 16, y: 102, width: 320, height: 18)
        ))
        dictationStatusBadge = StatusBadgeView(frame: NSRect(x: cardW - 120, y: 100, width: 104, height: 22))
        dictationStatusBadge.statusContextLabel = dictationModelsTitle
        dictCard.addSubview(dictationStatusBadge)
        dictCard.addSubview(makeDivider(width: cardW, y: 90))

        dictCard.addSubview(makeRowLabel(
            L10n.tr("settings.dialectRegion", "Dialect / Region"),
            frame: NSRect(x: 16, y: 58, width: 126, height: 18)
        ))

        deleteDictationBtn = NSButton(title: L10n.tr("model.delete", "Delete"), target: self, action: #selector(deleteDictationClicked))
        deleteDictationBtn.bezelStyle = .rounded
        deleteDictationBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let delW = max(76, ceil(deleteDictationBtn.fittingSize.width) + 8)
        let delX = cardW - 16 - delW
        deleteDictationBtn.frame = NSRect(x: delX, y: 53, width: delW, height: 28)
        deleteDictationBtn.setAccessibilityLabel(L10n.tr("model.delete", "Delete"))

        downloadDictationBtn = NSButton(title: L10n.tr("model.downloading", "Downloading…"), target: self, action: #selector(downloadDictationClicked))
        downloadDictationBtn.bezelStyle = .rounded
        downloadDictationBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let dlW = max(116, ceil(downloadDictationBtn.fittingSize.width) + 8)
        let dlX = delX - 8 - dlW
        downloadDictationBtn.title = L10n.tr("model.download", "Download")
        downloadDictationBtn.frame = NSRect(x: dlX, y: 53, width: dlW, height: 28)
        downloadDictationBtn.setAccessibilityLabel(L10n.tr("model.download", "Download"))

        dictationVariantPopup = NSPopUpButton(frame: NSRect(x: 146, y: 54, width: dlX - 8 - 146, height: 26))
        dictationVariantPopup.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        dictationVariantPopup.target = self
        dictationVariantPopup.action = #selector(dictationVariantChanged(_:))
        dictationVariantPopup.setAccessibilityLabel(L10n.tr("settings.dialectRegion", "Dialect / Region"))
        dictCard.addSubview(dictationVariantPopup)
        dictCard.addSubview(downloadDictationBtn)
        dictCard.addSubview(deleteDictationBtn)

        dictCard.addSubview(makeDivider(width: cardW, y: 44))

        dictationStatusLabel = NSTextField(labelWithString: L10n.tr("settings.checkingModels", "Checking installed speech models…"))
        dictationStatusLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        dictationStatusLabel.textColor = NSColor(white: 0.68, alpha: 1.0)
        dictationStatusLabel.lineBreakMode = .byTruncatingTail
        dictationStatusLabel.frame = NSRect(x: 16, y: 14, width: cardW - 32, height: 16)
        dictCard.addSubview(dictationStatusLabel)

        view.addSubview(dictCard)

        let footerY = dictCardY - 40
        let swapTitle = L10n.tr("header.swapLanguages", "Swap Languages")
        let swapBtn = NSButton(title: swapTitle, target: self, action: #selector(swapLanguagesClicked))
        swapBtn.bezelStyle = .rounded
        swapBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        if let swapImg = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil) {
            swapBtn.image = swapImg.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10.5, weight: .medium))
            swapBtn.imagePosition = .imageLeading
        }
        let swapW = max(144, ceil(swapBtn.fittingSize.width) + 10)
        swapBtn.frame = NSRect(x: 0, y: footerY, width: swapW, height: 28)
        swapBtn.setAccessibilityLabel(swapTitle)
        view.addSubview(swapBtn)

        let transTitle = L10n.tr("settings.translationLanguagesBtn", "Translation Languages…")
        let transBtn = NSButton(title: transTitle, target: self, action: #selector(openTranslationSettingsClicked))
        transBtn.bezelStyle = .rounded
        transBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let transW = max(150, ceil(transBtn.fittingSize.width) + 8)
        transBtn.frame = NSRect(x: swapW + 8, y: footerY, width: transW, height: 28)
        transBtn.setAccessibilityLabel(transTitle)
        view.addSubview(transBtn)

        let dictTitle = L10n.tr("settings.dictationSettingsBtn", "Dictation Settings…")
        let dictBtn = NSButton(title: dictTitle, target: self, action: #selector(openDictationSettingsClicked))
        dictBtn.bezelStyle = .rounded
        dictBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let dictW = max(140, ceil(dictBtn.fittingSize.width) + 8)
        dictBtn.frame = NSRect(x: cardW - dictW, y: footerY, width: dictW, height: 28)
        dictBtn.setAccessibilityLabel(dictTitle)
        view.addSubview(dictBtn)

        return view
    }


    private func createGeneralTabView(frame: NSRect) -> NSView {
        let view = NSView(frame: frame)
        let cardW = frame.width
        let rowH: CGFloat = 38
        let cardH: CGFloat = rowH * 10

        let card = makeCard(frame: NSRect(x: 0, y: frame.height - cardH - 6, width: cardW, height: cardH))

        let r1Y = cardH - rowH
        let micTransLabel = L10n.tr("settings.micTranslation", "Microphone Translation")
        card.addSubview(makeRowLabel(micTransLabel, frame: NSRect(x: 16, y: r1Y + 10, width: 380, height: 18)))
        micEnabledSwitch = NSSwitch(frame: NSRect(x: cardW - 54, y: r1Y + 8, width: 38, height: 22))
        micEnabledSwitch.target = self
        micEnabledSwitch.action = #selector(micEnabledToggled(_:))
        micEnabledSwitch.setAccessibilityLabel(micTransLabel)
        card.addSubview(micEnabledSwitch)
        card.addSubview(makeDivider(width: cardW, y: r1Y))

        let r2Y = cardH - rowH * 2
        let shareBothLabel = L10n.tr("settings.shareBothSpeakers", "Share Both Speakers on Live Link")
        card.addSubview(makeRowLabel(shareBothLabel, frame: NSRect(x: 16, y: r2Y + 10, width: 380, height: 18)))
        shareBothSwitch = NSSwitch(frame: NSRect(x: cardW - 54, y: r2Y + 8, width: 38, height: 22))
        shareBothSwitch.target = self
        shareBothSwitch.action = #selector(shareBothToggled(_:))
        shareBothSwitch.setAccessibilityLabel(shareBothLabel)
        card.addSubview(shareBothSwitch)
        card.addSubview(makeDivider(width: cardW, y: r2Y))

        let r3Y = cardH - rowH * 3
        let allowLANLabel = L10n.tr("settings.allowLAN", "Allow LAN Access on Live Link")
        card.addSubview(makeRowLabel(allowLANLabel, frame: NSRect(x: 16, y: r3Y + 10, width: 380, height: 18)))
        allowLANShareSwitch = NSSwitch(frame: NSRect(x: cardW - 54, y: r3Y + 8, width: 38, height: 22))
        allowLANShareSwitch.target = self
        allowLANShareSwitch.action = #selector(allowLANShareToggled(_:))
        allowLANShareSwitch.setAccessibilityLabel(allowLANLabel)
        card.addSubview(allowLANShareSwitch)
        card.addSubview(makeDivider(width: cardW, y: r3Y))

        let r4Y = cardH - rowH * 4
        let extTunnelLabel = L10n.tr("settings.useExternalTunnel", "Use External Live Link Tunnel")
        card.addSubview(makeRowLabel(extTunnelLabel, frame: NSRect(x: 16, y: r4Y + 10, width: 380, height: 18)))
        externalTunnelSwitch = NSSwitch(frame: NSRect(x: cardW - 54, y: r4Y + 8, width: 38, height: 22))
        externalTunnelSwitch.target = self
        externalTunnelSwitch.action = #selector(externalTunnelToggled(_:))
        externalTunnelSwitch.setAccessibilityLabel(extTunnelLabel)
        externalTunnelSwitch.toolTip = L10n.tr("settings.useExternalTunnel.tooltip", "Off keeps Live Link local/LAN only; no captions leave your network.")
        card.addSubview(externalTunnelSwitch)
        card.addSubview(makeDivider(width: cardW, y: r4Y))

        let r5Y = cardH - rowH * 5
        let pauseLockLabel = L10n.tr("settings.pauseOnLock", "Pause Capture on Lock/Sleep")
        card.addSubview(makeRowLabel(pauseLockLabel, frame: NSRect(x: 16, y: r5Y + 10, width: 380, height: 18)))
        pauseOnLockSwitch = NSSwitch(frame: NSRect(x: cardW - 54, y: r5Y + 8, width: 38, height: 22))
        pauseOnLockSwitch.target = self
        pauseOnLockSwitch.action = #selector(pauseOnLockToggled(_:))
        pauseOnLockSwitch.setAccessibilityLabel(pauseLockLabel)
        card.addSubview(pauseOnLockSwitch)
        card.addSubview(makeDivider(width: cardW, y: r5Y))

        let r6Y = cardH - rowH * 6
        let showOrigLabel = L10n.tr("settings.showOriginal", "Show Original Text Locally")
        card.addSubview(makeRowLabel(showOrigLabel, frame: NSRect(x: 16, y: r6Y + 10, width: 380, height: 18)))
        showOriginalSwitch = NSSwitch(frame: NSRect(x: cardW - 54, y: r6Y + 8, width: 38, height: 22))
        showOriginalSwitch.target = self
        showOriginalSwitch.action = #selector(showOriginalToggled(_:))
        showOriginalSwitch.setAccessibilityLabel(showOrigLabel)
        showOriginalSwitch.toolTip = L10n.tr("settings.showOriginal.tooltip", "Affects the local caption display. Live Link always includes original and translated text for the viewer.")
        card.addSubview(showOriginalSwitch)
        card.addSubview(makeDivider(width: cardW, y: r6Y))

        let r7Y = cardH - rowH * 7
        let autosaveLabel = L10n.tr("settings.autosaveTranscripts", "Autosave Session Transcripts")
        card.addSubview(makeRowLabel(autosaveLabel, frame: NSRect(x: 16, y: r7Y + 10, width: 380, height: 18)))
        autosaveSwitch = NSSwitch(frame: NSRect(x: cardW - 54, y: r7Y + 8, width: 38, height: 22))
        autosaveSwitch.target = self
        autosaveSwitch.action = #selector(autosaveToggled(_:))
        autosaveSwitch.setAccessibilityLabel(autosaveLabel)
        card.addSubview(autosaveSwitch)
        card.addSubview(makeDivider(width: cardW, y: r7Y))

        let r8Y = cardH - rowH * 8
        let autoPopupLabel = L10n.tr("settings.autoPopup", "Open Automatically on Caller Speech")
        card.addSubview(makeRowLabel(autoPopupLabel, frame: NSRect(x: 16, y: r8Y + 10, width: 380, height: 18)))
        autoPopupSwitch = NSSwitch(frame: NSRect(x: cardW - 54, y: r8Y + 8, width: 38, height: 22))
        autoPopupSwitch.target = self
        autoPopupSwitch.action = #selector(autoPopupToggled(_:))
        autoPopupSwitch.setAccessibilityLabel(autoPopupLabel)
        card.addSubview(autoPopupSwitch)
        card.addSubview(makeDivider(width: cardW, y: r8Y))

        let r9Y = cardH - rowH * 9
        let autoDismissLabel = L10n.tr("settings.autoDismiss", "Auto-Dismiss")
        card.addSubview(makeRowLabel(autoDismissLabel, frame: NSRect(x: 16, y: r9Y + 10, width: 220, height: 18)))
        autoHideDelayPopup = NSPopUpButton(frame: NSRect(x: cardW - 156, y: r9Y + 6, width: 140, height: 26))
        autoHideDelayPopup.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        autoHideDelayPopup.addItems(withTitles: [
            L10n.tr("settings.autoDismiss.3s", "3 seconds"),
            L10n.tr("settings.autoDismiss.5s", "5 seconds"),
            L10n.tr("settings.autoDismiss.8s", "8 seconds"),
            L10n.tr("settings.autoDismiss.12s", "12 seconds"),
            L10n.tr("settings.autoDismiss.never", "Never")
        ])
        autoHideDelayPopup.target = self
        autoHideDelayPopup.action = #selector(autoHideDelayChanged(_:))
        autoHideDelayPopup.setAccessibilityLabel(autoDismissLabel)
        card.addSubview(autoHideDelayPopup)
        card.addSubview(makeDivider(width: cardW, y: r9Y))

        let r10Y: CGFloat = 0
        let textSizeLabel = L10n.tr("settings.textSize", "Text Size")
        card.addSubview(makeRowLabel(textSizeLabel, frame: NSRect(x: 16, y: r10Y + 10, width: 220, height: 18)))
        fontSizeSegmented = NSSegmentedControl(
            labels: ["S", "M", "L", "XL"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(fontSizeChanged(_:))
        )
        fontSizeSegmented.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        fontSizeSegmented.frame = NSRect(x: cardW - 176, y: r10Y + 6, width: 160, height: 26)
        fontSizeSegmented.setAccessibilityLabel(textSizeLabel)
        card.addSubview(fontSizeSegmented)

        view.addSubview(card)

        let footerY: CGFloat = 16
        let deleteTitle = L10n.tr("settings.deleteLocalData", "Delete Local Data…")
        let deleteBtn = NSButton(title: deleteTitle, target: self, action: #selector(deleteLocalDataAction))
        deleteBtn.bezelStyle = .rounded
        deleteBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let deleteW = max(144, ceil(deleteBtn.fittingSize.width) + 8)
        deleteBtn.frame = NSRect(x: 0, y: footerY, width: deleteW, height: 28)
        deleteBtn.setAccessibilityLabel(deleteTitle)
        view.addSubview(deleteBtn)

        let privacyTitle = L10n.tr("settings.privacyLegal", "Privacy & Legal…")
        let privacyBtn = NSButton(title: privacyTitle, target: self, action: #selector(openPrivacyAction))
        privacyBtn.bezelStyle = .rounded
        privacyBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let privacyW = max(130, ceil(privacyBtn.fittingSize.width) + 8)
        privacyBtn.frame = NSRect(x: deleteW + 8, y: footerY, width: privacyW, height: 28)
        privacyBtn.setAccessibilityLabel(privacyTitle)
        view.addSubview(privacyBtn)

        return view
    }


    private func createPermissionsTabView(frame: NSRect) -> NSView {
        let view = NSView(frame: frame)
        let cardW = frame.width
        let rowH: CGFloat = 52
        let cardH: CGFloat = rowH * 3

        let card = makeCard(frame: NSRect(x: 0, y: frame.height - cardH - 8, width: cardW, height: cardH))

        let r1Y = cardH - rowH
        addPermissionRow(
            to: card,
            y: r1Y,
            width: cardW,
            height: rowH,
            iconName: "speaker.wave.2.fill",
            iconColor: NSColor(red: 0.24, green: 0.90, blue: 0.56, alpha: 1.0),
            title: L10n.tr("settings.perm.systemAudio", "System Audio Recording"),
            actionSelector: #selector(screenActionClicked),
            outBadge: &screenPermBadge,
            outButton: &screenActionBtn
        )
        card.addSubview(makeDivider(width: cardW, y: r1Y))

        let r2Y = cardH - rowH * 2
        addPermissionRow(
            to: card,
            y: r2Y,
            width: cardW,
            height: rowH,
            iconName: "mic.fill",
            iconColor: NSColor(red: 0.98, green: 0.58, blue: 0.24, alpha: 1.0),
            title: L10n.tr("settings.perm.microphone", "Microphone"),
            actionSelector: #selector(micActionClicked),
            outBadge: &micPermBadge,
            outButton: &micActionBtn
        )
        card.addSubview(makeDivider(width: cardW, y: r2Y))

        addPermissionRow(
            to: card,
            y: 0,
            width: cardW,
            height: rowH,
            iconName: "waveform",
            iconColor: NSColor(red: 0.28, green: 0.84, blue: 0.98, alpha: 1.0),
            title: L10n.tr("settings.perm.speech", "Speech Recognition"),
            actionSelector: #selector(speechActionClicked),
            outBadge: &speechPermBadge,
            outButton: &speechActionBtn
        )

        view.addSubview(card)

        let footerY = frame.height - cardH - 48
        let repromptTitle = L10n.tr("settings.perm.retryCapture", "Retry Capture")
        let repromptBtn = NSButton(title: repromptTitle, target: self, action: #selector(retryCaptureAction))
        repromptBtn.bezelStyle = .rounded
        repromptBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let repromptW = max(112, ceil(repromptBtn.fittingSize.width) + 6)
        repromptBtn.frame = NSRect(x: 0, y: footerY, width: repromptW, height: 28)
        repromptBtn.setAccessibilityLabel(repromptTitle)
        view.addSubview(repromptBtn)

        let onboardingTitle = L10n.tr("menu.setupGuide", "Setup Guide…")
        let onboardingBtn = NSButton(title: onboardingTitle, target: self, action: #selector(openOnboardingAction))
        onboardingBtn.bezelStyle = .rounded
        onboardingBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let guideW = max(112, ceil(onboardingBtn.fittingSize.width) + 6)
        onboardingBtn.frame = NSRect(x: repromptW + 6, y: footerY, width: guideW, height: 28)
        onboardingBtn.setAccessibilityLabel(onboardingTitle)
        view.addSubview(onboardingBtn)

        let privacyTitle = L10n.tr("settings.privacyLegal", "Privacy & Legal…")
        let privacyBtn = NSButton(title: privacyTitle, target: self, action: #selector(openPrivacyAction))
        privacyBtn.bezelStyle = .rounded
        privacyBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let privacyW = max(112, ceil(privacyBtn.fittingSize.width) + 6)
        privacyBtn.frame = NSRect(x: repromptW + 6 + guideW + 6, y: footerY, width: privacyW, height: 28)
        privacyBtn.setAccessibilityLabel(privacyTitle)
        view.addSubview(privacyBtn)

        let relaunchTitle = L10n.tr("settings.perm.restartApp", "Restart App")
        let relaunchBtn = NSButton(title: relaunchTitle, target: self, action: #selector(relaunchAppAction))
        relaunchBtn.bezelStyle = .rounded
        relaunchBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let relaunchW = max(98, ceil(relaunchBtn.fittingSize.width) + 6)
        relaunchBtn.frame = NSRect(x: cardW - relaunchW, y: footerY, width: relaunchW, height: 28)
        relaunchBtn.setAccessibilityLabel(relaunchTitle)
        view.addSubview(relaunchBtn)

        return view
    }

    private func createAudioTabView(frame: NSRect) -> NSView {
        let view = NSView(frame: frame)
        let cardW = frame.width
        let channelCardH: CGFloat = 132

        let callerCardY = frame.height - channelCardH - 6
        let callerCard = makeCard(frame: NSRect(x: 0, y: callerCardY, width: cardW, height: channelCardH))
        populateAudioChannelCard(
            callerCard,
            width: cardW,
            iconName: "speaker.wave.2.fill",
            iconColor: NSColor(red: 0.24, green: 0.90, blue: 0.56, alpha: 1.0),
            title: L10n.tr("settings.audio.systemCaller", "System Audio (Caller)"),
            gainAction: #selector(callerGainSliderChanged(_:)),
            outBadge: &callerCheckBadge,
            outDetailLabel: &callerDetailLabel,
            outMeter: &callerMeterView,
            outLevelLabel: &callerLevelValueLabel,
            outGainSlider: &callerGainSlider,
            outGainValueLabel: &callerGainValueLabel
        )
        view.addSubview(callerCard)

        let micCardY = callerCardY - channelCardH - 10
        let micCard = makeCard(frame: NSRect(x: 0, y: micCardY, width: cardW, height: channelCardH))
        populateAudioChannelCard(
            micCard,
            width: cardW,
            iconName: "mic.fill",
            iconColor: NSColor(red: 0.28, green: 0.84, blue: 0.98, alpha: 1.0),
            title: L10n.tr("settings.audio.micYou", "Microphone (You)"),
            gainAction: #selector(micGainSliderChanged(_:)),
            outBadge: &micCheckBadge,
            outDetailLabel: &micDetailLabel,
            outMeter: &micMeterView,
            outLevelLabel: &micLevelValueLabel,
            outGainSlider: &micGainSlider,
            outGainValueLabel: &micGainValueLabel
        )
        view.addSubview(micCard)

        let calCardH: CGFloat = 96
        let calCardY = micCardY - calCardH - 10
        let calCard = makeCard(frame: NSRect(x: 0, y: calCardY, width: cardW, height: calCardH))

        let autoGainTitle = L10n.tr("settings.audio.autoGain", "Automatic Gain & Noise Calibration")
        calCard.addSubview(makeRowLabel(
            autoGainTitle,
            frame: NSRect(x: 16, y: 63, width: 380, height: 18)
        ))
        autoGainSwitch = NSSwitch(frame: NSRect(x: cardW - 54, y: 61, width: 38, height: 22))
        autoGainSwitch.target = self
        autoGainSwitch.action = #selector(autoGainToggled(_:))
        autoGainSwitch.setAccessibilityLabel(autoGainTitle)
        calCard.addSubview(autoGainSwitch)
        calCard.addSubview(makeDivider(width: cardW, y: 50))

        let resetTitle = L10n.tr("settings.audio.reset", "Reset")
        resetCalibrationBtn = NSButton(title: resetTitle, target: self, action: #selector(resetCalibrationClicked))
        resetCalibrationBtn.bezelStyle = .rounded
        resetCalibrationBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let resetW = max(68, ceil(resetCalibrationBtn.fittingSize.width) + 8)
        let resetX = cardW - 16 - resetW
        resetCalibrationBtn.frame = NSRect(x: resetX, y: 11, width: resetW, height: 28)
        resetCalibrationBtn.setAccessibilityLabel(resetTitle)

        let calibrateTitle = L10n.tr("settings.audio.calibrateNow", "Calibrate Now")
        calibrateNowBtn = NSButton(title: calibrateTitle, target: self, action: #selector(calibrateNowClicked))
        calibrateNowBtn.bezelStyle = .rounded
        calibrateNowBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let calW = max(106, ceil(calibrateNowBtn.fittingSize.width) + 8)
        let calX = resetX - 8 - calW
        calibrateNowBtn.frame = NSRect(x: calX, y: 11, width: calW, height: 28)
        calibrateNowBtn.setAccessibilityLabel(calibrateTitle)

        calibrationStatusLabel = NSTextField(labelWithString: L10n.tr("settings.audio.calibrationHint", "Auto-adjusts caller & mic gains and noise thresholds"))
        calibrationStatusLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        calibrationStatusLabel.textColor = NSColor(white: 0.68, alpha: 1.0)
        calibrationStatusLabel.lineBreakMode = .byTruncatingTail
        calibrationStatusLabel.frame = NSRect(x: 16, y: 17, width: calX - 24, height: 16)

        calCard.addSubview(calibrationStatusLabel)
        calCard.addSubview(calibrateNowBtn)
        calCard.addSubview(resetCalibrationBtn)

        view.addSubview(calCard)

        let footerY: CGFloat = 12
        let checkAudioTitle = L10n.tr("settings.audio.checkAudio", "Check Audio")
        checkAudioBtn = NSButton(title: checkAudioTitle, target: self, action: #selector(checkAudioClicked))
        checkAudioBtn.bezelStyle = .rounded
        checkAudioBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let checkW = max(104, ceil(checkAudioBtn.fittingSize.width) + 8)
        checkAudioBtn.frame = NSRect(x: 0, y: footerY, width: checkW, height: 28)
        checkAudioBtn.setAccessibilityLabel(checkAudioTitle)
        view.addSubview(checkAudioBtn)

        let soundSettingsTitle = L10n.tr("settings.audio.soundSettings", "Sound Settings…")
        soundSettingsBtn = NSButton(title: soundSettingsTitle, target: self, action: #selector(openSoundSettingsClicked))
        soundSettingsBtn.bezelStyle = .rounded
        soundSettingsBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let soundW = max(126, ceil(soundSettingsBtn.fittingSize.width) + 8)
        let soundX = checkW + 8
        soundSettingsBtn.frame = NSRect(x: soundX, y: footerY, width: soundW, height: 28)
        soundSettingsBtn.setAccessibilityLabel(soundSettingsTitle)
        view.addSubview(soundSettingsBtn)

        acousticModeLabel = NSTextField(labelWithString: L10n.tr("settings.audio.outputSpeakers", "Output: Speakers (Echo Guard)"))
        acousticModeLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        acousticModeLabel.textColor = NSColor(white: 0.66, alpha: 1.0)
        acousticModeLabel.alignment = .right
        acousticModeLabel.lineBreakMode = .byTruncatingTail
        let acousticX = soundX + soundW + 10
        acousticModeLabel.frame = NSRect(x: acousticX, y: footerY + 6, width: cardW - acousticX, height: 16)
        view.addSubview(acousticModeLabel)

        return view
    }

    private func populateAudioChannelCard(
        _ card: NSBox,
        width: CGFloat,
        iconName: String,
        iconColor: NSColor,
        title: String,
        gainAction: Selector,
        outBadge: inout StatusBadgeView!,
        outDetailLabel: inout NSTextField!,
        outMeter: inout AudioLevelMeterView!,
        outLevelLabel: inout NSTextField!,
        outGainSlider: inout NSSlider!,
        outGainValueLabel: inout NSTextField!
    ) {
        let icon = NSImageView(frame: NSRect(x: 16, y: 101, width: 20, height: 20))
        if let img = NSImage(systemSymbolName: iconName, accessibilityDescription: title) {
            icon.image = img.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13.5, weight: .semibold))
            icon.contentTintColor = iconColor
        }
        card.addSubview(icon)

        let titleLabel = makeRowLabel(title, frame: NSRect(x: 44, y: 102, width: 190, height: 18))
        card.addSubview(titleLabel)

        let badgeW: CGFloat = 104
        let badgeX = width - 16 - badgeW
        let badge = StatusBadgeView(frame: NSRect(x: badgeX, y: 100, width: badgeW, height: 22))
        badge.statusContextLabel = title
        card.addSubview(badge)
        outBadge = badge

        let detailX: CGFloat = 238
        let detail = NSTextField(labelWithString: L10n.tr("settings.audio.floorPlaceholder", "Floor — dB · SNR — dB"))
        detail.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = NSColor(white: 0.58, alpha: 1.0)
        detail.alignment = .right
        detail.lineBreakMode = .byTruncatingHead
        detail.frame = NSRect(x: detailX, y: 103, width: badgeX - 8 - detailX, height: 16)
        card.addSubview(detail)
        outDetailLabel = detail

        card.addSubview(makeDivider(width: width, y: 90))

        let meterTitle = NSTextField(labelWithString: L10n.tr("settings.audio.signal", "Signal"))
        meterTitle.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        meterTitle.textColor = NSColor(white: 0.74, alpha: 1.0)
        meterTitle.frame = NSRect(x: 16, y: 59, width: 52, height: 16)
        card.addSubview(meterTitle)

        let meter = AudioLevelMeterView(frame: NSRect(x: 74, y: 59, width: width - 160, height: 16))
        meter.accentColor = iconColor
        meter.meterAccessibilityLabel = "\(title) \(L10n.tr("settings.audio.signal", "Signal"))"
        card.addSubview(meter)
        outMeter = meter

        let lvlLabel = NSTextField(labelWithString: "0%")
        lvlLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        lvlLabel.textColor = NSColor(white: 0.78, alpha: 1.0)
        lvlLabel.alignment = .right
        lvlLabel.frame = NSRect(x: width - 80, y: 59, width: 64, height: 16)
        card.addSubview(lvlLabel)
        outLevelLabel = lvlLabel

        card.addSubview(makeDivider(width: width, y: 46))

        let gainTitle = NSTextField(labelWithString: L10n.tr("settings.audio.gain", "Gain"))
        gainTitle.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        gainTitle.textColor = NSColor(white: 0.74, alpha: 1.0)
        gainTitle.frame = NSRect(x: 16, y: 14, width: 64, height: 16)
        card.addSubview(gainTitle)

        let slider = NSSlider(
            value: 1.0,
            minValue: Double(AppSettings.minInputGain),
            maxValue: Double(AppSettings.maxInputGain),
            target: self,
            action: gainAction
        )
        slider.isContinuous = true
        slider.frame = NSRect(x: 84, y: 12, width: width - 200, height: 22)
        slider.setAccessibilityLabel("\(title) \(L10n.tr("settings.audio.gain", "Gain"))")
        card.addSubview(slider)
        outGainSlider = slider

        let gainVal = NSTextField(labelWithString: "1.0× (0.0 dB)")
        gainVal.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        gainVal.textColor = NSColor(white: 0.88, alpha: 1.0)
        gainVal.alignment = .right
        gainVal.frame = NSRect(x: width - 110, y: 14, width: 94, height: 16)
        card.addSubview(gainVal)
        outGainValueLabel = gainVal
    }

    private func addPermissionRow(
        to container: NSView,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        iconName: String,
        iconColor: NSColor,
        title: String,
        actionSelector: Selector,
        outBadge: inout StatusBadgeView!,
        outButton: inout NSButton!
    ) {
        let icon = NSImageView(frame: NSRect(x: 16, y: y + (height - 20) / 2.0, width: 20, height: 20))
        if let img = NSImage(systemSymbolName: iconName, accessibilityDescription: title) {
            icon.image = img.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13.5, weight: .semibold))
            icon.contentTintColor = iconColor
        }
        container.addSubview(icon)

        let btnW: CGFloat = 96
        let badgeW: CGFloat = 104
        let btnX = width - 16 - btnW
        let badgeX = btnX - 8 - badgeW

        let label = makeRowLabel(title, frame: NSRect(x: 44, y: y + (height - 18) / 2.0, width: badgeX - 52, height: 18))
        container.addSubview(label)

        let badge = StatusBadgeView(frame: NSRect(x: badgeX, y: y + (height - 22) / 2.0, width: badgeW, height: 22))
        badge.statusContextLabel = title
        container.addSubview(badge)
        outBadge = badge

        let settingsTitle = L10n.tr("header.settings", "Settings")
        let btn = NSButton(title: settingsTitle, target: self, action: actionSelector)
        btn.bezelStyle = .rounded
        btn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        btn.frame = NSRect(x: btnX, y: y + (height - 28) / 2.0, width: btnW, height: 28)
        btn.setAccessibilityLabel("\(title): \(settingsTitle)")
        container.addSubview(btn)
        outButton = btn
    }


    private func populateLanguagePopup(_ popup: NSPopUpButton) {
        popup.removeAllItems()
        for lang in SupportedLanguages.all {
            let item = NSMenuItem(title: "\(lang.flag)  \(lang.localizedName)", action: nil, keyEquivalent: "")
            item.representedObject = lang.code
            popup.menu?.addItem(item)
        }
    }

    private func populateTargetLanguagePopup(_ popup: NSPopUpButton) {
        popup.removeAllItems()
        let mainLang = AppSettings.shared.mainLanguageItem
        lastRenderedTargetMainCode = mainLang.code
        let followItem = NSMenuItem(
            title: String(format: L10n.tr("settings.sameAsYourLanguage", "Same as Your Language (%@ %@)"), mainLang.flag, mainLang.localizedName),
            action: nil,
            keyEquivalent: ""
        )
        followItem.representedObject = Self.followMainSentinel
        popup.menu?.addItem(followItem)
        popup.menu?.addItem(NSMenuItem.separator())

        for lang in SupportedLanguages.all {
            let item = NSMenuItem(title: "\(lang.flag)  \(lang.localizedName)", action: nil, keyEquivalent: "")
            item.representedObject = lang.code
            popup.menu?.addItem(item)
        }
    }

    private func populateAppLanguagePopup(_ popup: NSPopUpButton) {
        popup.removeAllItems()
        for lang in AppSettings.supportedAppLanguages {
            let item = NSMenuItem(title: "\(lang.flag)  \(lang.name)", action: nil, keyEquivalent: "")
            item.representedObject = lang.code
            popup.menu?.addItem(item)
        }
    }

    private struct DictationProbeResult: Sendable {
        let localeMap: [String: Bool]?
        let foreignCode: String
        let mainCode: String
        let selectedCode: String
        let selectedLocaleId: String
        let selectedTitle: String
        let foreignDown: Bool
        let mainDown: Bool
        let selectedDown: Bool
        let selectedStatus: SpeechAssetDownloadStatus
        let foreignStatus: SpeechAssetDownloadStatus
        let mainStatus: SpeechAssetDownloadStatus
        let foreignRegionName: String?
        let mainRegionName: String?
    }

    public func refreshSettingsValues() {
        syncSettingsControlsFromStore()
        refreshPermissions()
        refreshAudioGainControls()
        refreshAudioDiagnostics()
        refreshDictationModelsStatus(rebuildPopupIfNeeded: true)
    }

    private func syncSettingsControlsFromStore() {
        let settings = AppSettings.shared

        if let target = targetLangPopup, lastRenderedTargetMainCode != settings.mainLanguageCode {
            populateTargetLanguagePopup(target)
        }

        if let idx = SupportedLanguages.all.firstIndex(where: { $0.code == settings.foreignLanguageCode }) {
            foreignLangPopup?.selectItem(at: idx)
        }
        if let idx = SupportedLanguages.all.firstIndex(where: { $0.code == settings.mainLanguageCode }) {
            mainLangPopup?.selectItem(at: idx)
        }
        if settings.subtitleFollowsMainLanguage {
            targetLangPopup?.selectItem(at: 0)
        } else if let idx = SupportedLanguages.all.firstIndex(where: { $0.code == settings.targetLanguageCode }) {
            targetLangPopup?.selectItem(at: idx + 2)
        }
        if let idx = AppSettings.supportedAppLanguages.firstIndex(where: { $0.code == settings.appLanguageCode }) {
            appLangPopup?.selectItem(at: idx)
        }

        micEnabledSwitch?.state = settings.isMicEnabled ? .on : .off
        shareBothSwitch?.state = settings.shareBothSpeakersOnLink ? .on : .off
        allowLANShareSwitch?.state = settings.allowLANShare ? .on : .off
        externalTunnelSwitch?.state = settings.liveShareUseExternalTunnel ? .on : .off
        pauseOnLockSwitch?.state = settings.pauseOnScreenLock ? .on : .off
        showOriginalSwitch?.state = settings.showOriginalText ? .on : .off
        autosaveSwitch?.state = settings.autosaveTranscripts ? .on : .off
        autoPopupSwitch?.state = settings.autoPopupOnForeignSpeech ? .on : .off

        let delay = settings.autoHideDelay
        if delay <= 0.0 {
            autoHideDelayPopup?.selectItem(at: 4)
        } else if delay <= 3.5 {
            autoHideDelayPopup?.selectItem(at: 0)
        } else if delay <= 5.5 {
            autoHideDelayPopup?.selectItem(at: 1)
        } else if delay <= 9.0 {
            autoHideDelayPopup?.selectItem(at: 2)
        } else {
            autoHideDelayPopup?.selectItem(at: 3)
        }

        let size = settings.captionFontSize
        if size <= 14 {
            fontSizeSegmented?.selectedSegment = 0
        } else if size <= 16.5 {
            fontSizeSegmented?.selectedSegment = 1
        } else if size <= 19.5 {
            fontSizeSegmented?.selectedSegment = 2
        } else {
            fontSizeSegmented?.selectedSegment = 3
        }
    }

    private func populateDictationVariantPopup(preservingSelection selectedRep: String?) {
        guard let popup = dictationVariantPopup else { return }
        popup.removeAllItems()

        let settings = AppSettings.shared
        let foreignCode = settings.foreignLanguageCode
        let mainCode = settings.mainLanguageCode
        let priorityCodes = foreignCode == mainCode ? [foreignCode] : [foreignCode, mainCode]
        lastDictationPriorityPair = (foreignCode, mainCode)

        var addedLocaleIds = Set<String>()
        let addVariantsForLanguage: (String) -> Void = { [self] code in
            for v in SupportedLanguages.variants(forCode: code) {
                let lowerLocale = v.localeId.lowercased()
                guard addedLocaleIds.insert(lowerLocale).inserted else { continue }
                let isDown = cachedLocaleDownloadedById[lowerLocale] ?? false
                let suffix = isDown ? " ✓" : ""
                let langDisplay = SupportedLanguages.item(forCode: v.languageCode)?.localizedName ?? v.languageName
                let item = NSMenuItem(
                    title: "\(v.flag) \(langDisplay) — \(v.localizedRegionName)\(suffix)",
                    action: nil,
                    keyEquivalent: ""
                )
                item.representedObject = "\(v.languageCode)|\(v.localeId)"
                popup.menu?.addItem(item)
            }
        }

        for code in priorityCodes {
            addVariantsForLanguage(code)
        }
        popup.menu?.addItem(NSMenuItem.separator())
        for lang in SupportedLanguages.all where !priorityCodes.contains(lang.code) {
            addVariantsForLanguage(lang.code)
        }

        if let selectedRep = selectedRep,
           let idx = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == selectedRep }) {
            popup.selectItem(at: idx)
        } else if let activeForeign = SupportedLanguages.activeVariant(forCode: foreignCode) {
            let targetRep = "\(activeForeign.languageCode)|\(activeForeign.localeId)"
            if let idx = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == targetRep }) {
                popup.selectItem(at: idx)
            }
        }
    }

    private func selectedDictationVariantInfo() -> (code: String, localeId: String, variant: SpeechVariant?)? {
        guard let raw = dictationVariantPopup?.selectedItem?.representedObject as? String else { return nil }
        let parts = raw.components(separatedBy: "|")
        guard parts.count == 2 else { return nil }
        let code = parts[0]
        let localeId = parts[1]
        return (code, localeId, SupportedLanguages.variant(forLocaleId: localeId))
    }

    private func refreshDictationModelsStatus(rebuildPopupIfNeeded: Bool = false) {
        let settings = AppSettings.shared
        let foreignCode = settings.foreignLanguageCode
        let mainCode = settings.mainLanguageCode
        let pairChanged = lastDictationPriorityPair == nil
            || lastDictationPriorityPair?.foreign != foreignCode
            || lastDictationPriorityPair?.main != mainCode

        if pairChanged {
            populateDictationVariantPopup(preservingSelection: nil)
        } else if rebuildPopupIfNeeded, (dictationVariantPopup?.numberOfItems ?? 0) == 0 {
            let currentRep = dictationVariantPopup?.selectedItem?.representedObject as? String
            populateDictationVariantPopup(preservingSelection: currentRep)
        }

        scheduleDictationStatusRefresh(includeFullLocaleScan: true)
    }

    private func scheduleDictationStatusRefresh(includeFullLocaleScan: Bool = false) {
        guard dictationVariantPopup != nil else { return }

        dictationProbeGeneration += 1
        let gen = dictationProbeGeneration

        let settings = AppSettings.shared
        let foreignCode = settings.foreignLanguageCode
        let mainCode = settings.mainLanguageCode
        let selectedInfo = selectedDictationVariantInfo()
        let selectedCode = selectedInfo?.code ?? foreignCode
        let explicitSelectedLocaleId = selectedInfo?.localeId
        let selectedTitle = selectedInfo?.variant?.localizedDisplayTitle ?? selectedCode

        let localeIdsToScan: [String] = if includeFullLocaleScan {
            {
                var ids: [String] = []
                var seen = Set<String>()
                for lang in SupportedLanguages.all {
                    for v in SupportedLanguages.variants(forCode: lang.code) {
                        let lower = v.localeId.lowercased()
                        if seen.insert(lower).inserted {
                            ids.append(v.localeId)
                        }
                    }
                }
                return ids
            }()
        } else {
            []
        }

        Self.probeDictationInBackground(
            includeFullLocaleScan: includeFullLocaleScan,
            localeIdsToScan: localeIdsToScan,
            foreignCode: foreignCode,
            mainCode: mainCode,
            selectedCode: selectedCode,
            explicitSelectedLocaleId: explicitSelectedLocaleId,
            selectedTitle: selectedTitle
        ) { [weak self] result in
            guard let self, self.dictationProbeGeneration == gen else { return }
            self.applyDictationProbeResult(result)
        }
    }

    private nonisolated static func probeDictationInBackground(
        includeFullLocaleScan: Bool,
        localeIdsToScan: [String],
        foreignCode: String,
        mainCode: String,
        selectedCode: String,
        explicitSelectedLocaleId: String?,
        selectedTitle: String,
        completion: @escaping @Sendable @MainActor (DictationProbeResult) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            var localeMap: [String: Bool]?
            if includeFullLocaleScan {
                var map: [String: Bool] = [:]
                map.reserveCapacity(localeIdsToScan.count)
                for localeId in localeIdsToScan {
                    map[localeId.lowercased()] = SupportedLanguages.isLocaleDownloaded(localeId)
                }
                localeMap = map
            }

            let resolvedLocaleId = explicitSelectedLocaleId ?? SupportedLanguages.bestLocale(forCode: selectedCode).identifier
            let selectedDown = localeMap?[resolvedLocaleId.lowercased()] ?? SupportedLanguages.isLocaleDownloaded(resolvedLocaleId)
            let foreignDown = SupportedLanguages.isOnDeviceDownloaded(forCode: foreignCode)
            let mainDown = SupportedLanguages.isOnDeviceDownloaded(forCode: mainCode)
            let selectedStatus = SpeechAssetDownloader.shared.status(forCode: selectedCode)
            let foreignStatus = SpeechAssetDownloader.shared.status(forCode: foreignCode)
            let mainStatus = SpeechAssetDownloader.shared.status(forCode: mainCode)
            let foreignRegionName = SupportedLanguages.activeVariant(forCode: foreignCode)?.localizedRegionName
            let mainRegionName = SupportedLanguages.activeVariant(forCode: mainCode)?.localizedRegionName

            let result = DictationProbeResult(
                localeMap: localeMap,
                foreignCode: foreignCode,
                mainCode: mainCode,
                selectedCode: selectedCode,
                selectedLocaleId: resolvedLocaleId,
                selectedTitle: selectedTitle,
                foreignDown: foreignDown,
                mainDown: mainDown,
                selectedDown: selectedDown,
                selectedStatus: selectedStatus,
                foreignStatus: foreignStatus,
                mainStatus: mainStatus,
                foreignRegionName: foreignRegionName,
                mainRegionName: mainRegionName
            )

            Task { @MainActor in
                completion(result)
            }
        }
    }

    private func updateDictationPopupCheckmarks() {
        guard let popup = dictationVariantPopup else { return }
        for item in popup.itemArray {
            guard let raw = item.representedObject as? String else { continue }
            let parts = raw.components(separatedBy: "|")
            guard parts.count == 2, let v = SupportedLanguages.variant(forLocaleId: parts[1]) else { continue }
            let isDown = cachedLocaleDownloadedById[v.localeId.lowercased()] ?? false
            let suffix = isDown ? " ✓" : ""
            let langDisplay = SupportedLanguages.item(forCode: v.languageCode)?.localizedName ?? v.languageName
            let desiredTitle = "\(v.flag) \(langDisplay) — \(v.localizedRegionName)\(suffix)"
            if item.title != desiredTitle {
                item.title = desiredTitle
            }
        }
    }

    private func applyDictationProbeResult(_ result: DictationProbeResult) {
        if let localeMap = result.localeMap {
            cachedLocaleDownloadedById = localeMap
            updateDictationPopupCheckmarks()
        }

        let currentSelected = selectedDictationVariantInfo()
        let activeLocaleId = currentSelected?.localeId ?? result.selectedLocaleId
        if currentSelected != nil,
           activeLocaleId.caseInsensitiveCompare(result.selectedLocaleId) != .orderedSame {
            scheduleDictationStatusRefresh(includeFullLocaleScan: false)
            return
        }

        let foreignItem = SupportedLanguages.item(forCode: result.foreignCode) ?? AppSettings.shared.foreignLanguageItem
        let mainItem = SupportedLanguages.item(forCode: result.mainCode) ?? AppSettings.shared.mainLanguageItem

        let activeBannerMessage: String?
        if let banner = deletedFeedbackBanner {
            if Date() < banner.until {
                activeBannerMessage = banner.message
            } else {
                deletedFeedbackBanner = nil
                activeBannerMessage = nil
            }
        } else {
            activeBannerMessage = nil
        }

        let downloadTitle = L10n.tr("model.download", "Download")
        let downloadingTitle = L10n.tr("model.downloading", "Downloading…")
        let reverifyTitle = L10n.tr("model.reverify", "Re-verify")

        let anyDownloading = result.selectedStatus.isDownloading
            || result.foreignStatus.isDownloading
            || result.mainStatus.isDownloading
        let finishedDownloadNeedsScan = !anyDownloading && wasDownloadingDictation && result.localeMap == nil
        wasDownloadingDictation = anyDownloading

        if case .downloading(let p) = result.selectedStatus {
            applyDownloadingDictationUI(progress: p, displayName: result.selectedTitle, deleteEnabled: result.selectedDown, bannerMessage: activeBannerMessage, downloadingTitle: downloadingTitle)
            return
        }
        if case .downloading(let p) = result.foreignStatus {
            applyDownloadingDictationUI(progress: p, displayName: foreignItem.localizedName, deleteEnabled: result.selectedDown, bannerMessage: activeBannerMessage, downloadingTitle: downloadingTitle)
            return
        }
        if case .downloading(let p) = result.mainStatus {
            applyDownloadingDictationUI(progress: p, displayName: mainItem.localizedName, deleteEnabled: result.selectedDown, bannerMessage: activeBannerMessage, downloadingTitle: downloadingTitle)
            return
        }

        if finishedDownloadNeedsScan {
            scheduleDictationStatusRefresh(includeFullLocaleScan: true)
        }

        if case .failed(let reason) = result.selectedStatus {
            applyFailedDictationUI(targetName: result.selectedTitle, reason: reason, downloadTitle: downloadTitle, deleteEnabled: result.selectedDown, bannerMessage: activeBannerMessage)
            return
        }
        if case .failed(let reason) = result.foreignStatus {
            applyFailedDictationUI(targetName: foreignItem.localizedName, reason: reason, downloadTitle: downloadTitle, deleteEnabled: result.selectedDown, bannerMessage: activeBannerMessage)
            return
        }
        if case .failed(let reason) = result.mainStatus {
            applyFailedDictationUI(targetName: mainItem.localizedName, reason: reason, downloadTitle: downloadTitle, deleteEnabled: result.selectedDown, bannerMessage: activeBannerMessage)
            return
        }

        if result.selectedStatus == .unsupported {
            dictationStatusBadge?.setStatus(.negative, title: L10n.tr("status.unsupported", "Unsupported"))
            dictationStatusLabel?.stringValue = activeBannerMessage ?? String(
                format: L10n.tr("settings.dictation.unsupported", "Offline dictation unsupported for %@"),
                result.selectedTitle
            )
            downloadDictationBtn?.title = downloadTitle
            downloadDictationBtn?.isEnabled = false
            deleteDictationBtn?.isEnabled = result.selectedDown
            return
        }

        downloadDictationBtn?.isEnabled = true
        downloadDictationBtn?.title = result.selectedDown ? reverifyTitle : downloadTitle
        deleteDictationBtn?.isEnabled = result.selectedDown

        let foreignDesc = result.foreignRegionName.map { "\(foreignItem.localizedName) (\($0))" } ?? foreignItem.localizedName
        let mainDesc = result.mainRegionName.map { "\(mainItem.localizedName) (\($0))" } ?? mainItem.localizedName

        if result.foreignDown && result.mainDown {
            dictationStatusBadge?.setStatus(.positive, title: L10n.tr("status.ready", "Ready"))
            dictationStatusLabel?.stringValue = activeBannerMessage ?? String(format: L10n.tr("settings.dictation.ready", "%@ and %@ ready on this Mac"), foreignDesc, mainDesc)
        } else {
            var missing: [String] = []
            if !result.foreignDown { missing.append(foreignDesc) }
            if !result.mainDown && mainItem.code != foreignItem.code { missing.append(mainDesc) }
            dictationStatusBadge?.setStatus(.warning, title: L10n.tr("status.needed", "Needed"))
            dictationStatusLabel?.stringValue = activeBannerMessage ?? String(format: L10n.tr("settings.dictation.missing", "Missing offline dictation: %@"), missing.joined(separator: ", "))
        }
    }

    private func applyDownloadingDictationUI(progress: Double, displayName: String, deleteEnabled: Bool, bannerMessage: String?, downloadingTitle: String) {
        let pct = Int((progress * 100.0).rounded())
        let pctSuffix = pct > 0 ? " (\(pct)%)" : "…"
        dictationStatusBadge?.setStatus(.warning, title: pct > 0 ? "\(pct)%" : L10n.tr("status.downloading", "Downloading"))
        dictationStatusLabel?.stringValue = bannerMessage ?? String(format: L10n.tr("settings.dictation.downloading", "Downloading %@ dictation model%@"), displayName, pctSuffix)
        downloadDictationBtn?.title = downloadingTitle
        downloadDictationBtn?.isEnabled = false
        deleteDictationBtn?.isEnabled = deleteEnabled
    }

    private func applyFailedDictationUI(targetName: String, reason: String, downloadTitle: String, deleteEnabled: Bool, bannerMessage: String?) {
        dictationStatusBadge?.setStatus(.negative, title: L10n.tr("status.failed", "Failed"))
        dictationStatusLabel?.stringValue = bannerMessage ?? String(
            format: L10n.tr("settings.dictation.failed", "%@ dictation failed: %@"),
            targetName,
            reason
        )
        downloadDictationBtn?.title = downloadTitle
        downloadDictationBtn?.isEnabled = true
        deleteDictationBtn?.isEnabled = deleteEnabled
    }

    public func updateAudioLevels(callerLevel: Float, micLevel: Float) {
        guard window?.isVisible == true, segmentedControl?.selectedSegment == 3 else { return }
        callerMeterView?.level = callerLevel
        micMeterView?.level = micLevel
    }

    private func startAudioCheckTimerIfNeeded() {
        guard window?.isVisible == true,
              segmentedControl?.selectedSegment == 3,
              !audioCheckTimerBox.isActive else {
            return
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleAudioCheckTimerTick()
            }
        }
        audioCheckTimerBox.replace(with: timer)
    }

    private func handleAudioCheckTimerTick() {
        guard window?.isVisible == true, segmentedControl?.selectedSegment == 3 else {
            stopAudioCheckTimer()
            return
        }
        refreshAudioDiagnostics()
    }

    private func stopAudioCheckTimer() {
        audioCheckTimerBox.invalidate()
    }

    private static func formatGainLabel(_ gain: Float) -> String {
        let clamped = AppSettings.clampInputGain(gain)
        let rawDb = 20.0 * log10(max(0.001, clamped))
        let db = abs(rawDb) < 0.05 ? 0.0 : rawDb
        let sign = db >= 0.05 ? "+" : ""
        return String(format: "%.2f× (%@%.1f dB)", clamped, sign, db)
    }

    private static func formatDecibels(_ rms: Float) -> String {
        guard rms > 0.00001 else { return "-∞ dB" }
        let db = max(-80.0, min(0.0, 20.0 * log10(rms)))
        return String(format: "%.0f dB", db)
    }

    private func refreshAudioGainControls() {
        let settings = AppSettings.shared
        let cGain = settings.callerInputGain
        let mGain = settings.micInputGain
        let minGain = Double(AppSettings.minInputGain)
        let maxGain = Double(AppSettings.maxInputGain)
        callerGainSlider?.doubleValue = min(maxGain, max(minGain, Double(cGain)))
        callerGainValueLabel?.stringValue = Self.formatGainLabel(cGain)
        micGainSlider?.doubleValue = min(maxGain, max(minGain, Double(mGain)))
        micGainValueLabel?.stringValue = Self.formatGainLabel(mGain)
        autoGainSwitch?.state = settings.isAutoGainEnabled ? .on : .off
    }

    private static func localizedAudioBadgeTitle(_ status: AudioSignalCheckStatus) -> String {
        switch status {
        case .inactive: return L10n.tr("audioStatus.off", "Off")
        case .permissionDenied: return L10n.tr("audioStatus.denied", "Denied")
        case .waitingForAudio: return L10n.tr("audioStatus.listening", "Listening")
        case .tooQuiet: return L10n.tr("audioStatus.lowSignal", "Low Signal")
        case .optimal: return L10n.tr("audioStatus.goodLevel", "Good Level")
        case .tooLoud: return L10n.tr("audioStatus.highLevel", "High Level")
        case .highNoiseFloor: return L10n.tr("audioStatus.noisyLine", "Noisy Line")
        case .echoSuppressed: return L10n.tr("audioStatus.echoGuard", "Echo Guard")
        }
    }

    private static func audioBadgeStyle(_ status: AudioSignalCheckStatus) -> StatusBadgeStyle {
        if status.isHealthy {
            return .positive
        }
        switch status {
        case .permissionDenied:
            return .negative
        case .inactive:
            return .neutral
        case .tooQuiet, .tooLoud, .highNoiseFloor, .optimal, .waitingForAudio, .echoSuppressed:
            return .warning
        }
    }

    public func refreshAudioDiagnostics() {
        let snapshot = CaptionCoordinator.shared.audioCaptureEngine.diagnosticsSnapshot()

        callerCheckBadge?.setStatus(
            Self.audioBadgeStyle(snapshot.caller.status),
            title: Self.localizedAudioBadgeTitle(snapshot.caller.status)
        )
        callerMeterView?.level = snapshot.caller.displayLevel
        callerMeterView?.peakLevel = min(1.0, snapshot.caller.peakLevel * 6.0)
        callerMeterView?.thresholdNormalized = min(0.65, max(0.03, snapshot.caller.effectiveThreshold * 12.0))
        callerLevelValueLabel?.stringValue = "\(Int(round(snapshot.caller.displayLevel * 100)))%"
        callerDetailLabel?.stringValue = String(
            format: L10n.tr("settings.audio.floorSNR", "Floor %@ · SNR %.0f dB"),
            Self.formatDecibels(snapshot.caller.noiseFloorRMS),
            snapshot.caller.snrDecibels
        )

        micCheckBadge?.setStatus(
            Self.audioBadgeStyle(snapshot.mic.status),
            title: Self.localizedAudioBadgeTitle(snapshot.mic.status)
        )
        micMeterView?.level = snapshot.mic.displayLevel
        micMeterView?.peakLevel = min(1.0, snapshot.mic.peakLevel * 6.0)
        micMeterView?.thresholdNormalized = min(0.75, max(0.03, snapshot.mic.effectiveThreshold * 14.0))
        micLevelValueLabel?.stringValue = "\(Int(round(snapshot.mic.displayLevel * 100)))%"
        micDetailLabel?.stringValue = String(
            format: L10n.tr("settings.audio.floorSNR", "Floor %@ · SNR %.0f dB"),
            Self.formatDecibels(snapshot.mic.noiseFloorRMS),
            snapshot.mic.snrDecibels
        )

        acousticModeLabel?.stringValue = snapshot.isAcousticallyIsolated
            ? L10n.tr("settings.audio.outputHeadphones", "Output: Headphones (Full Duplex)")
            : L10n.tr("settings.audio.outputSpeakers", "Output: Speakers (Echo Guard)")

        if snapshot.isCalibrating {
            calibrationStatusLabel?.stringValue = L10n.tr("settings.audio.calibrating", "Calibrating… Speak or play caller audio now")
            calibrateNowBtn?.isEnabled = false
        } else {
            calibrateNowBtn?.isEnabled = true
            let cGainStr = String(format: "%.2f×", snapshot.caller.inputGain)
            let mGainStr = String(format: "%.2f×", snapshot.mic.inputGain)
            calibrationStatusLabel?.stringValue = snapshot.isAutoGainEnabled
                ? String(format: L10n.tr("settings.audio.autoGainStatus", "Auto-Gain active · Caller %@, Mic %@"), cGainStr, mGainStr)
                : String(format: L10n.tr("settings.audio.manualGainStatus", "Manual Gain · Caller %@, Mic %@"), cGainStr, mGainStr)
        }
    }

    private func refreshPermissions() {
        let settingsTitle = L10n.tr("header.settings", "Settings")
        let allowTitle = L10n.tr("settings.perm.allow", "Allow")

        let screenRowTitle = L10n.tr("settings.perm.systemAudio", "System Audio Recording")
        switch PermissionHelper.shared.audioCaptureState {
        case .active:
            let running = CaptionCoordinator.shared.audioCaptureEngine.isRunning
            let paused = CaptionCoordinator.shared.isPaused
            screenPermBadge?.setStatus(
                running ? .positive : .warning,
                title: running ? L10n.tr("status.capturing", "Capturing") : (paused ? L10n.tr("status.paused", "Paused") : L10n.tr("status.notRunning", "Not running"))
            )
        case .deniedSilenceDetected:
            screenPermBadge?.setStatus(.negative, title: L10n.tr("status.denied", "Denied"))
        case .unknown:
            let running = CaptionCoordinator.shared.audioCaptureEngine.isRunning
            let paused = CaptionCoordinator.shared.isPaused
            screenPermBadge?.setStatus(
                running ? .positive : .neutral,
                title: running ? L10n.tr("status.listening", "Listening") : (paused ? L10n.tr("status.paused", "Paused") : L10n.tr("status.notStarted", "Not started"))
            )
        }
        screenActionBtn?.title = settingsTitle
        screenActionBtn?.setAccessibilityLabel("\(screenRowTitle): \(settingsTitle)")

        let micRowTitle = L10n.tr("settings.perm.microphone", "Microphone")
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .authorized:
            micPermBadge?.setStatus(.positive, title: L10n.tr("status.granted", "Granted"))
            micActionBtn?.title = settingsTitle
        case .denied:
            micPermBadge?.setStatus(.negative, title: L10n.tr("status.denied", "Denied"))
            micActionBtn?.title = settingsTitle
        case .restricted:
            micPermBadge?.setStatus(.negative, title: L10n.tr("status.restricted", "Restricted"))
            micActionBtn?.title = settingsTitle
        case .notDetermined:
            micPermBadge?.setStatus(.neutral, title: L10n.tr("status.optional", "Optional"))
            micActionBtn?.title = allowTitle
        @unknown default:
            micPermBadge?.setStatus(.neutral, title: L10n.tr("status.optional", "Optional"))
            micActionBtn?.title = allowTitle
        }
        if let btnTitle = micActionBtn?.title {
            micActionBtn?.setAccessibilityLabel("\(micRowTitle): \(btnTitle)")
        }

        let speechRowTitle = L10n.tr("settings.perm.speech", "Speech Recognition")
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        switch speechStatus {
        case .authorized:
            speechPermBadge?.setStatus(.positive, title: L10n.tr("status.granted", "Granted"))
            speechActionBtn?.title = settingsTitle
        case .denied:
            speechPermBadge?.setStatus(.negative, title: L10n.tr("status.denied", "Denied"))
            speechActionBtn?.title = settingsTitle
        case .restricted:
            speechPermBadge?.setStatus(.negative, title: L10n.tr("status.restricted", "Restricted"))
            speechActionBtn?.title = settingsTitle
        case .notDetermined:
            speechPermBadge?.setStatus(.warning, title: L10n.tr("status.required", "Required"))
            speechActionBtn?.title = allowTitle
        @unknown default:
            speechPermBadge?.setStatus(.warning, title: L10n.tr("status.required", "Required"))
            speechActionBtn?.title = allowTitle
        }
        if let btnTitle = speechActionBtn?.title {
            speechActionBtn?.setAccessibilityLabel("\(speechRowTitle): \(btnTitle)")
        }
    }


    @objc private func swapLanguagesClicked() {
        AppDelegate.sharedIfAvailable?.clearSystemAlertBanner()
        AppSettings.shared.swapLanguages()
        refreshSettingsValues()
    }

    @objc private func openTranslationSettingsClicked() {
        PermissionHelper.shared.openTranslationSettings()
    }

    @objc private func openDictationSettingsClicked() {
        PermissionHelper.shared.openDictationSettings()
    }

    @objc private func dictationVariantChanged(_ sender: NSPopUpButton) {
        deletedFeedbackBanner = nil
        if let info = selectedDictationVariantInfo() {
            let code = info.code
            let localeId = info.localeId
            if cachedLocaleDownloadedById[localeId.lowercased()] == true {
                AppSettings.shared.setPreferredSpeechLocale(localeId, forCode: code)
                scheduleDictationStatusRefresh(includeFullLocaleScan: false)
            } else {
                scheduleDictationStatusRefresh(includeFullLocaleScan: false)
                Self.checkLocaleDownloadedInBackground(localeId) { [weak self] isDown in
                    guard let self else { return }
                    self.cachedLocaleDownloadedById[localeId.lowercased()] = isDown
                    if isDown {
                        self.updateDictationPopupCheckmarks()
                        if let current = self.selectedDictationVariantInfo(),
                           current.localeId.caseInsensitiveCompare(localeId) == .orderedSame {
                            AppSettings.shared.setPreferredSpeechLocale(localeId, forCode: code)
                        }
                        self.scheduleDictationStatusRefresh(includeFullLocaleScan: false)
                    }
                }
            }
            return
        }
        scheduleDictationStatusRefresh(includeFullLocaleScan: false)
    }

    private nonisolated static func checkLocaleDownloadedInBackground(
        _ localeId: String,
        completion: @escaping @Sendable @MainActor (Bool) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let isDown = SupportedLanguages.isLocaleDownloaded(localeId)
            Task { @MainActor in
                completion(isDown)
            }
        }
    }

    @objc private func downloadDictationClicked() {
        deletedFeedbackBanner = nil
        if let info = selectedDictationVariantInfo() {
            AppSettings.shared.setPreferredSpeechLocale(info.localeId, forCode: info.code)
            SpeechAssetDownloader.shared.ensureDownloaded(forCode: info.code, preferredLocaleId: info.localeId, force: true)
        } else {
            SpeechAssetDownloader.shared.ensureActiveLanguagesDownloaded(force: true)
        }
        scheduleDictationStatusRefresh(includeFullLocaleScan: false)
    }

    @objc private func deleteDictationClicked() {
        if let info = selectedDictationVariantInfo() {
            if AppSettings.shared.preferredSpeechLocale(forCode: info.code)?.caseInsensitiveCompare(info.localeId) == .orderedSame {
                AppSettings.shared.setPreferredSpeechLocale(nil, forCode: info.code)
            }
            deleteDictationBtn?.isEnabled = false
            if let v = info.variant {
                let langDisplay = SupportedLanguages.item(forCode: v.languageCode)?.localizedName ?? v.languageName
                let message = String(format: L10n.tr("settings.dictation.deleted", "Deleted %@ (%@) dictation model"), langDisplay, v.localizedRegionName)
                deletedFeedbackBanner = (Date().addingTimeInterval(3.0), message)
                dictationStatusLabel?.stringValue = message
            }
            let localeId = info.localeId
            let code = info.code
            SpeechAssetDownloader.shared.deleteDownloadedAsset(forCode: code, localeId: localeId) { [weak self] _ in
                guard let self else { return }
                self.cachedLocaleDownloadedById[localeId.lowercased()] = false
                self.scheduleDictationStatusRefresh(includeFullLocaleScan: true)
            }
        } else {
            scheduleDictationStatusRefresh(includeFullLocaleScan: false)
        }
    }

    @objc private func appLanguageChanged(_ sender: NSPopUpButton) {
        if let code = sender.selectedItem?.representedObject as? String {
            AppSettings.shared.appLanguageCode = code
        }
    }

    @objc private func mainLanguageChanged(_ sender: NSPopUpButton) {
        if let code = sender.selectedItem?.representedObject as? String {
            AppSettings.shared.setMainAndTargetLanguage(code)
            refreshSettingsValues()
        }
    }

    @objc private func foreignLanguageChanged(_ sender: NSPopUpButton) {
        if let code = sender.selectedItem?.representedObject as? String {
            AppDelegate.sharedIfAvailable?.clearSystemAlertBanner()
            AppSettings.shared.foreignLanguageCode = code
            refreshSettingsValues()
        }
    }

    @objc private func targetLanguageChanged(_ sender: NSPopUpButton) {
        guard let code = sender.selectedItem?.representedObject as? String else { return }
        if code == Self.followMainSentinel {
            AppSettings.shared.subtitleFollowsMainLanguage = true
        } else {
            AppSettings.shared.targetLanguageCode = code
        }
        refreshSettingsValues()
    }

    @objc private func micEnabledToggled(_ sender: NSSwitch) {
        if sender.state == .on {
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            if status == .authorized {
                AppSettings.shared.isMicEnabled = true
            } else if status == .notDetermined {
                PermissionHelper.shared.requestMicrophoneAccess { [weak self, weak sender] granted in
                    AppSettings.shared.isMicEnabled = granted
                    sender?.state = granted ? .on : .off
                    self?.refreshPermissions()
                }
            } else {
                sender.state = .off
                AppSettings.shared.isMicEnabled = false
                PermissionHelper.shared.openMicrophoneSettings()
            }
        } else {
            AppSettings.shared.isMicEnabled = false
        }
    }

    @objc private func shareBothToggled(_ sender: NSSwitch) {
        AppSettings.shared.shareBothSpeakersOnLink = (sender.state == .on)
        LiveShareManager.shared.speakerSharingDidChange()
    }

    private func presentAlertSheet(_ alert: NSAlert, handler: @escaping @Sendable @MainActor (NSApplication.ModalResponse) -> Void) {
        if let window = self.window {
            alert.beginSheetModal(for: window) { response in
                Task { @MainActor in
                    handler(response)
                }
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            handler(alert.runModal())
        }
    }

    private func applyLiveShareNetworkSetting(
        requiresExternalConsent: Bool = false,
        _ change: @escaping @Sendable @MainActor () -> Void
    ) {
        if !LiveShareManager.shared.isSharing {
            change()
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.tr("settings.restartLiveLink.title", "Restart Live Link?")
        alert.informativeText = L10n.tr("settings.restartLiveLink.message", "Changing network sharing restarts the current Live Link and creates a new link. Current viewers will be disconnected.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("settings.restartLiveLink.confirm", "Restart Link"))
        alert.addButton(withTitle: L10n.tr("common.cancel", "Cancel"))
        presentAlertSheet(alert) { [weak self] response in
            guard let self = self else { return }
            guard response == .alertFirstButtonReturn else {
                self.refreshSettingsValues()
                return
            }
            let applyAndRestart: @MainActor () -> Void = {
                change()
                LiveShareManager.shared.stopSharing()
                CaptionCoordinator.shared.prepareForLiveShareStart()
                LiveShareManager.shared.startSharing()
                LiveShareManager.shared.broadcastPauseState(CaptionCoordinator.shared.isPaused)
            }
            if requiresExternalConsent && !AppSettings.shared.hasAcceptedExternalLiveShareConsent {
                let hostWin = self.window
                DispatchQueue.main.async { [weak self] in
                    guard let delegate = AppDelegate.sharedIfAvailable else {
                        applyAndRestart()
                        return
                    }
                    delegate.requestExternalLiveShareConsentIfNeeded(sheetFor: hostWin) { [weak self] granted in
                        if granted {
                            applyAndRestart()
                        } else {
                            self?.refreshSettingsValues()
                        }
                    }
                }
                return
            }
            applyAndRestart()
        }
    }

    @objc private func allowLANShareToggled(_ sender: NSSwitch) {
        let newValue = (sender.state == .on)
        if newValue {
            let alert = NSAlert()
            alert.messageText = L10n.tr("settings.lanWarning.title", "Enable plaintext LAN access?")
            alert.informativeText = L10n.tr("settings.lanWarning.message", "Direct LAN viewers receive captions over unencrypted HTTP because no TLS certificate is bundled. Use this only on a network you trust. The public HTTPS tunnel and loopback viewers remain end-to-end encrypted.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L10n.tr("settings.lanWarning.confirm", "Enable LAN"))
            alert.addButton(withTitle: L10n.tr("common.cancel", "Cancel"))
            presentAlertSheet(alert) { [weak self] response in
                guard response == .alertFirstButtonReturn else {
                    self?.refreshSettingsValues()
                    return
                }
                self?.applyLiveShareNetworkSetting {
                    AppSettings.shared.allowLANShare = true
                }
            }
            return
        }
        applyLiveShareNetworkSetting {
            AppSettings.shared.allowLANShare = false
        }
    }

    @objc private func externalTunnelToggled(_ sender: NSSwitch) {
        let newValue = (sender.state == .on)
        applyLiveShareNetworkSetting(requiresExternalConsent: newValue) {
            AppSettings.shared.liveShareUseExternalTunnel = newValue
        }
    }

    @objc private func pauseOnLockToggled(_ sender: NSSwitch) {
        AppSettings.shared.pauseOnScreenLock = (sender.state == .on)
    }

    @objc private func autosaveToggled(_ sender: NSSwitch) {
        let enabled = (sender.state == .on)
        AppSettings.shared.autosaveTranscripts = enabled
        if !enabled {
            TranscriptManager.shared.deleteSavedSession()
        }
    }

    @objc private func autoPopupToggled(_ sender: NSSwitch) {
        AppSettings.shared.autoPopupOnForeignSpeech = (sender.state == .on)
    }

    @objc private func autoHideDelayChanged(_ sender: NSPopUpButton) {
        let delays: [Double] = [3.0, 5.0, 8.0, 12.0, 0.0]
        let idx = sender.indexOfSelectedItem
        if idx >= 0 && idx < delays.count {
            AppSettings.shared.autoHideDelay = delays[idx]
        }
    }

    @objc private func showOriginalToggled(_ sender: NSSwitch) {
        AppSettings.shared.showOriginalText = (sender.state == .on)
    }

    @objc private func fontSizeChanged(_ sender: NSSegmentedControl) {
        let sizes: [CGFloat] = [13.0, 16.0, 18.0, 22.0]
        let idx = sender.selectedSegment
        if idx >= 0 && idx < sizes.count {
            AppSettings.shared.captionFontSize = sizes[idx]
        }
    }

    @objc private func screenActionClicked() {
        PermissionHelper.shared.openAudioCaptureSettings()
    }

    @objc private func micActionClicked() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            PermissionHelper.shared.requestMicrophoneAccess { [weak self] _ in
                self?.refreshPermissions()
            }
        } else {
            PermissionHelper.shared.openMicrophoneSettings()
        }
    }

    @objc private func speechActionClicked() {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            PermissionHelper.shared.checkSpeechRecognitionAccess { [weak self] _ in
                self?.refreshPermissions()
            }
        } else {
            PermissionHelper.shared.openSpeechRecognitionSettings()
        }
    }

    @objc private func retryCaptureAction() {
        if !AppSettings.shared.hasCompletedOnboarding {
            openOnboardingAction()
            return
        }
        CaptionCoordinator.shared.retryAudioCapture()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refreshPermissions()
        }
    }

    @objc private func deleteLocalDataAction() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("settings.deleteData.title", "Delete all local data?")
        alert.informativeText = L10n.tr("settings.deleteData.message", "This clears the current transcript, deletes the autosaved transcript, clears cached translations, and removes Live Link history. Your preferences are kept.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("common.delete", "Delete"))
        alert.addButton(withTitle: L10n.tr("common.cancel", "Cancel"))
        presentAlertSheet(alert) { response in
            guard response == .alertFirstButtonReturn else { return }
            CaptionCoordinator.shared.clearTranscript()
            TranscriptManager.shared.deleteSavedSession()
            Task { await TranslationEngine.shared.clearCache() }
        }
    }

    @objc private func openPrivacyAction() {
        AppDelegate.sharedIfAvailable?.openLegalDocument(.privacy)
    }

    @objc private func openOnboardingAction() {
        AppDelegate.sharedIfAvailable?.openOnboardingWindow()
    }

    @objc private func relaunchAppAction() {
        PermissionHelper.shared.restartApp()
    }

    @objc private func callerGainSliderChanged(_ sender: NSSlider) {
        let val = Float(sender.doubleValue)
        AppSettings.shared.callerInputGain = val
        callerGainValueLabel?.stringValue = Self.formatGainLabel(val)
    }

    @objc private func micGainSliderChanged(_ sender: NSSlider) {
        let val = Float(sender.doubleValue)
        AppSettings.shared.micInputGain = val
        micGainValueLabel?.stringValue = Self.formatGainLabel(val)
    }

    @objc private func autoGainToggled(_ sender: NSSwitch) {
        AppSettings.shared.isAutoGainEnabled = (sender.state == .on)
        refreshAudioDiagnostics()
    }

    @objc private func calibrateNowClicked() {
        calibrateNowBtn?.isEnabled = false
        ensureAudioCaptureAndMicReadyForCheck { [weak self] in
            guard let self else { return }
            AppSettings.shared.isAutoGainEnabled = true
            self.autoGainSwitch?.state = .on
            self.refreshAudioDiagnostics()
            CaptionCoordinator.shared.audioCaptureEngine.startGuidedCalibration(duration: 2.5) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.refreshAudioGainControls()
                    self?.refreshAudioDiagnostics()
                }
            }
            self.refreshAudioDiagnostics()
        }
    }

    @objc private func resetCalibrationClicked() {
        CaptionCoordinator.shared.audioCaptureEngine.resetCalibrationState()
        refreshAudioGainControls()
        refreshAudioDiagnostics()
    }

    @objc private func checkAudioClicked() {
        ensureAudioCaptureAndMicReadyForCheck { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.refreshSettingsValues()
            }
        }
    }

    private func startDiagnosticsCapture() {
        if !CaptionCoordinator.shared.hasStarted {
            CaptionCoordinator.shared.startForAudioDiagnostics()
        } else if CaptionCoordinator.shared.isPaused {
            CaptionCoordinator.shared.resume()
        } else {
            CaptionCoordinator.shared.recoverEnginesIfNeeded()
        }
    }

    private func ensureAudioCaptureAndMicReadyForCheck(then completion: @escaping @Sendable @MainActor () -> Void) {
        guard AppSettings.shared.isMicEnabled else {
            startDiagnosticsCapture()
            completion()
            return
        }
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .notDetermined {
            PermissionHelper.shared.requestMicrophoneAccess { [weak self] _ in
                self?.startDiagnosticsCapture()
                self?.refreshSettingsValues()
                completion()
            }
            return
        }
        startDiagnosticsCapture()
        completion()
    }

    @objc private func openSoundSettingsClicked() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
