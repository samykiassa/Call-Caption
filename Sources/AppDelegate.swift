import AppKit
import Speech
import SwiftUI
import os

@MainActor
private final class FloatingCaptionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        if let sheet = attachedSheet {
            endSheet(sheet)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var statusMenu: NSMenu!
    private var floatingPanel: FloatingCaptionPanel?
    private var floatingHostingController: NSHostingController<CaptionPopoverView>?
    private var sigtermSource: DispatchSourceSignal?

    private let popoverVisibility = SurfaceVisibilityState(isVisible: false)
    private let floatingVisibility = SurfaceVisibilityState(isVisible: false)
    private var isPopoverVisible = false
    private var isFloatingPanelVisible = false
    private var lastPopoverCloseEventNumber: Int?
    private var lastPopoverCloseUptime: TimeInterval = 0
    private var lastEngineRecoveryTriggerUptime: TimeInterval = 0

    private var togglePopoverMenuItem: NSMenuItem?
    private var detachMenuItem: NSMenuItem?
    private var pauseResumeMenuItem: NSMenuItem?
    private var conversationalMenuItem: NSMenuItem?
    private var shareMenuItem: NSMenuItem?

    private var pauseResumeMainMenuItem: NSMenuItem?
    private var conversationalMainMenuItem: NSMenuItem?
    private var shareMainMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupSignalHandlers()
        setupMainMenu()
        setupStatusItem()
        setupObservers()
        CaptionCoordinator.shared.setLevelMeteringVisible(false)

        let auth = SFSpeechRecognizer.authorizationStatus()
        if auth == .notDetermined {
            SpeechRecognitionManager.requestAuthorization { _ in
                Task { @MainActor in
                    CaptionCoordinator.shared.start()
                    self.updateStatusItemAppearance()
                    self.scheduleInitialSurfacePresentationIfNeeded()
                }
            }
        } else {
            CaptionCoordinator.shared.start()
            updateStatusItemAppearance()
            scheduleInitialSurfacePresentationIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        LiveShareManager.shared.stopSharingSynchronously()
        CaptionCoordinator.shared.stop()
    }

    private func setupSignalHandlers() {
        guard sigtermSource == nil else { return }
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            LiveShareManager.shared.stopSharingSynchronously()
            self?.quitApp()
        }
        source.resume()
        sigtermSource = source
    }

    private func scheduleInitialSurfacePresentationIfNeeded() {
        guard ProcessInfo.processInfo.environment["CALLCAPTION_TEST"] != "1" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            let defaults = UserDefaults.standard
            let isFirstLaunch = !defaults.bool(forKey: "hasShownInitialUI")
            let hasAlert = CaptionCoordinator.shared.viewModel.alertMessage != nil
            if isFirstLaunch || hasAlert {
                defaults.set(true, forKey: "hasShownInitialUI")
                if !self.isPopoverVisible && !self.isFloatingPanelVisible {
                    self.showPopover(activateApp: isFirstLaunch)
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if isFloatingPanelVisible, let panel = floatingPanel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate()
        } else {
            showPopover(activateApp: true)
        }
        return false
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let quitItem = NSMenuItem(
            title: AppL10n.string("menu.quit", fallback: "Quit Call Caption"),
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: AppL10n.string("menu.edit", fallback: "Edit"))
        editMenu.addItem(withTitle: AppL10n.string("menu.copy", fallback: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: AppL10n.string("menu.select_all", fallback: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: AppL10n.string("menu.controls", fallback: "Controls"))
        windowMenu.delegate = self

        let pauseItem = NSMenuItem(
            title: AppL10n.string("menu.pause_captions", fallback: "Pause Captions"),
            action: #selector(togglePauseAction),
            keyEquivalent: "p"
        )
        pauseItem.target = self
        windowMenu.addItem(pauseItem)
        pauseResumeMainMenuItem = pauseItem

        let convItem = NSMenuItem(
            title: AppL10n.string("menu.conversational_mode", fallback: "Conversational Mode"),
            action: #selector(toggleConversationalAction),
            keyEquivalent: "m"
        )
        convItem.target = self
        windowMenu.addItem(convItem)
        conversationalMainMenuItem = convItem

        let shareItem = NSMenuItem(
            title: AppL10n.string("menu.share_live_link", fallback: "Share Live Link"),
            action: #selector(toggleShareAction),
            keyEquivalent: "l"
        )
        shareItem.target = self
        windowMenu.addItem(shareItem)
        shareMainMenuItem = shareItem

        windowMenu.addItem(NSMenuItem.separator())

        let closeItem = NSMenuItem(
            title: AppL10n.string("menu.close", fallback: "Close"),
            action: #selector(closeActiveSurfaceAction),
            keyEquivalent: "w"
        )
        closeItem.target = self
        windowMenu.addItem(closeItem)
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.toolTip = AppL10n.string("app.name", fallback: "Call Caption")
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }

        popover = NSPopover()
        popover.delegate = self
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentSize = NSSize(width: 430, height: 540)
        applyAppearancePreference()
        updatePopoverBehavior()

        setupStatusMenu()
        updateStatusItemAppearance()
    }

    private func ensurePopoverHostingController() {
        guard popover.contentViewController == nil else { return }
        let hosting = NSHostingController(
            rootView: CaptionPopoverView(
                viewModel: CaptionCoordinator.shared.viewModel,
                isDetached: false,
                onToggleDetach: { [weak self] in self?.popOutFloatingPanel() },
                onQuit: { [weak self] in self?.quitApp() },
                surfaceVisibility: popoverVisibility
            )
        )
        hosting.sizingOptions = []
        popover.contentViewController = hosting
    }

    private func setupStatusMenu() {
        statusMenu = NSMenu()
        statusMenu.delegate = self

        let showItem = NSMenuItem(
            title: AppL10n.string("menu.show_captions", fallback: "Show Captions"),
            action: #selector(toggleCaptionsAction),
            keyEquivalent: ""
        )
        showItem.target = self
        statusMenu.addItem(showItem)
        togglePopoverMenuItem = showItem

        let detachItem = NSMenuItem(
            title: AppL10n.string("menu.open_floating", fallback: "Open Floating Window"),
            action: #selector(toggleFloatingWindowAction),
            keyEquivalent: ""
        )
        detachItem.target = self
        statusMenu.addItem(detachItem)
        detachMenuItem = detachItem

        statusMenu.addItem(NSMenuItem.separator())

        let pauseItem = NSMenuItem(
            title: AppL10n.string("menu.pause_captions", fallback: "Pause Captions"),
            action: #selector(togglePauseAction),
            keyEquivalent: "p"
        )
        pauseItem.target = self
        statusMenu.addItem(pauseItem)
        pauseResumeMenuItem = pauseItem

        let convItem = NSMenuItem(
            title: AppL10n.string("menu.conversational_mode", fallback: "Conversational Mode"),
            action: #selector(toggleConversationalAction),
            keyEquivalent: "m"
        )
        convItem.target = self
        statusMenu.addItem(convItem)
        conversationalMenuItem = convItem

        let shareItem = NSMenuItem(
            title: AppL10n.string("menu.share_live_link", fallback: "Share Live Link"),
            action: #selector(toggleShareAction),
            keyEquivalent: "l"
        )
        shareItem.target = self
        statusMenu.addItem(shareItem)
        shareMenuItem = shareItem

        statusMenu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: AppL10n.string("menu.quit", fallback: "Quit Call Caption"),
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }

    private func setupObservers() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleStateDidChange), name: CaptionCoordinator.pauseStateDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(handlePinStateDidChange), name: CaptionCoordinator.pinStateDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(handleStateDidChange), name: CaptionCoordinator.alertStateDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(handleStateDidChange), name: CaptionCoordinator.captureStateDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(handleAppearanceDidChange), name: CaptionCoordinator.appearanceDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(handleScreenSharingPrivacyDidChange), name: CaptionCoordinator.screenSharingPrivacyDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(handleCompactFloatingHUDDidChange), name: CaptionCoordinator.compactFloatingHUDDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(handleStateDidChange), name: LiveShareManager.stateDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(handleAppActivation), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(handleScreenParametersDidChange), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        center.addObserver(self, selector: #selector(handleWindowDidBecomeKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(handleSystemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(handleSystemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(handleSessionDidResignActive), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(handleSessionDidBecomeActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    }

    private func appearance(for mode: AppAppearanceMode) -> NSAppearance? {
        switch mode {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    private func applyAppearancePreference() {
        let targetAppearance = appearance(for: CaptionCoordinator.shared.appearanceMode)
        popover?.appearance = targetAppearance
        floatingPanel?.appearance = targetAppearance
    }

    private func applyScreenSharingPrivacy() {
        let sharingType: NSWindow.SharingType = CaptionCoordinator.shared.hideFromScreenSharing ? .none : .readOnly
        floatingPanel?.sharingType = sharingType
        popover?.contentViewController?.view.window?.sharingType = sharingType
    }

    private func updatePopoverBehavior() {
        popover?.behavior = CaptionCoordinator.shared.isPinned ? .applicationDefined : .transient
    }

    private func updateLevelMeteringVisibility() {
        CaptionCoordinator.shared.setLevelMeteringVisible(isPopoverVisible || isFloatingPanelVisible)
    }

    private func floatingPanelMinSize() -> NSSize {
        NSSize(width: 360, height: CaptionCoordinator.shared.isCompactFloatingHUD ? 180 : 300)
    }

    private func applyFloatingPanelMinSize() {
        guard let panel = floatingPanel else { return }
        let targetMinSize = floatingPanelMinSize()
        if panel.minSize != targetMinSize {
            panel.minSize = targetMinSize
        }
        clampPanelToVisibleScreens(panel)
    }

    private func makeOrReuseFloatingPanel() -> FloatingCaptionPanel {
        if let existing = floatingPanel {
            existing.appearance = appearance(for: CaptionCoordinator.shared.appearanceMode)
            existing.sharingType = CaptionCoordinator.shared.hideFromScreenSharing ? .none : .readOnly
            existing.minSize = floatingPanelMinSize()
            clampPanelToVisibleScreens(existing)
            return existing
        }

        let panel = FloatingCaptionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 540),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self
        panel.title = AppL10n.string("app.name", fallback: "Call Caption")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        panel.minSize = floatingPanelMinSize()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = appearance(for: CaptionCoordinator.shared.appearanceMode)
        panel.sharingType = CaptionCoordinator.shared.hideFromScreenSharing ? .none : .readOnly
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 430, height: 540))
        visualEffect.material = .popover
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.autoresizingMask = [.width, .height]

        let hosting = NSHostingController(
            rootView: CaptionPopoverView(
                viewModel: CaptionCoordinator.shared.viewModel,
                isDetached: true,
                onToggleDetach: { [weak self] in self?.dockFloatingPanelToPopover() },
                onQuit: { [weak self] in self?.quitApp() },
                surfaceVisibility: floatingVisibility
            )
        )
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.view.frame = visualEffect.bounds
        hosting.view.autoresizingMask = [.width, .height]

        let containerVC = NSViewController()
        containerVC.view = visualEffect
        containerVC.addChild(hosting)
        visualEffect.addSubview(hosting.view)

        panel.contentViewController = containerVC
        if !panel.setFrameUsingName("CallCaptionFloatingPanel") {
            positionFloatingPanelInitially(panel)
        }
        clampPanelToVisibleScreens(panel)
        panel.setFrameAutosaveName("CallCaptionFloatingPanel")

        floatingHostingController = hosting
        floatingPanel = panel
        return panel
    }

    private func positionFloatingPanelInitially(_ panel: NSPanel) {
        if let button = statusItem?.button,
           let buttonWindow = button.window,
           let screen = buttonWindow.screen ?? NSScreen.main ?? NSScreen.screens.first {
            let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            let visible = screen.visibleFrame
            let size = panel.frame.size
            let maxX = max(visible.minX + 12, visible.maxX - size.width - 12)
            let maxY = max(visible.minY + 12, visible.maxY - size.height - 12)
            let x = min(max(visible.minX + 12, buttonRect.midX - size.width * 0.5), maxX)
            let y = min(max(visible.minY + 12, buttonRect.minY - size.height - 10), maxY)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 20, y: visible.maxY - size.height - 20))
        }
    }

    private func clampPanelToVisibleScreens(_ panel: NSPanel) {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        var frame = panel.frame
        let intersectingScreen = screens
            .filter { $0.frame.intersects(frame) }
            .max { lhs, rhs in
                let la = lhs.frame.intersection(frame)
                let ra = rhs.frame.intersection(frame)
                return (la.width * la.height) < (ra.width * ra.height)
            }

        guard let targetScreen = intersectingScreen
            ?? panel.screen
            ?? statusItem?.button?.window?.screen
            ?? NSScreen.main
            ?? screens.first else {
            return
        }

        let visible = targetScreen.visibleFrame
        let maxAllowedWidth = max(min(panel.minSize.width, visible.width), visible.width - 24)
        let maxAllowedHeight = max(min(panel.minSize.height, visible.height), visible.height - 24)
        frame.size.width = min(max(frame.width, panel.minSize.width), maxAllowedWidth)
        frame.size.height = min(max(frame.height, panel.minSize.height), maxAllowedHeight)

        let marginX: CGFloat = (visible.width - frame.width) >= 24 ? 12 : 0
        let marginY: CGFloat = (visible.height - frame.height) >= 24 ? 12 : 0
        let maxX = max(visible.minX, visible.maxX - frame.width - marginX)
        let minX = min(visible.minX + marginX, maxX)
        let maxY = max(visible.minY, visible.maxY - frame.height - marginY)
        let minY = min(visible.minY + marginY, maxY)

        frame.origin.x = min(max(frame.origin.x, minX), maxX)
        frame.origin.y = min(max(frame.origin.y, minY), maxY)

        if frame != panel.frame {
            panel.setFrame(frame, display: true)
        }
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem?.button else { return }
        let coordinator = CaptionCoordinator.shared
        let hasStarted = coordinator.hasStarted
        let isAudioCapturing = coordinator.isAudioCapturing
        let shareManager = LiveShareManager.shared
        let isSharing = shareManager.isSharing
        let isPaused = coordinator.isPaused
        let hasAlert = coordinator.viewModel.alertMessage != nil
        let hasTunnelOrServerError = shareManager.serverError != nil
            || (isSharing && !shareManager.isTunnelStarting && shareManager.tunnelError != nil)

        let symbol: String
        let description: String
        if isPaused {
            symbol = "captions.bubble"
            description = AppL10n.string("status_item.paused", fallback: "Call Caption — Paused")
        } else if hasAlert {
            symbol = "exclamationmark.bubble.fill"
            description = AppL10n.string("status_item.alert", fallback: "Call Caption — Attention needed")
        } else if !hasStarted {
            symbol = "captions.bubble"
            description = AppL10n.string("status_item.starting", fallback: "Call Caption — Starting")
        } else if !isAudioCapturing {
            symbol = "exclamationmark.bubble.fill"
            description = AppL10n.string("status_item.inactive", fallback: "Call Caption — Audio capture inactive")
        } else if hasTunnelOrServerError {
            symbol = "exclamationmark.bubble.fill"
            description = AppL10n.string("status_item.tunnel_error", fallback: "Call Caption — Live Link error")
        } else if isSharing {
            symbol = "dot.radiowaves.left.and.right"
            description = AppL10n.string("status_item.sharing", fallback: "Call Caption — Live Link active")
        } else {
            symbol = "captions.bubble.fill"
            description = AppL10n.string("status_item.listening", fallback: "Call Caption — Listening")
        }

        let cfg = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .regular)
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: "captions.bubble.fill", accessibilityDescription: description)
        button.image = img?.withSymbolConfiguration(cfg)
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        let isAnyVisible = popover.isShown || isFloatingPanelVisible
        let isPaused = CaptionCoordinator.shared.isPaused
        let isConv = CaptionCoordinator.shared.isConversationalMode
        let isSharing = LiveShareManager.shared.isSharing

        let pauseTitle = isPaused
            ? AppL10n.string("menu.resume_captions", fallback: "Resume Captions")
            : AppL10n.string("menu.pause_captions", fallback: "Pause Captions")
        let convState: NSControl.StateValue = isConv ? .on : .off
        let shareTitle = isSharing
            ? AppL10n.string("menu.stop_sharing_link", fallback: "Stop Sharing Link")
            : AppL10n.string("menu.share_live_link", fallback: "Share Live Link")

        togglePopoverMenuItem?.title = isAnyVisible
            ? AppL10n.string("menu.hide_captions", fallback: "Hide Captions")
            : AppL10n.string("menu.show_captions", fallback: "Show Captions")
        detachMenuItem?.title = isFloatingPanelVisible
            ? AppL10n.string("menu.dock_popover", fallback: "Dock to Menu Bar")
            : AppL10n.string("menu.open_floating", fallback: "Open Floating Window")
        pauseResumeMenuItem?.title = pauseTitle
        conversationalMenuItem?.state = convState
        shareMenuItem?.title = shareTitle

        pauseResumeMainMenuItem?.title = pauseTitle
        conversationalMainMenuItem?.state = convState
        shareMainMenuItem?.title = shareTitle
    }

    // MARK: - NSPopoverDelegate

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        popover.contentViewController?.view.window?.attachedSheet == nil
    }

    func popoverShouldDetach(_ popover: NSPopover) -> Bool {
        true
    }

    func detachableWindow(for popover: NSPopover) -> NSWindow? {
        popoverVisibility.isVisible = false
        floatingVisibility.isVisible = true
        let panel = makeOrReuseFloatingPanel()
        isFloatingPanelVisible = true
        updateLevelMeteringVisibility()
        return panel
    }

    func popoverWillShow(_ notification: Notification) {
        popoverVisibility.isVisible = true
        isPopoverVisible = true
        lastPopoverCloseEventNumber = nil
        lastPopoverCloseUptime = 0
        applyScreenSharingPrivacy()
        updateLevelMeteringVisibility()
    }

    func popoverDidShow(_ notification: Notification) {
        applyScreenSharingPrivacy()
    }

    func popoverWillClose(_ notification: Notification) {
        if let event = NSApp.currentEvent,
           event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown || event.type == .leftMouseUp {
            lastPopoverCloseEventNumber = event.eventNumber
        } else {
            lastPopoverCloseEventNumber = nil
        }
        lastPopoverCloseUptime = ProcessInfo.processInfo.systemUptime
    }

    func popoverDidClose(_ notification: Notification) {
        isPopoverVisible = false
        popoverVisibility.isVisible = false
        updateLevelMeteringVisibility()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let panel = floatingPanel, (notification.object as? NSWindow) === panel {
            isFloatingPanelVisible = false
            floatingVisibility.isVisible = false
            updateLevelMeteringVisibility()
            updateStatusItemAppearance()
        }
    }

    // MARK: - Actions

    @objc private func handleStatusItemClick(_ sender: Any?) {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
            if popover.isShown && popover.behavior == .transient {
                forceClosePopover()
            }
            lastPopoverCloseEventNumber = nil
            lastPopoverCloseUptime = 0
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        toggleCaptionsAction()
    }

    @objc private func toggleCaptionsAction() {
        if isFloatingPanelVisible, let panel = floatingPanel {
            closeFloatingPanel(panel)
        } else if popover.isShown {
            forceClosePopover()
        } else {
            if let currentEvent = NSApp.currentEvent,
               let closeEventNumber = lastPopoverCloseEventNumber,
               currentEvent.eventNumber == closeEventNumber,
               (currentEvent.type == .leftMouseDown || currentEvent.type == .leftMouseUp) {
                lastPopoverCloseEventNumber = nil
                return
            }
            if lastPopoverCloseEventNumber == nil,
               ProcessInfo.processInfo.systemUptime - lastPopoverCloseUptime < 0.05 {
                lastPopoverCloseUptime = 0
                return
            }
            lastPopoverCloseEventNumber = nil
            showPopover(activateApp: true)
        }
    }

    @objc private func toggleFloatingWindowAction() {
        if isFloatingPanelVisible {
            dockFloatingPanelToPopover()
        } else {
            popOutFloatingPanel()
        }
    }

    private func popOutFloatingPanel() {
        if popover.isShown {
            forceClosePopover()
        }
        popoverVisibility.isVisible = false
        floatingVisibility.isVisible = true
        let panel = makeOrReuseFloatingPanel()
        isFloatingPanelVisible = true
        updateLevelMeteringVisibility()
        panel.makeKeyAndOrderFront(nil)
    }

    private func dockFloatingPanelToPopover() {
        if let panel = floatingPanel, isFloatingPanelVisible {
            closeFloatingPanel(panel)
        }
        floatingVisibility.isVisible = false
        showPopover(activateApp: true)
    }

    private func closeFloatingPanel(_ panel: NSPanel) {
        if let sheet = panel.attachedSheet {
            panel.endSheet(sheet)
        }
        panel.close()
    }

    private func forceClosePopover() {
        if let popWindow = popover.contentViewController?.view.window,
           let sheet = popWindow.attachedSheet {
            popWindow.endSheet(sheet)
        }
        popover.performClose(nil)
        if popover.isShown {
            popover.close()
        }
    }

    private func isStatusItemVisibleInMenuBar(_ button: NSStatusBarButton) -> Bool {
        guard let buttonWindow = button.window,
              buttonWindow.isVisible,
              button.frame.width > 0,
              button.frame.height > 0 else {
            return false
        }
        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRectInWindow)
        guard screenRect.width >= 8, screenRect.height >= 8 else {
            return false
        }
        guard let screen = buttonWindow.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(screenRect) }) else {
            return false
        }
        guard screen.frame.contains(NSPoint(x: screenRect.midX, y: screenRect.midY)),
              screenRect.minX >= screen.frame.minX - 1,
              screenRect.maxX <= screen.frame.maxX + 1 else {
            return false
        }
        if let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea,
           !leftArea.isEmpty || !rightArea.isEmpty {
            let inLeft = screenRect.minX >= leftArea.minX - 2 && screenRect.maxX <= leftArea.maxX + 2
            let inRight = screenRect.minX >= rightArea.minX - 2 && screenRect.maxX <= rightArea.maxX + 2
            if !inLeft && !inRight {
                return false
            }
        }
        return true
    }

    private func showPopover(activateApp: Bool) {
        guard let button = statusItem?.button,
              isStatusItemVisibleInMenuBar(button) else {
            popOutFloatingPanel()
            return
        }
        if !popover.isShown {
            ensurePopoverHostingController()
            popoverVisibility.isVisible = true
            applyAppearancePreference()
            updatePopoverBehavior()
            applyScreenSharingPrivacy()
            popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if popover.contentSize.width < 360 || popover.contentSize.height < 300 {
                popover.contentSize = NSSize(width: 430, height: 540)
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            applyScreenSharingPrivacy()
            if activateApp {
                NSApp.activate()
            }
        }
    }

    @objc private func closeActiveSurfaceAction() {
        if isFloatingPanelVisible, let panel = floatingPanel {
            closeFloatingPanel(panel)
        } else if popover.isShown {
            forceClosePopover()
        }
    }

    @objc private func togglePauseAction() {
        CaptionCoordinator.shared.togglePauseResume()
    }

    @objc private func toggleConversationalAction() {
        CaptionCoordinator.shared.setConversationalMode(!CaptionCoordinator.shared.isConversationalMode)
    }

    @objc private func toggleShareAction() {
        CaptionCoordinator.shared.toggleSharing()
        if LiveShareManager.shared.isSharing && !isFloatingPanelVisible {
            showPopover(activateApp: true)
        }
    }

    @objc private func handleStateDidChange() {
        updateStatusItemAppearance()
    }

    @objc private func handlePinStateDidChange() {
        updatePopoverBehavior()
    }

    @objc private func handleAppearanceDidChange() {
        applyAppearancePreference()
    }

    @objc private func handleScreenSharingPrivacyDidChange() {
        applyScreenSharingPrivacy()
    }

    @objc private func handleCompactFloatingHUDDidChange() {
        applyFloatingPanelMinSize()
    }

    private func triggerEngineRecoveryIfNeededDebounced() {
        let now = ProcessInfo.processInfo.systemUptime
        if (now - lastEngineRecoveryTriggerUptime) >= 0.3 {
            lastEngineRecoveryTriggerUptime = now
            CaptionCoordinator.shared.recoverEnginesIfNeeded()
        }
        updateStatusItemAppearance()
    }

    @objc private func handleAppActivation() {
        triggerEngineRecoveryIfNeededDebounced()
    }

    @objc private func handleWindowDidBecomeKey(_ notification: Notification) {
        if let panel = floatingPanel, (notification.object as? NSWindow) === panel {
            triggerEngineRecoveryIfNeededDebounced()
        }
    }

    @objc private func handleScreenParametersDidChange() {
        if let panel = floatingPanel {
            clampPanelToVisibleScreens(panel)
        }
    }

    @objc private func handleSystemWillSleep() {
        CaptionCoordinator.shared.autoPauseForSystem(reason: .systemSleep)
    }

    @objc private func handleSystemDidWake() {
        CaptionCoordinator.shared.autoResumeAfterSystem(reason: .systemSleep)
        updateStatusItemAppearance()
    }

    @objc private func handleSessionDidResignActive() {
        CaptionCoordinator.shared.autoPauseForSystem(reason: .sessionResigned)
    }

    @objc private func handleSessionDidBecomeActive() {
        CaptionCoordinator.shared.autoResumeAfterSystem(reason: .sessionResigned)
        updateStatusItemAppearance()
    }

    @objc private func quitApp() {
        LiveShareManager.shared.stopSharingSynchronously()
        NSApp.terminate(nil)
    }
}
