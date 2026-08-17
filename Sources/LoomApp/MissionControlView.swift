import LoomAgents
import LoomCore
import LoomTerminal
import LoomUI
import SwiftUI

/// v2 — Mission Control: the whole fleet at a glance. Every live claude
/// session as a card with a LIVE terminal preview, its state and branch;
/// one click dives into the session. This is the orchestrator's cockpit:
/// spot the session that needs input without cycling through tabs.
struct MissionControlView: View {
    let model: AppModel
    let onOpen: (SessionID) -> Void

    private var fleet: [AppModel.SessionItem] {
        model.sessions.filter { !$0.isShell }
    }

    var body: some View {
        ScrollView {
            if fleet.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 34))
                        .foregroundStyle(DefaultTheme.secondaryText)
                    Text("No live session")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DefaultTheme.primaryText)
                    Text("⌘N starts one in the current project.")
                        .font(.system(size: 12))
                        .foregroundStyle(DefaultTheme.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 120)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 14)],
                          spacing: 14) {
                    ForEach(fleet) { item in
                        FleetCard(model: model, item: item) { onOpen(item.id) }
                    }
                }
                .padding(20)
            }
        }
        .background(DefaultTheme.background)
    }
}

/// One session of the fleet: header (title, state), live terminal preview,
/// branch footer. The border takes the state color when the session needs
/// attention — amber is what you scan for.
private struct FleetCard: View {
    let model: AppModel
    let item: AppModel.SessionItem
    let onOpen: () -> Void
    @State private var surface: TerminalSurface?
    @State private var hovered = false
    @State private var quickReply = ""
    @State private var usage: ClaudeNativeSessions.SessionUsage?

    private var borderColor: Color {
        if item.state == .needsInput { return DefaultTheme.badgeColor(for: .needsInput).opacity(0.8) }
        if hovered { return DefaultTheme.accent.opacity(0.5) }
        return DefaultTheme.cardBorder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(model.project(item.projectID)?.name ?? "—")
                    .font(.system(size: 11))
                    .foregroundStyle(DefaultTheme.secondaryText)
                Text("/").foregroundStyle(DefaultTheme.mutedText)
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DefaultTheme.primaryText)
                    .lineLimit(1)
                Spacer()
                StatusLabel(item.state)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)

            Divider().overlay(DefaultTheme.cardBorder)

            preview
                .frame(height: 170)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(DefaultTheme.contentBackground)
                .clipped()

            // v3 — instant reply: answer the agent right from the fleet,
            // without opening the session.
            if item.state == .needsInput, let surface {
                Divider().overlay(DefaultTheme.cardBorder)
                TextField("Reply to the agent…", text: $quickReply)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(DefaultTheme.primaryText)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .onSubmit {
                        let text = quickReply.trimmingCharacters(in: .whitespaces)
                        guard !text.isEmpty else { return }
                        surface.send(text + "\r")
                        quickReply = ""
                    }
            }
            if item.branch != nil || usage != nil {
                Divider().overlay(DefaultTheme.cardBorder)
                HStack(spacing: 10) {
                    if let branch = item.branch {
                        MonoTag(branch, systemImage: "arrow.triangle.branch",
                                color: DefaultTheme.secondaryText)
                    }
                    Spacer()
                    if let usage {
                        MonoTag("ctx \(SessionDetailView.tokens(usage.contextTokens))",
                                systemImage: "gauge.with.needle",
                                color: DefaultTheme.mutedText)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
            }
        }
        .background(DefaultTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(borderColor, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
        .task {
            surface = await model.surface(for: item.id)
            // P1 perf: the native .jsonl can be MBs — read only its tail, off
            // the main actor (the context figure lives in the LAST entry).
            let id = item.id
            usage = await Task.detached(priority: .utility) {
                ClaudeNativeSessions.usage(for: id, tailBytes: 65_536)
            }.value
        }
    }

    /// Live miniature: the LAST populated screen lines, tiny mono type. The
    /// surface stays attached while the card is visible — frames keep flowing.
    @ViewBuilder
    private var preview: some View {
        if let surface {
            MiniTerminalPreview(surface: surface)
                .task { await surface.attached() }
        } else {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct MiniTerminalPreview: View {
    let surface: TerminalSurface

    private var lines: [String] {
        // P2 perf: find the populated tail FIRST, then map only what we show.
        let all = surface.screen.lines
        var end = all.count
        while end > 0, all[end - 1].cells.allSatisfy({ $0.character == " " }) { end -= 1 }
        let start = max(0, end - 22)
        return all[start..<end].map { String($0.cells.prefix(120).map(\.character)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(DefaultTheme.primaryText.opacity(0.85))
                    .lineLimit(1)
            }
        }
        .padding(8)
    }
}
