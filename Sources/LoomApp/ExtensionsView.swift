import LoomCore
import LoomExtensions
import LoomUI
import LoomWeb
import SwiftUI

/// The Extensions tab (ADR-0011): the installed extensions on the left, the
/// selected one's page on the right. A page is loaded the first time it shows
/// and kept alive while the user moves around the app.
struct ExtensionsView: View {
    let model: AppModel
    let onOpenSettings: () -> Void

    private var extensions: ExtensionsModel { model.extensions }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 240)
            Divider().overlay(DefaultTheme.cardBorder)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DefaultTheme.contentBackground)
        .onAppear { materializeSelection() }
        .onChange(of: extensions.selectedID) { materializeSelection() }
        // Enabled or approved in place: the page must load without a detour.
        .onChange(of: extensions.extensions) { materializeSelection() }
    }

    private func materializeSelection() {
        if let id = extensions.selectedID { extensions.host(for: id) }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("EXTENSIONS")
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(DefaultTheme.groupHeader)
                .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 6)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(extensions.extensions) { installed in
                        row(installed)
                    }
                }
                .padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
            GhostButton("Manage in Settings", systemImage: "gearshape") { onOpenSettings() }
                .padding(8)
        }
        .background(DefaultTheme.background)
    }

    private func row(_ installed: InstalledExtension) -> some View {
        let selected = extensions.selectedID == installed.id
        return Button {
            extensions.selectedID = installed.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: installed.manifest.icon ?? "puzzlepiece.extension")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? DefaultTheme.accent : DefaultTheme.secondaryText)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(installed.manifest.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DefaultTheme.primaryText)
                        .lineLimit(1)
                    Text(statusLine(installed))
                        .font(.system(size: 10))
                        .foregroundStyle(installed.isReady ? DefaultTheme.mutedText : DefaultTheme.badgeColor(for: .needsInput))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(selected ? DefaultTheme.surfaceRaised : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func statusLine(_ installed: InstalledExtension) -> String {
        switch installed.status {
        case .ready: return installed.isLinked ? "v\(installed.manifest.version) · linked" : "v\(installed.manifest.version)"
        case .needsConsent: return "Waiting for your approval"
        case .disabled: return "Disabled"
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let id = extensions.selectedID, let installed = extensions.extensionNamed(id) {
            switch installed.status {
            case .ready:
                page(installed)
            case .needsConsent(let missing):
                notice(icon: "hand.raised",
                       title: "\(installed.manifest.name) asks for more than you granted",
                       lines: missing.summary,
                       action: ("Review permissions…", { extensions.requestApproval(of: id) }))
            case .disabled:
                notice(icon: "pause.circle", title: "\(installed.manifest.name) is disabled", lines: [],
                       action: ("Enable", { extensions.setEnabled(true, for: id) }))
            }
        } else {
            notice(icon: "puzzlepiece.extension", title: "No extension yet",
                   lines: ["Extensions are web pages that plug into Loom: a Jira board, a Sentry inbox, your own tools.",
                           "Install one from a folder in Settings › Extensions."],
                   action: ("Open Settings", onOpenSettings))
        }
    }

    @ViewBuilder
    private func page(_ installed: InstalledExtension) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: installed.manifest.icon ?? "puzzlepiece.extension")
                    .foregroundStyle(DefaultTheme.accent)
                Text(installed.manifest.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DefaultTheme.primaryText)
                if installed.isLinked {
                    MonoTag("dev", color: DefaultTheme.mutedText)
                }
                Spacer()
                BarIconButton(systemImage: "arrow.clockwise") { extensions.reload(installed.id) }
                    .help("Reload the extension")
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(DefaultTheme.background)
            Divider().overlay(DefaultTheme.cardBorder)
            if let host = extensions.hosts[installed.id] {
                if let error = host.loadError {
                    notice(icon: "exclamationmark.triangle", title: "The extension could not load",
                           lines: [error], action: ("Retry", { extensions.reload(installed.id) }))
                } else {
                    ExtensionWebView(webView: host.webView)
                }
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func notice(icon: String, title: String, lines: [String],
                        action: (String, () -> Void)?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(DefaultTheme.mutedText)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DefaultTheme.primaryText)
                .multilineTextAlignment(.center)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 12))
                    .foregroundStyle(DefaultTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            if let action {
                AccentButton(action.0, action: action.1)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: 420)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What the rest of the app owes the extensions (ADR-0011): the theme as it
/// now is, the sessions as they now are, the sheets they ask for, and a live
/// session one of them wants on screen. A modifier of its own so ContentView's
/// body stays within the type checker's budget.
struct ExtensionsWiring: ViewModifier {
    let model: AppModel
    let onOpenSession: (SessionID) -> Void

    private var launchBinding: Binding<PendingExtensionLaunch?> {
        Binding(get: { model.extensions.pendingLaunch },
                set: { value in
                    guard value == nil, let shown = model.extensions.pendingLaunch else { return }
                    model.extensions.finishLaunch(BridgeLaunchResult(launched: false), for: shown)
                })
    }

    private var consentBinding: Binding<ExtensionConsentRequest?> {
        Binding(get: { model.extensions.consentRequest },
                set: { value in
                    if value == nil { model.extensions.consentRequest = nil }
                })
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: ThemeStore.shared.palette) {
                model.extensions.themeDidChange(model.bridgeTheme())
            }
            .onChange(of: model.sessions) { model.publishSessionSnapshot() }
            .onChange(of: model.allRecords) { model.publishSessionSnapshot() }
            .onChange(of: model.extensions.openSessionRequest) {
                guard let request = model.extensions.openSessionRequest,
                      let uuid = UUID(uuidString: request.sessionID) else { return }
                model.extensions.openSessionRequest = nil
                onOpenSession(SessionID(uuid))
            }
            .sheet(item: launchBinding) { request in
                ExtensionLaunchSheet(model: model, request: request)
            }
            // ADR-0012: an extension's page over everything, wherever the user is.
            .overlay {
                if let overlay = model.extensions.overlay {
                    ExtensionOverlayView(overlay: overlay) { model.extensions.dismissOverlayByUser() }
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.extensions.overlay?.id)
            .sheet(item: consentBinding) { request in
                ExtensionConsentSheet(request: request,
                                      onApprove: { model.extensions.confirm(request) },
                                      onCancel: { model.extensions.consentRequest = nil })
            }
    }
}

/// An extension's status in the top bar (ADR-0012): its icon, its text, and a
/// countdown Loom ticks itself.
struct ExtensionStatusChip: View {
    let item: ExtensionStatusItem
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 5) {
                if !item.text.isEmpty {
                    Text(item.text)
                } else {
                    Image(systemName: item.icon)
                }
                if let end = item.countdownTo {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.format(end.timeIntervalSince(context.date)))
                            .monospacedDigit()
                    }
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(DefaultTheme.primaryText)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 6))
            .hoverBrightness(0.1)
        }
        .buttonStyle(.plain)
        .help(item.tooltip ?? "")
    }

    /// 12:34, or 1:02:03 past an hour; never below zero.
    static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.up)))
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

/// The overlay (ADR-0012): the extension's page over the whole window, and
/// Loom's own bar with the time left and the dismiss button — never the
/// extension's to hide. Escape dismisses too.
struct ExtensionOverlayView: View {
    let overlay: ExtensionOverlay
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                // The traffic lights float over this corner (hidden title bar).
                Spacer().frame(width: 70)
                Image(systemName: "puzzlepiece.extension")
                    .foregroundStyle(DefaultTheme.accent)
                Text(overlay.extensionName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DefaultTheme.primaryText)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(ExtensionStatusChip.format(overlay.until.timeIntervalSince(context.date)) + " left")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(DefaultTheme.secondaryText)
                }
                GhostButton(overlay.dismissLabel, systemImage: "xmark", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(DefaultTheme.background)
            Divider().overlay(DefaultTheme.cardBorder)
            if let error = overlay.host.loadError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(DefaultTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ExtensionWebView(webView: overlay.host.webView, takesFocus: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DefaultTheme.contentBackground)
        .contentShape(Rectangle())
    }
}
