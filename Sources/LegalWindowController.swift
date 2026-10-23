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
public final class LegalWindowController: NSWindowController {
    private var segmentedControl: NSSegmentedControl!
    private var textView: NSTextView!

    public init(document: LegalDocument = .privacy) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Privacy & Terms"
        window.minSize = NSSize(width: 480, height: 380)
        window.isReleasedWhenClosed = false
        window.center()
        window.level = .normal
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0)

        super.init(window: window)
        setupUI()
        select(document: document)
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
        segmentedControl.frame = NSRect(x: 20, y: root.bounds.height - 44, width: 260, height: 28)
        segmentedControl.autoresizingMask = [.minYMargin]
        segmentedControl.setAccessibilityLabel("Legal document")
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
        tv.setAccessibilityLabel("Privacy Policy and Terms of Use")
        scrollView.documentView = tv
        root.addSubview(scrollView)
        textView = tv

        let doneButton = NSButton(title: L10n.tr("common.done", "Done"), target: self, action: #selector(closeWindow))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.frame = NSRect(x: root.bounds.width - 100, y: 16, width: 80, height: 30)
        doneButton.autoresizingMask = [.minXMargin, .maxYMargin]
        root.addSubview(doneButton)

        window.contentView = root
    }

    public func select(document: LegalDocument) {
        segmentedControl?.selectedSegment = document.rawValue
        load(document)
    }

    private func load(_ document: LegalDocument) {
        let url = Bundle.main.url(forResource: document.fileName, withExtension: "md")
            ?? Bundle.main.resourceURL?.appendingPathComponent("\(document.fileName).md")
        let text: String
        if let url, let contents = try? String(contentsOf: url, encoding: .utf8) {
            text = contents
        } else {
            text = "\(document.title)\n\nThe document could not be found in this build."
        }
        textView?.string = text
        textView?.scrollToBeginningOfDocument(nil)
        window?.title = document.title
    }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        guard let document = LegalDocument(rawValue: sender.selectedSegment) else { return }
        load(document)
    }

    @objc private func closeWindow() {
        close()
    }
}
