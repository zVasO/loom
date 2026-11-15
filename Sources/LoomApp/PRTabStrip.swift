import LoomCore
import LoomGit
import LoomUI
import SwiftUI

/// The open pull requests, one tab each, in Review's top bar. A preview tab
/// (italic) is the one the next PR opened from the Projects tab reuses; a
/// pinned one — anything opened from Browse — stays until closed. ⌘W closes the active tab, ⌘⇧] / ⌘⇧[ move along,
/// ⌘⇧P pins.
struct PRTabStrip: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DefaultTheme.space(4)) {
                    ForEach(model.prTabs.tabs) { tab in
                        // The session's id, not its state: which session a
                        // PR has changes when one starts or goes, its state
                        // at every turn of the agent. The dot reads that.
                        PRTabButton(model: model, tab: tab,
                                    isActive: tab.id == model.prTabs.activeID,
                                    sessionID: model.reviewSession(forPR: tab.pr.number,
                                                                   in: tab.projectID),
                                    onSelect: { model.activatePRTab(tab.id) },
                                    onPin: { model.pinPRTab(tab.id) },
                                    onClose: { model.closePRTab(tab.id) },
                                    onCloseOthers: { model.closeOtherPRTabs(tab.id) })
                    }
                    PRReviewsOpening(model: model)
                }
                .padding(.horizontal, DefaultTheme.space(8)).padding(.vertical, DefaultTheme.space(6))
            }
        }
        .background(DefaultTheme.background)
    }
}

/// A session's state as a dot. It reads the live sessions itself, so a
/// transition repaints the dot and nothing around it: the tab strip, the
/// drawer's handle and the review tabs used to be handed the state by a
/// parent that re-ran — workspace and diff included — at every transition
/// of every session (audit 2026-11-15).
struct SessionStateDot: View {
    let model: AppModel
    let id: SessionID
    var size: CGFloat = 5
    /// What the tooltip says before the state's name; nil for no tooltip.
    var helpPrefix: String? = nil
    /// A dormant session has no state. true: a hollow ring stands for it
    /// (resumed on click). false: nothing shows.
    var hollowWhenDormant = false

    var body: some View {
        let state: SessionState? = model.sessions.first(where: { $0.id == id })?.state
        if let state {
            if let helpPrefix {
                dot(state).help(helpPrefix + DefaultTheme.label(for: state))
            } else {
                dot(state)
            }
        } else if hollowWhenDormant {
            Circle()
                .stroke(DefaultTheme.mutedText, lineWidth: 1)
                .frame(width: size, height: size)
        }
    }

    private func dot(_ state: SessionState) -> some View {
        Circle()
            .fill(DefaultTheme.badgeColor(for: state))
            .frame(width: size, height: size)
    }
}

/// The reviews asked for by reference (a URL typed in the palette) whose
/// pull request GitHub has not answered for yet: no tab can show them, this
/// does — a spinner and the reference each, gone when the tab opens or the
/// attempt ends.
struct PRReviewsOpening: View {
    let model: AppModel

    var body: some View {
        ForEach(Array(model.prReviewsOpening.enumerated()), id: \.offset) { _, reference in
            HStack(spacing: DefaultTheme.space(6)) {
                ProgressView().controlSize(.mini)
                Text("Opening \(Self.label(reference))…")
                    .themeFont(size: 11)
                    .foregroundStyle(DefaultTheme.secondaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, DefaultTheme.space(9)).padding(.vertical, DefaultTheme.space(5))
            .help("Asking GitHub for the pull request — its review starts as soon as it answers")
        }
    }

    /// `owner/name#12`, or `#12` for a number typed alone.
    static func label(_ reference: PRReference) -> String {
        guard let repo = reference.repo else { return "#\(reference.number)" }
        return "\(repo)#\(reference.number)"
    }
}

/// Invisible buttons carrying the tab key equivalents. Mounted for the
/// whole PRs tab, tabs open or not, Browse or Review: once the last tab is
/// closed, one ⌘W too many must land here (a no-op) and not on File › Close,
/// which would close the only window — and the app with it. They act in
/// Review only: in Browse no tab is on screen to close or move along.
struct PRTabShortcuts: View {
    let model: AppModel

    private var reviewing: Bool { model.prMode == .review }

    var body: some View {
        Group {
            Button("Close tab") {
                guard reviewing, let id = model.prTabs.activeID else { return }
                model.closePRTab(id)
            }
            .keyboardShortcut("w", modifiers: .command)
            Button("Next tab") { if reviewing { model.nextPRTab() } }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous tab") { if reviewing { model.previousPRTab() } }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Pin tab") {
                guard reviewing, let id = model.prTabs.activeID else { return }
                model.pinPRTab(id)
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
    let model: AppModel
    let tab: PRTab
    let isActive: Bool
    /// The PR's review session, live or not — nil when it never had one.
    let sessionID: SessionID?
    let onSelect: () -> Void
    let onPin: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: DefaultTheme.space(6)) {
            AppIcon("arrow.triangle.pull", size: 11)
                .foregroundStyle(isActive ? DefaultTheme.accentInk : DefaultTheme.secondaryText)
            if let sessionID {
                // Shows while the session runs; nothing for a dormant one.
                SessionStateDot(model: model, id: sessionID, helpPrefix: "Review session: ")
            }
            Text("#\(tab.pr.number)")
                .themeFont(size: 10, weight: .bold, design: .monospaced)
                .foregroundStyle(isActive ? DefaultTheme.accentInk : DefaultTheme.secondaryText)
            Text(tab.pr.title)
                .themeFont(size: 11, weight: isActive ? .semibold : .regular)
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
        .padding(.horizontal, DefaultTheme.space(9)).padding(.vertical, DefaultTheme.space(5))
        .background(isActive ? DefaultTheme.surfaceRaised
                    : hovered ? DefaultTheme.surfaceRaised.opacity(0.5) : .clear,
                    in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
        .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(6))
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
