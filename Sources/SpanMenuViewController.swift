import AppKit

public class SpanMenuViewController: NSViewController {
    private var transcriptLabel: NSTextField!
    private var visualizer: AudioVisualizerView!
    private var settingsBtn: NSButton!
    
    // Golden Hour Colors
    private let orangeAccent = NSColor(red: 0.98, green: 0.38, blue: 0.08, alpha: 1.0)
    
    public override func loadView() {
        let container = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 320, height: 214))
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true
        
        // --- Header Bar (Height: 34, y: 172 to 206) ---
        let headerView = NSView(frame: NSRect(x: 14, y: 174, width: 292, height: 32))
        headerView.wantsLayer = true
        container.addSubview(headerView)
        
        // Header Icon & Title
        let iconView = NSImageView(frame: NSRect(x: 0, y: 6, width: 20, height: 20))
        if let icon = NSImage(systemSymbolName: "captions.bubble.fill", accessibilityDescription: "Live Captions") {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            iconView.image = icon.withSymbolConfiguration(config)
            iconView.contentTintColor = orangeAccent
        }
        headerView.addSubview(iconView)
        
        let titleLabel = NSTextField(labelWithString: "Live Captions")
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        titleLabel.textColor = NSColor.labelColor
        titleLabel.frame = NSRect(x: 26, y: 6, width: 140, height: 20)
        headerView.addSubview(titleLabel)
        
        let activeBadge = NSTextField(labelWithString: "ACTIVE")
        activeBadge.font = NSFont.systemFont(ofSize: 9.5, weight: .bold)
        activeBadge.textColor = NSColor(red: 0.25, green: 0.90, blue: 0.55, alpha: 1.0)
        activeBadge.alignment = .left
        activeBadge.frame = NSRect(x: 140, y: 8, width: 60, height: 16)
        headerView.addSubview(activeBadge)
        
        // Settings Button (Gear)
        settingsBtn = NSButton(frame: NSRect(x: 268, y: 5, width: 24, height: 24))
        settingsBtn.isBordered = false
        settingsBtn.bezelStyle = .regularSquare
        settingsBtn.imagePosition = .imageOnly
        if let gear = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: "Settings & Options") {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            settingsBtn.image = gear.withSymbolConfiguration(config)
        }
        settingsBtn.contentTintColor = NSColor.secondaryLabelColor
        settingsBtn.target = self
        settingsBtn.action = #selector(openSettingsMenu(_:))
        settingsBtn.toolTip = "Settings & Options"
        headerView.addSubview(settingsBtn)
        
        // --- Transcript Area (Height: 108, y: 56 to 164) ---
        let scrollView = NSScrollView(frame: NSRect(x: 14, y: 56, width: 292, height: 108))
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        
        transcriptLabel = NSTextField(frame: NSRect(x: 0, y: 0, width: 292, height: 108))
        transcriptLabel.isEditable = false
        transcriptLabel.isSelectable = true
        transcriptLabel.isBordered = false
        transcriptLabel.drawsBackground = false
        transcriptLabel.textColor = NSColor.labelColor
        transcriptLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        transcriptLabel.cell?.wraps = true
        transcriptLabel.cell?.lineBreakMode = .byWordWrapping
        transcriptLabel.stringValue = "Listening for speech..."
        
        scrollView.documentView = transcriptLabel
        container.addSubview(scrollView)
        
        // --- Separator Line (y: 46) ---
        let separator = NSBox(frame: NSRect(x: 14, y: 46, width: 292, height: 1))
        separator.boxType = .separator
        container.addSubview(separator)
        
        // --- Audio Visualizer (Suspension Cables Waveform) ---
        visualizer = AudioVisualizerView(frame: NSRect(x: 14, y: 10, width: 292, height: 28), mode: .waveform(barCount: 28))
        visualizer.tintColor = orangeAccent
        container.addSubview(visualizer)
        
        self.view = container
    }
    
    @objc private func openSettingsMenu(_ sender: NSButton) {
        if let appDelegate = NSApp.delegate as? AppDelegate, let menu = appDelegate.statusMenu {
            menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.minX, y: sender.bounds.minY - 4), in: sender)
        }
    }
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        
        NotificationCenter.default.addObserver(self, selector: #selector(handleTranscriptUpdate), name: TranscriptManager.EntriesUpdatedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleAudioLevelUpdate(_:)), name: NSNotification.Name("CallerAudioLevelUpdated"), object: nil)
        
        updateTranscriptDisplay()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func handleTranscriptUpdate() {
        updateTranscriptDisplay()
    }
    
    private func updateTranscriptDisplay() {
        let entries = TranscriptManager.shared.entries
        if entries.isEmpty {
            transcriptLabel.attributedStringValue = NSAttributedString(
                string: "Listening for speech...",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
            return
        }
        
        let recentEntries = entries.suffix(4)
        let attr = NSMutableAttributedString()
        
        for (idx, item) in recentEntries.enumerated() {
            let isCaller = item.speaker == "Caller"
            let speakerColor = isCaller ? NSColor(red: 0.98, green: 0.55, blue: 0.22, alpha: 1.0) : NSColor(red: 0.40, green: 0.75, blue: 1.0, alpha: 1.0)
            
            let headerAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .bold),
                .foregroundColor: speakerColor
            ]
            let bodyAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
            
            attr.append(NSAttributedString(string: "\(item.speaker.uppercased())\n", attributes: headerAttrs))
            attr.append(NSAttributedString(string: "\(item.translated)\(idx < recentEntries.count - 1 ? "\n\n" : "")", attributes: bodyAttrs))
        }
        
        transcriptLabel.attributedStringValue = attr
        transcriptLabel.sizeToFit()
        
        if let scrollView = transcriptLabel.enclosingScrollView {
            let point = NSPoint(x: 0, y: transcriptLabel.frame.size.height - scrollView.contentSize.height)
            if point.y > 0 {
                scrollView.contentView.scroll(to: point)
            }
        }
    }
    
    @objc private func handleAudioLevelUpdate(_ notification: Notification) {
        if let level = notification.userInfo?["level"] as? Float {
            visualizer.setAudioLevel(level)
        }
    }
}
