import AppKit
import CoreMedia
import AVFoundation
import Speech

// MARK: - Floating HUD Action Button (Full Mode)
public class HUDActionButton: NSView {
    public var iconName: String {
        didSet { updateIcon() }
    }
    public var title: String {
        didSet { titleLabel.stringValue = title }
    }
    public var action: (() -> Void)?
    
    private var iconBox: NSView!
    private var iconImageView: NSImageView!
    private var titleLabel: NSTextField!
    private var trackingArea: NSTrackingArea?
    public var isHighlightedState: Bool = false {
        didSet { updateHighlight() }
    }
    public var isDestructive: Bool = false {
        didSet { updateHighlight() }
    }
    
    public init(iconName: String, title: String, toolTip: String, isDestructive: Bool = false, action: @escaping () -> Void) {
        self.iconName = iconName
        self.title = title
        self.isDestructive = isDestructive
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: 40, height: 50))
        self.toolTip = toolTip
        setupUI()
    }
    
    public required init?(coder: NSCoder) { fatalError() }
    
    private func setupUI() {
        wantsLayer = true
        
        iconBox = NSView(frame: NSRect(x: 7, y: 20, width: 26, height: 26))
        iconBox.wantsLayer = true
        iconBox.layer?.cornerRadius = 6
        iconBox.layer?.borderWidth = 1.0
        iconBox.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        iconBox.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        addSubview(iconBox)
        
        iconImageView = NSImageView(frame: NSRect(x: 3, y: 3, width: 20, height: 20))
        iconImageView.imageScaling = .scaleProportionallyDown
        iconImageView.contentTintColor = isDestructive ? NSColor.systemRed : NSColor(red: 0.88, green: 0.90, blue: 0.96, alpha: 1.0)
        iconBox.addSubview(iconImageView)
        updateIcon()
        
        titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .medium)
        titleLabel.textColor = isDestructive ? NSColor.systemRed.withAlphaComponent(0.85) : NSColor(red: 0.65, green: 0.70, blue: 0.80, alpha: 1.0)
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(x: -4, y: 2, width: 48, height: 14)
        addSubview(titleLabel)
        
        updateHighlight()
    }
    
    private func updateIcon() {
        if let img = NSImage(systemSymbolName: iconName, accessibilityDescription: title) {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            iconImageView.image = img.withSymbolConfiguration(config)
        }
        if isDestructive {
            iconImageView.contentTintColor = NSColor.systemRed
        }
    }
    
    private func updateHighlight() {
        if isDestructive {
            iconBox.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.08).cgColor
            iconBox.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.3).cgColor
            titleLabel.textColor = NSColor.systemRed.withAlphaComponent(0.85)
            iconImageView.contentTintColor = NSColor.systemRed
        } else if isHighlightedState {
            iconBox.layer?.backgroundColor = NSColor(red: 0.98, green: 0.38, blue: 0.08, alpha: 0.25).cgColor
            iconBox.layer?.borderColor = NSColor(red: 0.98, green: 0.38, blue: 0.08, alpha: 0.8).cgColor
            titleLabel.textColor = NSColor(red: 0.98, green: 0.38, blue: 0.08, alpha: 1.0)
        } else {
            iconBox.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
            iconBox.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
            titleLabel.textColor = NSColor(red: 0.65, green: 0.70, blue: 0.80, alpha: 1.0)
        }
    }
    
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }
    
    public override func mouseEntered(with event: NSEvent) {
        if isDestructive {
            iconBox.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.25).cgColor
            iconBox.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.8).cgColor
            titleLabel.textColor = NSColor.systemRed
        } else {
            iconBox.layer?.backgroundColor = NSColor(red: 0.98, green: 0.38, blue: 0.08, alpha: 0.25).cgColor
            iconBox.layer?.borderColor = NSColor(red: 0.98, green: 0.38, blue: 0.08, alpha: 0.8).cgColor
            titleLabel.textColor = NSColor(red: 0.98, green: 0.38, blue: 0.08, alpha: 1.0)
        }
    }
    
    public override func mouseExited(with event: NSEvent) {
        updateHighlight()
    }
    
    public override func mouseUp(with event: NSEvent) {
        // Subtle press bounce animation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.08
            self.iconBox.animator().alphaValue = 0.6
        }, completionHandler: {
            self.iconBox.animator().alphaValue = 1.0
        })
        action?()
    }
}

// MARK: - Floating HUD Action Button (Compact Mode)
public class HUDCompactButton: NSButton {
    private var trackingArea: NSTrackingArea?
    
    public init(frame: NSRect, iconName: String, toolTip: String, target: AnyObject?, action: Selector) {
        super.init(frame: frame)
        self.isBordered = false
        self.toolTip = toolTip
        self.target = target
        self.action = action
        self.wantsLayer = true
        self.alphaValue = 0.85
        
        if let img = NSImage(systemSymbolName: iconName, accessibilityDescription: toolTip) {
            let config = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .semibold)
            self.image = img.withSymbolConfiguration(config)
        }
        self.contentTintColor = NSColor(red: 0.82, green: 0.85, blue: 0.92, alpha: 1.0)
    }
    
    public required init?(coder: NSCoder) { fatalError() }
    
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .cursorUpdate], owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }
    
    public override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }
    
    public override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            self.animator().alphaValue = 1.0
            self.contentTintColor = NSColor(red: 0.98, green: 0.38, blue: 0.08, alpha: 1.0)
        }
    }
    
    public override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            self.animator().alphaValue = 0.85
            self.contentTintColor = NSColor(red: 0.82, green: 0.85, blue: 0.92, alpha: 1.0)
        }
    }
}

// MARK: - Language Selector Capsule (Full Mode)
public class LanguageSelectorBarView: NSView {
    public var onLanguageChanged: ((_ isUser: Bool, _ newIndex: Int) -> Void)?
    public var onSwapLanguages: (() -> Void)?
    
    public var userLanguageIndex: Int = 1 {
        didSet { updateDisplay() }
    }
    public var callerLanguageIndex: Int = 0 {
        didSet { updateDisplay() }
    }
    
    private var youContainer: NSView!
    private var youFlagLabel: NSTextField!
    private var youTitleLabel: NSTextField!
    private var youNameLabel: NSTextField!
    
    private var swapButton: NSButton!
    
    private var callerContainer: NSView!
    private var callerFlagLabel: NSTextField!
    private var callerTitleLabel: NSTextField!
    private var callerNameLabel: NSTextField!
    
    private var youTrackingArea: NSTrackingArea?
    private var callerTrackingArea: NSTrackingArea?
    
    public override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 296, height: 48))
        setupUI()
    }
    
    public required init?(coder: NSCoder) { fatalError() }
    
    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1.0
        layer?.borderColor = NSColor(red: 0.98, green: 0.6, blue: 0.1, alpha: 0.4).cgColor
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        layer?.masksToBounds = true
        
        // --- YOU SECTION (Left: 6 to 130, width 124) ---
        youContainer = NSView(frame: NSRect(x: 6, y: 4, width: 124, height: 40))
        youContainer.wantsLayer = true
        youContainer.layer?.cornerRadius = 10
        youContainer.toolTip = "Change Your Language"
        addSubview(youContainer)
        
        youFlagLabel = NSTextField(labelWithString: "🇬🇧")
        youFlagLabel.font = NSFont.systemFont(ofSize: 20)
        youFlagLabel.alignment = .center
        youFlagLabel.isBordered = false
        youFlagLabel.drawsBackground = false
        youFlagLabel.cell?.wraps = false
        youFlagLabel.cell?.isScrollable = false
        youFlagLabel.frame = NSRect(x: 8, y: 7, width: 26, height: 26)
        youContainer.addSubview(youFlagLabel)
        
        youTitleLabel = NSTextField(labelWithString: "YOU")
        youTitleLabel.font = NSFont.systemFont(ofSize: 9.0, weight: .bold)
        youTitleLabel.textColor = NSColor(red: 0.65, green: 0.70, blue: 0.80, alpha: 1.0)
        youTitleLabel.isBordered = false
        youTitleLabel.drawsBackground = false
        youTitleLabel.frame = NSRect(x: 36, y: 21, width: 82, height: 13)
        youContainer.addSubview(youTitleLabel)
        
        youNameLabel = NSTextField(labelWithString: "English")
        youNameLabel.font = NSFont.systemFont(ofSize: 13.5, weight: .bold)
        youNameLabel.textColor = .white
        youNameLabel.isBordered = false
        youNameLabel.drawsBackground = false
        youNameLabel.lineBreakMode = .byTruncatingTail
        youNameLabel.frame = NSRect(x: 36, y: 4, width: 82, height: 17)
        youContainer.addSubview(youNameLabel)
        
        // --- SWAP BUTTON (Dead Center: 134 to 162, width 28) ---
        swapButton = NSButton(frame: NSRect(x: 134, y: 10, width: 28, height: 28))
        swapButton.isBordered = false
        swapButton.bezelStyle = .regularSquare
        swapButton.imagePosition = .imageOnly
        if let swapImg = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "Swap Languages") {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            swapButton.image = swapImg.withSymbolConfiguration(config)
        }
        swapButton.contentTintColor = NSColor(red: 0.75, green: 0.80, blue: 0.90, alpha: 1.0)
        swapButton.target = self
        swapButton.action = #selector(swapClicked)
        swapButton.toolTip = "Swap Languages"
        addSubview(swapButton)
        
        // --- CALLER SECTION (Right: 166 to 290, width 124) ---
        callerContainer = NSView(frame: NSRect(x: 166, y: 4, width: 124, height: 40))
        callerContainer.wantsLayer = true
        callerContainer.layer?.cornerRadius = 10
        callerContainer.toolTip = "Change Caller's Language"
        addSubview(callerContainer)
        
        callerFlagLabel = NSTextField(labelWithString: "🇪🇸")
        callerFlagLabel.font = NSFont.systemFont(ofSize: 20)
        callerFlagLabel.alignment = .center
        callerFlagLabel.isBordered = false
        callerFlagLabel.drawsBackground = false
        callerFlagLabel.cell?.wraps = false
        callerFlagLabel.cell?.isScrollable = false
        callerFlagLabel.frame = NSRect(x: 8, y: 7, width: 26, height: 26)
        callerContainer.addSubview(callerFlagLabel)
        
        callerTitleLabel = NSTextField(labelWithString: "CALLER")
        callerTitleLabel.font = NSFont.systemFont(ofSize: 9.0, weight: .bold)
        callerTitleLabel.textColor = NSColor(red: 0.65, green: 0.70, blue: 0.80, alpha: 1.0)
        callerTitleLabel.isBordered = false
        callerTitleLabel.drawsBackground = false
        callerTitleLabel.frame = NSRect(x: 36, y: 21, width: 82, height: 13)
        callerContainer.addSubview(callerTitleLabel)
        
        callerNameLabel = NSTextField(labelWithString: "Spanish")
        callerNameLabel.font = NSFont.systemFont(ofSize: 13.5, weight: .bold)
        callerNameLabel.textColor = .white
        callerNameLabel.isBordered = false
        callerNameLabel.drawsBackground = false
        callerNameLabel.lineBreakMode = .byTruncatingTail
        callerNameLabel.frame = NSRect(x: 36, y: 4, width: 82, height: 17)
        callerContainer.addSubview(callerNameLabel)
        
        updateDisplay()
    }
    
    public func updateDisplay() {
        let userLang = SupportedLanguages.all[max(0, min(SupportedLanguages.all.count - 1, userLanguageIndex))]
        let callerLang = SupportedLanguages.all[max(0, min(SupportedLanguages.all.count - 1, callerLanguageIndex))]
        
        youFlagLabel.stringValue = userLang.flag
        youNameLabel.stringValue = userLang.name
        
        callerFlagLabel.stringValue = callerLang.flag
        callerNameLabel.stringValue = callerLang.name
    }
    
    @objc private func swapClicked() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            self.swapButton.animator().alphaValue = 0.4
        }, completionHandler: {
            self.swapButton.animator().alphaValue = 1.0
        })
        onSwapLanguages?()
    }
    
    public override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if youContainer.frame.contains(location) {
            showLanguageMenu(forUser: true, anchorView: youContainer)
        } else if callerContainer.frame.contains(location) {
            showLanguageMenu(forUser: false, anchorView: callerContainer)
        }
    }
    
    private func showLanguageMenu(forUser: Bool, anchorView: NSView) {
        let menu = NSMenu(title: forUser ? "Select Your Language" : "Select Caller's Language")
        let selectedIndex = forUser ? userLanguageIndex : callerLanguageIndex
        
        for (i, lang) in SupportedLanguages.all.enumerated() {
            let item = NSMenuItem(title: "\(lang.flag) \(lang.name)", action: #selector(menuItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = (forUser ? 1000 : 2000) + i
            item.state = (i == selectedIndex) ? .on : .off
            menu.addItem(item)
        }
        
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: anchorView)
    }
    
    @objc private func menuItemSelected(_ sender: NSMenuItem) {
        let tag = sender.tag
        if tag >= 2000 {
            let callerIdx = tag - 2000
            callerLanguageIndex = callerIdx
            onLanguageChanged?(false, callerIdx)
        } else if tag >= 1000 {
            let userIdx = tag - 1000
            userLanguageIndex = userIdx
            onLanguageChanged?(true, userIdx)
        }
    }
}

// MARK: - Compact Language Route Capsule (Compact Mode)
public class CompactLanguageRouteView: NSView {
    public var onLanguageChanged: ((_ isUser: Bool, _ newIndex: Int) -> Void)?
    public var onSwapLanguages: (() -> Void)?
    
    public var userLanguageIndex: Int = 1 {
        didSet { updateDisplay() }
    }
    public var callerLanguageIndex: Int = 0 {
        didSet { updateDisplay() }
    }
    
    private var leftFlagLabel: NSTextField!
    private var routeLabel: NSTextField!
    private var rightFlagLabel: NSTextField!
    private var trackingArea: NSTrackingArea?
    
    public override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 128, height: 28))
        setupUI()
    }
    
    public required init?(coder: NSCoder) { fatalError() }
    
    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1.0
        layer?.borderColor = NSColor(red: 0.98, green: 0.6, blue: 0.1, alpha: 0.4).cgColor
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        layer?.masksToBounds = true
        self.toolTip = "Change languages or swap (Click to configure)"
        
        // Left Flag (Caller) - centered at x: 6
        leftFlagLabel = NSTextField(labelWithString: "🇪🇸")
        leftFlagLabel.font = NSFont.systemFont(ofSize: 15)
        leftFlagLabel.alignment = .center
        leftFlagLabel.isBordered = false
        leftFlagLabel.drawsBackground = false
        leftFlagLabel.cell?.wraps = false
        leftFlagLabel.cell?.isScrollable = false
        leftFlagLabel.frame = NSRect(x: 6, y: 4, width: 22, height: 20)
        addSubview(leftFlagLabel)
        
        // Center Route Text (e.g. ES → EN) - centered at x: 30
        routeLabel = NSTextField(labelWithString: "ES → EN")
        routeLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .bold)
        routeLabel.textColor = NSColor(red: 0.88, green: 0.90, blue: 0.96, alpha: 1.0)
        routeLabel.alignment = .center
        routeLabel.isBordered = false
        routeLabel.drawsBackground = false
        routeLabel.cell?.wraps = false
        routeLabel.cell?.isScrollable = false
        routeLabel.frame = NSRect(x: 30, y: 6, width: 68, height: 16)
        addSubview(routeLabel)
        
        // Right Flag (You) - centered at x: 100
        rightFlagLabel = NSTextField(labelWithString: "🇬🇧")
        rightFlagLabel.font = NSFont.systemFont(ofSize: 15)
        rightFlagLabel.alignment = .center
        rightFlagLabel.isBordered = false
        rightFlagLabel.drawsBackground = false
        rightFlagLabel.cell?.wraps = false
        rightFlagLabel.cell?.isScrollable = false
        rightFlagLabel.frame = NSRect(x: 100, y: 4, width: 22, height: 20)
        addSubview(rightFlagLabel)
        
        updateDisplay()
    }
    
    public func updateDisplay() {
        let userLang = SupportedLanguages.all[max(0, min(SupportedLanguages.all.count - 1, userLanguageIndex))]
        let callerLang = SupportedLanguages.all[max(0, min(SupportedLanguages.all.count - 1, callerLanguageIndex))]
        
        // Compact mode displays caller's translated captions: Caller (Source) → You (Target)
        leftFlagLabel.stringValue = callerLang.flag
        rightFlagLabel.stringValue = userLang.flag
        routeLabel.stringValue = "\(callerLang.code.uppercased()) → \(userLang.code.uppercased())"
    }
    
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .cursorUpdate], owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }
    
    public override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }
    
    public override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor(red: 0.98, green: 0.38, blue: 0.08, alpha: 0.25).cgColor
        layer?.borderColor = NSColor(red: 0.98, green: 0.38, blue: 0.08, alpha: 0.8).cgColor
    }
    
    public override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        layer?.borderColor = NSColor(red: 0.98, green: 0.6, blue: 0.1, alpha: 0.4).cgColor
    }
    
    public override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let userLang = SupportedLanguages.all[max(0, min(SupportedLanguages.all.count - 1, userLanguageIndex))]
        let callerLang = SupportedLanguages.all[max(0, min(SupportedLanguages.all.count - 1, callerLanguageIndex))]
        
        // If clicked on left flag (x < 36), directly open Caller language selection
        if location.x < 36 {
            showSingleLanguageMenu(forUser: false, anchorX: 0)
            return
        }
        
        // If clicked on right flag (x > 92), directly open Your language selection
        if location.x > 92 {
            showSingleLanguageMenu(forUser: true, anchorX: 84)
            return
        }
        
        // Center click (arrow / general badge): show comprehensive menu
        let menu = NSMenu(title: "Language Route")
        
        let swapItem = NSMenuItem(title: "⇄ Swap Languages (\(callerLang.code.uppercased()) ⇄ \(userLang.code.uppercased()))", action: #selector(swapClicked), keyEquivalent: "")
        swapItem.target = self
        menu.addItem(swapItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let callerMenuItem = NSMenuItem(title: "👤 Caller Speaks: \(callerLang.flag) \(callerLang.name)", action: nil, keyEquivalent: "")
        let callerSub = NSMenu(title: "Select Caller's Language")
        for (i, lang) in SupportedLanguages.all.enumerated() {
            let item = NSMenuItem(title: "\(lang.flag) \(lang.name)", action: #selector(menuItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = 2000 + i
            item.state = (i == callerLanguageIndex) ? .on : .off
            callerSub.addItem(item)
        }
        callerMenuItem.submenu = callerSub
        menu.addItem(callerMenuItem)
        
        let youMenuItem = NSMenuItem(title: "🎙️ You Read / Hear: \(userLang.flag) \(userLang.name)", action: nil, keyEquivalent: "")
        let youSub = NSMenu(title: "Select Your Language")
        for (i, lang) in SupportedLanguages.all.enumerated() {
            let item = NSMenuItem(title: "\(lang.flag) \(lang.name)", action: #selector(menuItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = 1000 + i
            item.state = (i == userLanguageIndex) ? .on : .off
            youSub.addItem(item)
        }
        youMenuItem.submenu = youSub
        menu.addItem(youMenuItem)
        
        menu.popUp(positioning: nil, at: NSPoint(x: 10, y: -4), in: self)
    }
    
    private func showSingleLanguageMenu(forUser: Bool, anchorX: CGFloat) {
        let menu = NSMenu(title: forUser ? "Select Your Language" : "Select Caller's Language")
        let selectedIndex = forUser ? userLanguageIndex : callerLanguageIndex
        
        for (i, lang) in SupportedLanguages.all.enumerated() {
            let item = NSMenuItem(title: "\(lang.flag) \(lang.name)", action: #selector(menuItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = (forUser ? 1000 : 2000) + i
            item.state = (i == selectedIndex) ? .on : .off
            menu.addItem(item)
        }
        
        menu.popUp(positioning: nil, at: NSPoint(x: anchorX, y: -4), in: self)
    }
    
    @objc private func swapClicked() {
        onSwapLanguages?()
    }
    
    @objc private func menuItemSelected(_ sender: NSMenuItem) {
        let tag = sender.tag
        if tag >= 2000 {
            let callerIdx = tag - 2000
            callerLanguageIndex = callerIdx
            onLanguageChanged?(false, callerIdx)
        } else if tag >= 1000 {
            let userIdx = tag - 1000
            userLanguageIndex = userIdx
            onLanguageChanged?(true, userIdx)
        }
    }
}

// MARK: - Main HUD Window
public class HUDCaptionWindow: NSPanel, NSWindowDelegate {
    public init() {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let windowWidth: CGFloat = 780
        let windowHeight: CGFloat = 50
        let initialX = visibleFrame.origin.x + (visibleFrame.width - windowWidth) / 2.0
        let initialY = visibleFrame.origin.y + (visibleFrame.height - windowHeight) / 2.0
        
        super.init(
            contentRect: NSRect(x: initialX, y: initialY, width: windowWidth, height: windowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.isMovableByWindowBackground = true
        self.hasShadow = true
        self.delegate = self
    }
    
    public override var canBecomeKey: Bool {
        return true
    }
    
    public override var canBecomeMain: Bool {
        return true
    }
    
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            let key = event.charactersIgnoringModifiers?.lowercased()
            if key == "m" {
                if let vc = contentViewController as? HUDCaptionViewController {
                    vc.toggleCompactMode()
                    return true
                }
            } else if key == "w" {
                self.orderOut(nil)
                return true
            } else if key == "s" {
                if let vc = contentViewController as? HUDCaptionViewController {
                    vc.openShare()
                    return true
                }
            } else if key == "t" {
                if let vc = contentViewController as? HUDCaptionViewController {
                    vc.openTranscript()
                    return true
                }
            }
        }
        
        if event.keyCode == 49 { // Spacebar
            if let vc = contentViewController as? HUDCaptionViewController {
                vc.togglePlayPause()
                return true
            }
        }
        
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - HUD Caption View Controller
public class HUDCaptionViewController: NSViewController, AudioCaptureDelegate, BidirectionalSpeechDelegate {
    
    // Core Engines
    private let audioCaptureEngine = AudioCaptureEngine()
    private let speechRecognitionManager = SpeechRecognitionManager()
    
    // Main Container
    private var mainContainer: NSView!
    
    // ========================================================
    // FULL MODE (State-of-the-Art Dynamic Island Pro)
    // ========================================================
    private var fullModeContainer: NSView!
    
    // 1. Top Island Floating Capsule
    private var topIslandBar: NSView!
    private var waveformVisualizer: AudioVisualizerView!
    private var languageSelectorBar: LanguageSelectorBarView!
    
    // 7 Action Buttons
    private var shareActionBtn: HUDActionButton!
    private var testAudioActionBtn: HUDActionButton!
    private var logActionBtn: HUDActionButton!
    private var pauseActionBtn: HUDActionButton!
    private var compactActionBtn: HUDActionButton!
    private var pinActionBtn: HUDActionButton!
    private var closeActionBtn: HUDActionButton!
    
    // 2. Middle Card: Caller Subtitles (Emerald Glow)
    private var callerCard: NSView!
    private var callerHeaderLabel: NSTextField!
    private var callerSubtitleLabel: NSTextField!
    
    // 3. Bottom Card: You Subtitles (Cyan Glow)
    private var youCard: NSView!
    private var youHeaderLabel: NSTextField!
    private var youSubtitleLabel: NSTextField!
    
    // ========================================================
    // COMPACT MODE (State-of-the-Art Ambient Whisper Pill)
    // ========================================================
    private var compactPill: NSView!
    private var compactGreenDot: NSView!
    private var compactLangRouteView: CompactLanguageRouteView!
    private var compactSubtitleLabel: NSTextField!
    
    // Compact Right Actions
    private var compactQRBtn: HUDCompactButton!
    private var compactEqualizerView: AudioVisualizerView!
    private var compactPauseBtn: HUDCompactButton!
    private var compactExpandBtn: HUDCompactButton!
    private var compactPinBtn: HUDCompactButton!
    private var compactCloseBtn: HUDCompactButton!
    
    // State Tracking
    public private(set) var isCompactMode: Bool = true
    private var normalWindowFrame: NSRect?
    private var isPinnedOnTop: Bool = true
    private var isPaused: Bool = false
    private var isStartingCapture: Bool = false
    
    // Active Speaker tracking
    private var lastActiveSpeakerIsCaller: Bool = true
    private var lastCallerText: String = ""
    private var lastMyText: String = ""
    
    // Sub-windows
    private var transcriptWindowController: TranscriptWindowController?
    private var shareWindowController: ShareWindowController?
    private var permissionsWindowController: PermissionsWindowController?
    
    // Permission Banner (Overlay)
    private var permissionBanner: NSView!
    private var permissionMessageLabel: NSTextField!
    private var permissionSettingsTarget: Selector = #selector(openSpeechSettingsAction)
    
    public override var acceptsFirstResponder: Bool { true }
    public override func becomeFirstResponder() -> Bool { true }
    
    public override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 50))
        setupUI()
    }
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        audioCaptureEngine.delegate = self
        speechRecognitionManager.delegate = self
        
        // Start web caption server & ssh tunnel
        WebCaptionServer.shared.start()
        
        let initialUserLang = SupportedLanguages.all[languageSelectorBar.userLanguageIndex]
        let initialCallerLang = SupportedLanguages.all[languageSelectorBar.callerLanguageIndex]
        WebCaptionServer.shared.setLanguages(hostCode: initialUserLang.code, callerCode: initialCallerLang.code)
        
        // Handle changes from mobile web client
        WebCaptionServer.shared.onLanguagesChangedFromWeb = { [weak self] hostCode, callerCode in
            guard let self = self else { return }
            if let userIdx = SupportedLanguages.all.firstIndex(where: { $0.code == hostCode }) {
                self.languageSelectorBar.userLanguageIndex = userIdx
            }
            if let callerIdx = SupportedLanguages.all.firstIndex(where: { $0.code == callerCode }) {
                self.languageSelectorBar.callerLanguageIndex = callerIdx
            }
            self.refreshLanguageDisplay()
        }
        
        // Handle speech received from the mobile phone web client
        WebCaptionServer.shared.onMobileSpeechReceived = { [weak self] speaker, text, lang, isFinal in
            guard let self = self else { return }
            let userLang = SupportedLanguages.all[self.languageSelectorBar.userLanguageIndex]
            let callerLang = SupportedLanguages.all[self.languageSelectorBar.callerLanguageIndex]
            
            let srcLang = lang.isEmpty ? callerLang.code : lang
            let targetLang = userLang.code
            
            Task {
                let translated = await TranslationEngine.shared.translate(text: text, sourceCode: srcLang, targetCode: targetLang)
                await MainActor.run {
                    self.lastActiveSpeakerIsCaller = true
                    self.lastCallerText = translated.isEmpty ? text : translated
                    self.callerSubtitleLabel.stringValue = self.lastCallerText
                    self.updateCompactSubtitle()
                    
                    if isFinal {
                        TranscriptManager.shared.addEntry(speaker: "Caller", original: text, translated: self.lastCallerText)
                    }
                }
            }
        }
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        
        let screenSize = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        normalWindowFrame = NSRect(
            x: (screenSize.width - 880) / 2.0,
            y: 70,
            width: 880,
            height: 284
        )
        
        checkPermissionsAndStart()
    }
    
    // MARK: - UI Initialization
    
    private func setupUI() {
        view.wantsLayer = true
        view.layer?.masksToBounds = false
        
        mainContainer = NSView(frame: view.bounds)
        mainContainer.autoresizingMask = [.width, .height]
        mainContainer.wantsLayer = true
        mainContainer.layer?.masksToBounds = false
        view.addSubview(mainContainer)
        
        setupFullModeUI()
        setupCompactModeUI()
        setupPermissionBanner()
        
        refreshLanguageDisplay()
        layoutAllViews()
    }
    
    // MARK: - Full Mode Setup (Matching Image Perfectly)
    
    private func setupFullModeUI() {
        fullModeContainer = NSView(frame: NSRect(x: 0, y: 0, width: 880, height: 284))
        fullModeContainer.wantsLayer = true
        fullModeContainer.layer?.masksToBounds = false
        fullModeContainer.isHidden = isCompactMode
        mainContainer.addSubview(fullModeContainer)
        
        // ----------------------------------------------------
        // 1. TOP ISLAND FLOATING BAR (Height: 68px)
        // ----------------------------------------------------
        topIslandBar = NSView(frame: NSRect(x: 0, y: 216, width: 880, height: 68))
        topIslandBar.wantsLayer = true
        topIslandBar.layer?.shadowColor = NSColor.black.cgColor
        topIslandBar.layer?.shadowRadius = 10
        topIslandBar.layer?.shadowOpacity = 0.40
        topIslandBar.layer?.shadowOffset = CGSize(width: 0, height: -2)
        
        let topIslandEffect = NSVisualEffectView(frame: topIslandBar.bounds)
        topIslandEffect.material = .hudWindow
        topIslandEffect.blendingMode = .behindWindow
        topIslandEffect.state = .active
        topIslandEffect.wantsLayer = true
        topIslandEffect.layer?.cornerRadius = 18
        topIslandEffect.layer?.masksToBounds = true
        topIslandEffect.layer?.borderWidth = 1.0
        // Golden Gate Golden Hour rim light
        topIslandEffect.layer?.borderColor = NSColor(red: 0.98, green: 0.6, blue: 0.1, alpha: 0.3).cgColor
        topIslandEffect.autoresizingMask = [.width, .height]
        topIslandBar.addSubview(topIslandEffect)
        
        fullModeContainer.addSubview(topIslandBar)
        
        // Left: Animated Glowing Orange Waveform (16 bars)
        waveformVisualizer = AudioVisualizerView(frame: NSRect(x: 18, y: 14, width: 120, height: 40), mode: .waveform(barCount: 16))
        waveformVisualizer.tintColor = NSColor(red: 0.98, green: 0.38, blue: 0.08, alpha: 1.0)
        topIslandBar.addSubview(waveformVisualizer)
        
        // Right: 7 Action Buttons (Share, Audio Test, Log, Pause, Compact, Pin, Close)
        let rightStartX: CGFloat = 880 - 334
        
        shareActionBtn = HUDActionButton(iconName: "square.and.arrow.up", title: "Share", toolTip: "Share Captions (⌘S)") { [weak self] in
            self?.openShare()
        }
        shareActionBtn.frame.origin = CGPoint(x: rightStartX, y: 9)
        topIslandBar.addSubview(shareActionBtn)
        
        testAudioActionBtn = HUDActionButton(iconName: "speaker.wave.2.fill", title: "Audio", toolTip: "Audio & Microphone Setup") { [weak self] in
            self?.testMicAction()
        }
        testAudioActionBtn.frame.origin = CGPoint(x: rightStartX + 46, y: 9)
        topIslandBar.addSubview(testAudioActionBtn)
        
        logActionBtn = HUDActionButton(iconName: "list.bullet", title: "Log", toolTip: "Transcript History (⌘T)") { [weak self] in
            self?.openTranscript()
        }
        logActionBtn.frame.origin = CGPoint(x: rightStartX + 92, y: 9)
        topIslandBar.addSubview(logActionBtn)
        
        pauseActionBtn = HUDActionButton(iconName: "pause.fill", title: "Pause", toolTip: "Pause Captions (Space)") { [weak self] in
            self?.togglePlayPause()
        }
        pauseActionBtn.frame.origin = CGPoint(x: rightStartX + 138, y: 9)
        topIslandBar.addSubview(pauseActionBtn)
        
        compactActionBtn = HUDActionButton(iconName: "arrow.down.right.and.arrow.up.left", title: "Compact", toolTip: "Compact Mode (⌘M)") { [weak self] in
            self?.toggleCompactMode()
        }
        compactActionBtn.frame.origin = CGPoint(x: rightStartX + 184, y: 9)
        topIslandBar.addSubview(compactActionBtn)
        
        pinActionBtn = HUDActionButton(iconName: "pin.fill", title: "Pin", toolTip: "Keep on Top") { [weak self] in
            self?.pinToggleAction()
        }
        pinActionBtn.frame.origin = CGPoint(x: rightStartX + 230, y: 9)
        topIslandBar.addSubview(pinActionBtn)
        
        closeActionBtn = HUDActionButton(iconName: "xmark", title: "Close", toolTip: "Close (⌘W)", isDestructive: true) { [weak self] in
            self?.closeBtnAction()
        }
        closeActionBtn.frame.origin = CGPoint(x: rightStartX + 276, y: 9)
        topIslandBar.addSubview(closeActionBtn)
        
        // Center: Language Selector Capsule mathematically centered between left visualizer and right actions
        let centerAvailableWidth = rightStartX - 138
        let langX = 138 + (centerAvailableWidth - 296) / 2.0
        languageSelectorBar = LanguageSelectorBarView(frame: NSRect(x: langX, y: 10, width: 296, height: 48))
        languageSelectorBar.userLanguageIndex = 1 // Default English
        languageSelectorBar.callerLanguageIndex = 0 // Default Spanish
        languageSelectorBar.onLanguageChanged = { [weak self] isUser, newIndex in
            self?.languageChanged()
        }
        languageSelectorBar.onSwapLanguages = { [weak self] in
            guard let self = self else { return }
            let oldUser = self.languageSelectorBar.userLanguageIndex
            let oldCaller = self.languageSelectorBar.callerLanguageIndex
            self.languageSelectorBar.userLanguageIndex = oldCaller
            self.languageSelectorBar.callerLanguageIndex = oldUser
            self.languageChanged()
        }
        topIslandBar.addSubview(languageSelectorBar)
        
        // ----------------------------------------------------
        // 2. CALLER SUBTITLE CARD (Orange Glow)
        // ----------------------------------------------------
        callerCard = NSView(frame: NSRect(x: 0, y: 108, width: 880, height: 96))
        callerCard.wantsLayer = true
        callerCard.layer?.shadowColor = NSColor(red: 0.98, green: 0.38, blue: 0.08, alpha: 0.6).cgColor
        callerCard.layer?.shadowRadius = 12
        callerCard.layer?.shadowOpacity = 0.45
        callerCard.layer?.shadowOffset = .zero
        
        let callerCardEffect = NSVisualEffectView(frame: callerCard.bounds)
        callerCardEffect.material = .popover
        callerCardEffect.blendingMode = .behindWindow
        callerCardEffect.state = .active
        callerCardEffect.wantsLayer = true
        callerCardEffect.layer?.cornerRadius = 18
        callerCardEffect.layer?.masksToBounds = true
        callerCardEffect.layer?.borderWidth = 1.5
        callerCardEffect.layer?.borderColor = NSColor(red: 0.98, green: 0.38, blue: 0.08, alpha: 0.8).cgColor
        callerCardEffect.autoresizingMask = [.width, .height]
        callerCard.addSubview(callerCardEffect)
        
        fullModeContainer.addSubview(callerCard)
        
        callerHeaderLabel = NSTextField(labelWithString: "Caller · Spanish → English")
        callerHeaderLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        callerHeaderLabel.textColor = NSColor(red: 0.98, green: 0.5, blue: 0.2, alpha: 1.0)
        callerHeaderLabel.frame = NSRect(x: 22, y: 64, width: 836, height: 20)
        callerCard.addSubview(callerHeaderLabel)
        
        callerSubtitleLabel = NSTextField(labelWithString: "Hello, how are you doing today?")
        callerSubtitleLabel.font = NSFont.systemFont(ofSize: 20, weight: .medium)
        callerSubtitleLabel.textColor = .white
        callerSubtitleLabel.maximumNumberOfLines = 2
        callerSubtitleLabel.cell?.lineBreakMode = .byWordWrapping
        callerSubtitleLabel.frame = NSRect(x: 22, y: 14, width: 836, height: 48)
        callerCard.addSubview(callerSubtitleLabel)
        
        // ----------------------------------------------------
        // 3. YOU SUBTITLE CARD (Golden Hour Glow)
        // ----------------------------------------------------
        youCard = NSView(frame: NSRect(x: 0, y: 0, width: 880, height: 96))
        youCard.wantsLayer = true
        youCard.layer?.shadowColor = NSColor(red: 0.98, green: 0.6, blue: 0.1, alpha: 0.6).cgColor
        youCard.layer?.shadowRadius = 12
        youCard.layer?.shadowOpacity = 0.45
        youCard.layer?.shadowOffset = .zero
        
        let youCardEffect = NSVisualEffectView(frame: youCard.bounds)
        youCardEffect.material = .popover
        youCardEffect.blendingMode = .behindWindow
        youCardEffect.state = .active
        youCardEffect.wantsLayer = true
        youCardEffect.layer?.cornerRadius = 18
        youCardEffect.layer?.masksToBounds = true
        youCardEffect.layer?.borderWidth = 1.5
        youCardEffect.layer?.borderColor = NSColor(red: 0.98, green: 0.6, blue: 0.1, alpha: 0.8).cgColor
        youCardEffect.autoresizingMask = [.width, .height]
        youCard.addSubview(youCardEffect)
        
        fullModeContainer.addSubview(youCard)
        
        youHeaderLabel = NSTextField(labelWithString: "You · English → Spanish")
        youHeaderLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        youHeaderLabel.textColor = NSColor(red: 0.98, green: 0.7, blue: 0.3, alpha: 1.0)
        youHeaderLabel.frame = NSRect(x: 22, y: 64, width: 836, height: 20)
        youCard.addSubview(youHeaderLabel)
        
        youSubtitleLabel = NSTextField(labelWithString: "I am doing great, can you hear me clearly?")
        youSubtitleLabel.font = NSFont.systemFont(ofSize: 20, weight: .medium)
        youSubtitleLabel.textColor = .white
        youSubtitleLabel.maximumNumberOfLines = 2
        youSubtitleLabel.cell?.lineBreakMode = .byWordWrapping
        youSubtitleLabel.frame = NSRect(x: 22, y: 14, width: 836, height: 48)
        youCard.addSubview(youSubtitleLabel)
    }
    
    // MARK: - Compact Mode Setup (Matching Image Perfectly)
    
    private func setupCompactModeUI() {
        compactPill = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 50))
        compactPill.wantsLayer = true
        compactPill.layer?.shadowColor = NSColor.black.cgColor
        compactPill.layer?.shadowRadius = 14
        compactPill.layer?.shadowOpacity = 0.55
        compactPill.layer?.shadowOffset = CGSize(width: 0, height: -3)
        compactPill.isHidden = !isCompactMode
        
        let compactEffect = NSVisualEffectView(frame: compactPill.bounds)
        compactEffect.material = .hudWindow
        compactEffect.blendingMode = .behindWindow
        compactEffect.state = .active
        compactEffect.wantsLayer = true
        compactEffect.layer?.cornerRadius = 25
        compactEffect.layer?.masksToBounds = true
        compactEffect.layer?.borderWidth = 1.0
        compactEffect.layer?.borderColor = NSColor(red: 0.98, green: 0.38, blue: 0.08, alpha: 0.4).cgColor
        compactEffect.autoresizingMask = [.width, .height]
        compactPill.addSubview(compactEffect)
        
        mainContainer.addSubview(compactPill)
        
        // 1. Left Glowing Orange Dot with radiant ambient bloom halo
        let dotContainer = NSView(frame: NSRect(x: 14, y: 15, width: 20, height: 20))
        dotContainer.wantsLayer = true
        
        let halo = NSView(frame: NSRect(x: 1, y: 1, width: 18, height: 18))
        halo.wantsLayer = true
        halo.layer?.cornerRadius = 9
        halo.layer?.backgroundColor = NSColor(red: 0.98, green: 0.38, blue: 0.08, alpha: 0.25).cgColor
        dotContainer.addSubview(halo)
        
        compactGreenDot = NSView(frame: NSRect(x: 5, y: 5, width: 10, height: 10))
        compactGreenDot.wantsLayer = true
        compactGreenDot.layer?.cornerRadius = 5
        compactGreenDot.layer?.backgroundColor = NSColor(red: 0.98, green: 0.38, blue: 0.08, alpha: 1.0).cgColor
        compactGreenDot.layer?.shadowColor = NSColor(red: 0.98, green: 0.38, blue: 0.08, alpha: 1.0).cgColor
        compactGreenDot.layer?.shadowRadius = 8
        compactGreenDot.layer?.shadowOpacity = 0.95
        compactGreenDot.layer?.shadowOffset = .zero
        dotContainer.addSubview(compactGreenDot)
        compactPill.addSubview(dotContainer)
        
        // 2. Inset Language Route Capsule [🇬🇧 EN → ES 🇪🇸] (Interactive)
        compactLangRouteView = CompactLanguageRouteView(frame: NSRect(x: 40, y: 11, width: 128, height: 28))
        compactLangRouteView.userLanguageIndex = languageSelectorBar.userLanguageIndex
        compactLangRouteView.callerLanguageIndex = languageSelectorBar.callerLanguageIndex
        compactLangRouteView.onLanguageChanged = { [weak self] isUser, newIndex in
            guard let self = self else { return }
            if isUser {
                self.languageSelectorBar.userLanguageIndex = newIndex
            } else {
                self.languageSelectorBar.callerLanguageIndex = newIndex
            }
            self.languageChanged()
        }
        compactLangRouteView.onSwapLanguages = { [weak self] in
            self?.swapLanguagesAction()
        }
        compactPill.addSubview(compactLangRouteView)
        
        // 3. Live Kinetic Subtitle (Clean without blinking cursor)
        compactSubtitleLabel = NSTextField(labelWithString: "Hello, how are you doing today?")
        compactSubtitleLabel.font = NSFont.systemFont(ofSize: 15, weight: .regular)
        compactSubtitleLabel.textColor = .white
        compactSubtitleLabel.isBordered = false
        compactSubtitleLabel.drawsBackground = false
        compactSubtitleLabel.lineBreakMode = .byTruncatingTail
        compactSubtitleLabel.frame = NSRect(x: 178, y: 13, width: 780 - 376, height: 24)
        compactPill.addSubview(compactSubtitleLabel)
        
        // 4. Right Controls Dock: QR Code, Equalizer, Pause, Expand, Pin, Close
        let rightPillWidth: CGFloat = 780
        
        // QR Code button
        compactQRBtn = HUDCompactButton(
            frame: NSRect(x: rightPillWidth - 188, y: 13, width: 24, height: 24),
            iconName: "qrcode",
            toolTip: "Share Captions (⌘S)",
            target: self,
            action: #selector(openShare)
        )
        compactPill.addSubview(compactQRBtn)
        
        // 4-Bar Micro Equalizer
        compactEqualizerView = AudioVisualizerView(frame: NSRect(x: rightPillWidth - 158, y: 18, width: 18, height: 14), mode: .equalizer(barCount: 4))
        compactEqualizerView.tintColor = NSColor(red: 0.98, green: 0.38, blue: 0.08, alpha: 1.0)
        compactPill.addSubview(compactEqualizerView)
        
        // Pause Button
        compactPauseBtn = HUDCompactButton(
            frame: NSRect(x: rightPillWidth - 134, y: 13, width: 24, height: 24),
            iconName: "pause.fill",
            toolTip: "Pause Captions (Space)",
            target: self,
            action: #selector(togglePlayPause)
        )
        compactPill.addSubview(compactPauseBtn)
        
        // Expand to Full Mode Button (⤢)
        compactExpandBtn = HUDCompactButton(
            frame: NSRect(x: rightPillWidth - 104, y: 13, width: 24, height: 24),
            iconName: "arrow.up.left.and.arrow.down.right",
            toolTip: "Expanded Mode (⌘M)",
            target: self,
            action: #selector(toggleCompactMode)
        )
        compactPill.addSubview(compactExpandBtn)
        
        // Pin Button
        compactPinBtn = HUDCompactButton(
            frame: NSRect(x: rightPillWidth - 74, y: 13, width: 24, height: 24),
            iconName: "pin.fill",
            toolTip: "Keep on Top",
            target: self,
            action: #selector(pinToggleAction)
        )
        compactPill.addSubview(compactPinBtn)
        
        // Close Button
        compactCloseBtn = HUDCompactButton(
            frame: NSRect(x: rightPillWidth - 44, y: 13, width: 24, height: 24),
            iconName: "xmark.circle.fill",
            toolTip: "Close (⌘W)",
            target: self,
            action: #selector(closeBtnAction)
        )
        // Make the close button red for standard window behavior
        if let closeImg = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close") {
            let config = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .semibold)
            compactCloseBtn.image = closeImg.withSymbolConfiguration(config)
            compactCloseBtn.contentTintColor = NSColor.systemRed
        }
        compactPill.addSubview(compactCloseBtn)
    }
    
    private func setupPermissionBanner() {
        permissionBanner = NSView(frame: .zero)
        permissionBanner.wantsLayer = true
        permissionBanner.layer?.backgroundColor = NSColor(red: 0.85, green: 0.35, blue: 0.05, alpha: 0.92).cgColor
        permissionBanner.layer?.cornerRadius = 10
        permissionBanner.layer?.borderWidth = 1.0
        permissionBanner.layer?.borderColor = NSColor.systemOrange.cgColor
        permissionBanner.isHidden = true
        permissionBanner.layer?.zPosition = 999
        
        permissionMessageLabel = NSTextField(labelWithString: "Permission required for speech recognition or call audio")
        permissionMessageLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        permissionMessageLabel.textColor = .white
        permissionBanner.addSubview(permissionMessageLabel)
        
        let settingsBtn = NSButton(title: "Open Settings", target: self, action: #selector(openCurrentPermissionSettings))
        settingsBtn.bezelStyle = .texturedRounded
        settingsBtn.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        permissionBanner.addSubview(settingsBtn)
        
        let dismissBtn = NSButton(title: "✕", target: self, action: #selector(hidePermissionBanner))
        dismissBtn.bezelStyle = .texturedRounded
        dismissBtn.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        permissionBanner.addSubview(dismissBtn)
        
        mainContainer.addSubview(permissionBanner)
    }
    
    // MARK: - Dynamic Updates
    
    private func refreshLanguageDisplay() {
        let userLang = SupportedLanguages.all[languageSelectorBar.userLanguageIndex]
        let callerLang = SupportedLanguages.all[languageSelectorBar.callerLanguageIndex]
        
        languageSelectorBar.updateDisplay()
        compactLangRouteView?.userLanguageIndex = languageSelectorBar.userLanguageIndex
        compactLangRouteView?.callerLanguageIndex = languageSelectorBar.callerLanguageIndex
        compactLangRouteView?.updateDisplay()
        
        callerHeaderLabel.stringValue = "Caller · \(callerLang.name) → \(userLang.name)"
        youHeaderLabel.stringValue = "You · \(userLang.name) → \(callerLang.name)"
        
        WebCaptionServer.shared.setLanguages(hostCode: userLang.code, callerCode: callerLang.code)
    }
    
    private func updateCompactSubtitle() {
        guard compactSubtitleLabel != nil else { return }
        
        let displayText: String
        if lastCallerText.isEmpty {
            displayText = "Hello, how are you doing today?"
        } else {
            displayText = lastCallerText
        }
        
        compactSubtitleLabel.stringValue = displayText
        
        if isCompactMode, let window = view.window {
            let font = compactSubtitleLabel.font ?? NSFont.systemFont(ofSize: 15)
            let textWidth = (displayText as NSString).size(withAttributes: [.font: font]).width
            let screenWidth = (window.screen?.visibleFrame.width ?? 1440) - 40
            let targetWidth = max(520, min(textWidth + 376 + 24, screenWidth))
            
            var frame = window.frame
            let widthDiff = targetWidth - frame.width
            frame.origin.x -= widthDiff / 2.0
            frame.size.width = targetWidth
            
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in
                self?.layoutAllViews()
            })
            layoutAllViews()
        }
    }
    
    private func languageChanged() {
        refreshLanguageDisplay()
        
        let userLang = SupportedLanguages.all[languageSelectorBar.userLanguageIndex]
        let callerLang = SupportedLanguages.all[languageSelectorBar.callerLanguageIndex]
        
        speechRecognitionManager.stop()
        speechRecognitionManager.start(callerLocaleId: callerLang.speechLocale, myLocaleId: userLang.speechLocale)
    }
    
    // MARK: - Compact / Full Mode Toggle
    
    @objc public func toggleCompactMode() {
        guard let window = view.window else { return }
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let currentFrame = window.frame
        
        if !isCompactMode {
            // TRANSITION TO AMBIENT WHISPER PILL
            normalWindowFrame = currentFrame
            isCompactMode = true
            
            let displayText = lastCallerText.isEmpty ? "Hello, how are you doing today?" : lastCallerText
            let font = compactSubtitleLabel.font ?? NSFont.systemFont(ofSize: 15)
            let textWidth = (displayText as NSString).size(withAttributes: [.font: font]).width
            let screenWidth = screen.width - 40
            let targetWidth = max(520, min(textWidth + 376 + 24, screenWidth))
            let targetHeight: CGFloat = 50
            
            let currentTopY = currentFrame.origin.y + currentFrame.height
            var targetY = currentTopY - targetHeight
            targetY = max(screen.minY + 20, min(screen.maxY - targetHeight, targetY))
            
            let currentCenterX = currentFrame.origin.x + (currentFrame.width / 2.0)
            var targetX = currentCenterX - (targetWidth / 2.0)
            targetX = max(screen.minX + 10, min(screen.maxX - targetWidth - 10, targetX))
            
            let targetFrame = NSRect(x: targetX, y: targetY, width: targetWidth, height: targetHeight)
            
            fullModeContainer.isHidden = true
            compactPill.isHidden = false
            updateCompactSubtitle()
            
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(targetFrame, display: true)
            }, completionHandler: { [weak self] in
                self?.layoutAllViews()
            })
        } else {
            // TRANSITION TO DYNAMIC ISLAND PRO FULL HUD
            isCompactMode = false
            
            let targetWidth: CGFloat = 880
            let targetHeight: CGFloat = 284
            
            let currentTopY = currentFrame.origin.y + currentFrame.height
            var targetY = currentTopY - targetHeight
            targetY = max(screen.minY + 20, min(screen.maxY - targetHeight, targetY))
            
            var targetX = normalWindowFrame?.origin.x ?? currentFrame.origin.x
            targetX = max(screen.minX + 10, min(screen.maxX - targetWidth - 10, targetX))
            
            let targetFrame = NSRect(x: targetX, y: targetY, width: targetWidth, height: targetHeight)
            
            compactPill.isHidden = true
            fullModeContainer.isHidden = false
            
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(targetFrame, display: true)
            }, completionHandler: { [weak self] in
                self?.layoutAllViews()
            })
        }
    }
    
    // Double click to toggle modes
    public override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 {
            toggleCompactMode()
        }
    }
    
    // MARK: - Layout Engine
    
    private func layoutAllViews() {
        guard let view = self.viewIfLoaded else { return }
        let width = view.bounds.width
        let height = view.bounds.height
        
        mainContainer.frame = view.bounds
        
        if isCompactMode {
            compactPill.isHidden = false
            fullModeContainer.isHidden = true
            compactPill.frame = NSRect(x: 0, y: (height - 50) / 2.0, width: width, height: 50)
            compactLangRouteView.frame = NSRect(x: 40, y: 11, width: 128, height: 28)
            compactSubtitleLabel.frame = NSRect(x: 178, y: 13, width: max(100, width - 376), height: 24)
            
            compactQRBtn?.frame.origin.x = width - 188
            compactEqualizerView?.frame.origin.x = width - 158
            compactPauseBtn?.frame.origin.x = width - 134
            compactExpandBtn?.frame.origin.x = width - 104
            compactPinBtn?.frame.origin.x = width - 74
            compactCloseBtn?.frame.origin.x = width - 44
        } else {
            compactPill.isHidden = true
            fullModeContainer.isHidden = false
            fullModeContainer.frame = view.bounds
            topIslandBar.frame = NSRect(x: 0, y: height - 68, width: width, height: 68)
            
            // Left: Waveform (ends at 138)
            waveformVisualizer.frame = NSRect(x: 18, y: 14, width: 120, height: 40)
            
            // Right: 7 Action Buttons (cluster from width - 334 to width - 18)
            let rightStartX = width - 334
            shareActionBtn.frame.origin.x = rightStartX
            testAudioActionBtn.frame.origin.x = rightStartX + 46
            logActionBtn.frame.origin.x = rightStartX + 92
            pauseActionBtn.frame.origin.x = rightStartX + 138
            compactActionBtn.frame.origin.x = rightStartX + 184
            pinActionBtn.frame.origin.x = rightStartX + 230
            closeActionBtn.frame.origin.x = rightStartX + 276
            
            // Center: Language Selector mathematically centered between left visualizer and right actions
            let centerAvailableWidth = rightStartX - 138
            let langX = 138 + (centerAvailableWidth - 296) / 2.0
            languageSelectorBar.frame = NSRect(x: langX, y: 10, width: 296, height: 48)
            
            let cardHeight: CGFloat = (height - 68 - 20) / 2.0
            callerCard.frame = NSRect(x: 0, y: cardHeight + 10, width: width, height: cardHeight)
            callerHeaderLabel.frame = NSRect(x: 22, y: cardHeight - 30, width: width - 44, height: 20)
            callerSubtitleLabel.frame = NSRect(x: 22, y: 10, width: width - 44, height: cardHeight - 44)
            
            youCard.frame = NSRect(x: 0, y: 0, width: width, height: cardHeight)
            youHeaderLabel.frame = NSRect(x: 22, y: cardHeight - 30, width: width - 44, height: 20)
            youSubtitleLabel.frame = NSRect(x: 22, y: 10, width: width - 44, height: cardHeight - 44)
        }
        
        if !permissionBanner.isHidden {
            permissionBanner.frame = NSRect(x: 20, y: height - 42, width: width - 40, height: 36)
        }
    }
    
    // MARK: - Actions
    
    @objc public func swapLanguagesAction() {
        let oldUser = languageSelectorBar.userLanguageIndex
        let oldCaller = languageSelectorBar.callerLanguageIndex
        languageSelectorBar.userLanguageIndex = oldCaller
        languageSelectorBar.callerLanguageIndex = oldUser
        languageChanged()
    }
    
    @objc public func copyPhoneLinkAction() {
        let link = WebCaptionServer.shared.effectiveShareableURL
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(link, forType: .string)
    }
    
    @objc public func openShare() {
        if shareWindowController == nil {
            shareWindowController = ShareWindowController()
        }
        shareWindowController?.updateFields()
        shareWindowController?.showWindow(nil)
        shareWindowController?.window?.makeKeyAndOrderFront(nil)
    }
    
    @objc public func openTranscript() {
        if transcriptWindowController == nil {
            transcriptWindowController = TranscriptWindowController()
        }
        transcriptWindowController?.showWindow(nil)
        transcriptWindowController?.window?.makeKeyAndOrderFront(nil)
    }
    
    @objc public func openPermissions() {
        if permissionsWindowController == nil {
            permissionsWindowController = PermissionsWindowController()
        }
        permissionsWindowController?.refreshStatus()
        permissionsWindowController?.showWindow(nil)
        permissionsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc public func togglePlayPause() {
        isPaused.toggle()
        if isPaused {
            stopCapturing()
            pauseActionBtn.iconName = "play.fill"
            pauseActionBtn.title = "Resume"
            if let playImg = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Resume") {
                let config = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .semibold)
                compactPauseBtn.image = playImg.withSymbolConfiguration(config)
            }
            compactPauseBtn.toolTip = "Resume Captions (Space)"
        } else {
            startCapturing()
            pauseActionBtn.iconName = "pause.fill"
            pauseActionBtn.title = "Pause"
            if let pauseImg = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause") {
                let config = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .semibold)
                compactPauseBtn.image = pauseImg.withSymbolConfiguration(config)
            }
            compactPauseBtn.toolTip = "Pause Captions (Space)"
        }
    }
    
    @objc public func pinToggleAction() {
        guard let window = view.window else { return }
        isPinnedOnTop.toggle()
        if isPinnedOnTop {
            window.level = .floating
            pinActionBtn.isHighlightedState = true
            compactPinBtn.alphaValue = 1.0
            compactPinBtn.toolTip = "Always on Top: Enabled"
        } else {
            window.level = .normal
            pinActionBtn.isHighlightedState = false
            compactPinBtn.alphaValue = 0.45
            compactPinBtn.toolTip = "Always on Top: Disabled"
        }
    }
    
    @objc public func closeBtnAction() {
        view.window?.orderOut(nil)
    }
    
    @objc public func testMicAction() {
        let auth = SFSpeechRecognizer.authorizationStatus()
        if auth == .denied {
            showPermissionBanner(message: "⚠️ Speech Recognition permission denied in System Settings.", settingsTarget: #selector(openSpeechSettingsAction))
            return
        }
        
        testAudioActionBtn.isHighlightedState = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.testAudioActionBtn.isHighlightedState = false
        }
    }
    
    // MARK: - Speech & Audio Capture Lifecycle
    
    private func checkPermissionsAndStart() {
        startCapturing()
        
        if !PermissionHelper.shared.hasScreenCaptureAccess {
            showPermissionBanner(
                message: "⚠️ Screen & Audio Recording needed for call audio. Click 'Open Settings' to enable.",
                settingsTarget: #selector(openScreenSettingsAction)
            )
        } else {
            hidePermissionBanner()
        }
        
        SpeechRecognitionManager.requestAuthorization { [weak self] granted in
            guard let self = self else { return }
            if !granted && SFSpeechRecognizer.authorizationStatus() == .denied {
                self.showPermissionBanner(
                    message: "⚠️ Speech Recognition permission denied in System Settings.",
                    settingsTarget: #selector(self.openSpeechSettingsAction)
                )
            }
        }
    }
    
    public func startCapturing() {
        if isStartingCapture || audioCaptureEngine.isRunning { return }
        isStartingCapture = true
        
        let userLang = SupportedLanguages.all[languageSelectorBar.userLanguageIndex]
        let callerLang = SupportedLanguages.all[languageSelectorBar.callerLanguageIndex]
        
        speechRecognitionManager.start(callerLocaleId: callerLang.speechLocale, myLocaleId: userLang.speechLocale)
        
        Task {
            defer {
                Task { @MainActor in
                    self.isStartingCapture = false
                }
            }
            do {
                try await audioCaptureEngine.start(mode: .bidirectional)
            } catch {
                NSLog("[HUD] Audio capture error: \(error)")
            }
        }
    }
    
    public func stopCapturing() {
        audioCaptureEngine.stop()
        speechRecognitionManager.stop()
    }
    
    // MARK: - AudioCaptureDelegate
    
    public func audioCaptureDidOutputCallerAudio(sampleBuffer: CMSampleBuffer) {
        speechRecognitionManager.feedCallerAudioBuffer(sampleBuffer)
    }
    
    public func audioCaptureDidOutputCallerAudio(pcmBuffer: AVAudioPCMBuffer) {
        speechRecognitionManager.feedCallerAudioBuffer(pcmBuffer)
    }
    
    public func audioCaptureDidOutputMyAudio(pcmBuffer: AVAudioPCMBuffer) {
        speechRecognitionManager.feedMyAudioBuffer(pcmBuffer)
    }
    
    public func audioCaptureDidUpdateCallerLevel(_ level: Float) {
        waveformVisualizer.tintColor = NSColor(red: 0.10, green: 0.88, blue: 0.52, alpha: 1.0)
        waveformVisualizer.setAudioLevel(level)
        
        if isCompactMode {
            compactEqualizerView.tintColor = NSColor(red: 0.10, green: 0.88, blue: 0.52, alpha: 1.0)
            compactEqualizerView.setAudioLevel(level)
            
            if level > 0.05 {
                compactGreenDot.layer?.shadowOpacity = 1.0
                compactGreenDot.layer?.shadowRadius = 10
            } else {
                compactGreenDot.layer?.shadowOpacity = 0.5
                compactGreenDot.layer?.shadowRadius = 5
            }
        }
    }
    
    public func audioCaptureDidUpdateMyLevel(_ level: Float) {
        if level > 0.06 {
            waveformVisualizer.tintColor = NSColor(red: 0.06, green: 0.75, blue: 0.95, alpha: 1.0)
            waveformVisualizer.setAudioLevel(level)
        }
    }
    
    public func audioCaptureDidEncounterError(_ error: Error) {
        NSLog("[AudioCapture] Error: \(error)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.showPermissionBanner(message: "⚠️ Audio capture error: \(error.localizedDescription)", settingsTarget: #selector(self.openScreenSettingsAction))
        }
    }
    
    // MARK: - BidirectionalSpeechDelegate
    
    public func callerSpeechDidUpdate(partialOriginal: String, partialTranslated: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lastActiveSpeakerIsCaller = true
            let display = partialTranslated.isEmpty ? partialOriginal : partialTranslated
            self.lastCallerText = display
            self.callerSubtitleLabel.stringValue = display
            self.updateCompactSubtitle()
        }
    }
    
    public func callerSpeechDidFinalize(original: String, translated: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lastActiveSpeakerIsCaller = true
            let display = translated.isEmpty ? original : translated
            self.lastCallerText = display
            self.callerSubtitleLabel.stringValue = display
            self.updateCompactSubtitle()
            
            TranscriptManager.shared.addEntry(speaker: "Caller", original: original, translated: display)
        }
    }
    
    public func mySpeechDidUpdate(partialOriginal: String, partialTranslated: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lastActiveSpeakerIsCaller = false
            let display = partialTranslated.isEmpty ? partialOriginal : partialTranslated
            self.lastMyText = display
            self.youSubtitleLabel.stringValue = display
            // In compact mode, we do NOT change the subtitle: it strictly shows the caller's translated caption
            
            WebCaptionServer.shared.broadcastSubtitle(speaker: "host", original: partialOriginal, translated: display, displayForCaller: display)
        }
    }
    
    public func mySpeechDidFinalize(original: String, translated: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lastActiveSpeakerIsCaller = false
            let display = translated.isEmpty ? original : translated
            self.lastMyText = display
            self.youSubtitleLabel.stringValue = display
            // In compact mode, we do NOT change the subtitle: it strictly shows the caller's translated caption
            
            WebCaptionServer.shared.broadcastSubtitle(speaker: "host", original: original, translated: display, displayForCaller: display)
            TranscriptManager.shared.addEntry(speaker: "You", original: original, translated: display)
        }
    }
    
    public func speechRecognitionStatusChanged(_ isRecognizing: Bool) {
    }
    
    public func speechRecognitionDidEncounterAuthError(message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.showPermissionBanner(message: message, settingsTarget: #selector(self.openSpeechSettingsAction))
        }
    }
    
    // MARK: - Permission Banner Helpers
    
    private func showPermissionBanner(message: String, settingsTarget: Selector) {
        permissionMessageLabel.stringValue = message
        permissionSettingsTarget = settingsTarget
        permissionBanner.isHidden = false
        if isCompactMode {
            toggleCompactMode()
        } else {
            layoutAllViews()
        }
    }
    
    @objc private func hidePermissionBanner() {
        permissionBanner.isHidden = true
        layoutAllViews()
    }
    
    @objc private func openCurrentPermissionSettings() {
        openPermissions()
    }
    
    @objc private func openSpeechSettingsAction() {
        PermissionHelper.shared.openSpeechRecognitionSettings()
    }
    
    @objc private func openScreenSettingsAction() {
        PermissionHelper.shared.openScreenCaptureSettings()
    }
    
    @objc private func handleAppDidBecomeActive() {
        if SFSpeechRecognizer.authorizationStatus() == .authorized && PermissionHelper.shared.hasScreenCaptureAccess {
            hidePermissionBanner()
        }
        if !audioCaptureEngine.isRunning && !isStartingCapture && !isPaused {
            startCapturing()
        }
    }
}
