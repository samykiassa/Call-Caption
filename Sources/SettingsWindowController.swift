import AppKit
import Speech
import AVFoundation


public final class StatusBadgeView: NSView {
    public var title: String = "Checking" {
        didSet { needsDisplay = true }
    }
    public var isGranted: Bool = false {
        didSet { needsDisplay = true }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func setStatus(isGranted: Bool, title: String) {
        self.isGranted = isGranted
        self.title = title
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let textColor: NSColor
        let bgColor: NSColor
        let borderColor: NSColor

        if isGranted {
            textColor = NSColor(red: 0.24, green: 0.90, blue: 0.56, alpha: 1.0)
            bgColor = NSColor(red: 0.08, green: 0.30, blue: 0.18, alpha: 0.45)
            borderColor = NSColor(red: 0.24, green: 0.90, blue: 0.56, alpha: 0.28)
        } else if title.lowercased().contains("denied") {
            textColor = NSColor(red: 0.98, green: 0.42, blue: 0.42, alpha: 1.0)
            bgColor = NSColor(red: 0.38, green: 0.12, blue: 0.12, alpha: 0.45)
            borderColor = NSColor(red: 0.98, green: 0.42, blue: 0.42, alpha: 0.28)
        } else {
            textColor = NSColor(red: 0.96, green: 0.72, blue: 0.28, alpha: 1.0)
            bgColor = NSColor(red: 0.36, green: 0.24, blue: 0.08, alpha: 0.45)
            borderColor = NSColor(red: 0.96, green: 0.72, blue: 0.28, alpha: 0.28)
        }

        let cornerRadius = bounds.height / 2.0
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        bgColor.setFill()
        path.fill()
        borderColor.setStroke()
        path.lineWidth = 1.0
        path.stroke()

        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .kern: -0.1
        ]
        let text = title as NSString
        let textSize = text.size(withAttributes: attrs)

        let dotSize: CGFloat = 6.0
        let spacing: CGFloat = 5.0
        let totalWidth = dotSize + spacing + textSize.width
        let startX = round((bounds.width - totalWidth) / 2.0)
        let centerY = bounds.height / 2.0

        let textY = round(centerY - (textSize.height / 2.0))
        let dotY = round(centerY - dotSize / 2.0)

        let dotRect = NSRect(x: startX, y: dotY, width: dotSize, height: dotSize)
        textColor.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        text.draw(at: NSPoint(x: startX + dotSize + spacing, y: textY), withAttributes: attrs)
    }

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    public override func accessibilityLabel() -> String? { title }
}


public final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    private static let followMainSentinel = "__follow_main__"

    private var tabView: NSTabView!
    private var segmentedControl: NSSegmentedControl!

    private var foreignLangPopup: NSPopUpButton!
    private var mainLangPopup: NSPopUpButton!
    private var targetLangPopup: NSPopUpButton!

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

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 520),
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
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        refreshSettingsValues()
        SupportedLanguages.refreshCacheInBackground { [weak self] in
            self?.refreshSettingsValues()
        }
    }

    @objc private func handlePermissionStateChanged() {
        refreshPermissions()
    }

    public func selectTab(_ index: Int) {
        guard index >= 0 && index < 3 else { return }
        segmentedControl?.selectedSegment = index
        tabView?.selectTabViewItem(at: index)
        if index == 2 {
            refreshPermissions()
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

        let root = NSView(frame: window.contentView!.bounds)
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
                L10n.tr("settings.tab.permissions", "Permissions")
            ],
            trackingMode: .selectOne,
            target: self,
            action: #selector(tabChanged(_:))
        )
        segmentedControl.selectedSegment = 0
        segmentedControl.segmentStyle = .texturedSquare
        segmentedControl.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        segmentedControl.frame = NSRect(x: (width - 300) / 2.0, y: height - 42, width: 300, height: 26)
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
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        selectTab(sender.selectedSegment)
    }


    private func createLanguagesTabView(frame: NSRect) -> NSView {
        let view = NSView(frame: frame)
        let cardW = frame.width
        let rowH: CGFloat = 46
        let cardH: CGFloat = rowH * 3

        let card = makeCard(frame: NSRect(x: 0, y: frame.height - cardH - 8, width: cardW, height: cardH))

        let r1Y = cardH - rowH
        card.addSubview(makeRowLabel("Caller Language", frame: NSRect(x: 16, y: r1Y + 14, width: 160, height: 18)))
        foreignLangPopup = NSPopUpButton(frame: NSRect(x: cardW - 226, y: r1Y + 10, width: 210, height: 26))
        foreignLangPopup.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        populateLanguagePopup(foreignLangPopup)
        foreignLangPopup.target = self
        foreignLangPopup.action = #selector(foreignLanguageChanged(_:))
        foreignLangPopup.setAccessibilityLabel("Caller Language")
        card.addSubview(foreignLangPopup)
        card.addSubview(makeDivider(width: cardW, y: r1Y))

        let r2Y = cardH - rowH * 2
        card.addSubview(makeRowLabel("Your Language", frame: NSRect(x: 16, y: r2Y + 14, width: 160, height: 18)))
        mainLangPopup = NSPopUpButton(frame: NSRect(x: cardW - 226, y: r2Y + 10, width: 210, height: 26))
        mainLangPopup.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        populateLanguagePopup(mainLangPopup)
        mainLangPopup.target = self
        mainLangPopup.action = #selector(mainLanguageChanged(_:))
        mainLangPopup.setAccessibilityLabel("Your Language")
        card.addSubview(mainLangPopup)
        card.addSubview(makeDivider(width: cardW, y: r2Y))

        let r3Y: CGFloat = 0
        card.addSubview(makeRowLabel("Subtitle Language", frame: NSRect(x: 16, y: r3Y + 14, width: 160, height: 18)))
        targetLangPopup = NSPopUpButton(frame: NSRect(x: cardW - 226, y: r3Y + 10, width: 210, height: 26))
        targetLangPopup.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        populateTargetLanguagePopup(targetLangPopup)
        targetLangPopup.target = self
        targetLangPopup.action = #selector(targetLanguageChanged(_:))
        targetLangPopup.setAccessibilityLabel("Subtitle Language")
        card.addSubview(targetLangPopup)

        view.addSubview(card)

        let footerY = frame.height - cardH - 48
        let swapBtn = NSButton(title: "Swap Languages", target: self, action: #selector(swapLanguagesClicked))
        swapBtn.bezelStyle = .rounded
        swapBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        if let swapImg = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil) {
            swapBtn.image = swapImg.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10.5, weight: .medium))
            swapBtn.imagePosition = .imageLeading
        }
        swapBtn.frame = NSRect(x: 0, y: footerY, width: 132, height: 28)
        swapBtn.setAccessibilityLabel("Swap Languages")
        view.addSubview(swapBtn)

        let transBtn = NSButton(title: "Translation Languages…", target: self, action: #selector(openTranslationSettingsClicked))
        transBtn.bezelStyle = .rounded
        transBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        transBtn.frame = NSRect(x: 140, y: footerY, width: 168, height: 28)
        transBtn.setAccessibilityLabel("Open Translation Language Settings")
        view.addSubview(transBtn)

        let dictBtn = NSButton(title: "Dictation Settings…", target: self, action: #selector(openDictationSettingsClicked))
        dictBtn.bezelStyle = .rounded
        dictBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        dictBtn.frame = NSRect(x: cardW - 144, y: footerY, width: 144, height: 28)
        dictBtn.setAccessibilityLabel("Open Dictation Settings")
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
        card.addSubview(makeRowLabel("Microphone Translation", frame: NSRect(x: 16, y: r1Y + 10, width: 240, height: 18)))
        micEnabledSwitch = NSSwitch(frame: NSRect(x: cardW - 54, y: r1Y + 8, width: 38, height: 22))
        micEnabledSwitch.target = self
        micEnabledSwitch.action = #selector(micEnabledToggled(_:))
        micEnabledSwitch.setAccessibilityLabel("Microphone Translation")
        card.addSubview(micEnabledSwitch)
        card.addSubview(makeDivider(width: cardW, y: r1Y))

        let r2Y = cardH - rowH * 2
        card.addSubview(makeRowLabel("Share Both Speakers on Live Link", frame: NSRect(x: 16, y: r2Y + 10, width: 300, height: 18)))
        shareBothSwitch = NSSwitch(frame: NSRect(x: cardW - 54, y: r2Y + 8, width: 38, height: 22))
        shareBothSwitch.target = self
        shareBothSwitch.action = #selector(shareBothToggled(_:))
        shareBothSwitch.setAccessibilityLabel("Share Both Speakers on Live Link")
        card.addSubview(shareBothSwitch)
        card.addSubview(makeDivider(width: cardW, y: r2Y))

        let r3Y = cardH - rowH * 3
        card.addSubview(makeRowLabel("Allow LAN Access on Live Link", frame: NSRect(x: 16, y: r3Y + 10, width: 300, height: 18)))
        allowLANShareSwitch = NSSwitch(frame: NSRect(x: cardW - 54, y: r3Y + 8, width: 38, height: 22))
        allowLANShareSwitch.target = self
        allowLANShareSwitch.action = #selector(allowLANShareToggled(_:))
        allowLANShareSwitch.setAccessibilityLabel("Allow LAN Access on Live Link")
        card.addSubview(allowLANShareSwitch)
        card.addSubview(makeDivider(width: cardW, y: r3Y))

        let r4Y = cardH - rowH * 4
        card.addSubview(makeRowLabel("Use External Live Link Tunnel", frame: NSRect(x: 16, y: r4Y + 10, width: 300, height: 18)))
        externalTunnelSwitch = NSSwitch(frame: NSRect(x: cardW - 54, y: r4Y + 8, width: 38, height: 22))
        externalTunnelSwitch.target = self
        externalTunnelSwitch.action = #selector(externalTunnelToggled(_:))
        externalTunnelSwitch.setAccessibilityLabel("Use External Live Link Tunnel")
        externalTunnelSwitch.toolTip = "Off keeps Live Link local/LAN only; no captions leave your network."
        card.addSubview(externalTunnelSwitch)
        card.addSubview(makeDivider(width: cardW, y: r4Y))

        let r5Y = cardH - rowH * 5
        card.addSubview(makeRowLabel("Pause Capture on Lock/Sleep", frame: NSRect(x: 16, y: r5Y + 10, width: 300, height: 18)))
        pauseOnLockSwitch = NSSwitch(frame: NSRect(x: cardW - 54, y: r5Y + 8, width: 38, height: 22))
        pauseOnLockSwitch.target = self
        pauseOnLockSwitch.action = #selector(pauseOnLockToggled(_:))
        pauseOnLockSwitch.setAccessibilityLabel("Pause Capture on Lock or Sleep")
        card.addSubview(pauseOnLockSwitch)
        card.addSubview(makeDivider(width: cardW, y: r5Y))

        let r6Y = cardH - rowH * 6
        card.addSubview(makeRowLabel("Show Original Text Locally", frame: NSRect(x: 16, y: r6Y + 10, width: 300, height: 18)))
        showOriginalSwitch = NSSwitch(frame: NSRect(x: cardW - 54, y: r6Y + 8, width: 38, height: 22))
        showOriginalSwitch.target = self
        showOriginalSwitch.action = #selector(showOriginalToggled(_:))
        showOriginalSwitch.setAccessibilityLabel("Show Original Text Locally")
        showOriginalSwitch.toolTip = "Affects the local caption display. Live Link always includes original and translated text for the viewer."
        card.addSubview(showOriginalSwitch)
        card.addSubview(makeDivider(width: cardW, y: r6Y))

        let r7Y = cardH - rowH * 7
        card.addSubview(makeRowLabel("Autosave Session Transcripts", frame: NSRect(x: 16, y: r7Y + 10, width: 300, height: 18)))
        autosaveSwitch = NSSwitch(frame: NSRect(x: cardW - 54, y: r7Y + 8, width: 38, height: 22))
        autosaveSwitch.target = self
        autosaveSwitch.action = #selector(autosaveToggled(_:))
        autosaveSwitch.setAccessibilityLabel("Autosave Session Transcripts")
        card.addSubview(autosaveSwitch)
        card.addSubview(makeDivider(width: cardW, y: r7Y))

        let r8Y = cardH - rowH * 8
        card.addSubview(makeRowLabel("Open Automatically on Caller Speech", frame: NSRect(x: 16, y: r8Y + 10, width: 300, height: 18)))
        autoPopupSwitch = NSSwitch(frame: NSRect(x: cardW - 54, y: r8Y + 8, width: 38, height: 22))
        autoPopupSwitch.target = self
        autoPopupSwitch.action = #selector(autoPopupToggled(_:))
        autoPopupSwitch.setAccessibilityLabel("Open Automatically on Caller Speech")
        card.addSubview(autoPopupSwitch)
        card.addSubview(makeDivider(width: cardW, y: r8Y))

        let r9Y = cardH - rowH * 9
        card.addSubview(makeRowLabel("Auto-Dismiss", frame: NSRect(x: 16, y: r9Y + 10, width: 160, height: 18)))
        autoHideDelayPopup = NSPopUpButton(frame: NSRect(x: cardW - 146, y: r9Y + 6, width: 130, height: 26))
        autoHideDelayPopup.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        autoHideDelayPopup.addItems(withTitles: [
            "3 seconds",
            "5 seconds",
            "8 seconds",
            "12 seconds",
            "Never"
        ])
        autoHideDelayPopup.target = self
        autoHideDelayPopup.action = #selector(autoHideDelayChanged(_:))
        autoHideDelayPopup.setAccessibilityLabel("Auto-Dismiss")
        card.addSubview(autoHideDelayPopup)
        card.addSubview(makeDivider(width: cardW, y: r9Y))

        let r10Y: CGFloat = 0
        card.addSubview(makeRowLabel("Text Size", frame: NSRect(x: 16, y: r10Y + 10, width: 120, height: 18)))
        fontSizeSegmented = NSSegmentedControl(
            labels: ["S", "M", "L", "XL"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(fontSizeChanged(_:))
        )
        fontSizeSegmented.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        fontSizeSegmented.frame = NSRect(x: cardW - 176, y: r10Y + 6, width: 160, height: 26)
        fontSizeSegmented.setAccessibilityLabel("Caption Text Size")
        card.addSubview(fontSizeSegmented)

        view.addSubview(card)

        let footerY: CGFloat = 16
        let deleteBtn = NSButton(title: "Delete Local Data…", target: self, action: #selector(deleteLocalDataAction))
        deleteBtn.bezelStyle = .rounded
        deleteBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        deleteBtn.frame = NSRect(x: 0, y: footerY, width: 160, height: 28)
        deleteBtn.setAccessibilityLabel("Delete Local Data")
        view.addSubview(deleteBtn)

        let privacyBtn = NSButton(title: "Privacy & Legal…", target: self, action: #selector(openPrivacyAction))
        privacyBtn.bezelStyle = .rounded
        privacyBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        privacyBtn.frame = NSRect(x: 168, y: footerY, width: 140, height: 28)
        privacyBtn.setAccessibilityLabel("Privacy and Legal")
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
            title: "System Audio Recording",
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
            title: "Microphone",
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
            title: "Speech Recognition",
            actionSelector: #selector(speechActionClicked),
            outBadge: &speechPermBadge,
            outButton: &speechActionBtn
        )

        view.addSubview(card)

        let footerY = frame.height - cardH - 48
        let repromptBtn = NSButton(title: "Retry Capture", target: self, action: #selector(retryCaptureAction))
        repromptBtn.bezelStyle = .rounded
        repromptBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        repromptBtn.frame = NSRect(x: 0, y: footerY, width: 132, height: 28)
        repromptBtn.setAccessibilityLabel("Retry Audio Capture")
        view.addSubview(repromptBtn)

        let onboardingBtn = NSButton(title: "Setup Guide…", target: self, action: #selector(openOnboardingAction))
        onboardingBtn.bezelStyle = .rounded
        onboardingBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        onboardingBtn.frame = NSRect(x: 138, y: footerY, width: 106, height: 28)
        onboardingBtn.setAccessibilityLabel("Open Setup Guide")
        view.addSubview(onboardingBtn)

        let privacyBtn = NSButton(title: "Privacy & Legal…", target: self, action: #selector(openPrivacyAction))
        privacyBtn.bezelStyle = .rounded
        privacyBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        privacyBtn.frame = NSRect(x: 250, y: footerY, width: 106, height: 28)
        privacyBtn.setAccessibilityLabel("Privacy and Legal")
        view.addSubview(privacyBtn)

        let relaunchBtn = NSButton(title: "Restart App", target: self, action: #selector(relaunchAppAction))
        relaunchBtn.bezelStyle = .rounded
        relaunchBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        relaunchBtn.frame = NSRect(x: cardW - 96, y: footerY, width: 96, height: 28)
        relaunchBtn.setAccessibilityLabel("Restart Call Caption")
        view.addSubview(relaunchBtn)

        return view
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

        let label = makeRowLabel(title, frame: NSRect(x: 44, y: y + (height - 18) / 2.0, width: 180, height: 18))
        container.addSubview(label)

        let badge = StatusBadgeView(frame: NSRect(x: width - 196, y: y + (height - 22) / 2.0, width: 88, height: 22))
        container.addSubview(badge)
        outBadge = badge

        let btn = NSButton(title: "Settings", target: self, action: actionSelector)
        btn.bezelStyle = .rounded
        btn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        btn.frame = NSRect(x: width - 98, y: y + (height - 28) / 2.0, width: 84, height: 28)
        btn.setAccessibilityLabel("\(title) Settings")
        container.addSubview(btn)
        outButton = btn
    }


    private func populateLanguagePopup(_ popup: NSPopUpButton) {
        popup.removeAllItems()
        for lang in SupportedLanguages.all {
            let item = NSMenuItem(title: "\(lang.flag)  \(lang.name)", action: nil, keyEquivalent: "")
            item.representedObject = lang.code
            popup.menu?.addItem(item)
        }
    }

    private func populateTargetLanguagePopup(_ popup: NSPopUpButton) {
        popup.removeAllItems()
        let mainLang = AppSettings.shared.mainLanguageItem
        let followItem = NSMenuItem(
            title: "Same as Your Language (\(mainLang.flag) \(mainLang.name))",
            action: nil,
            keyEquivalent: ""
        )
        followItem.representedObject = Self.followMainSentinel
        popup.menu?.addItem(followItem)
        popup.menu?.addItem(NSMenuItem.separator())

        for lang in SupportedLanguages.all {
            let item = NSMenuItem(title: "\(lang.flag)  \(lang.name)", action: nil, keyEquivalent: "")
            item.representedObject = lang.code
            popup.menu?.addItem(item)
        }
    }

    public func refreshSettingsValues() {
        let settings = AppSettings.shared

        if let foreign = foreignLangPopup { populateLanguagePopup(foreign) }
        if let main = mainLangPopup { populateLanguagePopup(main) }
        if let target = targetLangPopup { populateTargetLanguagePopup(target) }

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

        refreshPermissions()
    }

    private func refreshPermissions() {
        switch PermissionHelper.shared.audioCaptureState {
        case .active:
            let running = CaptionCoordinator.shared.audioCaptureEngine.isRunning
            let paused = CaptionCoordinator.shared.isPaused
            screenPermBadge?.setStatus(
                isGranted: running,
                title: running ? "Capturing" : (paused ? "Paused" : "Not running")
            )
            screenActionBtn?.title = "Settings"
        case .deniedSilenceDetected:
            screenPermBadge?.setStatus(isGranted: false, title: "Denied")
            screenActionBtn?.title = "Settings"
        case .unknown:
            let running = CaptionCoordinator.shared.audioCaptureEngine.isRunning
            let paused = CaptionCoordinator.shared.isPaused
            screenPermBadge?.setStatus(
                isGranted: running,
                title: running ? "Listening" : (paused ? "Paused" : "Not started")
            )
            screenActionBtn?.title = "Settings"
        }

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let hasMic = (micStatus == .authorized)
        micPermBadge?.setStatus(
            isGranted: hasMic,
            title: hasMic ? "Granted" : (micStatus == .denied ? "Denied" : "Optional")
        )
        micActionBtn?.title = (micStatus == .notDetermined) ? "Allow" : "Settings"

        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let hasSpeech = (speechStatus == .authorized)
        speechPermBadge?.setStatus(
            isGranted: hasSpeech,
            title: hasSpeech ? "Granted" : (speechStatus == .denied ? "Denied" : "Required")
        )
        speechActionBtn?.title = (speechStatus == .notDetermined) ? "Allow" : "Settings"
    }


    @objc private func swapLanguagesClicked() {
        AppDelegate.shared.clearSystemAlertBanner()
        AppSettings.shared.swapLanguages()
        refreshSettingsValues()
    }

    @objc private func openTranslationSettingsClicked() {
        PermissionHelper.shared.openTranslationSettings()
    }

    @objc private func openDictationSettingsClicked() {
        PermissionHelper.shared.openDictationSettings()
    }

    @objc private func mainLanguageChanged(_ sender: NSPopUpButton) {
        if let code = sender.selectedItem?.representedObject as? String {
            AppSettings.shared.setMainAndTargetLanguage(code)
            refreshSettingsValues()
        }
    }

    @objc private func foreignLanguageChanged(_ sender: NSPopUpButton) {
        if let code = sender.selectedItem?.representedObject as? String {
            AppDelegate.shared.clearSystemAlertBanner()
            AppSettings.shared.foreignLanguageCode = code
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
            if PermissionHelper.shared.hasMicrophoneAccess {
                AppSettings.shared.isMicEnabled = true
            } else {
                PermissionHelper.shared.requestMicrophoneAccess { [weak self] granted in
                    AppSettings.shared.isMicEnabled = granted
                    sender.state = granted ? .on : .off
                    self?.refreshPermissions()
                }
            }
        } else {
            AppSettings.shared.isMicEnabled = false
        }
    }

    @objc private func shareBothToggled(_ sender: NSSwitch) {
        AppSettings.shared.shareBothSpeakersOnLink = (sender.state == .on)
        LiveShareManager.shared.speakerSharingDidChange()
    }

    private func applyLiveShareNetworkSetting(_ change: () -> Void) {
        if !LiveShareManager.shared.isSharing {
            change()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Restart Live Link?"
        alert.informativeText = "Changing network sharing restarts the current Live Link and creates a new link. Current viewers will be disconnected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restart Link")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            refreshSettingsValues()
            return
        }
        change()
        LiveShareManager.shared.stopSharing()
        CaptionCoordinator.shared.prepareForLiveShareStart()
        LiveShareManager.shared.startSharing()
        LiveShareManager.shared.broadcastPauseState(CaptionCoordinator.shared.isPaused)
    }

    @objc private func allowLANShareToggled(_ sender: NSSwitch) {
        let newValue = (sender.state == .on)
        if newValue {
            let alert = NSAlert()
            alert.messageText = "Enable plaintext LAN access?"
            alert.informativeText = "Direct LAN viewers receive captions over unencrypted HTTP because no TLS certificate is bundled. Use this only on a network you trust. The public HTTPS tunnel and loopback viewers remain end-to-end encrypted."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Enable LAN")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                refreshSettingsValues()
                return
            }
        }
        applyLiveShareNetworkSetting {
            AppSettings.shared.allowLANShare = newValue
        }
    }

    @objc private func externalTunnelToggled(_ sender: NSSwitch) {
        let newValue = (sender.state == .on)
        if newValue && LiveShareManager.shared.isSharing,
           !AppDelegate.shared.requestExternalLiveShareConsentIfNeeded() {
            refreshSettingsValues()
            return
        }
        applyLiveShareNetworkSetting {
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
        CaptionCoordinator.shared.retryAudioCapture()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refreshPermissions()
        }
    }

    @objc private func deleteLocalDataAction() {
        let alert = NSAlert()
        alert.messageText = "Delete all local data?"
        alert.informativeText = "This clears the current transcript, deletes the autosaved transcript, clears cached translations, and removes Live Link history. Your preferences are kept."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        CaptionCoordinator.shared.clearTranscript()
        TranscriptManager.shared.deleteSavedSession()
        Task { await TranslationEngine.shared.clearCache() }
    }

    @objc private func openPrivacyAction() {
        AppDelegate.shared.openLegalDocument(.privacy)
    }

    @objc private func openOnboardingAction() {
        AppDelegate.shared.openOnboardingWindow()
    }

    @objc private func relaunchAppAction() {
        PermissionHelper.shared.restartApp()
    }
}
