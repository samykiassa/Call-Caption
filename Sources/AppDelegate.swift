import AppKit
import Speech
import SwiftUI
import os

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var statusMenu: NSMenu!

    private var togglePopoverMenuItem: NSMenuItem?
    private var pauseResumeMenuItem: NSMenuItem?
    private var conversationalMenuItem: NSMenuItem?
    private var shareMenuItem: NSMenuItem?
    private var lastAlertShown: String?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()
        setupStatusItem()
        setupObservers()

        let auth = SFSpeechRecognizer.authorizationStatus()
        if auth == .notDetermined {
            SpeechRecognitionManager.requestAuthorization { _ in
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

    public func applicationWillTerminate(_ notification: Notification) {
        CaptionCoordinator.shared.stop()
        LiveShareManager.shared.stopSharingSynchronously()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return false
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit Call Caption", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.toolTip = "Call Caption"
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let hosting = NSHostingController(
            rootView: CaptionPopoverView(
                viewModel: CaptionCoordinator.shared.viewModel,
                onQuit: { [weak self] in self?.quitApp() }
            )
        )
        popover = NSPopover()
        popover.delegate = self
        popover.contentViewController = hosting
        popover.appearance = NSAppearance(named: .darkAqua)
        updatePopoverBehavior()

        setupStatusMenu()
        updateStatusItemAppearance()
    }

    private func setupStatusMenu() {
        statusMenu = NSMenu()
        statusMenu.delegate = self

        let showItem = NSMenuItem(title: "Show Captions", action: #selector(togglePopoverAction), keyEquivalent: "")
        showItem.target = self
        statusMenu.addItem(showItem)
        togglePopoverMenuItem = showItem

        let pauseItem = NSMenuItem(title: "Pause Captions", action: #selector(togglePauseAction), keyEquivalent: "")
        pauseItem.target = self
        statusMenu.addItem(pauseItem)
        pauseResumeMenuItem = pauseItem

        let convItem = NSMenuItem(title: "Conversational Mode", action: #selector(toggleConversationalAction), keyEquivalent: "")
        convItem.target = self
        statusMenu.addItem(convItem)
        conversationalMenuItem = convItem

        let shareItem = NSMenuItem(title: "Share Live Link", action: #selector(toggleShareAction), keyEquivalent: "")
        shareItem.target = self
        statusMenu.addItem(shareItem)
        shareMenuItem = shareItem

        statusMenu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Call Caption", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }

    private func setupObservers() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleStateDidChange), name: CaptionCoordinator.pauseStateDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(handlePinStateDidChange), name: CaptionCoordinator.pinStateDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(handleStateDidChange), name: LiveShareManager.stateDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(handleAppActivation), name: NSApplication.didBecomeActiveNotification, object: nil)

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(handleSystemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(handleSystemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(handleSystemWillSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(handleSystemDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(handleSystemWillSleep), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(handleSystemDidWake), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    }

    private func updatePopoverBehavior() {
        popover?.behavior = CaptionCoordinator.shared.isPinned ? .applicationDefined : .transient
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem?.button else { return }
        let isSharing = LiveShareManager.shared.isSharing
        let isPaused = CaptionCoordinator.shared.isPaused

        let symbol: String
        let description: String
        if isSharing {
            symbol = "dot.radiowaves.left.and.right"
            description = "Call Caption — Live Link active"
        } else if isPaused {
            symbol = "captions.bubble"
            description = "Call Caption — Paused"
        } else {
            symbol = "captions.bubble.fill"
            description = "Call Caption — Listening"
        }

        let cfg = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .regular)
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: "captions.bubble.fill", accessibilityDescription: description)
        button.image = img?.withSymbolConfiguration(cfg)
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        togglePopoverMenuItem?.title = popover.isShown ? "Hide Captions" : "Show Captions"
        pauseResumeMenuItem?.title = CaptionCoordinator.shared.isPaused ? "Resume Captions" : "Pause Captions"
        conversationalMenuItem?.state = CaptionCoordinator.shared.isConversationalMode ? .on : .off
        shareMenuItem?.title = LiveShareManager.shared.isSharing ? "Stop Sharing Link" : "Share Live Link"
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        togglePopoverAction()
    }

    @objc private func togglePopoverAction() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        if !popover.isShown {
            updatePopoverBehavior()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
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
        if LiveShareManager.shared.isSharing {
            showPopover()
        }
    }

    @objc private func handleStateDidChange() {
        updateStatusItemAppearance()
        if let msg = CaptionCoordinator.shared.viewModel.alertMessage, msg != lastAlertShown {
            lastAlertShown = msg
            showPopover()
        }
    }

    @objc private func handlePinStateDidChange() {
        updatePopoverBehavior()
    }

    @objc private func handleAppActivation() {
        CaptionCoordinator.shared.recoverEnginesIfNeeded()
    }

    @objc private func handleSystemWillSleep() {
        CaptionCoordinator.shared.autoPauseForSystem()
    }

    @objc private func handleSystemDidWake() {
        CaptionCoordinator.shared.autoResumeAfterSystem()
    }

    @objc private func quitApp() {
        CaptionCoordinator.shared.stop()
        LiveShareManager.shared.stopSharingSynchronously()
        NSApp.terminate(nil)
    }
}
