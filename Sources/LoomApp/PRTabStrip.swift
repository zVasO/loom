import LoomCore
import LoomGit
import LoomUI
import SwiftUI

/// The open pull requests, one tab each, over the PR toolbar. A preview tab
/// (italic) is the one the next click in the list reuses; a pinned one
/// stays until closed. ⌘W closes the active tab, ⌘⇧] / ⌘⇧[ move along,
/// ⌘⇧P pins.
struct PRTabStrip: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.prTabs.tabs) { tab in
                        PRTabButton(tab: tab,
                                    isActive: tab.id == model.prTabs.activeID,
                                    sessionState: sessionState(of: tab),
                                    onSelect: { model.activatePRTab(tab.id) },
                                    onPin: { model.pinPRTab(tab.id) },
                                    onClose: { model.closePRTab(tab.id) },
                                    onCloseOthers: { model.closeOtherPRTabs(tab.id) })
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
            }
            shortcuts
        }
        .background(DefaultTheme.background)
    }

    /// The tab's review session state, for the dot — nil without a session.
    private func sessionState(of tab: PRTab) -> SessionState? {
        guard let id = model.reviewSession(forPR: tab.pr.number, in: tab.projectID) else { return nil }
        return model.sessions.first { $0.id == id }?.state
    }

    /// Invisible buttons carry the key equivalents; they exist only while a
    /// tab is on screen, so ⌘W means "close the tab" here and nothing
    /// elsewhere.
    private var shortcuts: some View {
        Group {
            Button("Close tab") {
                if let id = model.prTabs.activeID { model.closePRTab(id) }
            }
            .keyboardShortcut("w", modifiers: .command)
            Button("Next tab") { model.nextPRTab() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous tab") { model.previousPRTab() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Pin tab") {
                if let id = model.prTabs.activeID { model.pinPRTab(id) }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
    }
}

/// One PR tab, in the language of the stack bar: icon, "#n title", the
/// review session's dot, close cross on hover or when active. Italic while
/// it is only a preview; a pin appears on hover to keep it.
struct PRTabButton: View {
    let tab: PRTab
    let isActive: Bool
    let sessionState: SessionState?
    let onSelect: () -> Void
    let onPin: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 9))
                .foregroundStyle(isActive ? DefaultTheme.accent : DefaultTheme.secondaryText)
            if let sessionState {
                Circle().fill(DefaultTheme.badgeColor(for: sessionState)).frame(width: 5, height: 5)
                    .help("Review session: " + DefaultTheme.label(for: sessionState))
            }
            Text("#\(tab.pr.number)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(isActive ? DefaultTheme.accent : DefaultTheme.secondaryText)
            Text(tab.pr.title)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .italic(tab.isPreview)
                .foregroundStyle(isActive || hovered ? DefaultTheme.primaryText
                                                     : DefaultTheme.secondaryText)
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            if tab.isPreview, hovered || isActive {
                HoverIconButton(systemImage: "pin", help: "Keep this tab (⌘⇧P)", action: onPin)
            }
            if hovered || isActive {
                HoverIconButton(systemImage: "xmark", help: "Close (⌘W)", action: onClose)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(isActive ? DefaultTheme.surfaceRaised
                    : hovered ? DefaultTheme.surfaceRaised.opacity(0.5) : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(isActive ? DefaultTheme.cardBorder : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .help(tab.isPreview ? "Preview — the next click in the list replaces it; double-click or pin to keep"
                            : tab.pr.title)
        .onTapGesture(count: 2, perform: onPin)
        .onTapGesture(perform: onSelect)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
        .contextMenu {
            if tab.isPreview { Button("Keep this tab", action: onPin) }
            Button("Close", action: onClose)
            Button("Close others", action: onCloseOthers)
            Divider()
            Button("Open on GitHub") {
                if let url = URL(string: tab.pr.url) { NSWorkspace.shared.open(url) }
            }
        }
    }
}
