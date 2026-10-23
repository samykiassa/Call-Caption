import AppKit

public final class TranscriptWindowController: NSWindowController, NSSearchFieldDelegate, NSWindowDelegate {
    private var textView: NSTextView!
    private var countLabel: NSTextField!
    private var searchField: NSSearchField!
    private var filterQuery: String = ""
    private var needsContentRefresh: Bool = false
    private var lastShowOriginalSetting: Bool = AppSettings.shared.showOriginalText
    private var entryCharRanges: [UUID: NSRange] = [:]

    private let timeAttrs: [NSAttributedString.Key: Any]
    private let callerSpeakerAttrs: [NSAttributedString.Key: Any]
    private let youSpeakerAttrs: [NSAttributedString.Key: Any]
    private let untranslatedBadgeAttrs: [NSAttributedString.Key: Any]
    private let transWithOrigAttrs: [NSAttributedString.Key: Any]
    private let transSoloAttrs: [NSAttributedString.Key: Any]
    private let origAttrs: [NSAttributedString.Key: Any]
    private let emptyStateAttrs: [NSAttributedString.Key: Any]

    public init() {
        let headerStyle = NSMutableParagraphStyle()
        headerStyle.lineHeightMultiple = 1.15
        headerStyle.paragraphSpacing = 3.0

        let bodyTightStyle = NSMutableParagraphStyle()
        bodyTightStyle.lineHeightMultiple = 1.24
        bodyTightStyle.headIndent = 10.0
        bodyTightStyle.firstLineHeadIndent = 10.0
        bodyTightStyle.paragraphSpacing = 3.0
        bodyTightStyle.baseWritingDirection = .natural
        bodyTightStyle.alignment = .natural

        let bodySoloStyle = NSMutableParagraphStyle()
        bodySoloStyle.lineHeightMultiple = 1.24
        bodySoloStyle.headIndent = 10.0
        bodySoloStyle.firstLineHeadIndent = 10.0
        bodySoloStyle.paragraphSpacing = 14.0
        bodySoloStyle.baseWritingDirection = .natural
        bodySoloStyle.alignment = .natural

        let subStyle = NSMutableParagraphStyle()
        subStyle.lineHeightMultiple = 1.18
        subStyle.headIndent = 10.0
        subStyle.firstLineHeadIndent = 10.0
        subStyle.paragraphSpacing = 14.0
        subStyle.baseWritingDirection = .natural
        subStyle.alignment = .natural

        let emptyStyle = NSMutableParagraphStyle()
        emptyStyle.lineHeightMultiple = 1.35
        emptyStyle.alignment = .center

        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let speakerFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        let transFont = NSFont.systemFont(ofSize: 14, weight: .regular)
        let origFont = NSFont.systemFont(ofSize: 12.5, weight: .regular)

        timeAttrs = [
            .font: timeFont,
            .foregroundColor: NSColor(white: 0.46, alpha: 1.0),
            .paragraphStyle: headerStyle
        ]
        callerSpeakerAttrs = [
            .font: speakerFont,
            .kern: 0.5,
            .foregroundColor: NSColor(red: 0.24, green: 0.90, blue: 0.56, alpha: 1.0),
            .paragraphStyle: headerStyle
        ]
        youSpeakerAttrs = [
            .font: speakerFont,
            .kern: 0.5,
            .foregroundColor: NSColor(red: 0.28, green: 0.84, blue: 0.98, alpha: 1.0),
            .paragraphStyle: headerStyle
        ]
        untranslatedBadgeAttrs = [
            .font: NSFont.systemFont(ofSize: 10.0, weight: .medium),
            .foregroundColor: NSColor(red: 0.96, green: 0.72, blue: 0.28, alpha: 0.90),
            .paragraphStyle: headerStyle
        ]
        transWithOrigAttrs = [
            .font: transFont,
            .kern: -0.15,
            .foregroundColor: NSColor(white: 0.96, alpha: 1.0),
            .paragraphStyle: bodyTightStyle
        ]
        transSoloAttrs = [
            .font: transFont,
            .kern: -0.15,
            .foregroundColor: NSColor(white: 0.96, alpha: 1.0),
            .paragraphStyle: bodySoloStyle
        ]
        origAttrs = [
            .font: origFont,
            .kern: -0.08,
            .foregroundColor: NSColor(red: 0.62, green: 0.66, blue: 0.74, alpha: 0.88),
            .paragraphStyle: subStyle
        ]
        emptyStateAttrs = [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor(white: 0.48, alpha: 1.0),
            .paragraphStyle: emptyStyle
        ]

        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.tr("transcript.title", "Transcript")
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0)
        super.init(window: window)
        window.delegate = self

        setupUI()
        updateContent()

        NotificationCenter.default.addObserver(self, selector: #selector(entriesUpdated(_:)), name: TranscriptManager.EntriesUpdatedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleSettingsChanged), name: AppSettings.didChangeNotification, object: nil)
    }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if needsContentRefresh {
            updateContent()
        }
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        if needsContentRefresh {
            updateContent()
        }
    }

    @objc private func handleSettingsChanged() {
        let currentShowOrig = AppSettings.shared.showOriginalText
        guard currentShowOrig != lastShowOriginalSetting else { return }
        lastShowOriginalSetting = currentShowOrig
        if window?.isVisible == true {
            updateContent()
        } else {
            needsContentRefresh = true
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func entriesUpdated(_ notification: Notification) {
        guard window?.isVisible == true else {
            needsContentRefresh = true
            return
        }

        if filterQuery.isEmpty,
           let tv = textView,
           let storage = tv.textStorage {
            if let entry = notification.userInfo?["newEntry"] as? TranscriptEntry,
               TranscriptManager.shared.entries.count > 1,
               !entryCharRanges.isEmpty {
                if entryCharRanges.count > TranscriptManager.shared.entries.count {
                    updateContent()
                    return
                }
                appendSingleEntry(entry, storage: storage, tv: tv)
                return
            }
            if let refined = notification.userInfo?["refinedEntry"] as? TranscriptEntry,
               let existingRange = entryCharRanges[refined.id],
               NSMaxRange(existingRange) <= storage.length {
                replaceSingleEntry(refined, at: existingRange, storage: storage, tv: tv)
                return
            }
        }
        updateContent()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let window = self.window else { return }

        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.wantsLayer = true
        contentView.autoresizingMask = [.width, .height]
        contentView.layer?.backgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0).cgColor

        let topBar = NSView(frame: NSRect(x: 16, y: contentView.bounds.height - 44, width: contentView.bounds.width - 32, height: 32))
        topBar.autoresizingMask = [.width, .minYMargin]

        searchField = NSSearchField(frame: NSRect(x: 0, y: 2, width: 240, height: 28))
        searchField.placeholderString = L10n.tr("transcript.search", "Search")
        searchField.setAccessibilityLabel("Search Transcript")
        searchField.font = NSFont.systemFont(ofSize: 12)
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        topBar.addSubview(searchField)

        countLabel = NSTextField(labelWithString: "0")
        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.frame = NSRect(x: topBar.bounds.width - 140, y: 6, width: 140, height: 18)
        countLabel.autoresizingMask = [.minXMargin]
        topBar.addSubview(countLabel)

        contentView.addSubview(topBar)

        let scrollView = NSScrollView(frame: NSRect(x: 16, y: 54, width: contentView.bounds.width - 32, height: contentView.bounds.height - 106))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 10
        scrollView.layer?.borderWidth = 1.0
        scrollView.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        scrollView.layer?.backgroundColor = NSColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1.0).cgColor

        let tv = NSTextView(frame: scrollView.contentView.bounds)
        tv.autoresizingMask = [.width]
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        tv.backgroundColor = NSColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1.0)
        tv.textColor = .white
        tv.textContainerInset = NSSize(width: 16, height: 16)

        scrollView.documentView = tv
        contentView.addSubview(scrollView)
        self.textView = tv

        let bottomBar = NSView(frame: NSRect(x: 16, y: 12, width: contentView.bounds.width - 32, height: 34))
        bottomBar.autoresizingMask = [.width, .maxYMargin]

        let copyBtn = NSButton(title: L10n.tr("common.copy", "Copy"), target: self, action: #selector(copyAction(_:)))
        copyBtn.frame = NSRect(x: 0, y: 2, width: 82, height: 30)
        copyBtn.bezelStyle = .rounded
        copyBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        copyBtn.setAccessibilityLabel("Copy Transcript")
        bottomBar.addSubview(copyBtn)

        let exportBtn = NSButton(title: L10n.tr("transcript.export", "Export…"), target: self, action: #selector(exportAction))
        exportBtn.frame = NSRect(x: 90, y: 2, width: 88, height: 30)
        exportBtn.bezelStyle = .rounded
        exportBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        exportBtn.setAccessibilityLabel("Export Transcript")
        bottomBar.addSubview(exportBtn)

        let clearBtn = NSButton(title: L10n.tr("common.clear", "Clear"), target: self, action: #selector(clearAction))
        clearBtn.frame = NSRect(x: 186, y: 2, width: 78, height: 30)
        clearBtn.bezelStyle = .rounded
        clearBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        clearBtn.setAccessibilityLabel("Clear Transcript")
        bottomBar.addSubview(clearBtn)

        contentView.addSubview(bottomBar)
        window.contentView = contentView
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        filterQuery = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        updateContent()
    }

    public func controlTextDidChange(_ obj: Notification) {
        filterQuery = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        updateContent()
    }

    private func formatEntry(_ entry: TranscriptEntry, showOriginalSetting: Bool) -> NSAttributedString {
        let isCaller = entry.speaker.lowercased().hasPrefix("caller")
        let primary = isCaller ? entry.translated : (entry.original.isEmpty ? entry.translated : entry.original)
        let secondary = isCaller ? entry.original : entry.translated
        let showSecondary = !entry.isUntranslated
            && showOriginalSetting
            && !secondary.isEmpty
            && secondary.lowercased() != primary.lowercased()

        let attrText = NSMutableAttributedString()
        attrText.append(NSAttributedString(string: "\(entry.formattedTime)  ", attributes: timeAttrs))
        if entry.isUntranslated {
            attrText.append(NSAttributedString(string: "\(entry.speaker.uppercased())  ", attributes: isCaller ? callerSpeakerAttrs : youSpeakerAttrs))
            attrText.append(NSAttributedString(string: "[\(L10n.tr("caption.untranslated", "Untranslated"))]\n", attributes: untranslatedBadgeAttrs))
            attrText.append(NSAttributedString(string: "\(entry.original)\n", attributes: transSoloAttrs))
        } else {
            attrText.append(NSAttributedString(string: "\(entry.speaker.uppercased())\n", attributes: isCaller ? callerSpeakerAttrs : youSpeakerAttrs))
            attrText.append(NSAttributedString(string: "\(primary)\n", attributes: showSecondary ? transWithOrigAttrs : transSoloAttrs))
            if showSecondary {
                attrText.append(NSAttributedString(string: "\(secondary)\n", attributes: origAttrs))
            }
        }
        return attrText
    }

    private func isNearBottom() -> Bool {
        guard let scrollView = textView.enclosingScrollView else { return true }
        let visible = scrollView.contentView.bounds
        let docHeight = textView.bounds.height
        return docHeight <= visible.height || visible.maxY >= docHeight - 48
    }

    private func appendSingleEntry(_ entry: TranscriptEntry, storage: NSTextStorage, tv: NSTextView) {
        let count = TranscriptManager.shared.entries.count
        countLabel?.stringValue = "\(count)"
        let shouldScroll = isNearBottom()

        let entryAttr = formatEntry(entry, showOriginalSetting: AppSettings.shared.showOriginalText)
        let startLoc = storage.length
        storage.beginEditing()
        storage.append(entryAttr)
        storage.endEditing()
        entryCharRanges[entry.id] = NSRange(location: startLoc, length: entryAttr.length)

        if let lm = tv.layoutManager, let tc = tv.textContainer {
            lm.ensureLayout(for: tc)
        }
        tv.layoutSubtreeIfNeeded()
        if shouldScroll {
            tv.scrollToEndOfDocument(nil)
        }
    }

    private func replaceSingleEntry(_ entry: TranscriptEntry, at range: NSRange, storage: NSTextStorage, tv: NSTextView) {
        let entryAttr = formatEntry(entry, showOriginalSetting: AppSettings.shared.showOriginalText)
        let delta = entryAttr.length - range.length
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: entryAttr)
        storage.endEditing()
        entryCharRanges[entry.id] = NSRange(location: range.location, length: entryAttr.length)

        if delta != 0 {
            for (id, r) in entryCharRanges where r.location > range.location {
                entryCharRanges[id] = NSRange(location: r.location + delta, length: r.length)
            }
        }
        if let lm = tv.layoutManager, let tc = tv.textContainer {
            lm.ensureLayout(for: tc)
        }
        tv.layoutSubtreeIfNeeded()
    }

    public func updateContent() {
        needsContentRefresh = false
        let allEntries = TranscriptManager.shared.entries
        guard let tv = textView else { return }
        let shouldScroll = isNearBottom()

        let entries: [TranscriptEntry]
        if filterQuery.isEmpty {
            entries = allEntries
            countLabel?.stringValue = "\(allEntries.count)"
        } else {
            entries = allEntries.filter {
                $0.translated.lowercased().contains(filterQuery) ||
                $0.original.lowercased().contains(filterQuery) ||
                $0.speaker.lowercased().contains(filterQuery)
            }
            countLabel?.stringValue = "\(entries.count) / \(allEntries.count)"
        }

        entryCharRanges.removeAll(keepingCapacity: true)

        if entries.isEmpty {
            let msg = allEntries.isEmpty
                ? "\n\n\n\(L10n.tr("transcript.empty", "No transcript"))"
                : "\n\n\n\(L10n.tr("transcript.no_results", "No results"))"
            tv.textStorage?.setAttributedString(NSAttributedString(string: msg, attributes: emptyStateAttrs))
            return
        }

        let showOrig = AppSettings.shared.showOriginalText
        let attrText = NSMutableAttributedString()
        for entry in entries {
            let formatted = formatEntry(entry, showOriginalSetting: showOrig)
            if filterQuery.isEmpty {
                entryCharRanges[entry.id] = NSRange(location: attrText.length, length: formatted.length)
            }
            attrText.append(formatted)
        }

        tv.textStorage?.setAttributedString(attrText)
        if let lm = tv.layoutManager, let tc = tv.textContainer {
            lm.ensureLayout(for: tc)
        }
        tv.layoutSubtreeIfNeeded()
        if filterQuery.isEmpty && shouldScroll {
            tv.scrollToEndOfDocument(nil)
        }
    }

    @objc private func copyAction(_ sender: NSButton) {
        TranscriptManager.shared.copyToClipboard()
        let oldTitle = sender.title
        sender.title = L10n.tr("common.copied", "Copied")
        sender.isEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            sender.title = oldTitle
            sender.isEnabled = true
        }
    }

    @objc private func exportAction() {
        let savePanel = NSSavePanel()
        savePanel.title = L10n.tr("transcript.save_title", "Save Call Transcript")
        savePanel.nameFieldStringValue = "CallCaption_Transcript_\(Int(Date().timeIntervalSince1970)).txt"
        savePanel.allowedContentTypes = [.plainText]

        if savePanel.runModal() == .OK, let url = savePanel.url {
            let text = TranscriptManager.shared.exportAsText()
            do {
                try AppPaths.writePrivateData(Data(text.utf8), to: url)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    @objc private func clearAction() {
        guard !TranscriptManager.shared.entries.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("transcript.clearConfirm.title", "Clear Transcript?")
        alert.informativeText = L10n.tr("transcript.clearConfirm.message", "This will permanently remove all caption history from the current session.")
        alert.addButton(withTitle: L10n.tr("common.clear", "Clear"))
        alert.addButton(withTitle: L10n.tr("common.cancel", "Cancel"))
        if let window = self.window {
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn {
                    CaptionCoordinator.shared.clearTranscript()
                    self?.updateContent()
                }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            CaptionCoordinator.shared.clearTranscript()
            updateContent()
        }
    }
}
