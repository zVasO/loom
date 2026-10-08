import AppKit
import LoomCore
import LoomUI
import LoomWeb
import SwiftUI

/// The side panel beside a stack's terminal: one of the stack's browsers,
/// picked in its header. It belongs to the stack, not to the tab — a shell of
/// the stack shows the same panel.
struct SessionSidePanelView: View {
    let model: AppModel
    let parentID: SessionID

    private var state: SidePanelState { model.sidePanel(for: parentID) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DefaultTheme.cardBorder)
            content
        }
        .background(DefaultTheme.contentBackground)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                if model.hasAgentBrowser(parentID) || canHaveAgentBrowser {
                    Button { model.showAgentBrowser(for: parentID) } label: {
                        Label("Agent browser", systemImage: "sparkles")
                    }
                    Divider()
                }
                ForEach(model.panes(of: parentID)) { pane in
                    Button { model.showInSidePanel(.pane(pane.id), for: parentID) } label: {
                        Label(pane.title, systemImage: "globe")
                    }
                }
                Divider()
                Button { model.newPaneInSidePanel(for: parentID) } label: {
                    Label("New browser pane", systemImage: "plus")
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: sourceIcon)
                        .font(.system(size: 10))
                        .foregroundStyle(DefaultTheme.accent)
                    Text(sourceTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DefaultTheme.primaryText)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Which browser this panel shows")
            Spacer()
            HoverIconButton(systemImage: "xmark", help: "Hide the browser (⌘⇧B)") {
                model.closeSidePanel(for: parentID)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(DefaultTheme.background)
    }

    @ViewBuilder
    private var content: some View {
        switch state.source {
        case .pane(let id):
            if let pane = model.browserPane(id) {
                BrowserPanelView(controller: pane.controller, emptyHint: "+ to open a tab",
                                 onVisit: { model.recordVisit(url: $0, title: $1) })
                    .id(id)
            } else {
                emptyState
            }
        case .agent:
            agentContent
        case nil:
            emptyState
        }
    }

    /// A running claude session, browser tools on: its agent may have one.
    private var canHaveAgentBrowser: Bool {
        model.agentBrowserToolsEnabled
            && model.sessions.contains { $0.id == parentID && !$0.isShell }
    }

    /// The agent's browser — absent until the stack has one.
    @ViewBuilder
    private var agentContent: some View {
        if let browser = model.agentBrowsers[parentID] {
            AgentBrowserPanelView(browser: browser, caption: model.agentBrowserCaption(for: parentID),
                                  defaultWidth: model.agentDefaultWidth(for: parentID))
                .id(ObjectIdentifier(browser))
        } else {
            VStack(spacing: 8) {
                Text("The agent's browser")
                    .foregroundStyle(DefaultTheme.secondaryText)
                Text("It opens the first time claude uses it — or pick it in the menu above to sign in to your app first.")
                    .font(.system(size: 12))
                    .foregroundStyle(DefaultTheme.mutedText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("Nothing to show")
                .foregroundStyle(DefaultTheme.secondaryText)
            Text("Pick a browser in the menu above")
                .font(.system(size: 12))
                .foregroundStyle(DefaultTheme.mutedText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sourceTitle: String {
        switch state.source {
        case .agent: return "Agent browser"
        case .pane(let id): return model.browserPane(id)?.title ?? "Browser"
        case nil: return "Browser"
        }
    }

    private var sourceIcon: String {
        state.source == .agent ? "sparkles" : "globe"
    }
}

/// The divider between the terminal and the panel: a slot of its own, so its
/// hit area overlaps neither the terminal (whose mouse monitors would take the
/// press, and send it to claude) nor the web view.
struct SidePanelResizeHandle: View {
    var isEnabled = true

    var body: some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(DefaultTheme.cardBorder)
                .frame(width: 1)
        }
        .frame(width: SidePanelLayout.handleWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        // set(), not push()/pop(): a hover whose exit is missed would leave
        // the resize cursor stuck on the stack.
        .onHover { inside in
            (inside && isEnabled ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
        }
    }
}
