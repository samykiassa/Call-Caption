import AppKit
import Speech
import AVFoundation

public final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private var speechBadge: StatusBadgeView!
    private var speechBtn: NSButton!
    private var audioBadge: StatusBadgeView!
    private var audioBtn: NSButton!
    private var micBadge: StatusBadgeView!
    private var micBtn: NSButton!
    private var foreignPopup: NSPopUpButton!
    private var mainPopup: NSPopUpButton!
    private var consentCheckbox: NSButton!
    private var continueBtn: NSButton!
    private var onComplete: (() -> Void)?
    private var onClose: (() -> Void)?
    private var didComplete = false

    public init(onComplete: (() -> Void)? = nil, onClose: (() -> Void)? = nil) {
        self.onComplete = onComplete
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.tr("onboarding.title", "Welcome to Call Caption")
        window.isReleasedWhenClosed = false
        window.center()
        window.level = .normal
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0)

        super.init(window: window)
        window.delegate = self
        setupUI()
        refreshState()
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        refreshState()
        SupportedLanguages.refreshCacheInBackground { [weak self] in
            self?.refreshState()
        }
    }

    public func windowWillClose(_ notification: Notification) {
        guard !didComplete else { return }
        let close = onClose
        onComplete = nil
        onClose = nil
        close?()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let window = self.window, let contentView = window.contentView else { return }
        let root = NSView(frame: contentView.bounds)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0).cgColor
        window.contentView = root

        let w = root.bounds.width
        let sidePad: CGFloat = 28
        let cardW = w - (sidePad * 2)

        let titleLabel = NSTextField(labelWithString: L10n.tr("onboarding.title", "Welcome to Call Caption"))
        titleLabel.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.frame = NSRect(x: sidePad, y: 470, width: cardW, height: 26)
        root.addSubview(titleLabel)

        let subtitleLabel = NSTextField(wrappingLabelWithString: L10n.tr(
            "onboarding.subtitle",
            "On-device captions for system audio, including calls, media, and other apps. Audio never leaves your Mac unless you start a Live Link."
        ))
        subtitleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        subtitleLabel.textColor = NSColor(white: 0.72, alpha: 1.0)
        subtitleLabel.frame = NSRect(x: sidePad, y: 430, width: cardW, height: 34)
        root.addSubview(subtitleLabel)

        let langCardH: CGFloat = 92
        let langCard = makeCard(frame: NSRect(x: sidePad, y: 326, width: cardW, height: langCardH))

        let r1Label = NSTextField(labelWithString: "Caller Language")
        r1Label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        r1Label.textColor = NSColor(white: 0.92, alpha: 1.0)
        r1Label.frame = NSRect(x: 16, y: 56, width: 180, height: 18)
        langCard.addSubview(r1Label)

        foreignPopup = NSPopUpButton(frame: NSRect(x: cardW - 220, y: 52, width: 204, height: 26))
        populateLanguages(foreignPopup)
        foreignPopup.target = self
        foreignPopup.action = #selector(foreignChanged(_:))
        foreignPopup.setAccessibilityLabel("Caller Language")
        langCard.addSubview(foreignPopup)

        let div1 = NSView(frame: NSRect(x: 16, y: 46, width: cardW - 32, height: 1))
        div1.wantsLayer = true
        div1.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        langCard.addSubview(div1)

        let r2Label = NSTextField(labelWithString: "Your Language")
        r2Label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        r2Label.textColor = NSColor(white: 0.92, alpha: 1.0)
        r2Label.frame = NSRect(x: 16, y: 14, width: 180, height: 18)
        langCard.addSubview(r2Label)

        mainPopup = NSPopUpButton(frame: NSRect(x: cardW - 220, y: 10, width: 204, height: 26))
        populateLanguages(mainPopup)
        mainPopup.target = self
        mainPopup.action = #selector(mainChanged(_:))
        mainPopup.setAccessibilityLabel("Your Language")
        langCard.addSubview(mainPopup)

        root.addSubview(langCard)

        let permCardH: CGFloat = 160
        let permCard = makeCard(frame: NSRect(x: sidePad, y: 150, width: cardW, height: permCardH))

        addPermissionRow(
            to: permCard,
            y: 107,
            height: 53,
            cardWidth: cardW,
            iconName: "waveform",
            iconColor: NSColor(red: 0.28, green: 0.84, blue: 0.98, alpha: 1.0),
            title: "Speech Recognition",
            subtitle: "Required for on-device transcription",
            buttonTitle: "Grant",
            action: #selector(requestSpeechAction),
            outBadge: &speechBadge,
            outButton: &speechBtn
        )

        let divP1 = NSView(frame: NSRect(x: 16, y: 107, width: cardW - 32, height: 1))
        divP1.wantsLayer = true
        divP1.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        permCard.addSubview(divP1)

        addPermissionRow(
            to: permCard,
            y: 53,
            height: 54,
            cardWidth: cardW,
            iconName: "speaker.wave.2.fill",
            iconColor: NSColor(red: 0.24, green: 0.90, blue: 0.56, alpha: 1.0),
            title: "System Audio Recording",
            subtitle: "Prompts automatically when listening starts",
            buttonTitle: "Settings",
            action: #selector(openAudioCaptureSettingsAction),
            outBadge: &audioBadge,
            outButton: &audioBtn
        )

        let divP2 = NSView(frame: NSRect(x: 16, y: 53, width: cardW - 32, height: 1))
        divP2.wantsLayer = true
        divP2.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        permCard.addSubview(divP2)

        addPermissionRow(
            to: permCard,
            y: 0,
            height: 53,
            cardWidth: cardW,
            iconName: "mic.fill",
            iconColor: NSColor(red: 0.98, green: 0.58, blue: 0.24, alpha: 1.0),
            title: "Microphone Translation",
            subtitle: "Optional — off by default",
            buttonTitle: "Enable",
            action: #selector(requestMicAction),
            outBadge: &micBadge,
            outButton: &micBtn
        )

        root.addSubview(permCard)

        let consentBox = makeCard(frame: NSRect(x: sidePad, y: 68, width: cardW, height: 66))
        let consentText = NSTextField(wrappingLabelWithString: L10n.tr(
            "onboarding.consentNotice",
            "Legal Notice: Recording or transcribing phone/video calls may require the consent of all participants under applicable local laws."
        ))
        consentText.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        consentText.textColor = NSColor(white: 0.76, alpha: 1.0)
        consentText.frame = NSRect(x: 14, y: 31, width: cardW - 28, height: 28)
        consentBox.addSubview(consentText)

        consentCheckbox = NSButton(
            checkboxWithTitle: "I understand and will comply with call recording/transcription consent laws",
            target: self,
            action: #selector(consentToggled)
        )
        consentCheckbox.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        consentCheckbox.state = AppSettings.shared.hasCompletedOnboarding ? .on : .off
        consentCheckbox.frame = NSRect(x: 14, y: 7, width: cardW - 28, height: 20)
        consentCheckbox.setAccessibilityLabel("I understand and will comply with call recording and transcription consent laws")
        consentBox.addSubview(consentCheckbox)

        root.addSubview(consentBox)

        let transModelsBtn = NSButton(title: "Download Translation Models…", target: self, action: #selector(openTranslationSettingsAction))
        transModelsBtn.bezelStyle = .rounded
        transModelsBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        transModelsBtn.frame = NSRect(x: sidePad, y: 20, width: 196, height: 30)
        transModelsBtn.setAccessibilityLabel("Open Translation Language Settings")
        root.addSubview(transModelsBtn)

        let legalBtn = NSButton(title: "Privacy & Terms…", target: self, action: #selector(openLegalAction))
        legalBtn.bezelStyle = .rounded
        legalBtn.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        legalBtn.frame = NSRect(x: sidePad + 202, y: 20, width: 116, height: 30)
        legalBtn.setAccessibilityLabel("Privacy Policy and Terms of Use")
        root.addSubview(legalBtn)

        continueBtn = NSButton(title: L10n.tr("onboarding.startListening", "Start Listening"), target: self, action: #selector(finishOnboardingAction))
        continueBtn.bezelStyle = .rounded
        continueBtn.keyEquivalent = "\r"
        continueBtn.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        continueBtn.frame = NSRect(x: w - sidePad - 148, y: 20, width: 148, height: 30)
        continueBtn.setAccessibilityLabel("Start Listening")
        root.addSubview(continueBtn)
    }

    private func addPermissionRow(
        to container: NSView,
        y: CGFloat,
        height: CGFloat,
        cardWidth: CGFloat,
        iconName: String,
        iconColor: NSColor,
        title: String,
        subtitle: String,
        buttonTitle: String,
        action: Selector,
        outBadge: inout StatusBadgeView!,
        outButton: inout NSButton!
    ) {
        let iconView = NSImageView(frame: NSRect(x: 16, y: y + round((height - 20) / 2.0), width: 20, height: 20))
        if let img = NSImage(systemSymbolName: iconName, accessibilityDescription: title) {
            iconView.image = img.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13.5, weight: .semibold))
            iconView.contentTintColor = iconColor
        }
        container.addSubview(iconView)

        let textMaxW = cardWidth - 196 - 48
        let titleField = NSTextField(labelWithString: title)
        titleField.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = .white
        titleField.lineBreakMode = .byTruncatingTail
        titleField.frame = NSRect(x: 44, y: y + 27, width: textMaxW, height: 18)
        container.addSubview(titleField)

        let subField = NSTextField(labelWithString: subtitle)
        subField.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        subField.textColor = NSColor(white: 0.62, alpha: 1.0)
        subField.lineBreakMode = .byTruncatingTail
        subField.frame = NSRect(x: 44, y: y + 9, width: textMaxW, height: 16)
        container.addSubview(subField)

        let badge = StatusBadgeView(frame: NSRect(x: cardWidth - 190, y: y + round((height - 22) / 2.0), width: 82, height: 22))
        container.addSubview(badge)
        outBadge = badge

        let btn = NSButton(title: buttonTitle, target: self, action: action)
        btn.bezelStyle = .rounded
        btn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        btn.frame = NSRect(x: cardWidth - 98, y: y + round((height - 28) / 2.0), width: 82, height: 28)
        btn.setAccessibilityLabel("\(title) permission")
        container.addSubview(btn)
        outButton = btn
    }

    private func makeCard(frame: NSRect) -> NSBox {
        let card = NSBox(frame: frame)
        card.boxType = .custom
        card.cornerRadius = 10
        card.fillColor = NSColor.white.withAlphaComponent(0.035)
        card.borderColor = NSColor.white.withAlphaComponent(0.08)
        card.borderWidth = 1.0
        card.contentViewMargins = .zero
        return card
    }

    private func populateLanguages(_ popup: NSPopUpButton) {
        popup.removeAllItems()
        for lang in SupportedLanguages.all {
            let item = NSMenuItem(title: "\(lang.flag)  \(lang.name)", action: nil, keyEquivalent: "")
            item.representedObject = lang.code
            popup.menu?.addItem(item)
        }
    }

    public func refreshState() {
        let settings = AppSettings.shared
        if let fIdx = SupportedLanguages.all.firstIndex(where: { $0.code == settings.foreignLanguageCode }) {
            foreignPopup?.selectItem(at: fIdx)
        }
        if let mIdx = SupportedLanguages.all.firstIndex(where: { $0.code == settings.mainLanguageCode }) {
            mainPopup?.selectItem(at: mIdx)
        }

        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let speechOK = (speechStatus == .authorized)
        speechBadge?.setStatus(
            isGranted: speechOK,
            title: speechOK ? "Granted" : (speechStatus == .denied ? "Denied" : "Required")
        )
        speechBtn?.title = (speechStatus == .notDetermined) ? "Grant" : "Settings"
        speechBtn?.isEnabled = true

        switch PermissionHelper.shared.audioCaptureState {
        case .active:
            let running = CaptionCoordinator.shared.audioCaptureEngine.isRunning
            let paused = CaptionCoordinator.shared.isPaused
            audioBadge?.setStatus(
                isGranted: running,
                title: running ? "Capturing" : (paused ? "Paused" : "Not running")
            )
            audioBtn?.title = "Settings"
        case .deniedSilenceDetected:
            audioBadge?.setStatus(isGranted: false, title: "Denied")
            audioBtn?.title = "Settings"
        case .unknown:
            let running = CaptionCoordinator.shared.audioCaptureEngine.isRunning
            let paused = CaptionCoordinator.shared.isPaused
            audioBadge?.setStatus(
                isGranted: running,
                title: running ? "Listening" : (paused ? "Paused" : "Not started")
            )
            audioBtn?.title = "Settings"
        }

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let micOK = (micStatus == .authorized) && settings.isMicEnabled
        micBadge?.setStatus(
            isGranted: micOK,
            title: micOK ? "Enabled" : (micStatus == .denied ? "Denied" : "Off")
        )
        micBtn?.title = micOK ? "Disable" : "Enable"

        continueBtn?.isEnabled = (consentCheckbox?.state == .on)
    }

    @objc private func foreignChanged(_ sender: NSPopUpButton) {
        if let code = sender.selectedItem?.representedObject as? String {
            AppSettings.shared.foreignLanguageCode = code
        }
    }

    @objc private func mainChanged(_ sender: NSPopUpButton) {
        if let code = sender.selectedItem?.representedObject as? String {
            AppSettings.shared.setMainAndTargetLanguage(code)
        }
    }

    @objc private func requestSpeechAction() {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            PermissionHelper.shared.checkSpeechRecognitionAccess { [weak self] _ in
                self?.refreshState()
            }
        } else {
            PermissionHelper.shared.openSpeechRecognitionSettings()
        }
    }

    @objc private func openAudioCaptureSettingsAction() {
        PermissionHelper.shared.openAudioCaptureSettings()
    }

    @objc private func requestMicAction() {
        if AppSettings.shared.isMicEnabled {
            AppSettings.shared.isMicEnabled = false
            refreshState()
            return
        }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized {
            AppSettings.shared.isMicEnabled = true
            refreshState()
        } else if status == .notDetermined {
            PermissionHelper.shared.requestMicrophoneAccess { [weak self] granted in
                AppSettings.shared.isMicEnabled = granted
                self?.refreshState()
            }
        } else {
            PermissionHelper.shared.openMicrophoneSettings()
        }
    }

    @objc private func openTranslationSettingsAction() {
        PermissionHelper.shared.openTranslationSettings()
    }

    @objc private func openLegalAction() {
        AppDelegate.shared.openLegalDocument(.privacy)
    }

    @objc private func consentToggled() {
        continueBtn?.isEnabled = (consentCheckbox.state == .on)
    }

    @objc private func finishOnboardingAction() {
        guard consentCheckbox.state == .on else { return }
        AppSettings.shared.hasCompletedOnboarding = true
        didComplete = true
        let completion = onComplete
        onComplete = nil
        onClose = nil
        window?.close()
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            PermissionHelper.shared.checkSpeechRecognitionAccess { _ in
                completion?()
            }
        } else {
            completion?()
        }
    }
}
