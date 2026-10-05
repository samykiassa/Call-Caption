import AppKit

public class TranscriptWindowController: NSWindowController {
    private var textView: NSTextView!
    private var countLabel: NSTextField!
    
    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 680, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Live Call Transcript Log"
        window.level = .floating
        window.minSize = NSSize(width: 500, height: 320)
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1.0)
        super.init(window: window)
        
        setupUI()
        updateContent()
        
        TranscriptManager.shared.onEntriesUpdated = { [weak self] _ in
            self?.updateContent()
        }
    }
    
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        guard let window = self.window else { return }
        
        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.wantsLayer = true
        contentView.autoresizingMask = [.width, .height]
        contentView.layer?.backgroundColor = NSColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1.0).cgColor
        
        // Scroll view with text view
        let scrollView = NSScrollView(frame: NSRect(x: 16, y: 56, width: contentView.bounds.width - 32, height: contentView.bounds.height - 72))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 10
        scrollView.layer?.borderWidth = 1.0
        scrollView.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        scrollView.layer?.backgroundColor = NSColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1.0).cgColor
        
        let tv = NSTextView(frame: scrollView.contentView.bounds)
        tv.autoresizingMask = [.width]
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        tv.backgroundColor = NSColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1.0)
        tv.textColor = .white
        tv.textContainerInset = NSSize(width: 14, height: 14)
        
        scrollView.documentView = tv
        contentView.addSubview(scrollView)
        self.textView = tv
        
        // Bottom toolbar
        let bottomBar = NSView(frame: NSRect(x: 16, y: 12, width: contentView.bounds.width - 32, height: 36))
        bottomBar.autoresizingMask = [.width, .minYMargin]
        
        let copyBtn = NSButton(title: "📋 Copy All", target: self, action: #selector(copyAction))
        copyBtn.frame = NSRect(x: 0, y: 2, width: 110, height: 32)
        copyBtn.bezelStyle = .rounded
        bottomBar.addSubview(copyBtn)
        
        let exportBtn = NSButton(title: "💾 Save .txt...", target: self, action: #selector(exportAction))
        exportBtn.frame = NSRect(x: 120, y: 2, width: 120, height: 32)
        exportBtn.bezelStyle = .rounded
        bottomBar.addSubview(exportBtn)
        
        let clearBtn = NSButton(title: "🗑️ Clear Log", target: self, action: #selector(clearAction))
        clearBtn.frame = NSRect(x: 250, y: 2, width: 110, height: 32)
        clearBtn.bezelStyle = .rounded
        bottomBar.addSubview(clearBtn)
        
        countLabel = NSTextField(labelWithString: "0 entries")
        countLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.frame = NSRect(x: bottomBar.bounds.width - 150, y: 8, width: 150, height: 20)
        countLabel.autoresizingMask = [.minXMargin]
        bottomBar.addSubview(countLabel)
        
        contentView.addSubview(bottomBar)
        window.contentView = contentView
    }
    
    public func updateContent() {
        let entries = TranscriptManager.shared.entries
        guard let tv = textView else { return }
        
        countLabel?.stringValue = "\(entries.count) utteranc\(entries.count == 1 ? "e" : "es")"
        
        if entries.isEmpty {
            tv.string = "\n  No speech captured yet.\n\n  Subtitles from both the caller and your microphone will be recorded here in real-time."
            return
        }
        
        let attrText = NSMutableAttributedString()
        
        for entry in entries {
            let isCaller = entry.speaker == "Caller"
            
            let timeAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor(white: 0.50, alpha: 1.0)
            ]
            let speakerAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .bold),
                .foregroundColor: isCaller ? NSColor(red: 0.20, green: 0.88, blue: 0.50, alpha: 1.0) : NSColor(red: 0.25, green: 0.80, blue: 1.0, alpha: 1.0)
            ]
            let origAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor(white: 0.70, alpha: 1.0)
            ]
            let transAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            
            attrText.append(NSAttributedString(string: "[\(entry.formattedTime)] ", attributes: timeAttrs))
            attrText.append(NSAttributedString(string: "\(entry.speaker):\n", attributes: speakerAttrs))
            attrText.append(NSAttributedString(string: "  \"\(entry.original)\"\n", attributes: origAttrs))
            attrText.append(NSAttributedString(string: "  ➔ \"\(entry.translated)\"\n\n", attributes: transAttrs))
        }
        
        tv.textStorage?.setAttributedString(attrText)
        tv.scrollToEndOfDocument(nil)
    }
    
    @objc private func copyAction() {
        TranscriptManager.shared.copyToClipboard()
        let alert = NSAlert()
        alert.messageText = "Transcript Copied"
        alert.informativeText = "Call transcript has been copied to your clipboard."
        alert.alertStyle = .informational
        alert.runModal()
    }
    
    @objc private func exportAction() {
        let savePanel = NSSavePanel()
        savePanel.title = "Save Call Transcript"
        savePanel.nameFieldStringValue = "CallCaption_Transcript_\(Int(Date().timeIntervalSince1970)).txt"
        savePanel.allowedContentTypes = [.plainText]
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            let text = TranscriptManager.shared.exportAsText()
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
    
    @objc private func clearAction() {
        TranscriptManager.shared.clear()
        updateContent()
    }
}
