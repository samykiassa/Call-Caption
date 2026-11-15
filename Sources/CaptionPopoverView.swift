import SwiftUI

public struct CaptionPopoverView: View {
    public let viewModel: CaptionViewModel
    public let onQuit: () -> Void

    public init(viewModel: CaptionViewModel, onQuit: @escaping () -> Void = { NSApp.terminate(nil) }) {
        self.viewModel = viewModel
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().opacity(0.25)
            controlsBar
            if viewModel.isSharing || viewModel.showShareOptions {
                liveShareBar
                Divider().opacity(0.25)
            }
            if let alert = viewModel.alertMessage {
                alertBar(message: alert)
                Divider().opacity(0.25)
            }
            captionFeed
            Divider().opacity(0.25)
            footerBar
        }
        .frame(width: 430, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 8, height: 8)

            Text("Call Caption")
                .font(.system(size: 13, weight: .semibold))

            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                viewModel.setShowOriginalText(!viewModel.showOriginalText)
            } label: {
                Image(systemName: "doc.plaintext")
                    .font(.system(size: 12))
                    .foregroundStyle(viewModel.showOriginalText ? .primary : .secondary)
            }
            .buttonStyle(.borderless)
            .help(viewModel.showOriginalText ? "Hide original text" : "Show original text")

            Button {
                viewModel.togglePauseResume()
            } label: {
                Image(systemName: viewModel.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(viewModel.isPaused ? Color.orange : .primary)
            }
            .buttonStyle(.borderless)
            .help(viewModel.isPaused ? "Resume captions" : "Pause captions")

            Button {
                viewModel.setPinned(!viewModel.isPinned)
            } label: {
                Image(systemName: viewModel.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 12))
                    .foregroundStyle(viewModel.isPinned ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help(viewModel.isPinned ? "Unpin popover" : "Pin popover open")

            Button {
                viewModel.toggleSharing()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: viewModel.isSharing ? "dot.radiowaves.left.and.right" : "link")
                        .font(.system(size: 11, weight: .medium))
                    Text(viewModel.isSharing ? "Sharing" : "Share")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(viewModel.isSharing ? Color.accentColor.opacity(0.22) : Color.white.opacity(0.08))
                .foregroundStyle(viewModel.isSharing ? Color.accentColor : .primary)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(viewModel.isSharing ? "Stop live transcription link" : "Share live transcription link with caller")

            Button {
                viewModel.showShareOptions.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11))
                    .foregroundStyle(viewModel.showShareOptions ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help("Live link options")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var controlsBar: some View {
        VStack(spacing: 8) {
            Picker("Mode", selection: Binding(
                get: { viewModel.isConversationalMode },
                set: { viewModel.setConversationalMode($0) }
            )) {
                Text("System Audio Only").tag(false)
                Text("Conversational (System + Mic)").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 6) {
                languageMenu(
                    title: "Caller",
                    level: viewModel.isPaused ? 0 : viewModel.callerLevel,
                    tint: .blue,
                    selection: Binding(
                        get: { viewModel.callerLanguageCode },
                        set: { viewModel.setCallerLanguage($0) }
                    )
                )

                Button {
                    viewModel.swapLanguages()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Swap languages")

                languageMenu(
                    title: "Mine",
                    level: (viewModel.isPaused || !viewModel.isConversationalMode) ? 0 : viewModel.micLevel,
                    tint: .green,
                    selection: Binding(
                        get: { viewModel.myLanguageCode },
                        set: { viewModel.setMyLanguage($0) }
                    )
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.03))
    }

    private func languageMenu(
        title: String,
        level: Float,
        tint: Color,
        selection: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle()
                    .fill(level > 0.04 ? tint : Color.gray.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Picker(title, selection: selection) {
                ForEach(SupportedLanguages.all) { item in
                    Text(item.displayName).tag(item.code)
                }
            }
            .labelsHidden()
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var liveShareBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch viewModel.shareStatus {
            case .off:
                Text("Live Link Options")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

            case .startingLocal:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Starting local live link server…")
                        .font(.system(size: 11))
                    Spacer()
                    Button("Stop") { viewModel.toggleSharing() }
                        .controlSize(.small)
                }

            case .connectingTunnel(let localURL, let statusText):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(statusText)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Spacer()
                    if let localURL {
                        copyURLButton(localURL, label: "Local")
                    }
                    Button("Stop") { viewModel.toggleSharing() }
                        .controlSize(.small)
                }

            case .ready(let primaryURL, _, let isPublic, let viewers):
                HStack(spacing: 6) {
                    Image(systemName: isPublic ? "lock.fill" : "network")
                        .font(.system(size: 11))
                        .foregroundStyle(isPublic ? .green : .blue)
                    Text(primaryURL.absoluteString)
                        .font(.system(size: 10.5, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    if viewers > 0 {
                        Text("\(viewers)")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.2))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                            .help("\(viewers) active viewer(s)")
                    }
                    copyURLButton(primaryURL, label: viewModel.copiedLinkFeedback ? "Copied" : "Copy")
                }

            case .failed(let localURL, let errorText):
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 11))
                    Text(errorText)
                        .font(.system(size: 11))
                        .lineLimit(2)
                    Spacer()
                    if let localURL {
                        copyURLButton(localURL, label: "Local")
                    }
                    Button("Retry") { viewModel.retryTunnel() }
                        .controlSize(.small)
                }
            }

            if viewModel.showShareOptions || !viewModel.isSharing {
                HStack(spacing: 12) {
                    Toggle("Public Tunnel", isOn: Binding(
                        get: { viewModel.shareUseTunnel },
                        set: { viewModel.setShareOptions(useTunnel: $0) }
                    ))
                    Toggle("LAN", isOn: Binding(
                        get: { viewModel.shareAllowLAN },
                        set: { viewModel.setShareOptions(allowLAN: $0) }
                    ))
                    Toggle("Both Speakers", isOn: Binding(
                        get: { viewModel.shareBothSpeakers },
                        set: { viewModel.setShareOptions(bothSpeakers: $0) }
                    ))
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
    }

    private func copyURLButton(_ url: URL, label: String) -> some View {
        Button(label) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            viewModel.copiedLinkFeedback = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                viewModel.copiedLinkFeedback = false
            }
        }
        .controlSize(.small)
    }

    private func alertBar(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
            Text(message)
                .font(.system(size: 11))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle = viewModel.alertAction.actionButtonTitle {
                Button(actionTitle) {
                    viewModel.openAlertSettings()
                }
                .controlSize(.small)
            }
            Button {
                viewModel.dismissAlert()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.14))
    }

    private var captionFeed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if viewModel.entries.isEmpty {
                    emptyState
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.entries) { entry in
                            captionRow(entry)
                                .id(entry.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("BOTTOM_ANCHOR")
                    }
                    .padding(12)
                }
            }
            .onChange(of: viewModel.entries.last?.translated) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("BOTTOM_ANCHOR", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.entries.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("BOTTOM_ANCHOR", anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 90)
            Image(systemName: viewModel.isPaused ? "pause.circle" : "waveform")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(viewModel.isPaused
                 ? "Captions are paused"
                 : (viewModel.isConversationalMode
                    ? "Listening to system audio & microphone…"
                    : "Listening to system audio…"))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Start a call or play speech on your Mac.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func captionRow(_ entry: CaptionEntry) -> some View {
        let isCaller = entry.speaker.caseInsensitiveCompare("caller") == .orderedSame
        let targetRTL = SupportedLanguages.isRTL(languageCode: entry.targetLangCode)
        let sourceRTL = SupportedLanguages.isRTL(languageCode: entry.sourceLangCode)
        let sameText = entry.original.caseInsensitiveCompare(entry.translated) == .orderedSame

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(isCaller ? "CALLER" : "YOU")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(isCaller ? Color.blue : Color.green)

                if !entry.isFinal {
                    Text("live")
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.08))
                        .foregroundStyle(.secondary)
                        .clipShape(Capsule())
                }

                if entry.isUntranslated && entry.sourceLangCode != entry.targetLangCode {
                    Text("untranslated")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }

                Spacer()

                Text(entry.timestamp, style: .time)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Text(entry.translated)
                .font(.system(size: 13.5))
                .foregroundStyle(entry.isFinal ? .primary : .secondary)
                .multilineTextAlignment(targetRTL ? .trailing : .leading)
                .frame(maxWidth: .infinity, alignment: targetRTL ? .trailing : .leading)
                .environment(\.layoutDirection, targetRTL ? .rightToLeft : .leftToRight)
                .textSelection(.enabled)

            if viewModel.showOriginalText && !sameText {
                Text(entry.original)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(sourceRTL ? .trailing : .leading)
                    .frame(maxWidth: .infinity, alignment: sourceRTL ? .trailing : .leading)
                    .environment(\.layoutDirection, sourceRTL ? .rightToLeft : .leftToRight)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isCaller ? Color.white.opacity(0.05) : Color.green.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var footerBar: some View {
        HStack(spacing: 8) {
            levelBar(label: "Sys", value: viewModel.isPaused ? 0 : viewModel.callerLevel, color: .blue)
            if viewModel.isConversationalMode {
                levelBar(label: "Mic", value: viewModel.isPaused ? 0 : viewModel.micLevel, color: .green)
            }

            Spacer()

            Button(viewModel.copiedTranscriptFeedback ? "Copied" : "Copy") {
                if !viewModel.copyTranscript().isEmpty {
                    viewModel.copiedTranscriptFeedback = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        viewModel.copiedTranscriptFeedback = false
                    }
                }
            }
            .controlSize(.small)
            .disabled(viewModel.entries.isEmpty)

            Button("Clear") {
                viewModel.clearTranscript()
            }
            .controlSize(.small)
            .disabled(viewModel.entries.isEmpty)

            Button("Quit") {
                onQuit()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func levelBar(label: String, value: Float, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule()
                        .fill(color)
                        .frame(width: max(2, geo.size.width * CGFloat(min(1, max(0, value * 3.5)))))
                }
            }
            .frame(width: 38, height: 5)
        }
    }

    private var statusDotColor: Color {
        if viewModel.isSharing { return .green }
        if viewModel.isPaused { return .orange }
        return .blue
    }

    private var statusText: String {
        if viewModel.isPaused { return "Paused" }
        if viewModel.isSharing { return "Live Link" }
        return viewModel.isConversationalMode ? "Conversation" : "Listening"
    }
}
