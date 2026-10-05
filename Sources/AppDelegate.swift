import AppKit

public class AppDelegate: NSObject, NSApplicationDelegate {
    private var hudWindow: HUDCaptionWindow!
    private var hudViewController: HUDCaptionViewController!
    private var statusItem: NSStatusItem!
    
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
            button.title = "💬 CC"
            button.toolTip = "Live Call Captions & Translation"
        }
        
        let menu = NSMenu()
        
        let showItem = NSMenuItem(title: "Show Captions HUD", action: #selector(showHUD), keyEquivalent: "h")
        showItem.target = self
        menu.addItem(showItem)
        
        let compactItem = NSMenuItem(title: "Toggle Compact Subtitle Banner", action: #selector(toggleCompactMode), keyEquivalent: "m")
        compactItem.target = self
        menu.addItem(compactItem)
        
        let toggleItem = NSMenuItem(title: "Pause / Resume Captions", action: #selector(toggleHUDCapture), keyEquivalent: "p")
        toggleItem.target = self
        menu.addItem(toggleItem)
        
        let swapItem = NSMenuItem(title: "Swap Languages (You ⇄ Caller)", action: #selector(swapLanguages), keyEquivalent: "")
        swapItem.target = self
        menu.addItem(swapItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let shareItem = NSMenuItem(title: "📱 Share Subtitles with Phone (QR)...", action: #selector(openShareWindow), keyEquivalent: "s")
        shareItem.target = self
        menu.addItem(shareItem)
        
        let copyLinkItem = NSMenuItem(title: "📋 Copy Phone Subtitles Link", action: #selector(copyPhoneLink), keyEquivalent: "")
        copyLinkItem.target = self
        menu.addItem(copyLinkItem)
        
        let transcriptItem = NSMenuItem(title: "📄 View Call Transcript Log...", action: #selector(openTranscriptWindow), keyEquivalent: "t")
        transcriptItem.target = self
        menu.addItem(transcriptItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let permissionsItem = NSMenuItem(title: "⚙️ System Permissions & Setup...", action: #selector(openPermissions), keyEquivalent: ",")
        permissionsItem.target = self
        menu.addItem(permissionsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit CallCaption", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }
    
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
    
    @objc public func openPermissions() {
        hudViewController.openPermissions()
    }
    
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
    
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showHUD()
        return true
    }
    
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false // Keep running in menu bar even if window closed
    }
    
    public func applicationWillTerminate(_ notification: Notification) {
        WebCaptionServer.shared.stop()
        TunnelManager.shared.stop()
    }
}
