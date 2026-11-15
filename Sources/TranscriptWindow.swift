import AppKit
import os

private final class TranscriptDelayTaskBox: Sendable {
    private struct Entry: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let activeEntry = OSAllocatedUnfairLock<Entry?>(initialState: nil)

    @MainActor
    func schedule(delayNanoseconds: UInt64, operation: @escaping @MainActor @Sendable () -> Void) {
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            let stillActive = self?.activeEntry.withLock { entry -> Bool in
                guard entry?.id == id else { return false }
                entry = nil
                return true
            } ?? false
            guard stillActive else { return }
            operation()
        }
        let previous = activeEntry.withLock { entry -> Task<Void, Never>? in
            let prev = entry?.task
            entry = Entry(id: id, task: task)
            return prev
        }
        previous?.cancel()
    }

    func cancel() {
        let previous = activeEntry.withLock { entry -> Task<Void, Never>? in
            let prev = entry?.task
            entry = nil
            return prev
        }
        previous?.cancel()
    }
}

public final class TranscriptWindowController: NSWindowController, NSSearchFieldDelegate, NSWindowDelegate {
    private var textView: NSTextView!
    private var countLabel: NSTextField!
    private var searchField: NSSearchField!
    private var filterQuery: String = ""
    private var needsContentRefresh: Bool = true
    private var needsUIRebuild: Bool = false
    private var lastShowOriginalSetting: Bool = AppSettings.shared.showOriginalText
    private var lastRenderedAppLanguage: String = AppSettings.shared.appLanguageCode
    private var cachedUntranslatedBadge: String = "[\(L10n.tr("caption.untranslated", "Untranslated"))]\n"
    private var entryCharRanges: [UUID: NSRange] = [:]
    private var entryOrder: [UUID] = []
    private var trimmedPrefixLength: Int = 0
    private var lastKnownFirstAllEntryID: UUID?
    private let searchDebounceBox = TranscriptDelayTaskBox()
    private let copyResetBox = TranscriptDelayTaskBox()

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
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.tr("transcript.title", "Transcript")
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0)
        window.center()
        super.init(window: window)
        window.delegate = self

        setupUI()
        needsContentRefresh = true

        NotificationCenter.default.addObserver(self, selector: #selector(entriesUpdated(_:)), name: TranscriptManager.EntriesUpdatedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleSettingsChanged), name: AppSettings.didChangeNotification, object: nil)
    }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        flushPendingUpdatesIfNeeded()
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        flushPendingUpdatesIfNeeded()
    }

    public func windowWillClose(_ notification: Notification) {
        searchDebounceBox.cancel()
        if let sf = searchField {
            filterQuery = sf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        entryOrder.removeAll(keepingCapacity: false)
        entryCharRanges.removeAll(keepingCapacity: false)
        trimmedPrefixLength = 0
        lastKnownFirstAllEntryID = nil
        if let storage = textView?.textStorage, storage.length > 0 {
            storage.beginEditing()
            storage.setAttributedString(NSAttributedString())
            storage.endEditing()
        }
        needsContentRefresh = true
    }

    private func flushPendingUpdatesIfNeeded() {
        if needsUIRebuild {
            needsUIRebuild = false
            setupUI()
            searchField?.stringValue = filterQuery
            needsContentRefresh = true
        }
        if needsContentRefresh {
            updateContent()
        }
    }

    @objc private func handleSettingsChanged() {
        let currentAppLang = AppSettings.shared.appLanguageCode
        let appLangChanged = (currentAppLang != lastRenderedAppLanguage)
        let currentShowOrig = AppSettings.shared.showOriginalText
        let showOrigChanged = (currentShowOrig != lastShowOriginalSetting)

        if appLangChanged {
            lastRenderedAppLanguage = currentAppLang
            lastShowOriginalSetting = currentShowOrig
            cachedUntranslatedBadge = "[\(L10n.tr("caption.untranslated", "Untranslated"))]\n"
            window?.title = L10n.tr("transcript.title", "Transcript")
            if window?.isVisible == true {
                needsUIRebuild = false
                setupUI()
                searchField?.stringValue = filterQuery
                updateContent()
            } else {
                needsUIRebuild = true
                needsContentRefresh = true
            }
            return
        }

        guard showOrigChanged else { return }
        lastShowOriginalSetting = currentShowOrig
        if window?.isVisible == true {
            updateContent()
        } else {
            needsContentRefresh = true
        }
    }

    deinit {
        searchDebounceBox.cancel()
        copyResetBox.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func entriesUpdated(_ notification: Notification) {
        guard window?.isVisible == true else {
            needsContentRefresh = true
            return
        }

        let allEntries = TranscriptManager.shared.entries
        if allEntries.isEmpty {
            updateContent()
            return
        }

        guard let tv = textView, let storage = tv.textStorage else {
            updateContent()
            return
        }

        if let entry = notification.userInfo?["newEntry"] as? TranscriptEntry {
            if entryOrder.isEmpty {
                if filterQuery.isEmpty || entryMatchesFilter(entry, query: filterQuery) {
                    updateContent()
                } else {
                    lastKnownFirstAllEntryID = allEntries.first?.id
                    countLabel?.stringValue = "0 / \(allEntries.count)"
                }
                return
            }

            let newFirstID = allEntries.first?.id
            if filterQuery.isEmpty {
                var dropCount = 0
                if let prevFirst = lastKnownFirstAllEntryID, prevFirst != newFirstID {
                    if let newFirstID = newFirstID, let foundIdx = entryOrder.firstIndex(of: newFirstID) {
                        dropCount = foundIdx
                    } else {
                        updateContent()
                        return
                    }
                }
                lastKnownFirstAllEntryID = newFirstID
                appendSingleEntry(
                    entry,
                    allCount: allEntries.count,
                    dropLeadingCount: dropCount,
                    storage: storage,
                    tv: tv,
                    shouldAutoScroll: true
                )
                return
            } else {
                if let prevFirst = lastKnownFirstAllEntryID,
                   prevFirst != newFirstID {
                    if entryCharRanges[prevFirst] != nil ||
                        (entryOrder.first.map { firstID in !allEntries.contains(where: { $0.id == firstID }) } ?? false) {
                        updateContent()
                        return
                    }
                }
                lastKnownFirstAllEntryID = newFirstID
                if !entryMatchesFilter(entry, query: filterQuery) {
                    countLabel?.stringValue = "\(entryOrder.count) / \(allEntries.count)"
                    return
                }
                appendSingleEntry(
                    entry,
                    allCount: allEntries.count,
                    dropLeadingCount: 0,
                    storage: storage,
                    tv: tv,
                    shouldAutoScroll: false
                )
                return
            }
        }

        if let refined = notification.userInfo?["refinedEntry"] as? TranscriptEntry {
            let matches = filterQuery.isEmpty || entryMatchesFilter(refined, query: filterQuery)
            if let existingRange = storageRange(for: refined.id),
               NSMaxRange(existingRange) <= storage.length {
                if matches {
                    replaceSingleEntry(refined, at: existingRange, storage: storage)
                } else {
                    updateContent()
                }
                return
            } else if !filterQuery.isEmpty && !matches {
                return
            }
        }

        updateContent()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let window = self.window,
              let contentBounds = window.contentView?.bounds else { return }

        let contentView = NSView(frame: contentBounds)
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
        tv.layoutManager?.allowsNonContiguousLayout = true

        scrollView.documentView = tv
        contentView.addSubview(scrollView)
        self.textView = tv

        let bottomBar = NSView(frame: NSRect(x: 16, y: 12, width: contentView.bounds.width - 32, height: 34))
        bottomBar.autoresizingMask = [.width, .maxYMargin]

        let copyTitle = L10n.tr("common.copy", "Copy")
        let copyBtn = NSButton(title: copyTitle, target: self, action: #selector(copyAction(_:)))
        copyBtn.frame = NSRect(x: 0, y: 2, width: 84, height: 30)
        copyBtn.bezelStyle = .rounded
        copyBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        copyBtn.setAccessibilityLabel(copyTitle)
        bottomBar.addSubview(copyBtn)

        let exportTitle = L10n.tr("transcript.export", "Export…")
        let exportBtn = NSButton(title: exportTitle, target: self, action: #selector(exportAction))
        exportBtn.frame = NSRect(x: 92, y: 2, width: 94, height: 30)
        exportBtn.bezelStyle = .rounded
        exportBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        exportBtn.setAccessibilityLabel(exportTitle)
        bottomBar.addSubview(exportBtn)

        let clearTitle = L10n.tr("common.clear", "Clear")
        let clearBtn = NSButton(title: clearTitle, target: self, action: #selector(clearAction))
        clearBtn.frame = NSRect(x: 194, y: 2, width: 84, height: 30)
        clearBtn.bezelStyle = .rounded
        clearBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        clearBtn.setAccessibilityLabel(clearTitle)
        bottomBar.addSubview(clearBtn)

        contentView.addSubview(bottomBar)
        window.contentView = contentView
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        searchDebounceBox.cancel()
        let query = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != filterQuery else { return }
        filterQuery = query
        updateContent()
    }

    public func controlTextDidChange(_ obj: Notification) {
        let pendingQuery = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if pendingQuery == filterQuery {
            searchDebounceBox.cancel()
            return
        }
        searchDebounceBox.schedule(delayNanoseconds: 150_000_000) { [weak self] in
            guard let self = self else { return }
            let latestQuery = self.searchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard latestQuery != self.filterQuery else { return }
            self.filterQuery = latestQuery
            self.updateContent()
        }
    }

    private func entryMatchesFilter(_ entry: TranscriptEntry, query: String) -> Bool {
        entry.translated.range(of: query, options: .caseInsensitive) != nil
            || entry.original.range(of: query, options: .caseInsensitive) != nil
            || entry.speaker.range(of: query, options: .caseInsensitive) != nil
    }

    private func storageRange(for id: UUID) -> NSRange? {
        guard let raw = entryCharRanges[id], raw.location >= trimmedPrefixLength else { return nil }
        return NSRange(location: raw.location - trimmedPrefixLength, length: raw.length)
    }

    private func formatEntry(_ entry: TranscriptEntry, showOriginalSetting: Bool) -> NSAttributedString {
        let isCaller = entry.speaker.range(of: "caller", options: [.caseInsensitive, .anchored]) != nil
        let speakerLabel = isCaller
            ? "CALLER"
            : (entry.speaker.caseInsensitiveCompare("you") == .orderedSame ? "YOU" : entry.speaker.uppercased())
        let primary = isCaller ? entry.translated : (entry.original.isEmpty ? entry.translated : entry.original)
        let secondary = isCaller ? entry.original : entry.translated
        let showSecondary = !entry.isUntranslated
            && showOriginalSetting
            && !secondary.isEmpty
            && secondary.caseInsensitiveCompare(primary) != .orderedSame

        let attrText = NSMutableAttributedString()
        attrText.append(NSAttributedString(string: "\(entry.formattedTime)  ", attributes: timeAttrs))
        if entry.isUntranslated {
            attrText.append(NSAttributedString(string: "\(speakerLabel)  ", attributes: isCaller ? callerSpeakerAttrs : youSpeakerAttrs))
            attrText.append(NSAttributedString(string: cachedUntranslatedBadge, attributes: untranslatedBadgeAttrs))
            attrText.append(NSAttributedString(string: "\(entry.original)\n", attributes: transSoloAttrs))
        } else {
            attrText.append(NSAttributedString(string: "\(speakerLabel)\n", attributes: isCaller ? callerSpeakerAttrs : youSpeakerAttrs))
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

    private func scrollToTail(tv: NSTextView, storageLength: Int) {
        guard storageLength > 0 else { return }
        let tailLoc = max(0, storageLength - 1)
        let tailRange = NSRange(location: tailLoc, length: storageLength - tailLoc)
        tv.layoutManager?.ensureLayout(forCharacterRange: tailRange)
        tv.scrollToEndOfDocument(nil)
    }

    private func appendSingleEntry(
        _ entry: TranscriptEntry,
        allCount: Int,
        dropLeadingCount: Int,
        storage: NSTextStorage,
        tv: NSTextView,
        shouldAutoScroll: Bool
    ) {
        let shouldScroll = shouldAutoScroll && isNearBottom()
        let entryAttr = formatEntry(entry, showOriginalSetting: AppSettings.shared.showOriginalText)

        storage.beginEditing()
        if dropLeadingCount > 0 && dropLeadingCount <= entryOrder.count {
            let dropEndVirtualLoc: Int
            if dropLeadingCount < entryOrder.count,
               let nextRange = entryCharRanges[entryOrder[dropLeadingCount]] {
                dropEndVirtualLoc = nextRange.location
            } else {
                dropEndVirtualLoc = trimmedPrefixLength + storage.length
            }
            let dropLength = min(max(0, dropEndVirtualLoc - trimmedPrefixLength), storage.length)
            for idx in 0..<dropLeadingCount {
                entryCharRanges.removeValue(forKey: entryOrder[idx])
            }
            entryOrder.removeFirst(dropLeadingCount)
            if dropLength > 0 {
                storage.replaceCharacters(in: NSRange(location: 0, length: dropLength), with: "")
                trimmedPrefixLength += dropLength
            }
        }
        let startStorageLoc = storage.length
        storage.append(entryAttr)
        storage.endEditing()

        entryOrder.append(entry.id)
        entryCharRanges[entry.id] = NSRange(location: trimmedPrefixLength + startStorageLoc, length: entryAttr.length)
        countLabel?.stringValue = filterQuery.isEmpty ? "\(allCount)" : "\(entryOrder.count) / \(allCount)"

        if shouldScroll {
            scrollToTail(tv: tv, storageLength: storage.length)
        }
    }

    private func replaceSingleEntry(_ entry: TranscriptEntry, at range: NSRange, storage: NSTextStorage) {
        let shouldScroll = isNearBottom()
        let entryAttr = formatEntry(entry, showOriginalSetting: AppSettings.shared.showOriginalText)
        let delta = entryAttr.length - range.length
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: entryAttr)
        storage.endEditing()

        let virtualLocation = trimmedPrefixLength + range.location
        entryCharRanges[entry.id] = NSRange(location: virtualLocation, length: entryAttr.length)

        if delta != 0 {
            if let pos = entryOrder.lastIndex(of: entry.id) {
                let nextStart = entryOrder.index(after: pos)
                for id in entryOrder[nextStart...] {
                    if let r = entryCharRanges[id] {
                        entryCharRanges[id] = NSRange(location: r.location + delta, length: r.length)
                    }
                }
            } else {
                for (id, r) in entryCharRanges where r.location > virtualLocation {
                    entryCharRanges[id] = NSRange(location: r.location + delta, length: r.length)
                }
            }
        }
        if shouldScroll, let tv = textView {
            scrollToTail(tv: tv, storageLength: storage.length)
        }
    }

    public func updateContent() {
        needsContentRefresh = false
        let allEntries = TranscriptManager.shared.entries
        lastKnownFirstAllEntryID = allEntries.first?.id
        guard let tv = textView, let storage = tv.textStorage else { return }
        let shouldScroll = isNearBottom()

        let entries: [TranscriptEntry]
        if filterQuery.isEmpty {
            entries = allEntries
            countLabel?.stringValue = "\(allEntries.count)"
        } else {
            entries = allEntries.filter { entryMatchesFilter($0, query: filterQuery) }
            countLabel?.stringValue = "\(entries.count) / \(allEntries.count)"
        }

        trimmedPrefixLength = 0
        entryOrder.removeAll(keepingCapacity: true)
        entryCharRanges.removeAll(keepingCapacity: true)

        if entries.isEmpty {
            let msg = allEntries.isEmpty
                ? "\n\n\n\(L10n.tr("transcript.empty", "No transcript"))"
                : "\n\n\n\(L10n.tr("transcript.no_results", "No results"))"
            storage.beginEditing()
            storage.setAttributedString(NSAttributedString(string: msg, attributes: emptyStateAttrs))
            storage.endEditing()
            return
        }

        let showOrig = AppSettings.shared.showOriginalText
        let attrText = NSMutableAttributedString()
        entryOrder.reserveCapacity(entries.count)
        for entry in entries {
            let formatted = formatEntry(entry, showOriginalSetting: showOrig)
            entryOrder.append(entry.id)
            entryCharRanges[entry.id] = NSRange(location: attrText.length, length: formatted.length)
            attrText.append(formatted)
        }

        storage.beginEditing()
        storage.setAttributedString(attrText)
        storage.endEditing()

        if filterQuery.isEmpty && shouldScroll && storage.length > 0 {
            scrollToTail(tv: tv, storageLength: storage.length)
        }
    }

    @objc private func copyAction(_ sender: NSButton) {
        TranscriptManager.shared.copyToClipboard()
        sender.title = L10n.tr("common.copied", "Copied")
        sender.isEnabled = false
        copyResetBox.schedule(delayNanoseconds: 1_200_000_000) { [weak sender] in
            guard let sender = sender else { return }
            sender.title = L10n.tr("common.copy", "Copy")
            sender.isEnabled = true
        }
    }

    private func writeExportFile(to url: URL, alertHostWindow: NSWindow?) {
        let text = TranscriptManager.shared.exportAsText()
        do {
            try AppPaths.writePrivateData(Data(text.utf8), to: url)
        } catch {
            let alert = NSAlert(error: error)
            if let hostWindow = alertHostWindow {
                alert.beginSheetModal(for: hostWindow, completionHandler: nil)
            } else {
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    @objc private func exportAction() {
        let savePanel = NSSavePanel()
        savePanel.title = L10n.tr("transcript.save_title", "Save Call Transcript")
        savePanel.nameFieldStringValue = "CallCaption_Transcript_\(Int(Date().timeIntervalSince1970)).txt"
        savePanel.allowedContentTypes = [.plainText]

        if let window = self.window {
            savePanel.beginSheetModal(for: window) { [weak self, weak savePanel] response in
                guard response == .OK, let url = savePanel?.url else { return }
                savePanel?.orderOut(nil)
                self?.writeExportFile(to: url, alertHostWindow: self?.window)
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            if savePanel.runModal() == .OK, let url = savePanel.url {
                writeExportFile(to: url, alertHostWindow: nil)
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
        } else {
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                CaptionCoordinator.shared.clearTranscript()
                updateContent()
            }
        }
    }
}
