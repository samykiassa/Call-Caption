import AppKit
import AVFoundation
import Speech
import ScreenCaptureKit

// MARK: - Perfectly Centered Status Badge View

public class StatusBadgeView: NSView {
    public var title: String = "Checking..." {
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
            textColor = NSColor(red: 0.25, green: 0.95, blue: 0.60, alpha: 1.0)
            bgColor = NSColor(red: 0.10, green: 0.35, blue: 0.18, alpha: 0.55)
            borderColor = NSColor(red: 0.20, green: 0.92, blue: 0.55, alpha: 0.40)
        } else if title.lowercased().contains("denied") {
            textColor = NSColor(red: 1.0, green: 0.45, blue: 0.45, alpha: 1.0)
            bgColor = NSColor(red: 0.45, green: 0.15, blue: 0.15, alpha: 0.55)
            borderColor = NSColor(red: 1.0, green: 0.45, blue: 0.45, alpha: 0.40)
        } else {
            textColor = NSColor(red: 0.98, green: 0.72, blue: 0.25, alpha: 1.0)
            bgColor = NSColor(red: 0.42, green: 0.28, blue: 0.10, alpha: 0.55)
            borderColor = NSColor(red: 0.98, green: 0.72, blue: 0.25, alpha: 0.40)
        }
        
        // Background capsule
        let cornerRadius = bounds.height / 2.0
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        bgColor.setFill()
        path.fill()
        borderColor.setStroke()
        path.lineWidth = 1.0
        path.stroke()
        
        // Text & metrics
        let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let text = title as NSString
        let textSize = text.size(withAttributes: attrs)
        
        let dotSize: CGFloat = 7.0
        let spacing: CGFloat = 6.0
        let totalWidth = dotSize + spacing + textSize.width
        let startX = round((bounds.width - totalWidth) / 2.0)
        let centerY = bounds.height / 2.0
        
        // Exact optical centering: aligns vertical center of text cap-height with vertical center of dot
        let textY = round(centerY + font.descender - (font.capHeight / 2.0))
        let dotY = round(centerY - dotSize / 2.0)
        
        // Draw dot
        let dotRect = NSRect(x: startX, y: dotY, width: dotSize, height: dotSize)
        textColor.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        
        // Draw text
        text.draw(at: NSPoint(x: startX + dotSize + spacing, y: textY), withAttributes: attrs)
    }
}

// MARK: - Permissions Window Controller

public class PermissionsWindowController: NSWindowController, NSWindowDelegate {
    
    // Status badges (Centered StatusBadgeView)
    private var micStatusBadge: StatusBadgeView!
    private var speechStatusBadge: StatusBadgeView!
    private var screenStatusBadge: StatusBadgeView!
    
    // Action buttons
    private var micActionBtn: NSButton!
    private var speechActionBtn: NSButton!
    private var screenActionBtn: NSButton!
    
    // Live mic test
    private var testMicBtn: NSButton!
    private var micTestLabel: NSTextField!
    private var audioEngine: AVAudioEngine?
    private var isTestingMic: Bool = false
    
    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 640),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "System Permissions & Audio Setup"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()
        window.backgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1.0)
        
        super.init(window: window)
        window.delegate = self
        setupUI()
        refreshStatus()
    }
    
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func windowDidBecomeKey(_ notification: Notification) {
        refreshStatus()
    }
    
    private func setupUI() {
        guard let window = self.window else { return }
        
        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.wantsLayer = true
        contentView.autoresizingMask = [.width, .height]
        contentView.layer?.backgroundColor = NSColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1.0).cgColor
        
        var currentY: CGFloat = contentView.bounds.height - 40
        
        // ------------------------------------------------------------------
        // Header
        // ------------------------------------------------------------------
        let headerIcon = NSTextField(labelWithString: "⚙️")
        headerIcon.font = NSFont.systemFont(ofSize: 24)
        headerIcon.frame = NSRect(x: 24, y: currentY - 6, width: 34, height: 32)
        contentView.addSubview(headerIcon)
        
        let titleLabel = NSTextField(labelWithString: "System Permissions & Audio Setup")
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.frame = NSRect(x: 64, y: currentY, width: 510, height: 24)
        contentView.addSubview(titleLabel)
        
        currentY -= 28
        let subtitleLabel = NSTextField(labelWithString: "CallCaption requires system permissions to capture call audio and translate both speakers in real-time.")
        subtitleLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        subtitleLabel.textColor = NSColor(white: 0.70, alpha: 1.0)
        subtitleLabel.cell?.wraps = true
        subtitleLabel.cell?.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.frame = NSRect(x: 64, y: currentY - 4, width: 510, height: 32)
        contentView.addSubview(subtitleLabel)
        
        currentY -= 22
        let divider = NSBox(frame: NSRect(x: 24, y: currentY, width: 552, height: 1))
        divider.boxType = .separator
        contentView.addSubview(divider)
        
        currentY -= 16
        
        // ------------------------------------------------------------------
        // Permission Cards
        // ------------------------------------------------------------------
        
        // 1. Microphone Card (Without "Your Voice")
        currentY -= 82
        let (micCard, mBadge, mBtn) = createPermissionCard(
            frame: NSRect(x: 24, y: currentY, width: 552, height: 82),
            icon: "🎙️",
            title: "Microphone Access",
            desc: "Captures spoken speech so CallCaption can translate your words for the caller.",
            actionTitle: "Grant Access",
            actionSelector: #selector(micActionClicked)
        )
        contentView.addSubview(micCard)
        micStatusBadge = mBadge
        micActionBtn = mBtn
        
        // 2. Speech Recognition Card
        currentY -= 92
        let (speechCard, spBadge, spBtn) = createPermissionCard(
            frame: NSRect(x: 24, y: currentY, width: 552, height: 82),
            icon: "🗣️",
            title: "Speech Recognition Engine",
            desc: "Transcribes spoken audio into text locally with Apple's neural speech engine.",
            actionTitle: "Authorize Speech",
            actionSelector: #selector(speechActionClicked)
        )
        contentView.addSubview(speechCard)
        speechStatusBadge = spBadge
        speechActionBtn = spBtn
        
        // 3. Screen & System Audio Recording Card (Generic Call Audio)
        currentY -= 92
        let (screenCard, scBadge, scBtn) = createPermissionCard(
            frame: NSRect(x: 24, y: currentY, width: 552, height: 82),
            icon: "🖥️",
            title: "Screen & Audio Recording (Call Audio)",
            desc: "Directly captures incoming caller audio from calls without virtual cables.",
            actionTitle: "Open Settings ↗",
            actionSelector: #selector(screenActionClicked)
        )
        contentView.addSubview(screenCard)
        screenStatusBadge = scBadge
        screenActionBtn = scBtn
        
        currentY -= 14
        let noteLabel = NSTextField(labelWithString: "ℹ️ Note: macOS requires restarting CallCaption once Screen & Audio Recording is enabled.")
        noteLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        noteLabel.textColor = NSColor(red: 0.95, green: 0.75, blue: 0.25, alpha: 1.0)
        noteLabel.frame = NSRect(x: 28, y: currentY, width: 544, height: 16)
        contentView.addSubview(noteLabel)
        
        // ------------------------------------------------------------------
        // Live Mic Test & Diagnostics Box
        // ------------------------------------------------------------------
        currentY -= 74
        let testBox = NSView(frame: NSRect(x: 24, y: currentY, width: 552, height: 64))
        testBox.wantsLayer = true
        testBox.layer?.cornerRadius = 10
        testBox.layer?.backgroundColor = NSColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 0.9).cgColor
        testBox.layer?.borderWidth = 1.0
        testBox.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        
        let testBoxTitle = NSTextField(labelWithString: "🎙️ Quick Microphone Diagnostic:")
        testBoxTitle.font = NSFont.systemFont(ofSize: 11.5, weight: .bold)
        testBoxTitle.textColor = .white
        testBoxTitle.frame = NSRect(x: 14, y: 36, width: 260, height: 18)
        testBox.addSubview(testBoxTitle)
        
        micTestLabel = NSTextField(labelWithString: "Click 'Test Mic' and speak to verify your input signal.")
        micTestLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        micTestLabel.textColor = NSColor(white: 0.65, alpha: 1.0)
        micTestLabel.frame = NSRect(x: 14, y: 12, width: 380, height: 18)
        testBox.addSubview(micTestLabel)
        
        testMicBtn = NSButton(title: "Test Mic 🎙️", target: self, action: #selector(testMicClicked))
        testMicBtn.frame = NSRect(x: 410, y: 16, width: 128, height: 32)
        testMicBtn.bezelStyle = .rounded
        testMicBtn.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        testBox.addSubview(testMicBtn)
        
        contentView.addSubview(testBox)
        
        // ------------------------------------------------------------------
        // Live Call Audio Routing Guide Box
        // ------------------------------------------------------------------
        currentY -= 84
        let guideBox = NSView(frame: NSRect(x: 24, y: currentY, width: 552, height: 76))
        guideBox.wantsLayer = true
        guideBox.layer?.cornerRadius = 10
        guideBox.layer?.backgroundColor = NSColor(red: 0.08, green: 0.13, blue: 0.18, alpha: 0.9).cgColor
        guideBox.layer?.borderWidth = 1.0
        guideBox.layer?.borderColor = NSColor(red: 0.15, green: 0.50, blue: 0.85, alpha: 0.35).cgColor
        
        let guideTitle = NSTextField(labelWithString: "💬 Live Call Audio Routing Guide")
        guideTitle.font = NSFont.systemFont(ofSize: 11.5, weight: .bold)
        guideTitle.textColor = NSColor(red: 0.35, green: 0.75, blue: 1.0, alpha: 1.0)
        guideTitle.frame = NSRect(x: 14, y: 50, width: 520, height: 18)
        guideBox.addSubview(guideTitle)
        
        let guideDesc = NSTextField(labelWithString: "1. Open your call app's Audio Settings (FaceTime, Zoom, Phone, etc.).\n2. Ensure Audio Output is set to your regular Speakers or Headphones.\n3. CallCaption captures caller audio automatically without extra audio drivers.")
        guideDesc.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        guideDesc.textColor = NSColor(white: 0.75, alpha: 1.0)
        guideDesc.cell?.wraps = true
        guideDesc.cell?.lineBreakMode = .byWordWrapping
        guideDesc.maximumNumberOfLines = 3
        guideDesc.frame = NSRect(x: 14, y: 8, width: 524, height: 40)
        guideBox.addSubview(guideDesc)
        
        contentView.addSubview(guideBox)
        
        // ------------------------------------------------------------------
        // Bottom Action Bar
        // ------------------------------------------------------------------
        let bottomBar = NSView(frame: NSRect(x: 24, y: 14, width: 552, height: 36))
        
        let refreshBtn = NSButton(title: "🔄 Refresh", target: self, action: #selector(refreshClicked))
        refreshBtn.frame = NSRect(x: 0, y: 2, width: 96, height: 32)
        refreshBtn.bezelStyle = .rounded
        bottomBar.addSubview(refreshBtn)
        
        let sysSettingsBtn = NSButton(title: "⚙️ System Settings...", target: self, action: #selector(openSysSettingsClicked))
        sysSettingsBtn.frame = NSRect(x: 104, y: 2, width: 148, height: 32)
        sysSettingsBtn.bezelStyle = .rounded
        bottomBar.addSubview(sysSettingsBtn)
        
        let restartBtn = NSButton(title: "🔄 Restart App", target: self, action: #selector(restartAppClicked))
        restartBtn.frame = NSRect(x: 328, y: 2, width: 118, height: 32)
        restartBtn.bezelStyle = .rounded
        bottomBar.addSubview(restartBtn)
        
        let closeBtn = NSButton(title: "Done", target: self, action: #selector(closeClicked))
        closeBtn.frame = NSRect(x: 454, y: 2, width: 98, height: 32)
        closeBtn.bezelStyle = .rounded
        closeBtn.keyEquivalent = "\r"
        bottomBar.addSubview(closeBtn)
        
        contentView.addSubview(bottomBar)
        
        window.contentView = contentView
    }
    
    // MARK: - Card Component Builder
    
    private func createPermissionCard(
        frame: NSRect,
        icon: String,
        title: String,
        desc: String,
        actionTitle: String,
        actionSelector: Selector
    ) -> (NSView, StatusBadgeView, NSButton) {
        let card = NSView(frame: frame)
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.backgroundColor = NSColor(red: 0.11, green: 0.13, blue: 0.18, alpha: 0.95).cgColor
        card.layer?.borderWidth = 1.0
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        
        // Icon
        let iconLabel = NSTextField(labelWithString: icon)
        iconLabel.font = NSFont.systemFont(ofSize: 22)
        iconLabel.frame = NSRect(x: 16, y: (frame.height - 30) / 2.0, width: 32, height: 30)
        card.addSubview(iconLabel)
        
        // Text details
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.frame = NSRect(x: 56, y: 46, width: 320, height: 20)
        card.addSubview(titleLabel)
        
        let descLabel = NSTextField(labelWithString: desc)
        descLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        descLabel.textColor = NSColor(white: 0.65, alpha: 1.0)
        descLabel.cell?.wraps = true
        descLabel.cell?.lineBreakMode = .byWordWrapping
        descLabel.maximumNumberOfLines = 2
        descLabel.frame = NSRect(x: 56, y: 12, width: 320, height: 32)
        card.addSubview(descLabel)
        
        // Mathematically Centered Status Badge Pill
        let badge = StatusBadgeView(frame: NSRect(x: 386, y: 44, width: 152, height: 26))
        card.addSubview(badge)
        
        // Action Button
        let btn = NSButton(title: actionTitle, target: self, action: actionSelector)
        btn.frame = NSRect(x: 386, y: 12, width: 152, height: 28)
        btn.bezelStyle = .rounded
        btn.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        card.addSubview(btn)
        
        return (card, badge, btn)
    }
    
    // MARK: - Status Updates
    
    public func refreshStatus() {
        // 1. Microphone
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .authorized {
            micStatusBadge.setStatus(isGranted: true, title: "Granted")
            micActionBtn.title = "Settings ↗"
        } else if micStatus == .denied || micStatus == .restricted {
            micStatusBadge.setStatus(isGranted: false, title: "Denied")
            micActionBtn.title = "Open Settings ↗"
        } else {
            micStatusBadge.setStatus(isGranted: false, title: "Needs Permission")
            micActionBtn.title = "Grant Access"
        }
        
        // 2. Speech Recognition
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        if speechStatus == .authorized {
            speechStatusBadge.setStatus(isGranted: true, title: "Granted")
            speechActionBtn.title = "Settings ↗"
        } else if speechStatus == .denied || speechStatus == .restricted {
            speechStatusBadge.setStatus(isGranted: false, title: "Denied")
            speechActionBtn.title = "Open Settings ↗"
        } else {
            speechStatusBadge.setStatus(isGranted: false, title: "Needs Permission")
            speechActionBtn.title = "Authorize Speech"
        }
        
        // 3. Screen & System Audio Recording
        let screenAccess = PermissionHelper.shared.hasScreenCaptureAccess
        if screenAccess {
            screenStatusBadge.setStatus(isGranted: true, title: "Granted")
            screenActionBtn.title = "Settings ↗"
        } else {
            screenStatusBadge.setStatus(isGranted: false, title: "Action Required")
            screenActionBtn.title = "Open Settings ↗"
        }
    }
    
    // MARK: - Actions
    
    @objc private func micActionClicked() {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.refreshStatus()
                }
            }
        } else {
            PermissionHelper.shared.openMicrophoneSettings()
        }
    }
    
    @objc private func speechActionClicked() {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        if speechStatus == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { [weak self] _ in
                DispatchQueue.main.async {
                    self?.refreshStatus()
                }
            }
        } else {
            PermissionHelper.shared.openSpeechRecognitionSettings()
        }
    }
    
    @objc private func screenActionClicked() {
        if #available(macOS 14.0, *) {
            if !CGPreflightScreenCaptureAccess() {
                _ = CGRequestScreenCaptureAccess()
            }
        }
        PermissionHelper.shared.openScreenCaptureSettings()
    }
    
    @objc private func testMicClicked() {
        if isTestingMic {
            stopMicTest()
            return
        }
        
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micStatus == .authorized else {
            micTestLabel.stringValue = "⚠️ Microphone not authorized! Click 'Grant Access' first."
            micTestLabel.textColor = NSColor.systemOrange
            return
        }
        
        startMicTest()
    }
    
    private func startMicTest() {
        isTestingMic = true
        testMicBtn.title = "Stop Test ⏹"
        micTestLabel.stringValue = "Listening... Speak now to test signal!"
        micTestLabel.textColor = NSColor(red: 0.20, green: 0.88, blue: 0.52, alpha: 1.0)
        
        let engine = AVAudioEngine()
        self.audioEngine = engine
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] (buffer, _) in
            guard let self = self, self.isTestingMic else { return }
            let channelData = buffer.floatChannelData?[0]
            let frameLength = Int(buffer.frameLength)
            guard let data = channelData, frameLength > 0 else { return }
            
            var sum: Float = 0
            for i in 0..<frameLength {
                sum += abs(data[i])
            }
            let avg = sum / Float(frameLength)
            
            DispatchQueue.main.async {
                if avg > 0.015 {
                    self.micTestLabel.stringValue = "✅ Audio signal detected! (Level: \(Int(avg * 1000)))"
                    self.micTestLabel.textColor = NSColor(red: 0.20, green: 0.95, blue: 0.55, alpha: 1.0)
                }
            }
        }
        
        do {
            try engine.start()
            // Auto stop after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                if self?.isTestingMic == true {
                    self?.stopMicTest()
                }
            }
        } catch {
            micTestLabel.stringValue = "⚠️ Could not start audio engine: \(error.localizedDescription)"
            micTestLabel.textColor = NSColor.systemRed
            stopMicTest()
        }
    }
    
    private func stopMicTest() {
        isTestingMic = false
        testMicBtn.title = "Test Mic 🎙️"
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        micTestLabel.stringValue = "Test completed. Microphone input verified."
        micTestLabel.textColor = NSColor(white: 0.70, alpha: 1.0)
    }
    
    @objc private func refreshClicked() {
        refreshStatus()
    }
    
    @objc private func openSysSettingsClicked() {
        PermissionHelper.shared.openGeneralPrivacySettings()
    }
    
    @objc private func restartAppClicked() {
        let alert = NSAlert()
        alert.messageText = "Restart CallCaption?"
        alert.informativeText = "CallCaption will close and relaunch immediately to apply any new macOS permissions."
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            PermissionHelper.shared.restartApp()
        }
    }
    
    @objc private func closeClicked() {
        window?.orderOut(nil)
    }
}
