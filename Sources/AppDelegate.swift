import AppKit

/// The application delegate responsible for managing the primary lifecycle and UI components.
///
/// `AppDelegate` oversees the status bar menu, the heads-up display (HUD) caption window,
/// system permissions requests, and cleanly tearing down background services upon exit.
public class AppDelegate: NSObject, NSApplicationDelegate {
    private var hudWindow: HUDCaptionWindow!
    private var hudViewController: HUDCaptionViewController!
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    public var statusMenu: NSMenu!
    
    /// Called when the application finishes launching. Sets up the main window, status item, and requests permissions.
    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Configure app to run as an accessory or regular app
        NSApp.setActivationPolicy(.regular)
        
        // Setup HUD Window
        hudWindow = HUDCaptionWindow()
        hudViewController = HUDCaptionViewController()
        hudWindow.contentViewController = hudViewController
        hudWindow.makeKeyAndOrderFront(nil)
        
        // Setup Status Bar Menu Item
        setupStatusItem()
        
        // Request speech permissions early
        SpeechRecognitionManager.requestAuthorization { granted in
            NSLog("[App] Speech recognition authorized: \(granted)")
        }
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "captions.bubble.fill", accessibilityDescription: "CallCaption Live Captions") {
                let config = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .regular)
                button.image = image.withSymbolConfiguration(config)
                button.imagePosition = .imageOnly
            } else {
                button.title = "CC"
            }
            button.toolTip = "CallCaption — Live Captions & Translation"
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        
        popover = NSPopover()
        popover.contentViewController = SpanMenuViewController()
        popover.behavior = .transient
        
        statusMenu = NSMenu()
        
        let showItem = NSMenuItem(title: "Show Captions", action: #selector(showHUD), keyEquivalent: "h")
        showItem.target = self
        statusMenu.addItem(showItem)
        
        let compactItem = NSMenuItem(title: "Compact Mode", action: #selector(toggleCompactMode), keyEquivalent: "m")
        compactItem.target = self
        statusMenu.addItem(compactItem)
        
        let toggleItem = NSMenuItem(title: "Pause Captions", action: #selector(toggleHUDCapture), keyEquivalent: "p")
        toggleItem.target = self
        statusMenu.addItem(toggleItem)
        
        let swapItem = NSMenuItem(title: "Swap Languages", action: #selector(swapLanguages), keyEquivalent: "")
        swapItem.target = self
        statusMenu.addItem(swapItem)
        
        statusMenu.addItem(NSMenuItem.separator())
        
        let shareItem = NSMenuItem(title: "Share Captions...", action: #selector(openShareWindow), keyEquivalent: "s")
        shareItem.target = self
        statusMenu.addItem(shareItem)
        
        let copyLinkItem = NSMenuItem(title: "Copy Web Link", action: #selector(copyPhoneLink), keyEquivalent: "")
        copyLinkItem.target = self
        statusMenu.addItem(copyLinkItem)
        
        let transcriptItem = NSMenuItem(title: "Transcript History...", action: #selector(openTranscriptWindow), keyEquivalent: "t")
        transcriptItem.target = self
        statusMenu.addItem(transcriptItem)
        
        statusMenu.addItem(NSMenuItem.separator())
        
        let permissionsItem = NSMenuItem(title: "Audio & Speech Settings...", action: #selector(openPermissions), keyEquivalent: ",")
        permissionsItem.target = self
        statusMenu.addItem(permissionsItem)
        
        statusMenu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit CallCaption", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }
    
    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            if popover.isShown {
                popover.performClose(sender)
            } else {
                if let button = statusItem.button {
                    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                }
            }
        }
    }
    
    /// Displays and focuses the main caption HUD window.
    @objc public func showHUD() {
        hudWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func toggleCompactMode() {
        showHUD()
        hudViewController.toggleCompactMode()
    }
    
    @objc private func toggleHUDCapture() {
        hudViewController.togglePlayPause()
    }
    
    @objc private func swapLanguages() {
        hudViewController.swapLanguagesAction()
    }
    
    @objc private func openShareWindow() {
        showHUD()
        hudViewController.openShare()
    }
    
    @objc private func copyPhoneLink() {
        hudViewController.copyPhoneLinkAction()
    }
    
    @objc private func openTranscriptWindow() {
        showHUD()
        hudViewController.openTranscript()
    }
    
    /// Opens the application's permission setup window, typically embedded within the HUD.
    @objc public func openPermissions() {
        hudViewController.openPermissions()
    }
    
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
    
    /// Handles reopening the application (e.g., clicking the dock icon).
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showHUD()
        return true
    }
    
    /// Determines whether the application should terminate when its last window is closed.
    /// - Returns: `false` to keep the application running in the menu bar.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false // Keep running in menu bar even if window closed
    }
    
    /// Called before the application terminates. Responsible for stopping web and tunnel background services.
    public func applicationWillTerminate(_ notification: Notification) {
        WebCaptionServer.shared.stop()
        TunnelManager.shared.stop()
    }
}
