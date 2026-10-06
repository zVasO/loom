import LoomUI
import SwiftUI

/// The agent's browser in the side panel: the same chrome as the user's,
/// under a caption that never changes height (the page must not resize under
/// the agent's actions), with the agent's activity and a page's dialog laid
/// OVER the page rather than above it.
public struct AgentBrowserPanelView: View {
    private let browser: any AgentBrowserEngine
    private let caption: String
    /// The project whose default width the menu can set, and how — nil for
    /// a session without one, or a review (it reads the default, never writes it).
    private let defaultWidth: DefaultWidth?

    @State private var promptText = ""

    /// A project's default page width, as the panel's menu shows and sets it.
    public struct DefaultWidth {
        public var projectName: String
        public var current: ViewportWidth
        public var set: @MainActor (ViewportWidth) -> Void

        public init(projectName: String, current: ViewportWidth, set: @escaping @MainActor (ViewportWidth) -> Void) {
            self.projectName = projectName
            self.current = current
            self.set = set
        }
    }

    public init(browser: any AgentBrowserEngine, caption: String, defaultWidth: DefaultWidth? = nil) {
        self.browser = browser
        self.caption = caption
        self.defaultWidth = defaultWidth
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
                widthMenu
            }
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(DefaultTheme.background)
            page
                .overlay(alignment: .top) { overlays }
        }
    }

    @ViewBuilder
    private var page: some View {
        switch browser.panelContent {
        case .webKit(let controller):
            BrowserPanelView(controller: controller,
                             emptyHint: "The agent hasn't opened a page yet — it will appear here.",
                             newTabAddress: "about:blank")
        }
    }

    /// The page's width: the panel's, or a laptop's scaled into it — a
    /// layout the terminal's 80 columns would otherwise squeeze to mobile.
    private var widthMenu: some View {
        Menu {
            ForEach(ViewportWidth.presets, id: \.label) { width in
                Button {
                    browser.setViewportWidth(width)
                } label: {
                    if width == browser.viewportWidth {
                        Label(width.label, systemImage: "checkmark")
                    } else {
                        Text(width.label)
                    }
                }
            }
            if !ViewportWidth.presets.contains(browser.viewportWidth) {
                Divider()
                Label(browser.viewportWidth.label + " (set by claude)", systemImage: "checkmark")
            }
            if let defaultWidth {
                Divider()
                if defaultWidth.current == browser.viewportWidth {
                    Text("Default for \(defaultWidth.projectName): \(defaultWidth.current.label)")
                } else {
                    Button("Use \(browser.viewportWidth.label) as default for \(defaultWidth.projectName)") {
                        defaultWidth.set(browser.viewportWidth)
                    }
                }
            }
        } label: {
            Text(browser.viewportWidth == .fit ? "Fit" : browser.viewportWidth.label)
                .font(.system(size: 10))
                .foregroundStyle(DefaultTheme.secondaryText)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("This session's page width: the panel's, or another scaled to fit. New sessions open at the project's default (Settings).")
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
                    // Return answers only from the banner's own field: a
                    // window-wide default button would take claude's Return.
                    .onSubmit { browser.answerDialog(accept: true, text: promptText) }
            }
            HStack {
                Spacer()
                if dialog.kind != .alert {
                    Button("Cancel") { browser.answerDialog(accept: false, text: nil) }
                }
                Button("OK") { browser.answerDialog(accept: true, text: promptText) }
            }
        }
        .padding(12)
        .frame(maxWidth: 360, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}
