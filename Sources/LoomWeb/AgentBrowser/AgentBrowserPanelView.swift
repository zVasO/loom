import LoomUI
import SwiftUI

/// The agent's browser in the side panel: the same chrome as the user's,
/// under a caption that never changes height (the page must not resize under
/// the agent's actions), with the agent's activity and a page's dialog laid
/// OVER the page rather than above it.
public struct AgentBrowserPanelView: View {
    private let browser: AgentBrowser
    private let caption: String

    @State private var promptText = ""

    public init(browser: AgentBrowser, caption: String) {
        self.browser = browser
        self.caption = caption
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 9))
                    .foregroundStyle(DefaultTheme.mutedText)
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(DefaultTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(DefaultTheme.background)
            BrowserPanelView(controller: browser.controller,
                             emptyHint: "The agent hasn't opened a page yet — it will appear here.",
                             newTabAddress: "about:blank")
                .overlay(alignment: .top) { overlays }
        }
    }

    @ViewBuilder
    private var overlays: some View {
        VStack(spacing: 6) {
            if let activity = browser.activity, activity.isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("claude: " + activity.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(DefaultTheme.primaryText)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(DefaultTheme.surfaceRaised, in: Capsule())
                .overlay(Capsule().stroke(DefaultTheme.cardBorder, lineWidth: 1))
                .allowsHitTesting(false)
            }
            if let dialog = browser.activeDialog {
                dialogBanner(dialog)
            }
        }
        .padding(.top, 52)   // below the address bar and the tab strip
        .padding(.horizontal, 12)
    }

    /// Plain, page-like styling: the words are the page's, never Loom's —
    /// "<host> says:" first.
    private func dialogBanner(_ dialog: AgentModalState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(dialog.host) says:")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.8))
            if case .fileChooser = dialog.kind {
                Text("The page asks for a file.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.black)
            } else {
                Text(String(dialog.message.prefix(400)))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.black)
                    .lineLimit(6)
            }
            if case .prompt(let defaultText) = dialog.kind {
                TextField("", text: $promptText)
                    .textFieldStyle(.roundedBorder)
                    .onAppear { promptText = defaultText ?? "" }
            }
            HStack {
                Spacer()
                if dialog.kind != .alert {
                    Button("Cancel") { browser.answerDialog(accept: false, text: nil) }
                }
                Button("OK") { browser.answerDialog(accept: true, text: promptText) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(maxWidth: 360, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}
