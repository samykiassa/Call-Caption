import SwiftUI
import AppKit

@MainActor
@Observable
final class SurfaceVisibilityState {
    var isVisible: Bool

    init(isVisible: Bool = true) {
        self.isVisible = isVisible
    }
}

@MainActor
private final class WeakWindowBox {
    weak var window: NSWindow?
}

private struct FeedLayoutAnchorTrigger: Equatable, Sendable {
    let showLiveShareBar: Bool
    let hasAlert: Bool
    let isCompactHUD: Bool
    let showOriginalText: Bool
    let captionFontSize: Double
}

struct CaptionPopoverView: View {
    let viewModel: CaptionViewModel
    let isDetached: Bool
    let onToggleDetach: (() -> Void)?
    let onQuit: () -> Void
    private let surfaceVisibility: SurfaceVisibilityState?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.colorScheme) private var colorScheme

    private var _showClearConfirmation = State(wrappedValue: false)
    private var _hoverResetToken = State(wrappedValue: 0)
    private var _hostWindowBox = State(wrappedValue: WeakWindowBox())

    private var showClearConfirmation: Bool {
        get { _showClearConfirmation.wrappedValue }
        nonmutating set { _showClearConfirmation.wrappedValue = newValue }
    }
    private var hoverResetToken: Int {
        get { _hoverResetToken.wrappedValue }
        nonmutating set { _hoverResetToken.wrappedValue = newValue }
    }

    init(
        viewModel: CaptionViewModel,
        isDetached: Bool = false,
        onToggleDetach: (() -> Void)? = nil,
        onQuit: @escaping () -> Void = { NSApp.terminate(nil) },
        surfaceVisibility: SurfaceVisibilityState? = nil
    ) {
        self.viewModel = viewModel
        self.isDetached = isDetached
        self.onToggleDetach = onToggleDetach
        self.onQuit = onQuit
        self.surfaceVisibility = surfaceVisibility
    }

    private var showLiveShareBar: Bool {
        viewModel.isSharing || viewModel.showShareOptions || viewModel.shareStatus != .off
    }

    private var preferredColorScheme: ColorScheme? {
        switch viewModel.appearanceMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var body: some View {
        if let surfaceVisibility, !surfaceVisibility.isVisible {
            Color.clear
                .frame(width: isDetached ? nil : 430, height: isDetached ? nil : 540)
        } else {
            mainContent
        }
    }

    private var mainContent: some View {
        let isCompactHUD = isDetached && viewModel.isCompactFloatingHUD
        return VStack(spacing: 0) {
            HeaderBarView(
                viewModel: viewModel,
                isDetached: isDetached,
                reduceMotion: reduceMotion,
                increasedContrast: colorSchemeContrast == .increased,
                onToggleDetach: onToggleDetach,
                onQuit: onQuit
            )
            if !isCompactHUD {
                CaptionSectionDivider(increasedContrast: colorSchemeContrast == .increased, colorScheme: colorScheme)
                ControlsBarView(
                    viewModel: viewModel,
                    reduceMotion: reduceMotion,
                    reduceTransparency: reduceTransparency,
                    increasedContrast: colorSchemeContrast == .increased
                )
            }
            OptionalBannersView(
                viewModel: viewModel,
                reduceMotion: reduceMotion,
                reduceTransparency: reduceTransparency,
                increasedContrast: colorSchemeContrast == .increased
            )
            CaptionSectionDivider(increasedContrast: colorSchemeContrast == .increased, colorScheme: colorScheme)
            CaptionFeedView(
                viewModel: viewModel,
                isDetached: isDetached,
                reduceMotion: reduceMotion,
                reduceTransparency: reduceTransparency,
                increasedContrast: colorSchemeContrast == .increased,
                hoverResetToken: hoverResetToken,
                layoutAnchorTrigger: FeedLayoutAnchorTrigger(
                    showLiveShareBar: showLiveShareBar,
                    hasAlert: viewModel.alertMessage != nil,
                    isCompactHUD: isCompactHUD,
                    showOriginalText: viewModel.showOriginalText,
                    captionFontSize: viewModel.captionFontSize
                )
            )
            if !isCompactHUD {
                CaptionSectionDivider(increasedContrast: colorSchemeContrast == .increased, colorScheme: colorScheme)
                FooterBarView(
                    viewModel: viewModel,
                    reduceMotion: reduceMotion,
                    increasedContrast: colorSchemeContrast == .increased,
                    showClearConfirmation: _showClearConfirmation.projectedValue
                )
            }
        }
        .ignoresSafeArea(.container, edges: isDetached ? .top : [])
        .frame(
            minWidth: isDetached ? 360 : 430,
            idealWidth: 430,
            maxWidth: isDetached ? .infinity : 430,
            minHeight: isDetached ? (isCompactHUD ? 180 : 300) : 540,
            idealHeight: 540,
            maxHeight: isDetached ? .infinity : 540
        )
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Color.clear
            }
        }
        .background(keyboardShortcutsBridge)
        .background(
            HostWindowAccessor { window in
                let box = _hostWindowBox.wrappedValue
                if box.window !== window {
                    box.window = window
                }
            }
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        )
        .preferredColorScheme(preferredColorScheme)
        .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: showLiveShareBar)
        .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: viewModel.alertMessage != nil)
        .animation(reduceMotion ? nil : .snappy(duration: 0.20), value: isCompactHUD)
        .onChange(of: viewModel.alertMessage) { oldValue, newValue in
            if let newValue, !newValue.isEmpty, newValue != oldValue {
                CaptionCoordinator.postAccessibilityAnnouncement(newValue)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.willCloseNotification)) { _ in
            hoverResetToken &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let closingWindow = notification.object as? NSWindow,
               let hostWindow = _hostWindowBox.wrappedValue.window,
               closingWindow === hostWindow {
                hoverResetToken &+= 1
            }
        }
        .confirmationDialog(
            AppL10n.string("footer.clear.confirm_title", fallback: "Clear Transcript?"),
            isPresented: _showClearConfirmation.projectedValue,
            titleVisibility: .visible
        ) {
            Button(AppL10n.string("footer.clear.confirm_action", fallback: "Clear Transcript"), role: .destructive) {
                viewModel.clearTranscript()
            }
            Button(AppL10n.string("footer.cancel", fallback: "Cancel"), role: .cancel) {}
        } message: {
            Text(
                viewModel.isSharing
                    ? AppL10n.string(
                        "footer.clear.confirm_sharing",
                        fallback: "This removes all captions from this window and clears Live Link history for connected viewers."
                    )
                    : AppL10n.string(
                        "footer.clear.confirm_local",
                        fallback: "This removes all captions from this window."
                    )
            )
        }
    }

    // MARK: - Keyboard Shortcuts Bridge

    private var keyboardShortcutsBridge: some View {
        Group {
            Button(AppL10n.string("menu.conversational_mode", fallback: "Conversational Mode")) {
                viewModel.setConversationalMode(!viewModel.isConversationalMode)
            }
            .keyboardShortcut("m", modifiers: .command)
            Button(AppL10n.string("menu.show_original", fallback: "Show Original Text")) {
                viewModel.setShowOriginalText(!viewModel.showOriginalText)
            }
            .keyboardShortcut("o", modifiers: .command)
            Button(AppL10n.string("menu.copy_transcript", fallback: "Copy Transcript")) {
                _ = viewModel.copyTranscript()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            Button(AppL10n.string("menu.text_larger", fallback: "Larger Text")) {
                viewModel.increaseFontSize()
            }
            .keyboardShortcut("=", modifiers: .command)
            Button(AppL10n.string("menu.text_larger", fallback: "Larger Text")) {
                viewModel.increaseFontSize()
            }
            .keyboardShortcut("+", modifiers: .command)
            Button(AppL10n.string("menu.text_smaller", fallback: "Smaller Text")) {
                viewModel.decreaseFontSize()
            }
            .keyboardShortcut("-", modifiers: .command)
            Button(AppL10n.string("menu.text_reset", fallback: "Default Text Size")) {
                viewModel.resetFontSize()
            }
            .keyboardShortcut("0", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .focusable(false)
        .accessibilityHidden(true)
    }
}

private struct CaptionSectionDivider: View {
    let increasedContrast: Bool
    let colorScheme: ColorScheme

    var body: some View {
        Divider().opacity(
            increasedContrast
                ? 0.70
                : (colorScheme == .light ? 0.42 : 0.28)
        )
    }
}

// MARK: - Extracted Bar Subviews (Observation Isolation)

private struct HeaderBarView: View {
    let viewModel: CaptionViewModel
    let isDetached: Bool
    let reduceMotion: Bool
    let increasedContrast: Bool
    let onToggleDetach: (() -> Void)?
    let onQuit: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var _headerWidth = State(wrappedValue: 430.0)
    private var headerWidth: Double {
        get { _headerWidth.wrappedValue }
        nonmutating set { _headerWidth.wrappedValue = newValue }
    }

    private var warningAccentColor: Color {
        CaptionPalette.warningAccent(for: colorScheme, increasedContrast: increasedContrast)
    }

    private var isMicDegraded: Bool {
        CaptionPalette.isMicDegraded(viewModel: viewModel)
    }

    private var statusDotColor: Color {
        if viewModel.alertMessage != nil && !viewModel.isPaused { return warningAccentColor }
        if viewModel.isStartingUp { return .secondary }
        if !viewModel.isPaused && (!viewModel.isAudioCapturing || isMicDegraded) { return warningAccentColor }
        if case .failed = viewModel.shareStatus, !viewModel.isPaused { return warningAccentColor }
        if viewModel.isSharing { return .teal }
        if viewModel.isPaused { return warningAccentColor }
        return .accentColor
    }

    private var statusText: String {
        if viewModel.isPaused { return AppL10n.string("status.paused", fallback: "Paused") }
        if viewModel.isStartingUp { return AppL10n.string("status.starting", fallback: "Starting…") }
        if !viewModel.isAudioCapturing { return AppL10n.string("status.capture_off", fallback: "Capture Off") }
        if isMicDegraded { return AppL10n.string("status.mic_off", fallback: "Mic off") }
        if case .failed = viewModel.shareStatus {
            return AppL10n.string("status.tunnel_error", fallback: "Link Error")
        }
        if viewModel.alertMessage != nil {
            return AppL10n.string("status.setup_needed", fallback: "Setup")
        }
        if viewModel.isSharing { return AppL10n.string("status.live_link", fallback: "Live Link") }
        return viewModel.isConversationalMode
            ? AppL10n.string("status.conversation", fallback: "Conversation")
            : AppL10n.string("status.listening", fallback: "Listening")
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)

                Text(AppL10n.string("app.name", fallback: "Call Caption"))
                    .font(.system(.subheadline, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(increasedContrast ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(0)
            }

            Spacer(minLength: 4)

            GlassEffectContainer(spacing: 5) {
                HStack(spacing: 5) {
                    Button {
                        viewModel.togglePauseResume()
                    } label: {
                        Image(systemName: viewModel.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(viewModel.isPaused ? warningAccentColor : Color.primary)
                            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help(
                        viewModel.isPaused
                            ? AppL10n.string("header.resume.help", fallback: "Resume captions")
                            : AppL10n.string("header.pause.help", fallback: "Pause captions")
                    )
                    .accessibilityLabel(
                        viewModel.isPaused
                            ? AppL10n.string("header.resume.help", fallback: "Resume captions")
                            : AppL10n.string("header.pause.help", fallback: "Pause captions")
                    )
                    .keyboardShortcut("p", modifiers: .command)

                    shareHeaderButton

                    if let onToggleDetach {
                        Button(action: onToggleDetach) {
                            Image(systemName: isDetached ? "menubar.dock.rectangle" : "macwindow.on.rectangle")
                                .font(.system(size: 11.5, weight: .medium))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .help(
                            isDetached
                                ? AppL10n.string("header.dock.help", fallback: "Dock back to menu bar")
                                : AppL10n.string("header.pop_out.help", fallback: "Open in floating window")
                        )
                        .accessibilityLabel(
                            isDetached
                                ? AppL10n.string("header.dock.help", fallback: "Dock back to menu bar")
                                : AppL10n.string("header.pop_out.help", fallback: "Open in floating window")
                        )
                    }

                    moreOptionsMenu
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)
        }
        .padding(.leading, isDetached ? 42 : 14)
        .padding(.trailing, 12)
        .padding(.top, isDetached ? 6 : 10)
        .padding(.bottom, isDetached ? 8 : 10)
        .onGeometryChange(for: Double.self) { geo in
            geo.size.width
        } action: { newWidth in
            if abs(headerWidth - newWidth) > 1 {
                headerWidth = newWidth
            }
        }
    }

    @ViewBuilder
    private var shareHeaderButton: some View {
        let shareTitle = viewModel.isSharing
            ? AppL10n.string("header.sharing", fallback: "Sharing")
            : AppL10n.string("header.share", fallback: "Share")
        let compactMode = (isDetached && headerWidth < 455) || (shareTitle.count > 8 && headerWidth < 455)
        let label = HStack(spacing: compactMode ? 0 : 4) {
            Image(systemName: viewModel.isSharing ? "dot.radiowaves.left.and.right" : "link")
                .font(.system(size: 11, weight: .medium))
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            if !compactMode {
                Text(shareTitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, compactMode ? 0 : 6)
        .frame(minWidth: compactMode ? 24 : nil, minHeight: 24)

        let helpText = viewModel.isSharing
            ? AppL10n.string("header.stop_share.help", fallback: "Stop live transcription link")
            : AppL10n.string("header.share.help", fallback: "Share live transcription link with caller")

        Group {
            if viewModel.isSharing {
                Button {
                    viewModel.toggleSharing()
                } label: {
                    label
                }
                .buttonStyle(.glassProminent)
                .tint(.accentColor)
            } else {
                Button {
                    viewModel.toggleSharing()
                } label: {
                    label
                }
                .buttonStyle(.glass)
            }
        }
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(2)
        .help(helpText)
        .accessibilityLabel(helpText)
        .keyboardShortcut("l", modifiers: .command)
    }

    private var moreOptionsMenu: some View {
        Menu {
            Button(
                viewModel.isPaused
                    ? AppL10n.string("menu.resume_captions", fallback: "Resume Captions")
                    : AppL10n.string("menu.pause_captions", fallback: "Pause Captions")
            ) {
                viewModel.togglePauseResume()
            }
            .keyboardShortcut("p", modifiers: .command)

            Toggle(
                AppL10n.string("menu.conversational_mode", fallback: "Conversational Mode"),
                isOn: Binding(
                    get: { viewModel.isConversationalMode },
                    set: { viewModel.setConversationalMode($0) }
                )
            )
            .keyboardShortcut("m", modifiers: .command)

            Button(
                viewModel.isSharing
                    ? AppL10n.string("menu.stop_sharing_link", fallback: "Stop Sharing Link")
                    : AppL10n.string("menu.share_live_link", fallback: "Share Live Link")
            ) {
                viewModel.toggleSharing()
            }
            .keyboardShortcut("l", modifiers: .command)

            Button(AppL10n.string("menu.copy_transcript", fallback: "Copy Transcript")) {
                _ = viewModel.copyTranscript()
            }
            .disabled(!viewModel.hasEntries)
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Divider()

            Toggle(
                AppL10n.string("menu.show_original", fallback: "Show Original Text"),
                isOn: Binding(
                    get: { viewModel.showOriginalText },
                    set: { viewModel.setShowOriginalText($0) }
                )
            )
            .keyboardShortcut("o", modifiers: .command)

            Toggle(
                AppL10n.string("overflow.live_link_options", fallback: "Live Link Options"),
                isOn: Binding(
                    get: { viewModel.showShareOptions },
                    set: { viewModel.showShareOptions = $0 }
                )
            )

            Toggle(
                AppL10n.string("overflow.hide_screen_share", fallback: "Hide from Screen Sharing"),
                isOn: Binding(
                    get: { viewModel.hideFromScreenSharing },
                    set: { viewModel.setHideFromScreenSharing($0) }
                )
            )

            if isDetached {
                Toggle(
                    AppL10n.string("overflow.compact_hud", fallback: "Compact Floating View"),
                    isOn: Binding(
                        get: { viewModel.isCompactFloatingHUD },
                        set: { viewModel.setCompactFloatingHUD($0) }
                    )
                )
            } else {
                Toggle(
                    AppL10n.string("overflow.pin_popover", fallback: "Pin Popover Open"),
                    isOn: Binding(
                        get: { viewModel.isPinned },
                        set: { viewModel.setPinned($0) }
                    )
                )
            }

            Divider()

            Menu(AppL10n.string("overflow.text_size", fallback: "Caption Text Size")) {
                let fontPercent = Int(((viewModel.captionFontSize / CaptionCoordinator.defaultCaptionFontSize) * 100).rounded())
                Text(
                    AppL10n.format(
                        "overflow.text_size.value",
                        fallback: "Caption text size, %ld percent",
                        fontPercent
                    )
                )
                Divider()

                Button(AppL10n.string("overflow.text_smaller", fallback: "Smaller")) {
                    viewModel.decreaseFontSize()
                }
                .disabled(viewModel.captionFontSize <= CaptionCoordinator.minCaptionFontSize)
                .keyboardShortcut("-", modifiers: .command)

                Button(AppL10n.string("overflow.text_default", fallback: "Default")) {
                    viewModel.resetFontSize()
                }
                .disabled(abs(viewModel.captionFontSize - CaptionCoordinator.defaultCaptionFontSize) < 0.01)
                .keyboardShortcut("0", modifiers: .command)

                Button(AppL10n.string("overflow.text_larger", fallback: "Larger")) {
                    viewModel.increaseFontSize()
                }
                .disabled(viewModel.captionFontSize >= CaptionCoordinator.maxCaptionFontSize)
                .keyboardShortcut("+", modifiers: .command)
            }

            Menu(AppL10n.string("overflow.appearance", fallback: "Appearance")) {
                Picker(
                    AppL10n.string("overflow.appearance", fallback: "Appearance"),
                    selection: Binding(
                        get: { viewModel.appearanceMode },
                        set: { viewModel.setAppearanceMode($0) }
                    )
                ) {
                    ForEach(AppAppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.localizedTitle).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            }

            Divider()

            Button(AppL10n.string("menu.quit", fallback: "Quit Call Caption"), role: .destructive) {
                onQuit()
            }
            .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11.5, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.glass)
        .controlSize(.small)
        .help(AppL10n.string("header.more.help", fallback: "More options"))
        .accessibilityLabel(AppL10n.string("header.more.a11y", fallback: "More options"))
    }
}

private struct ControlsBarView: View {
    let viewModel: CaptionViewModel
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let increasedContrast: Bool

    @Environment(\.colorScheme) private var colorScheme
    private var _swapRotationDegrees = State(wrappedValue: 0.0)
    private var swapRotationDegrees: Double {
        get { _swapRotationDegrees.wrappedValue }
        nonmutating set { _swapRotationDegrees.wrappedValue = newValue }
    }

    private var speakerCallerColor: Color {
        CaptionPalette.callerAccent(for: colorScheme, increasedContrast: increasedContrast)
    }

    private var speakerYouColor: Color {
        CaptionPalette.youAccent(for: colorScheme, increasedContrast: increasedContrast)
    }

    private var subtlePanelFill: Color {
        if reduceTransparency {
            return Color(nsColor: .controlBackgroundColor)
        }
        if increasedContrast {
            return Color(nsColor: .controlBackgroundColor).opacity(0.75)
        }
        return Color.primary.opacity(colorScheme == .light ? 0.04 : 0.03)
    }

    var body: some View {
        VStack(spacing: 8) {
            Picker(
                AppL10n.string("mode.picker.label", fallback: "Mode"),
                selection: Binding(
                    get: { viewModel.isConversationalMode },
                    set: { viewModel.setConversationalMode($0) }
                )
            ) {
                Text(AppL10n.string("mode.caller_only", fallback: "Caller Only"))
                    .tag(false)
                    .help(AppL10n.string("mode.caller_only.help", fallback: "Transcribe and translate system audio from the caller"))
                Text(AppL10n.string("mode.caller_and_mic", fallback: "Caller + Mic"))
                    .tag(true)
                    .help(AppL10n.string("mode.caller_and_mic.help", fallback: "Transcribe and translate both system audio and your microphone"))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(AppL10n.string("mode.picker.a11y", fallback: "Speaker capture mode"))

            HStack(alignment: .bottom, spacing: 8) {
                languageMenu(
                    title: viewModel.isConversationalMode
                        ? AppL10n.string("lang.caller", fallback: "Caller")
                        : AppL10n.string("lang.caller_speaks", fallback: "Caller Speaks"),
                    isMic: false,
                    showActivityDot: true,
                    tint: speakerCallerColor,
                    selection: Binding(
                        get: { viewModel.callerLanguageCode },
                        set: { viewModel.setCallerLanguage($0) }
                    )
                )

                Button {
                    if !reduceMotion {
                        withAnimation(.snappy(duration: 0.28)) {
                            swapRotationDegrees += 180
                        }
                    }
                    viewModel.swapLanguages()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 10.5, weight: .medium))
                        .rotationEffect(.degrees(swapRotationDegrees))
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .disabled(viewModel.callerLanguageCode == viewModel.myLanguageCode)
                .help(AppL10n.string("lang.swap.help", fallback: "Swap languages"))
                .accessibilityLabel(AppL10n.string("lang.swap.a11y", fallback: "Swap caller and target languages"))

                languageMenu(
                    title: viewModel.isConversationalMode
                        ? AppL10n.string("lang.you_speak", fallback: "You Speak")
                        : AppL10n.string("lang.translate_to", fallback: "Translate To"),
                    isMic: true,
                    showActivityDot: viewModel.isConversationalMode,
                    tint: speakerYouColor,
                    selection: Binding(
                        get: { viewModel.myLanguageCode },
                        set: { viewModel.setMyLanguage($0) }
                    )
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(subtlePanelFill)
        .animation(reduceMotion ? nil : .snappy(duration: 0.20), value: viewModel.isConversationalMode)
    }

    private func languageMenu(
        title: String,
        isMic: Bool,
        showActivityDot: Bool,
        tint: Color,
        selection: Binding<String>
    ) -> some View {
        let selectedName = SupportedLanguages.item(forCode: selection.wrappedValue)?.localizedName
            ?? selection.wrappedValue
        let inactiveDotColor = increasedContrast
            ? Color.secondary.opacity(0.68)
            : (colorScheme == .light ? Color.secondary.opacity(0.50) : Color.secondary.opacity(0.45))

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if showActivityDot {
                    AudioActivityDot(
                        viewModel: viewModel,
                        isMic: isMic,
                        tint: tint,
                        inactiveColor: inactiveDotColor,
                        reduceMotion: reduceMotion
                    )
                }
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(increasedContrast ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Menu {
                Picker(title, selection: selection) {
                    ForEach(SupportedLanguages.sortedByLocalizedName) { item in
                        Text(item.localizedPickerName).tag(item.code)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 4) {
                    Text(selectedName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(title)
            .accessibilityValue(selectedName)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OptionalBannersView: View {
    let viewModel: CaptionViewModel
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let increasedContrast: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var showLiveShareBar: Bool {
        viewModel.isSharing || viewModel.showShareOptions || viewModel.shareStatus != .off
    }

    private var speakerCallerColor: Color {
        CaptionPalette.callerAccent(for: colorScheme, increasedContrast: increasedContrast)
    }

    private var speakerYouColor: Color {
        CaptionPalette.youAccent(for: colorScheme, increasedContrast: increasedContrast)
    }

    private var warningAccentColor: Color {
        CaptionPalette.warningAccent(for: colorScheme, increasedContrast: increasedContrast)
    }

    private var bannerTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity),
                removal: .opacity
            )
    }

    var body: some View {
        VStack(spacing: 0) {
            if showLiveShareBar {
                let bannerMaxHeight: CGFloat = (viewModel.showShareOptions || !viewModel.isSharing) ? 150 : 88
                ViewThatFits(in: .vertical) {
                    liveShareBannerSection
                    ScrollView(.vertical) {
                        liveShareBannerSection
                    }
                    .scrollIndicators(.visible)
                    .frame(minHeight: 44, maxHeight: bannerMaxHeight)
                    .clipped()
                }
            }

            if let alert = viewModel.alertMessage {
                CaptionSectionDivider(increasedContrast: increasedContrast, colorScheme: colorScheme)
                alertBar(message: alert)
                    .transition(bannerTransition)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .snappy(duration: 0.20), value: viewModel.shareLANIPUnavailable)
        .animation(reduceMotion ? nil : .snappy(duration: 0.20), value: viewModel.sharePublicLinkRotated)
    }

    private var liveShareBannerSection: some View {
        VStack(spacing: 0) {
            CaptionSectionDivider(increasedContrast: increasedContrast, colorScheme: colorScheme)
            liveShareBar
                .transition(bannerTransition)
        }
        .frame(maxWidth: .infinity)
    }

    private var liveShareBar: some View {
        let localHelp = AppL10n.string("share.local.help", fallback: "Copy local Wi-Fi link (unencrypted HTTP)")
        let copyHelp = AppL10n.string("share.copy.help", fallback: "Copy live link")
        return VStack(alignment: .leading, spacing: 7) {
            switch viewModel.shareStatus {
            case .off:
                HStack(spacing: 6) {
                    Text(AppL10n.string("share.options_title", fallback: "Live Link Options"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(increasedContrast ? .primary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        viewModel.showShareOptions = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(AppL10n.string("share.options.close.help", fallback: "Hide Live Link options"))
                    .accessibilityLabel(AppL10n.string("share.options.close.a11y", fallback: "Hide Live Link options"))
                }

            case .startingLocal:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text(AppL10n.string("share.starting_local", fallback: "Starting local live link server…"))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(AppL10n.string("share.stop", fallback: "Stop")) {
                        viewModel.toggleSharing()
                    }
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                }

            case .connectingTunnel(let localURL, let statusText):
                HStack(alignment: .center, spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text(statusText)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if viewModel.shareAllowLAN && viewModel.viewerCount > 0 {
                        viewerCountBadge(viewers: viewModel.viewerCount)
                    }
                    if let localURL {
                        CopyActionButton(
                            idleTitle: AppL10n.string("share.local", fallback: "Local"),
                            copiedTitle: AppL10n.string("share.copied", fallback: "Copied"),
                            idleAccessibilityLabel: localHelp,
                            showIcon: false
                        ) {
                            viewModel.copyString(localURL.absoluteString)
                        }
                        .help(localHelp)
                        .id(localURL)
                    }
                    Button(AppL10n.string("share.stop", fallback: "Stop")) {
                        viewModel.toggleSharing()
                    }
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                }

            case .ready(let primaryURL, let localURL, let isPublic, let viewers):
                HStack(spacing: 6) {
                    Image(systemName: isPublic ? "lock.fill" : "network")
                        .font(.caption)
                        .foregroundStyle(isPublic ? speakerYouColor : speakerCallerColor)
                        .accessibilityHidden(true)

                    Text(primaryURL.absoluteString)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    Spacer(minLength: 4)

                    if viewers > 0 {
                        viewerCountBadge(viewers: viewers)
                    }

                    if isPublic, let localURL {
                        CopyActionButton(
                            idleTitle: AppL10n.string("share.local", fallback: "Local"),
                            copiedTitle: AppL10n.string("share.copied", fallback: "Copied"),
                            idleAccessibilityLabel: localHelp,
                            showIcon: false
                        ) {
                            viewModel.copyString(localURL.absoluteString)
                        }
                        .help(localHelp)
                        .id(localURL)
                    }

                    CopyActionButton(
                        idleTitle: AppL10n.string("share.copy", fallback: "Copy"),
                        copiedTitle: AppL10n.string("share.copied", fallback: "Copied"),
                        idleAccessibilityLabel: copyHelp,
                        showIcon: false,
                        externalCopiedFeedback: viewModel.copiedLinkFeedback
                    ) {
                        viewModel.copyString(primaryURL.absoluteString)
                    }
                    .help(copyHelp)
                    .id(primaryURL)
                }

            case .failed(let localURL, let errorText):
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(warningAccentColor)
                        .font(.caption)
                        .accessibilityHidden(true)
                    Text(errorText)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if viewModel.shareAllowLAN && viewModel.viewerCount > 0 {
                        viewerCountBadge(viewers: viewModel.viewerCount)
                    }
                    if let localURL {
                        CopyActionButton(
                            idleTitle: AppL10n.string("share.local", fallback: "Local"),
                            copiedTitle: AppL10n.string("share.copied", fallback: "Copied"),
                            idleAccessibilityLabel: localHelp,
                            showIcon: false
                        ) {
                            viewModel.copyString(localURL.absoluteString)
                        }
                        .help(localHelp)
                        .id(localURL)
                    }
                    Button(AppL10n.string("share.retry", fallback: "Retry")) {
                        viewModel.retryShare()
                    }
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                    if viewModel.isSharing {
                        Button(AppL10n.string("share.stop", fallback: "Stop")) {
                            viewModel.toggleSharing()
                        }
                        .controlSize(.small)
                        .fixedSize(horizontal: true, vertical: false)
                    } else {
                        Button {
                            viewModel.dismissShareError()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .help(AppL10n.string("alert.dismiss.help", fallback: "Dismiss alert"))
                        .accessibilityLabel(AppL10n.string("alert.dismiss.a11y", fallback: "Dismiss alert"))
                    }
                }
            }

            if viewModel.isSharing && !viewModel.shareUseTunnel && !viewModel.shareAllowLAN {
                Text(
                    AppL10n.string(
                        "share.local.loopback_hint",
                        fallback: "This Mac only — enable Local Wi-Fi (LAN) or Public Tunnel to share with another device."
                    )
                )
                .font(.caption2)
                .foregroundStyle(increasedContrast ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if viewModel.shareLANIPUnavailable {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(warningAccentColor)
                        .accessibilityHidden(true)
                    Text(
                        AppL10n.string(
                            "share.lan_unavailable",
                            fallback: "Local Wi-Fi (LAN) IP unavailable; using localhost only."
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(increasedContrast ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if viewModel.sharePublicLinkRotated {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption2)
                        .foregroundStyle(speakerCallerColor)
                        .accessibilityHidden(true)
                    Text(
                        AppL10n.string(
                            "share.link_rotated",
                            fallback: "Public link changed — share the updated link."
                        )
                    )
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        viewModel.dismissShareRotationNotice()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(AppL10n.string("share.link_rotated.dismiss.help", fallback: "Dismiss notice"))
                    .accessibilityLabel(
                        AppL10n.string(
                            "share.link_rotated.dismiss.a11y",
                            fallback: "Dismiss updated link notice"
                        )
                    )
                }
            }

            if viewModel.showShareOptions || !viewModel.isSharing {
                VStack(alignment: .leading, spacing: 4) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            sharePublicToggle.fixedSize(horizontal: true, vertical: false)
                            shareLANToggle.fixedSize(horizontal: true, vertical: false)
                            shareBothSpeakersToggle.fixedSize(horizontal: true, vertical: false)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 12) {
                                sharePublicToggle
                                shareLANToggle
                            }
                            shareBothSpeakersToggle
                        }
                    }
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .foregroundStyle(increasedContrast ? .primary : .secondary)

                    if viewModel.isSharing {
                        Text(AppL10n.string("share.opt.locked_hint", fallback: "Stop sharing to change tunnel or LAN visibility."))
                            .font(.caption2)
                            .foregroundStyle(increasedContrast ? .primary : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.accentColor.opacity(
                reduceTransparency
                    ? (increasedContrast ? 0.22 : 0.16)
                    : (increasedContrast ? 0.14 : 0.08)
            )
        )
    }

    private var sharePublicToggle: some View {
        Toggle(
            AppL10n.string("share.opt.public_tunnel", fallback: "Public Tunnel"),
            isOn: Binding(
                get: { viewModel.shareUseTunnel },
                set: { viewModel.setShareOptions(useTunnel: $0) }
            )
        )
        .disabled(viewModel.isSharing)
    }

    private var shareLANToggle: some View {
        Toggle(
            AppL10n.string("share.opt.lan", fallback: "Local Wi-Fi (LAN)"),
            isOn: Binding(
                get: { viewModel.shareAllowLAN },
                set: { viewModel.setShareOptions(allowLAN: $0) }
            )
        )
        .disabled(viewModel.isSharing)
        .help(AppL10n.string("share.opt.lan.help", fallback: "Allow viewers on your local Wi-Fi network over unencrypted HTTP"))
    }

    private var shareBothSpeakersToggle: some View {
        Toggle(
            AppL10n.string("share.opt.both_speakers", fallback: "Both Speakers"),
            isOn: Binding(
                get: { viewModel.shareBothSpeakers },
                set: { viewModel.setShareOptions(bothSpeakers: $0) }
            )
        )
    }

    private func viewerCountBadge(viewers: Int) -> some View {
        let badgeColor = speakerYouColor
        let fillOpacity: Double = increasedContrast ? 0.24 : (colorScheme == .light ? 0.16 : 0.18)
        return Label("\(viewers)", systemImage: "eye.fill")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(fillOpacity), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(badgeColor.opacity(increasedContrast ? 0.65 : 0), lineWidth: 1)
            )
            .foregroundStyle(badgeColor)
            .fixedSize(horizontal: true, vertical: false)
            .help(
                AppL10n.plural(
                    "share.viewers.help",
                    fallbackSingular: "%ld active viewer",
                    fallbackPlural: "%ld active viewers",
                    count: viewers
                )
            )
            .accessibilityLabel(
                AppL10n.plural(
                    "share.viewers.a11y",
                    fallbackSingular: "%ld active viewer",
                    fallbackPlural: "%ld active viewers",
                    count: viewers
                )
            )
    }

    private func alertBar(message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(warningAccentColor)
                    .font(.callout)
                    .accessibilityHidden(true)

                Text(message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    viewModel.dismissAlert()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(AppL10n.string("alert.dismiss.help", fallback: "Dismiss alert"))
                .accessibilityLabel(AppL10n.string("alert.dismiss.a11y", fallback: "Dismiss alert"))
            }

            if viewModel.showAlertRetryAction || viewModel.alertAction.actionButtonTitle != nil {
                HStack(spacing: 6) {
                    if viewModel.showAlertRetryAction {
                        Button(AppL10n.string("alert.retry", fallback: "Retry")) {
                            viewModel.retryAlertAction()
                        }
                        .controlSize(.small)
                        .fixedSize(horizontal: true, vertical: false)
                    }

                    if let actionTitle = viewModel.alertAction.actionButtonTitle {
                        Button(actionTitle) {
                            viewModel.openAlertSettings()
                        }
                        .controlSize(.small)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .padding(.leading, 22)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.orange.opacity(
                reduceTransparency
                    ? (increasedContrast ? 0.28 : 0.22)
                    : (increasedContrast ? 0.20 : 0.14)
            )
        )
    }
}

private struct FooterBarView: View {
    let viewModel: CaptionViewModel
    let reduceMotion: Bool
    let increasedContrast: Bool
    @Binding var showClearConfirmation: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var speakerCallerColor: Color {
        CaptionPalette.callerAccent(for: colorScheme, increasedContrast: increasedContrast)
    }

    private var speakerYouColor: Color {
        CaptionPalette.youAccent(for: colorScheme, increasedContrast: increasedContrast)
    }

    var body: some View {
        HStack(spacing: 10) {
            AudioLevelMeter(
                viewModel: viewModel,
                isMic: false,
                label: AppL10n.string("footer.sys", fallback: "Sys"),
                a11yLabel: AppL10n.string("footer.sys.a11y", fallback: "System audio level"),
                color: speakerCallerColor,
                reduceMotion: reduceMotion,
                increasedContrast: increasedContrast
            )

            if viewModel.isConversationalMode {
                AudioLevelMeter(
                    viewModel: viewModel,
                    isMic: true,
                    label: AppL10n.string("footer.mic", fallback: "Mic"),
                    a11yLabel: AppL10n.string("footer.mic.a11y", fallback: "Microphone audio level"),
                    color: speakerYouColor,
                    reduceMotion: reduceMotion,
                    increasedContrast: increasedContrast
                )
                .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
            }

            Spacer()

            CopyActionButton(
                idleTitle: AppL10n.string("share.copy", fallback: "Copy"),
                copiedTitle: AppL10n.string("share.copied", fallback: "Copied"),
                idleAccessibilityLabel: AppL10n.string("footer.copy.a11y", fallback: "Copy transcript"),
                showIcon: true,
                externalCopiedFeedback: viewModel.copiedTranscriptFeedback,
                announceOnTap: false
            ) {
                _ = viewModel.copyTranscript()
            }
            .help(AppL10n.string("footer.copy.a11y", fallback: "Copy transcript"))
            .disabled(!viewModel.hasEntries)

            Button(AppL10n.string("footer.clear", fallback: "Clear")) {
                showClearConfirmation = true
            }
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(!viewModel.hasEntries)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .animation(reduceMotion ? nil : .snappy(duration: 0.20), value: viewModel.isConversationalMode)
    }
}

// MARK: - Subviews

private enum CaptionPalette {
    static func callerAccent(for colorScheme: ColorScheme, increasedContrast: Bool = false) -> Color {
        if colorScheme == .dark {
            return increasedContrast
                ? Color(red: 0.50, green: 0.78, blue: 1.0)
                : Color(red: 0.38, green: 0.70, blue: 1.0)
        }
        return increasedContrast
            ? Color(red: 0.0, green: 0.24, blue: 0.60)
            : Color(red: 0.0, green: 0.32, blue: 0.72)
    }

    static func youAccent(for colorScheme: ColorScheme, increasedContrast: Bool = false) -> Color {
        if colorScheme == .dark {
            return increasedContrast
                ? Color(red: 0.38, green: 0.90, blue: 0.52)
                : Color(red: 0.24, green: 0.82, blue: 0.44)
        }
        return increasedContrast
            ? Color(red: 0.02, green: 0.32, blue: 0.10)
            : Color(red: 0.04, green: 0.40, blue: 0.14)
    }

    static func warningAccent(for colorScheme: ColorScheme, increasedContrast: Bool = false) -> Color {
        if colorScheme == .dark {
            return increasedContrast
                ? Color(red: 1.0, green: 0.78, blue: 0.30)
                : Color(red: 1.0, green: 0.68, blue: 0.22)
        }
        return increasedContrast
            ? Color(red: 0.54, green: 0.22, blue: 0.0)
            : Color(red: 0.64, green: 0.28, blue: 0.0)
    }

    @MainActor
    static func effectiveAudioLevel(viewModel: CaptionViewModel, isMic: Bool) -> Float {
        if viewModel.isPaused || !viewModel.isAudioCapturing || (isMic && !viewModel.isConversationalMode) {
            return 0
        }
        return isMic ? viewModel.micLevel : viewModel.callerLevel
    }

    @MainActor
    static func isMicDegraded(viewModel: CaptionViewModel) -> Bool {
        !viewModel.isPaused
            && !viewModel.isStartingUp
            && viewModel.isAudioCapturing
            && viewModel.isConversationalMode
            && !viewModel.isMicCapturing
    }
}

@MainActor
private final class FeedScrollTracker {
    var isUserScrolling: Bool = false
    var lastNearBottom: Bool = true
    var ignoreFollowLossUntil: Date = .distantPast
}

private struct CaptionFeedView: View {
    let viewModel: CaptionViewModel
    let isDetached: Bool
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let increasedContrast: Bool
    let hoverResetToken: Int
    let layoutAnchorTrigger: FeedLayoutAnchorTrigger

    private struct ScrollGeometrySnapshot: Equatable, Sendable {
        let nearBottom: Bool
        let visibleHeight: Int
    }

    private var _scrollPosition = State(wrappedValue: ScrollPosition(edge: .bottom))
    private var _isFollowingLive = State(wrappedValue: true)
    private var _scrollTracker = State(wrappedValue: FeedScrollTracker())

    private var scrollPosition: ScrollPosition {
        get { _scrollPosition.wrappedValue }
        nonmutating set { _scrollPosition.wrappedValue = newValue }
    }
    private var isFollowingLive: Bool {
        get { _isFollowingLive.wrappedValue }
        nonmutating set { _isFollowingLive.wrappedValue = newValue }
    }
    private var scrollTracker: FeedScrollTracker {
        _scrollTracker.wrappedValue
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if !viewModel.hasEntries {
                FeedEmptyStateView(
                    viewModel: viewModel,
                    reduceMotion: reduceMotion,
                    increasedContrast: increasedContrast
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.finalizedEntries) { entry in
                            CaptionRowView(
                                entry: entry,
                                showOriginalText: viewModel.showOriginalText,
                                fontSize: viewModel.captionFontSize,
                                reduceMotion: reduceMotion,
                                reduceTransparency: reduceTransparency,
                                increasedContrast: increasedContrast,
                                hoverResetToken: hoverResetToken,
                                onCopyEntry: { text in
                                    viewModel.copyString(text)
                                }
                            )
                            .equatable()
                            .id(entry.id)
                        }

                        LiveCaptionSlotsView(
                            viewModel: viewModel,
                            reduceMotion: reduceMotion,
                            reduceTransparency: reduceTransparency,
                            increasedContrast: increasedContrast,
                            hoverResetToken: hoverResetToken
                        )
                    }
                    .padding(12)
                }
                .scrollPosition(_scrollPosition.projectedValue)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(isFollowingLive ? .bottom : .top, for: .sizeChanges)
                .onScrollPhaseChange { _, newPhase in
                    let tracker = scrollTracker
                    let userScrolling = (newPhase == .interacting || newPhase == .decelerating)
                    tracker.isUserScrolling = userScrolling
                    if userScrolling
                        && !tracker.lastNearBottom
                        && Date() >= tracker.ignoreFollowLossUntil
                        && isFollowingLive {
                        isFollowingLive = false
                    }
                }
                .onScrollGeometryChange(for: ScrollGeometrySnapshot.self) { geo in
                    let nearBottom = geo.contentSize.height <= geo.visibleRect.height + 4
                        || (geo.contentSize.height - geo.visibleRect.maxY) <= 44
                    return ScrollGeometrySnapshot(
                        nearBottom: nearBottom,
                        visibleHeight: Int(geo.visibleRect.height.rounded())
                    )
                } action: { oldValue, newValue in
                    let tracker = scrollTracker
                    tracker.lastNearBottom = newValue.nearBottom
                    if newValue.nearBottom {
                        if !isFollowingLive {
                            isFollowingLive = true
                        }
                    } else if tracker.isUserScrolling && Date() >= tracker.ignoreFollowLossUntil && isFollowingLive {
                        isFollowingLive = false
                    } else if isFollowingLive
                        && !tracker.isUserScrolling
                        && oldValue.visibleHeight != newValue.visibleHeight {
                        tracker.ignoreFollowLossUntil = Date().addingTimeInterval(0.25)
                        scrollPosition.scrollTo(edge: .bottom)
                    }
                }
            }

            if !isFollowingLive && viewModel.hasEntries {
                Button {
                    scrollTracker.ignoreFollowLossUntil = Date().addingTimeInterval(0.35)
                    isFollowingLive = true
                    if reduceMotion {
                        scrollPosition.scrollTo(edge: .bottom)
                    } else {
                        withAnimation(.snappy(duration: 0.25)) {
                            scrollPosition.scrollTo(edge: .bottom)
                        }
                    }
                } label: {
                    Label(
                        AppL10n.string("feed.jump_latest", fallback: "Latest"),
                        systemImage: "arrow.down"
                    )
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Capsule())
                .padding(.bottom, 10)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .accessibilityLabel(AppL10n.string("feed.jump_latest.a11y", fallback: "Jump to latest captions"))
            }
        }
        .frame(maxWidth: .infinity, minHeight: isDetached ? 80 : 120, maxHeight: .infinity)
        .onChange(of: viewModel.hasEntries) { _, hasEntries in
            if !hasEntries {
                let tracker = scrollTracker
                tracker.ignoreFollowLossUntil = Date().addingTimeInterval(0.2)
                tracker.isUserScrolling = false
                tracker.lastNearBottom = true
                isFollowingLive = true
                scrollPosition = ScrollPosition(edge: .bottom)
            }
        }
        .onChange(of: layoutAnchorTrigger) { _, _ in
            let tracker = scrollTracker
            if isFollowingLive && !tracker.isUserScrolling && viewModel.hasEntries {
                tracker.ignoreFollowLossUntil = Date().addingTimeInterval(0.35)
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: isFollowingLive)
    }
}

private struct LiveCaptionSlotsView: View {
    let viewModel: CaptionViewModel
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let increasedContrast: Bool
    let hoverResetToken: Int

    private func row(for entry: CaptionEntry) -> some View {
        CaptionRowView(
            entry: entry,
            showOriginalText: viewModel.showOriginalText,
            fontSize: viewModel.captionFontSize,
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            increasedContrast: increasedContrast,
            hoverResetToken: hoverResetToken,
            onCopyEntry: { text in
                viewModel.copyString(text)
            }
        )
        .equatable()
        .id(entry.id)
    }

    var body: some View {
        switch (viewModel.liveCallerEntry, viewModel.liveMicEntry) {
        case (nil, nil):
            EmptyView()
        case (let c?, nil):
            row(for: c)
        case (nil, let m?):
            row(for: m)
        case (let c?, let m?):
            if c.timestamp <= m.timestamp {
                row(for: c)
                row(for: m)
            } else {
                row(for: m)
                row(for: c)
            }
        }
    }
}

private struct FeedEmptyStateView: View {
    let viewModel: CaptionViewModel
    let reduceMotion: Bool
    let increasedContrast: Bool

    private var isMicDegraded: Bool {
        CaptionPalette.isMicDegraded(viewModel: viewModel)
    }

    private var isSpeechRecognitionBlocked: Bool {
        !viewModel.isPaused
            && !viewModel.isStartingUp
            && viewModel.isAudioCapturing
            && !isMicDegraded
            && viewModel.alertMessage != nil
            && (viewModel.alertAction == .speechRecognition || viewModel.alertAction == .dictation)
    }

    private var emptyStateIconName: String {
        if viewModel.isPaused { return "pause.circle" }
        if !viewModel.isStartingUp && (!viewModel.isAudioCapturing || isMicDegraded || isSpeechRecognitionBlocked) {
            return "exclamationmark.triangle"
        }
        return "waveform"
    }

    private var emptyStateTitle: String {
        if viewModel.isPaused {
            return AppL10n.string("feed.empty.paused", fallback: "Captions are paused")
        }
        if viewModel.isStartingUp {
            return AppL10n.string("feed.empty.starting", fallback: "Starting audio capture…")
        }
        if !viewModel.isAudioCapturing {
            return AppL10n.string("feed.empty.capture_off", fallback: "Audio capture is inactive")
        }
        if isMicDegraded {
            return AppL10n.string(
                "feed.empty.listening_sys_mic_off",
                fallback: "Listening to system audio (microphone unavailable)…"
            )
        }
        if isSpeechRecognitionBlocked {
            return AppL10n.string(
                "feed.empty.speech_blocked",
                fallback: "Speech recognition unavailable"
            )
        }
        return viewModel.isConversationalMode
            ? AppL10n.string("feed.empty.listening_both", fallback: "Listening to system audio & microphone…")
            : AppL10n.string("feed.empty.listening_sys", fallback: "Listening to system audio…")
    }

    private var emptyStateSubtitle: String {
        if !viewModel.isPaused && !viewModel.isStartingUp && (!viewModel.isAudioCapturing || isMicDegraded) {
            return AppL10n.string(
                "feed.empty.capture_off_subtitle",
                fallback: "Check permissions or retry audio capture from the alert above."
            )
        }
        if isSpeechRecognitionBlocked {
            return AppL10n.string(
                "feed.empty.speech_blocked_subtitle",
                fallback: "Resolve the alert above to start transcribing speech."
            )
        }
        return AppL10n.string("feed.empty.subtitle", fallback: "Start a call or play speech on your Mac.")
    }

    private var emptyStateAnimateSymbol: Bool {
        !viewModel.isPaused && !viewModel.isStartingUp && viewModel.isAudioCapturing && !isSpeechRecognitionBlocked && !reduceMotion
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            ContentUnavailableView {
                Label {
                    Text(emptyStateTitle)
                } icon: {
                    Image(systemName: emptyStateIconName)
                        .symbolEffect(.variableColor.iterative, isActive: emptyStateAnimateSymbol)
                        .accessibilityHidden(true)
                }
            } description: {
                Text(emptyStateSubtitle)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 4) {
                Image(systemName: emptyStateIconName)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .symbolEffect(.variableColor.iterative, isActive: emptyStateAnimateSymbol)
                    .accessibilityHidden(true)
                Text(emptyStateTitle)
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(emptyStateSubtitle)
                    .font(.caption2)
                    .foregroundStyle(increasedContrast ? .primary : .secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AudioActivityDot: View {
    let viewModel: CaptionViewModel
    let isMic: Bool
    let tint: Color
    let inactiveColor: Color
    let reduceMotion: Bool

    var body: some View {
        let isActive = CaptionPalette.effectiveAudioLevel(viewModel: viewModel, isMic: isMic) > 0.04
        Circle()
            .fill(isActive ? tint : inactiveColor)
            .frame(width: 6, height: 6)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isActive)
            .accessibilityHidden(true)
    }
}

private struct CaptionRowView: View, Equatable {
    let entry: CaptionEntry
    let showOriginalText: Bool
    let fontSize: Double
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let increasedContrast: Bool
    let hoverResetToken: Int
    let onCopyEntry: (String) -> Void

    nonisolated static func == (lhs: CaptionRowView, rhs: CaptionRowView) -> Bool {
        lhs.entry == rhs.entry
            && lhs.showOriginalText == rhs.showOriginalText
            && lhs.fontSize == rhs.fontSize
            && lhs.reduceMotion == rhs.reduceMotion
            && lhs.reduceTransparency == rhs.reduceTransparency
            && lhs.increasedContrast == rhs.increasedContrast
            && lhs.hoverResetToken == rhs.hoverResetToken
    }

    @Environment(\.colorScheme) private var colorScheme

    private var _isHovering = State(wrappedValue: false)
    private var isHovering: Bool {
        get { _isHovering.wrappedValue }
        nonmutating set { _isHovering.wrappedValue = newValue }
    }

    private var isCaller: Bool {
        entry.speaker.caseInsensitiveCompare("caller") == .orderedSame
    }

    private var speakerTitle: String {
        isCaller
            ? AppL10n.string("row.speaker.caller", fallback: "CALLER")
            : AppL10n.string("row.speaker.you", fallback: "YOU")
    }

    private var targetRTL: Bool {
        SupportedLanguages.isRTL(languageCode: entry.targetLangCode)
    }

    private var sourceRTL: Bool {
        SupportedLanguages.isRTL(languageCode: entry.sourceLangCode)
    }

    private var sameText: Bool {
        entry.original.caseInsensitiveCompare(entry.translated) == .orderedSame
    }

    private var primaryIsSource: Bool {
        entry.isUntranslated || (sameText && entry.sourceLangCode != entry.targetLangCode)
    }

    private var primaryLanguageCode: String {
        primaryIsSource ? entry.sourceLangCode : entry.targetLangCode
    }

    private var primaryRTL: Bool {
        primaryIsSource ? sourceRTL : targetRTL
    }

    private var metadataScale: Double {
        max(0.85, min(1.6, fontSize / CaptionCoordinator.defaultCaptionFontSize))
    }

    private static func localizedAttributedText(_ text: String, languageCode: String) -> AttributedString {
        var attributed = AttributedString(text)
        if !languageCode.isEmpty {
            attributed.languageIdentifier = languageCode
        }
        return attributed
    }

    private var speakerColor: Color {
        isCaller
            ? CaptionPalette.callerAccent(for: colorScheme, increasedContrast: increasedContrast)
            : CaptionPalette.youAccent(for: colorScheme, increasedContrast: increasedContrast)
    }

    private var warningColor: Color {
        CaptionPalette.warningAccent(for: colorScheme, increasedContrast: increasedContrast)
    }

    private var cardBackground: Color {
        if reduceTransparency {
            if isCaller {
                return Color(nsColor: .controlBackgroundColor)
            }
            return colorScheme == .dark
                ? Color(red: 0.10, green: 0.20, blue: 0.13)
                : Color(red: 0.89, green: 0.96, blue: 0.91)
        }
        if isCaller {
            return Color.primary.opacity(
                increasedContrast ? 0.09 : (colorScheme == .light ? 0.06 : 0.045)
            )
        }
        return Color.green.opacity(
            increasedContrast ? 0.16 : (colorScheme == .light ? 0.12 : 0.085)
        )
    }

    private var cardBorderColor: Color {
        if !entry.isFinal {
            return speakerColor.opacity(
                increasedContrast ? 0.75 : (colorScheme == .light ? 0.55 : 0.40)
            )
        }
        if increasedContrast {
            return Color.primary.opacity(0.45)
        }
        return Color.primary.opacity(colorScheme == .light ? 0.15 : 0.09)
    }

    var body: some View {
        let speakerFontSize = round(10.0 * metadataScale * 2) / 2
        let badgeFontSize = round(9.5 * metadataScale * 2) / 2
        let timeFontSize = round(10.0 * metadataScale * 2) / 2
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(speakerTitle)
                    .font(.system(size: speakerFontSize, weight: .bold))
                    .foregroundStyle(speakerColor)

                if !entry.isFinal {
                    Text(AppL10n.string("row.badge.live", fallback: "live"))
                        .font(.system(size: badgeFontSize, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(
                            Color.primary.opacity(
                                increasedContrast ? 0.18 : (colorScheme == .light ? 0.10 : 0.08)
                            ),
                            in: Capsule()
                        )
                        .foregroundStyle(increasedContrast ? .primary : .secondary)
                        .transition(.opacity)
                }

                if entry.isUntranslated && entry.sourceLangCode != entry.targetLangCode {
                    Text(AppL10n.string("row.badge.untranslated", fallback: "untranslated"))
                        .font(.system(size: badgeFontSize, weight: .medium))
                        .foregroundStyle(warningColor)
                }

                Spacer()

                CopyIconButton(
                    helpText: AppL10n.string("row.copy.help", fallback: "Copy caption"),
                    reduceMotion: reduceMotion,
                    increasedContrast: increasedContrast
                ) {
                    copyRowText()
                }
                .focusable(false)
                .opacity(isHovering ? 1 : 0.001)
                .allowsHitTesting(isHovering)

                Text(entry.formattedTime)
                    .font(.system(size: timeFontSize))
                    .monospacedDigit()
                    .foregroundStyle(increasedContrast ? .primary : .secondary)
            }

            Text(Self.localizedAttributedText(entry.translated, languageCode: primaryLanguageCode))
                .font(.system(size: fontSize))
                .foregroundStyle(entry.isFinal ? .primary : .secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.layoutDirection, primaryRTL ? .rightToLeft : .leftToRight)
                .selectableIf(entry.isFinal)

            if showOriginalText && !sameText {
                Text(Self.localizedAttributedText(entry.original, languageCode: entry.sourceLangCode))
                    .font(.system(size: max(11, fontSize * 0.82)))
                    .foregroundStyle(increasedContrast ? .primary : .secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.layoutDirection, sourceRTL ? .rightToLeft : .leftToRight)
                    .selectableIf(entry.isFinal)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(cardBorderColor, lineWidth: !entry.isFinal || increasedContrast ? 1 : 0.5)
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: entry.isFinal)
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.easeInOut(duration: 0.14)) {
                    isHovering = hovering
                }
            }
        }
        .onDisappear {
            isHovering = false
        }
        .onChange(of: hoverResetToken) { _, _ in
            isHovering = false
        }
        .contextMenu {
            Button {
                copyRowText()
            } label: {
                Label(AppL10n.string("row.copy.help", fallback: "Copy caption"), systemImage: "doc.on.doc")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: AppL10n.string("row.copy.help", fallback: "Copy caption")) {
            copyRowText()
        }
    }

    private func copyRowText() {
        let textToCopy = (showOriginalText && !sameText)
            ? "\(entry.translated)\n(\(entry.original))"
            : entry.translated
        onCopyEntry(textToCopy)
    }
}

private extension View {
    @ViewBuilder
    func selectableIf(_ enabled: Bool) -> some View {
        if enabled {
            self.textSelection(.enabled)
        } else {
            self
        }
    }
}

private struct AudioLevelMeter: View {
    let viewModel: CaptionViewModel
    let isMic: Bool
    let label: String
    let a11yLabel: String
    let color: Color
    let reduceMotion: Bool
    let increasedContrast: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let level = CaptionPalette.effectiveAudioLevel(viewModel: viewModel, isMic: isMic)
        let normalized: CGFloat = level > 0.005 ? CGFloat(min(1, max(0.05, level * 3.5))) : 0
        let trackFill = increasedContrast
            ? Color.primary.opacity(0.38)
            : (colorScheme == .light ? Color.primary.opacity(0.24) : Color.primary.opacity(0.18))

        return HStack(spacing: 5) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(increasedContrast ? .primary : .secondary)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackFill)
                Capsule()
                    .fill(color)
                    .scaleEffect(x: normalized, y: 1, anchor: .leading)
                    .animation(reduceMotion ? nil : .linear(duration: 0.08), value: normalized)
            }
            .frame(width: 40, height: 5)
            .clipShape(Capsule())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel)
        .accessibilityValue(
            AppL10n.format(
                "footer.level_percent.a11y",
                fallback: "%ld percent",
                Int((normalized * 100).rounded())
            )
        )
    }
}

private struct CopyActionButton: View {
    let idleTitle: String
    let copiedTitle: String
    var idleAccessibilityLabel: String? = nil
    let showIcon: Bool
    var externalCopiedFeedback: Bool = false
    var announceOnTap: Bool = true
    let action: () -> Void

    private var _didCopy = State(wrappedValue: false)
    private var _resetTask = State<Task<Void, Never>?>(wrappedValue: nil)

    private var didCopy: Bool {
        get { _didCopy.wrappedValue }
        nonmutating set { _didCopy.wrappedValue = newValue }
    }
    private var resetTask: Task<Void, Never>? {
        get { _resetTask.wrappedValue }
        nonmutating set { _resetTask.wrappedValue = newValue }
    }

    private var isShowingCopied: Bool {
        didCopy || externalCopiedFeedback
    }

    var body: some View {
        Button {
            action()
            didCopy = true
            if announceOnTap {
                CaptionCoordinator.postAccessibilityAnnouncement(copiedTitle)
            }
            resetTask?.cancel()
            resetTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                didCopy = false
            }
        } label: {
            ZStack {
                buttonLabelContent(title: idleTitle, isCopied: false)
                    .opacity(isShowingCopied ? 0 : 1)
                buttonLabelContent(title: copiedTitle, isCopied: true)
                    .opacity(isShowingCopied ? 1 : 0)
            }
            .accessibilityHidden(true)
        }
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(isShowingCopied ? copiedTitle : (idleAccessibilityLabel ?? idleTitle))
        .onDisappear {
            resetTask?.cancel()
            resetTask = nil
            didCopy = false
        }
    }

    @ViewBuilder
    private func buttonLabelContent(title: String, isCopied: Bool) -> some View {
        if showIcon {
            Label(title, systemImage: isCopied ? "checkmark" : "doc.on.doc")
                .lineLimit(1)
        } else {
            Text(title)
                .lineLimit(1)
        }
    }
}

private struct CopyIconButton: View {
    let helpText: String
    let reduceMotion: Bool
    let increasedContrast: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var _didCopy = State(wrappedValue: false)
    private var _resetTask = State<Task<Void, Never>?>(wrappedValue: nil)

    private var didCopy: Bool {
        get { _didCopy.wrappedValue }
        nonmutating set { _didCopy.wrappedValue = newValue }
    }
    private var resetTask: Task<Void, Never>? {
        get { _resetTask.wrappedValue }
        nonmutating set { _resetTask.wrappedValue = newValue }
    }

    var body: some View {
        let copiedTitle = AppL10n.string("share.copied", fallback: "Copied")
        Button {
            action()
            didCopy = true
            CaptionCoordinator.postAccessibilityAnnouncement(copiedTitle)
            resetTask?.cancel()
            resetTask = Task {
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                didCopy = false
            }
        } label: {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(
                    didCopy
                        ? CaptionPalette.youAccent(for: colorScheme, increasedContrast: increasedContrast)
                        : Color.secondary
                )
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .focusable(false)
        .help(helpText)
        .accessibilityLabel(didCopy ? copiedTitle : helpText)
        .onDisappear {
            resetTask?.cancel()
            resetTask = nil
            didCopy = false
        }
    }
}

private struct HostWindowAccessor: NSViewRepresentable {
    let onWindowChange: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowObserverNSView {
        let view = WindowObserverNSView()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ nsView: WindowObserverNSView, context: Context) {
        nsView.onWindowChange = onWindowChange
        nsView.notifyWindowIfNeeded()
    }

    final class WindowObserverNSView: NSView {
        var onWindowChange: (@MainActor (NSWindow?) -> Void)?
        private weak var lastReportedWindow: NSWindow?
        private var hasReportedWindow = false

        func notifyWindowIfNeeded() {
            let currentWindow = window
            guard !hasReportedWindow || lastReportedWindow !== currentWindow else { return }
            hasReportedWindow = true
            lastReportedWindow = currentWindow
            let callback = onWindowChange
            DispatchQueue.main.async {
                callback?(currentWindow)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            notifyWindowIfNeeded()
        }
    }
}
