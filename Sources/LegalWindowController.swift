import AppKit

public enum LegalDocument: Int, Sendable {
    case privacy = 0
    case terms = 1

    var title: String {
        switch self {
        case .privacy: return L10n.tr("legal.privacyPolicy", "Privacy Policy")
        case .terms: return L10n.tr("legal.termsOfUse", "Terms of Use")
        }
    }

    var fileName: String {
        switch self {
        case .privacy: return "PRIVACY"
        case .terms: return "TERMS"
        }
    }
}
public final class LegalWindowController: NSWindowController, NSWindowDelegate {
    private var segmentedControl: NSSegmentedControl!
    private var textView: NSTextView!
    private var currentDocument: LegalDocument = .privacy
    private var lastRenderedAppLanguage: String = AppSettings.shared.appLanguageCode
    private var needsReloadOnShow = false
    private var cachedDocuments: [LegalDocument: String] = [:]

    public init(document: LegalDocument = .privacy) {
        self.currentDocument = document
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.tr("legal.title", "Privacy & Terms")
        window.minSize = NSSize(width: 480, height: 380)
        window.isReleasedWhenClosed = false
        window.center()
        window.level = .normal
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0)

        super.init(window: window)
        window.delegate = self
        setupUI()
        select(document: document)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppSettingsChanged),
            name: AppSettings.didChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public override func showWindow(_ sender: Any?) {
        flushPendingReloadIfNeeded()
        super.showWindow(sender)
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        flushPendingReloadIfNeeded()
    }

    @objc private func handleAppSettingsChanged() {
        let currentAppLang = AppSettings.shared.appLanguageCode
        guard currentAppLang != lastRenderedAppLanguage else { return }
        lastRenderedAppLanguage = currentAppLang
        guard window?.isVisible == true else {
            needsReloadOnShow = true
            return
        }
        needsReloadOnShow = false
        setupUI()
        select(document: currentDocument)
    }

    private func flushPendingReloadIfNeeded() {
        guard needsReloadOnShow else { return }
        needsReloadOnShow = false
        setupUI()
        select(document: currentDocument)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let window = self.window, let content = window.contentView else { return }

        let root = NSView(frame: content.bounds)
        root.wantsLayer = true
        root.autoresizingMask = [.width, .height]
        root.layer?.backgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0).cgColor

        segmentedControl = NSSegmentedControl(
            labels: [
                L10n.tr("legal.privacyPolicy", "Privacy Policy"),
                L10n.tr("legal.termsOfUse", "Terms of Use")
            ],
            trackingMode: .selectOne,
            target: self,
            action: #selector(segmentChanged(_:))
        )
        let segW = min(root.bounds.width - 40, max(320, ceil(segmentedControl.fittingSize.width) + 16))
        segmentedControl.frame = NSRect(x: 20, y: root.bounds.height - 44, width: segW, height: 28)
        segmentedControl.autoresizingMask = [.width, .minYMargin]
        segmentedControl.setAccessibilityLabel(L10n.tr("legal.title", "Privacy & Terms"))
        root.addSubview(segmentedControl)

        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 60, width: root.bounds.width - 40, height: root.bounds.height - 120))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        let tv = NSTextView(frame: scrollView.contentView.bounds)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = true
        tv.backgroundColor = NSColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1.0)
        tv.textColor = NSColor(white: 0.92, alpha: 1.0)
        tv.font = NSFont.systemFont(ofSize: 12.5)
        tv.textContainerInset = NSSize(width: 18, height: 16)
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.setAccessibilityLabel(L10n.tr("legal.title", "Privacy & Terms"))
        scrollView.documentView = tv
        root.addSubview(scrollView)
        textView = tv

        let doneButton = NSButton(title: L10n.tr("common.done", "Done"), target: self, action: #selector(closeWindow))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        let doneW = max(80, ceil(doneButton.fittingSize.width) + 16)
        doneButton.frame = NSRect(x: root.bounds.width - 20 - doneW, y: 16, width: doneW, height: 30)
        doneButton.autoresizingMask = [.minXMargin, .maxYMargin]
        root.addSubview(doneButton)

        window.contentView = root
    }

    public func select(document: LegalDocument) {
        if needsReloadOnShow {
            needsReloadOnShow = false
            setupUI()
        }
        currentDocument = document
        segmentedControl?.selectedSegment = document.rawValue
        load(document)
    }

    private func load(_ document: LegalDocument) {
        let text: String
        if let cached = cachedDocuments[document] {
            text = cached
        } else {
            let url = Bundle.main.url(forResource: document.fileName, withExtension: "md")
                ?? Bundle.main.resourceURL?.appendingPathComponent("\(document.fileName).md")
            if let url, let contents = try? String(contentsOf: url, encoding: .utf8) {
                cachedDocuments[document] = contents
                text = contents
            } else {
                text = "\(document.title)\n\n\(L10n.tr("legal.notFound", "The document could not be found in this build."))"
            }
        }
        textView?.string = text
        textView?.scrollToBeginningOfDocument(nil)
        window?.title = document.title
    }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        guard let document = LegalDocument(rawValue: sender.selectedSegment) else { return }
        select(document: document)
    }

    @objc private func closeWindow() {
        close()
    }
}
