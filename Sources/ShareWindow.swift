import AppKit

public class ShareWindowController: NSWindowController, TunnelManagerDelegate {
    
    private var qrImageView: NSImageView!
    private var publicUrlField: NSTextField!
    private var localUrlField: NSTextField!
    private var tunnelStatusLabel: NSTextField!
    
    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 320, y: 200, width: 500, height: 490),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Share Live Subtitles (iOS & Android)"
        window.level = .floating
        window.isReleasedWhenClosed = false
        super.init(window: window)
        
        TunnelManager.shared.delegate = self
        NotificationCenter.default.addObserver(
            forName: TunnelManager.tunnelURLNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateFields()
        }
        setupUI()
    }
    
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        guard let window = self.window else { return }
        
        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.wantsLayer = true
        
        let titleLabel = NSTextField(labelWithString: "📱 Live Subtitles for Caller (iOS & Android)")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        titleLabel.frame = NSRect(x: 24, y: contentView.bounds.height - 38, width: 452, height: 24)
        contentView.addSubview(titleLabel)
        
        let subtitleLabel = NSTextField(labelWithString: "The caller can view live translated subtitles on their iPhone or Android browser without installing any app!")
        subtitleLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.frame = NSRect(x: 24, y: contentView.bounds.height - 68, width: 452, height: 28)
        subtitleLabel.maximumNumberOfLines = 2
        contentView.addSubview(subtitleLabel)
        
        // QR Code Display
        qrImageView = NSImageView(frame: NSRect(x: (contentView.bounds.width - 150) / 2.0, y: contentView.bounds.height - 228, width: 150, height: 150))
        qrImageView.imageScaling = .scaleProportionallyUpOrDown
        contentView.addSubview(qrImageView)
        
        // ------------------------------------------------------------------
        // Link 1: Public HTTPS Link (Recommended - works anywhere on 4G/5G)
        // ------------------------------------------------------------------
        let pubHeader = NSTextField(labelWithString: "🌐 Public Link (Recommended • Works on 4G/5G/Any Wi-Fi):")
        pubHeader.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        pubHeader.textColor = NSColor.systemGreen
        pubHeader.frame = NSRect(x: 24, y: contentView.bounds.height - 254, width: 452, height: 18)
        contentView.addSubview(pubHeader)
        
        publicUrlField = NSTextField(string: "Starting public HTTPS tunnel...")
        publicUrlField.isEditable = false
        publicUrlField.alignment = .left
        publicUrlField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        publicUrlField.textColor = NSColor.systemTeal
        publicUrlField.frame = NSRect(x: 24, y: contentView.bounds.height - 282, width: 366, height: 24)
        publicUrlField.backgroundColor = NSColor.black.withAlphaComponent(0.2)
        publicUrlField.isBezeled = true
        publicUrlField.bezelStyle = .roundedBezel
        contentView.addSubview(publicUrlField)
        
        let copyPubBtn = NSButton(title: "Copy", target: self, action: #selector(copyPublicLinkAction))
        copyPubBtn.frame = NSRect(x: 396, y: contentView.bounds.height - 282, width: 80, height: 24)
        copyPubBtn.bezelStyle = .texturedRounded
        copyPubBtn.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        contentView.addSubview(copyPubBtn)
        
        tunnelStatusLabel = NSTextField(labelWithString: "Connecting to secure tunnel...")
        tunnelStatusLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        tunnelStatusLabel.textColor = .secondaryLabelColor
        tunnelStatusLabel.frame = NSRect(x: 24, y: contentView.bounds.height - 302, width: 452, height: 16)
        contentView.addSubview(tunnelStatusLabel)
        
        // ------------------------------------------------------------------
        // Link 2: Local Wi-Fi Link
        // ------------------------------------------------------------------
        let localHeader = NSTextField(labelWithString: "🏠 Local Wi-Fi Link (If caller phone is on same Wi-Fi router):")
        localHeader.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        localHeader.textColor = .secondaryLabelColor
        localHeader.frame = NSRect(x: 24, y: contentView.bounds.height - 326, width: 452, height: 16)
        contentView.addSubview(localHeader)
        
        localUrlField = NSTextField(string: "")
        localUrlField.isEditable = false
        localUrlField.alignment = .left
        localUrlField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        localUrlField.frame = NSRect(x: 24, y: contentView.bounds.height - 352, width: 366, height: 24)
        localUrlField.backgroundColor = NSColor.black.withAlphaComponent(0.15)
        localUrlField.isBezeled = true
        localUrlField.bezelStyle = .roundedBezel
        contentView.addSubview(localUrlField)
        
        let copyLocalBtn = NSButton(title: "Copy", target: self, action: #selector(copyLocalLinkAction))
        copyLocalBtn.frame = NSRect(x: 396, y: contentView.bounds.height - 352, width: 80, height: 24)
        copyLocalBtn.bezelStyle = .texturedRounded
        copyLocalBtn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        contentView.addSubview(copyLocalBtn)
        
        // ------------------------------------------------------------------
        // Action Buttons: Copy Invite & Test in Browser
        // ------------------------------------------------------------------
        let copyInviteBtn = NSButton(title: "📋 Copy Subtitle Invitation", target: self, action: #selector(copyFullInviteAction))
        copyInviteBtn.frame = NSRect(x: 24, y: contentView.bounds.height - 396, width: 280, height: 34)
        copyInviteBtn.bezelStyle = .rounded
        copyInviteBtn.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        contentView.addSubview(copyInviteBtn)
        
        let testBtn = NSButton(title: "🌐 Test in Browser", target: self, action: #selector(openBrowserAction))
        testBtn.frame = NSRect(x: 312, y: contentView.bounds.height - 396, width: 164, height: 34)
        testBtn.bezelStyle = .rounded
        testBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        contentView.addSubview(testBtn)
        
        // Instructions Box
        let box = NSBox(frame: NSRect(x: 24, y: 12, width: 452, height: 76))
        box.title = "Features"
        box.titleFont = NSFont.systemFont(ofSize: 10, weight: .bold)
        
        let instructions = NSTextField(labelWithString: "• Works on Cellular 4G/5G and Wi-Fi worldwide via HTTPS.\n• Tap '📌 Float Subtitles' for a floating picture-in-picture window over video calls.\n• Streamed with real-time bidirectional translation and zero latency.")
        instructions.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        instructions.frame = NSRect(x: 10, y: 4, width: 432, height: 50)
        instructions.maximumNumberOfLines = 3
        box.contentView?.addSubview(instructions)
        contentView.addSubview(box)
        
        window.contentView = contentView
        
        updateFields()
    }
    
    public func updateFields() {
        let localShare = WebCaptionServer.shared.getLocalURL() ?? "http://localhost:8765"
        localUrlField?.stringValue = localShare
        
        var pubShare = ""
        if let pub = TunnelManager.shared.publicURL, !pub.isEmpty {
            pubShare = pub
            publicUrlField?.stringValue = pubShare
            tunnelStatusLabel?.stringValue = "✅ Public HTTPS Tunnel Active • Accessible on any network"
            tunnelStatusLabel?.textColor = NSColor.systemGreen
        } else {
            publicUrlField?.stringValue = "Connecting to tunnel... (Or use local Wi-Fi link)"
            tunnelStatusLabel?.stringValue = "⏳ Tunnel connecting in background..."
            tunnelStatusLabel?.textColor = NSColor.systemOrange
        }
        
        // Generate QR code for the preferred URL (Public if available, otherwise local)
        let qrTarget = pubShare.isEmpty ? localShare : pubShare
        if let qrImage = WebCaptionServer.shared.generateQRCodeImage(from: qrTarget) {
            qrImageView?.image = qrImage
        }
    }
    
    // TunnelManagerDelegate
    public func tunnelDidUpdateURL(_ url: String) {
        updateFields()
    }
    
    public func tunnelDidFail(error: String) {
        tunnelStatusLabel?.stringValue = "⚠️ Tunnel not available. Use the Local Wi-Fi link."
        tunnelStatusLabel?.textColor = NSColor.systemOrange
    }
    
    @objc private func copyPublicLinkAction() {
        let link = publicUrlField.stringValue
        guard !link.isEmpty && !link.contains("Connecting") else {
            copyLocalLinkAction()
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(link, forType: .string)
        showAlert(title: "Link Copied!", message: "Public HTTPS subtitle link copied to clipboard. Send it to the caller!")
    }
    
    @objc private func copyLocalLinkAction() {
        let link = localUrlField.stringValue
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(link, forType: .string)
        showAlert(title: "Local Link Copied!", message: "Local Wi-Fi subtitle link copied to clipboard. (Caller must be on the same Wi-Fi).")
    }
    
    @objc private func copyFullInviteAction() {
        let activeURL = (TunnelManager.shared.publicURL != nil) ? publicUrlField.stringValue : localUrlField.stringValue
        let hostLang = WebCaptionServer.shared.hostLangName
        let callerLang = WebCaptionServer.shared.callerLangName
        
        let msg = "📱 Live Translated Subtitles (\(callerLang) ⇄ \(hostLang))\n\nOpen this link on your phone (Safari or Chrome):\n\(activeURL)\n\nTap '📌 Float Subtitles' for a floating caption window during our call!"
        
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(msg, forType: .string)
        
        showAlert(title: "Invitation Copied!", message: "Subtitle invitation copied to clipboard. Paste it into your chat with the caller!")
    }
    
    @objc private func openBrowserAction() {
        let target = (TunnelManager.shared.publicURL != nil) ? publicUrlField.stringValue : localUrlField.stringValue
        if let url = URL(string: target) {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }
}
