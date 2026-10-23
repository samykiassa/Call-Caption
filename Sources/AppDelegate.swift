import AppKit
import Speech
import os

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    public static var shared: AppDelegate {
        NSApp.delegate as! AppDelegate
    }
    
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    public var statusMenu: NSMenu!
    
    public private(set) var trayViewController: TrayCaptionViewController!
    private var settingsWindowController: SettingsWindowController?
    private var transcriptWindowController: TranscriptWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var legalWindowController: LegalWindowController?
    
    private var autoHideWorkItem: DispatchWorkItem?
    private var lastAutoHideScheduleTime: TimeInterval = 0
    private var lastManualCloseTime: TimeInterval = 0
    public static let manualCloseCooldownSeconds: TimeInterval = 15.0
    
    private var micMenuItem: NSMenuItem?
    private var liveShareMenuItem: NSMenuItem?
    private var stopLiveShareMenuItem: NSMenuItem?
    private var retryTunnelMenuItem: NSMenuItem?
    private var mainLangMenuItem: NSMenuItem?
    private var foreignLangMenuItem: NSMenuItem?
    private var pauseResumeMenuItem: NSMenuItem?
    
    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStandardMainMenu()
        setupStatusItem()
        CaptionCoordinator.shared.delegate = self

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppSettingsChanged),
            name: AppSettings.didChangeNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppActivation),
            name: NSApplication.didBecomeActiveNotification,
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
            selector: #selector(handleLiveShareStateChanged(_:)),
            name: LiveShareManager.stateDidChangeNotification,
            object: nil
        )

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(self, selector: #selector(handleSystemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(handleSystemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(handleSystemWillSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(handleSystemDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(handleSystemWillSleep), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(handleSystemDidWake), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)

        SupportedLanguages.refreshCacheInBackground()

        if !AppSettings.shared.hasCompletedOnboarding {
            openOnboardingWindow { [weak self] in
                self?.showTrayPopoverAction()
            }
        } else {
            startEnginesWithAuthorization()
        }
    }

    private func startEnginesWithAuthorization() {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            SpeechRecognitionManager.requestAuthorization { granted in
                AppLog.app.info("Speech recognition authorization status: \(granted)")
                Task { @MainActor in
                    CaptionCoordinator.shared.start()
                    self.updateStatusItemAppearance()
                }
            }
        } else {
            CaptionCoordinator.shared.start()
            updateStatusItemAppearance()
        }
    }
    
    private func setupStandardMainMenu() {
        let mainMenu = NSMenu()
        
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Call Caption", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsMenuAction), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(NSMenuItem.separator())
        let privacyItem = NSMenuItem(title: "Privacy Policy", action: #selector(openPrivacyMenuAction), keyEquivalent: "")
        privacyItem.target = self
        appMenu.addItem(privacyItem)
        let termsItem = NSMenuItem(title: "Terms of Use", action: #selector(openTermsMenuAction), keyEquivalent: "")
        termsItem.target = self
        appMenu.addItem(termsItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide Call Caption", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit Call Caption", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        let transcriptItem = NSMenuItem(title: "Transcript…", action: #selector(openTranscriptWindow), keyEquivalent: "t")
        transcriptItem.target = self
        windowMenu.addItem(transcriptItem)
        let permItem = NSMenuItem(title: "Permissions…", action: #selector(openPermissions), keyEquivalent: "")
        permItem.target = self
        windowMenu.addItem(permItem)
        let guideItem = NSMenuItem(title: "Setup Guide…", action: #selector(openOnboardingMenuAction), keyEquivalent: "")
        guideItem.target = self
        windowMenu.addItem(guideItem)
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        
        NSApp.mainMenu = mainMenu
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "captions.bubble.fill", accessibilityDescription: "Call Caption") {
                let config = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .regular)
                button.image = image.withSymbolConfiguration(config)
                button.imagePosition = .imageOnly
            } else {
                button.title = "CC"
            }
            button.toolTip = "Call Caption"
            button.setAccessibilityLabel("Call Caption")
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        
        trayViewController = TrayCaptionViewController()
        trayViewController.loadViewIfNeeded()
        
        popover = NSPopover()
        popover.contentViewController = trayViewController
        updatePopoverBehavior()
        popover.appearance = NSAppearance(named: .darkAqua)
        
        setupStatusMenu()
        updateStatusItemAppearance()
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem?.button else { return }
        let isSharing = LiveShareManager.shared.isSharing
        let isPaused = CaptionCoordinator.shared.isPaused || !CaptionCoordinator.shared.hasStarted
        let symbol: String
        let description: String
        if isSharing {
            symbol = "dot.radiowaves.left.and.right"
            description = "Call Caption — Live Link active"
        } else if isPaused {
            symbol = "captions.bubble"
            description = "Call Caption — paused"
        } else {
            symbol = "captions.bubble.fill"
            description = "Call Caption — listening"
        }
        let config = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .regular)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: "captions.bubble.fill", accessibilityDescription: description)
        button.image = image?.withSymbolConfiguration(config)
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    @objc private func handleLiveShareStateChanged(_ notification: Notification) {
        updateStatusItemAppearance()
        updateMenuItemsState()
    }

    @objc private func handleAppSettingsChanged() {
        updatePopoverBehavior()
        updateStatusItemAppearance()
    }

    private func updatePopoverBehavior() {
        guard popover != nil else { return }
        popover.behavior = AppSettings.shared.isPinned ? .applicationDefined : .transient
    }
    
    private func setupStatusMenu() {
        statusMenu = NSMenu()
        statusMenu.delegate = self
        
        let showItem = NSMenuItem(title: "Show Captions", action: #selector(showTrayPopoverAction), keyEquivalent: "c")
        showItem.target = self
        statusMenu.addItem(showItem)

        let startItem = NSMenuItem(title: "Start Listening", action: #selector(ensureListeningAction), keyEquivalent: "")
        startItem.target = self
        statusMenu.addItem(startItem)

        let pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePauseResumeAction), keyEquivalent: "p")
        pauseItem.target = self
        statusMenu.addItem(pauseItem)
        self.pauseResumeMenuItem = pauseItem
        
        statusMenu.addItem(NSMenuItem.separator())
        
        let micItem = NSMenuItem(title: "Microphone", action: #selector(toggleMicAction), keyEquivalent: "m")
        micItem.target = self
        micItem.state = AppSettings.shared.isMicEnabled ? .on : .off
        statusMenu.addItem(micItem)
        self.micMenuItem = micItem
        
        let liveItem = NSMenuItem(title: "Share Live Link…", action: #selector(shareLiveCaptionsLinkAction), keyEquivalent: "l")
        liveItem.target = self
        statusMenu.addItem(liveItem)
        self.liveShareMenuItem = liveItem

        let stopLiveItem = NSMenuItem(title: "Stop Live Link", action: #selector(stopLiveCaptionsLinkAction), keyEquivalent: "")
        stopLiveItem.target = self
        statusMenu.addItem(stopLiveItem)
        self.stopLiveShareMenuItem = stopLiveItem

        let retryTunnelItem = NSMenuItem(title: "Retry Public Tunnel", action: #selector(retryLiveTunnelAction), keyEquivalent: "")
        retryTunnelItem.target = self
        statusMenu.addItem(retryTunnelItem)
        self.retryTunnelMenuItem = retryTunnelItem

        statusMenu.addItem(NSMenuItem.separator())
        
        let foreignItem = NSMenuItem(title: "Caller: 🇪🇸 Spanish", action: #selector(openSettingsMenuAction), keyEquivalent: "")
        foreignItem.target = self
        statusMenu.addItem(foreignItem)
        self.foreignLangMenuItem = foreignItem
        
        let mainItem = NSMenuItem(title: "You: 🇬🇧 English", action: #selector(openSettingsMenuAction), keyEquivalent: "")
        mainItem.target = self
        statusMenu.addItem(mainItem)
        self.mainLangMenuItem = mainItem
        
        let swapItem = NSMenuItem(title: "Swap Languages", action: #selector(swapLanguagesMenuAction), keyEquivalent: "s")
        swapItem.target = self
        statusMenu.addItem(swapItem)
        
        statusMenu.addItem(NSMenuItem.separator())
        
        let transcriptItem = NSMenuItem(title: "Transcript…", action: #selector(openTranscriptWindow), keyEquivalent: "t")
        transcriptItem.target = self
        statusMenu.addItem(transcriptItem)
        
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsMenuAction), keyEquivalent: ",")
        settingsItem.target = self
        statusMenu.addItem(settingsItem)
        
        let permissionsItem = NSMenuItem(title: "Permissions…", action: #selector(openPermissions), keyEquivalent: "")
        permissionsItem.target = self
        statusMenu.addItem(permissionsItem)
        
        statusMenu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit Call Caption", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }
    
    public func menuWillOpen(_ menu: NSMenu) {
        updateMenuItemsState()
    }
    
    public func menuNeedsUpdate(_ menu: NSMenu) {
        updateMenuItemsState()
    }
    
    private func updateMenuItemsState() {
        updatePauseResumeMenuItem()
        
        micMenuItem?.state = AppSettings.shared.isMicEnabled ? .on : .off
        liveShareMenuItem?.title = LiveShareManager.shared.isSharing
            ? "Show Live Link"
            : "Share Live Link…"
        stopLiveShareMenuItem?.isEnabled = LiveShareManager.shared.isSharing
        retryTunnelMenuItem?.isEnabled = LiveShareManager.shared.isSharing
            && AppSettings.shared.liveShareUseExternalTunnel
            && LiveShareManager.shared.publicShareURL == nil
        
        let main = AppSettings.shared.mainLanguageItem
        let foreign = AppSettings.shared.foreignLanguageItem
        foreignLangMenuItem?.title = "Caller: \(foreign.flag) \(foreign.name)"
        mainLangMenuItem?.title = "You: \(main.flag) \(main.name)"
    }
    
    private func updatePauseResumeMenuItem() {
        let isPaused = CaptionCoordinator.shared.isPaused
        pauseResumeMenuItem?.title = isPaused ? "Resume" : "Pause"
        if let icon = NSImage(systemSymbolName: isPaused ? "play.fill" : "pause.fill", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            pauseResumeMenuItem?.image = icon.withSymbolConfiguration(config)
        }
    }
    
    @objc public func togglePauseResumeAction() {
        CaptionCoordinator.shared.togglePauseResume()
    }
    
    @objc private func swapLanguagesMenuAction() {
        clearSystemAlertBanner()
        AppSettings.shared.swapLanguages()
    }
    
    @objc public func toggleMicAction() {
        if AppSettings.shared.isMicEnabled {
            AppSettings.shared.isMicEnabled = false
            updateMenuItemsState()
        } else {
            if PermissionHelper.shared.hasMicrophoneAccess {
                AppSettings.shared.isMicEnabled = true
                updateMenuItemsState()
            } else {
                PermissionHelper.shared.requestMicrophoneAccess { [weak self] granted in
                    if granted {
                        AppSettings.shared.isMicEnabled = true
                        self?.clearSystemAlertBanner()
                    } else {
                        AppSettings.shared.isMicEnabled = false
                        self?.showSystemAlertBanner(
                            message: "Microphone access required",
                            actionType: .permissions
                        )
                    }
                    self?.updateMenuItemsState()
                }
            }
        }
    }
    
    @objc public func shareLiveCaptionsLinkAction() {
        if LiveShareManager.shared.isSharing {
            showTrayPopoverAction()
            trayViewController?.showLiveShareBanner()
        } else {
            confirmAndStartLiveShare()
        }
    }

    @objc public func stopLiveCaptionsLinkAction() {
        LiveShareManager.shared.stopSharing()
        trayViewController?.hideLiveShareBanner()
        updateMenuItemsState()
    }

    @objc public func retryLiveTunnelAction() {
        LiveShareManager.shared.retryTunnel()
        showTrayPopoverAction()
        trayViewController?.showLiveShareBanner()
    }

    public func confirmAndStartLiveShare() {
        let externalTunnel = AppSettings.shared.liveShareUseExternalTunnel
        if externalTunnel {
            guard requestExternalLiveShareConsentIfNeeded() else { return }
        } else if !AppSettings.shared.hasAcceptedLiveShareConsent {
            let alert = NSAlert()
            alert.messageText = "Start Local Live Link?"
            alert.informativeText = "Local-only mode keeps captions on this Mac or your local network. No external tunnel is opened.\n\nEnsure all call participants have consented to caption sharing where required by law."
            alert.alertStyle = .informational
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't ask again"
            alert.addButton(withTitle: L10n.tr("liveshare.consent.confirm", "Start Live Link"))
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }
            if alert.suppressionButton?.state == .on {
                AppSettings.shared.hasAcceptedLiveShareConsent = true
            }
        }

        CaptionCoordinator.shared.prepareForLiveShareStart()
        LiveShareManager.shared.startSharing()
        LiveShareManager.shared.broadcastPauseState(CaptionCoordinator.shared.isPaused)
        showTrayPopoverAction()
        trayViewController?.showLiveShareBanner()
    }

    public func requestExternalLiveShareConsentIfNeeded() -> Bool {
        if AppSettings.shared.hasAcceptedExternalLiveShareConsent { return true }
        let alert = NSAlert()
        alert.messageText = L10n.tr("liveshare.consent.title", "Start External Live Link?")
        alert.informativeText = L10n.tr(
            "liveshare.consent.message",
            "Live Link streams captions through a public tunnel (localhost.run) to anyone with your link. Captions are encrypted end-to-end.\n\nMake sure call participants consent to caption sharing where required."
        )
        alert.alertStyle = .informational
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        alert.addButton(withTitle: L10n.tr("liveshare.consent.confirm", "Start Live Link"))
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return false }
        if alert.suppressionButton?.state == .on {
            AppSettings.shared.hasAcceptedExternalLiveShareConsent = true
        }
        return true
    }

    
    @objc public func togglePopover(_ sender: AnyObject?) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            updateMenuItemsState()
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            if popover.isShown {
                lastManualCloseTime = ProcessInfo.processInfo.systemUptime
                popover.performClose(sender)
            } else if let button = statusItem.button {
                updatePopoverBehavior()
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }
    
    @objc public func showTrayPopoverAction() {
        if let button = statusItem.button, !popover.isShown {
            updatePopoverBehavior()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
    
    public func closeTrayPopover() {
        if popover.isShown {
            lastManualCloseTime = ProcessInfo.processInfo.systemUptime
            popover.performClose(nil)
        }
    }

    public static func shouldAutoOpenPopover(
        isPopoverShown: Bool,
        autoPopupSetting: Bool,
        speaker: String,
        nowUptime: TimeInterval,
        lastManualCloseUptime: TimeInterval
    ) -> Bool {
        guard !isPopoverShown, autoPopupSetting else { return false }
        guard speaker.lowercased() == "caller" else { return false }
        if lastManualCloseUptime > 0 && (nowUptime - lastManualCloseUptime) < manualCloseCooldownSeconds {
            return false
        }
        return true
    }
    
    
    private var lastAlertShownMessage: String?
    
    public func showSystemAlertBanner(message: String, actionType: SystemAlertActionType) {
        trayViewController?.showAlertBanner(message: message, actionType: actionType)
        if lastAlertShownMessage != message {
            lastAlertShownMessage = message
            if let button = statusItem?.button, let pop = popover, !pop.isShown {
                updatePopoverBehavior()
                pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }
    
    public func clearSystemAlertBanner() {
        lastAlertShownMessage = nil
        trayViewController?.clearAlertBanner()
    }
    
    
    public func handleSpeechReceived(
        utteranceID: UUID,
        speaker: String,
        original: String,
        translated: String,
        sourceLangCode: String,
        targetLangCode: String,
        isFinal: Bool,
        isUntranslated: Bool = false
    ) {
        trayViewController.updateCaption(
            utteranceID: utteranceID,
            speaker: speaker,
            translated: translated,
            original: original,
            sourceLangCode: sourceLangCode,
            targetLangCode: targetLangCode,
            isFinal: isFinal,
            isUntranslated: isUntranslated
        )
        
        let now = ProcessInfo.processInfo.systemUptime
        if Self.shouldAutoOpenPopover(
            isPopoverShown: popover.isShown,
            autoPopupSetting: AppSettings.shared.autoPopupOnForeignSpeech,
            speaker: speaker,
            nowUptime: now,
            lastManualCloseUptime: lastManualCloseTime
        ), let button = statusItem.button {
            updatePopoverBehavior()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        
        guard isFinal || (now - lastAutoHideScheduleTime) >= 0.5 else { return }
        lastAutoHideScheduleTime = now
        
        autoHideWorkItem?.cancel()
        let delay = AppSettings.shared.autoHideDelay
        if delay > 0 {
            let item = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                if !AppSettings.shared.isPinned && self.popover.isShown {
                    self.popover.performClose(nil)
                }
            }
            autoHideWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }
    

    @objc private func handleAppActivation(_ notification: Notification) {
        CaptionCoordinator.shared.recoverEnginesIfNeeded()
    }

    @objc private func handleSystemWillSleep(_ notification: Notification) {
        guard AppSettings.shared.pauseOnScreenLock else { return }
        CaptionCoordinator.shared.autoPauseForSystem()
    }

    @objc private func handleSystemDidWake(_ notification: Notification) {
        CaptionCoordinator.shared.autoResumeAfterSystem()
        CaptionCoordinator.shared.recoverEnginesIfNeeded()
    }

    @objc private func handlePauseStateChanged(_ notification: Notification) {
        LiveShareManager.shared.broadcastPauseState(CaptionCoordinator.shared.isPaused)
        updateStatusItemAppearance()
        updateMenuItemsState()
    }

    @objc public func ensureListeningAction() {
        guard AppSettings.shared.hasCompletedOnboarding else {
            openOnboardingWindow()
            return
        }
        if !CaptionCoordinator.shared.hasStarted {
            startEnginesWithAuthorization()
        } else if CaptionCoordinator.shared.isPaused {
            CaptionCoordinator.shared.resume()
        } else {
            CaptionCoordinator.shared.recoverEnginesIfNeeded()
        }
        showTrayPopoverAction()
    }

    
    @objc private func openSettingsMenuAction() {
        openSettingsWindow(selectedTab: nil)
    }

    @objc private func openOnboardingMenuAction() {
        openOnboardingWindow()
    }

    public func openOnboardingWindow(onComplete: (() -> Void)? = nil) {
        closeTrayPopover()
        onboardingWindowController = OnboardingWindowController(
            onComplete: { [weak self] in
                if let self = self, !CaptionCoordinator.shared.hasStarted {
                    self.startEnginesWithAuthorization()
                }
                onComplete?()
                self?.onboardingWindowController = nil
            },
            onClose: { [weak self] in
                self?.onboardingWindowController = nil
            }
        )
        onboardingWindowController?.refreshState()
        onboardingWindowController?.showWindow(nil)
        onboardingWindowController?.window?.makeKeyAndOrderFront(nil)
        onboardingWindowController?.window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func openPrivacyMenuAction() {
        openLegalDocument(.privacy)
    }

    @objc private func openTermsMenuAction() {
        openLegalDocument(.terms)
    }

    public func openLegalDocument(_ document: LegalDocument) {
        if legalWindowController == nil {
            legalWindowController = LegalWindowController(document: document)
        } else {
            legalWindowController?.select(document: document)
        }
        legalWindowController?.showWindow(nil)
        legalWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func openSettingsWindow(selectedTab: Int? = nil) {
        closeTrayPopover()
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.refreshSettingsValues()
        if let tab = selectedTab {
            settingsWindowController?.selectTab(tab)
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.level = .normal
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        settingsWindowController?.window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc public func openTranscriptWindow() {
        closeTrayPopover()
        if transcriptWindowController == nil {
            transcriptWindowController = TranscriptWindowController()
        }
        transcriptWindowController?.showWindow(nil)
        transcriptWindowController?.window?.level = .normal
        transcriptWindowController?.window?.makeKeyAndOrderFront(nil)
        transcriptWindowController?.window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc public func openPermissions() {
        openSettingsWindow(selectedTab: 2)
    }
    
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
    
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showTrayPopoverAction()
        return true
    }
    
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
    
    public func applicationWillTerminate(_ notification: Notification) {
        LiveShareManager.shared.stopSharingSynchronously()
        CaptionCoordinator.shared.stop()
        TranscriptManager.shared.flushPersistence()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }
}


extension AppDelegate: CaptionCoordinatorDelegate {
    public func coordinatorDidRequestShowAlert(message: String, actionType: SystemAlertActionType) {
        showSystemAlertBanner(message: message, actionType: actionType)
    }
    
    public func coordinatorDidRequestClearAlert() {
        clearSystemAlertBanner()
    }
    
    public func coordinatorDidReceiveSpeech(
        utteranceID: UUID,
        speaker: String,
        original: String,
        translated: String,
        sourceLangCode: String,
        targetLangCode: String,
        isFinal: Bool,
        isUntranslated: Bool
    ) {
        handleSpeechReceived(
            utteranceID: utteranceID,
            speaker: speaker,
            original: original,
            translated: translated,
            sourceLangCode: sourceLangCode,
            targetLangCode: targetLangCode,
            isFinal: isFinal,
            isUntranslated: isUntranslated
        )
    }
    
    public func coordinatorDidUpdateAudioLevels(callerLevel: Float, micLevel: Float) {
        trayViewController?.updateAudioLevels(callerLevel: callerLevel, micLevel: micLevel)
    }
}
