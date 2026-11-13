import AppKit
import LoomCore
import SwiftUI

// The conversation of a native session as a chat: what claude said as
// Markdown, what the user sent as bubbles, tool calls and thoughts folded to
// a line each. The views take values and closures only — reading claude's
// file and typing into the session's terminal are the app's.

/// The list's arithmetic and vocabulary, kept pure for the tests.
enum ConversationLayout {
    /// The widest the column of messages gets: prose stays readable in a
    /// pane as wide as a terminal.
    static let columnWidth: CGFloat = 760
    /// How far above the end still reads as "at the end": a line or two of
    /// slack, so a trackpad's rest does not stop the list from following.
    static let followSlack: CGFloat = 48

    /// `contentEnd` is where the conversation ends, measured in the scroll
    /// view's own space: at the bottom it is the viewport's height (less for
    /// a conversation shorter than the pane), and every point scrolled up
    /// pushes it one point below.
    static func isAtBottom(contentEnd: CGFloat, viewportHeight: CGFloat) -> Bool {
        contentEnd - viewportHeight <= followSlack
    }

    /// The most a user's bubble takes: four fifths of the column, so it
    /// still reads as set to one side.
    static func bubbleWidth(viewportWidth: CGFloat, margin: CGFloat) -> CGFloat {
        max(0, min(columnWidth, viewportWidth - 2 * margin)) * 0.8
    }

    /// The icon of a tool's family, as an SF Symbol name for `AppIcon`.
    static func toolIcon(for name: String) -> String {
        switch name {
        case "Bash", "BashOutput": return "terminal"
        case "Read": return "doc.text"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "pencil"
        case "Grep", "Glob": return "magnifyingglass"
        case "Task", "Agent": return "person.2"
        default: return name.hasPrefix("Web") ? "globe" : "wrench"
        }
    }
}

private extension ConversationEntry.Kind {
    var isUser: Bool {
        if case .user = self { return true }
        return false
    }

    /// Shown as one closed line: a run of them reads as one block.
    var isFolded: Bool {
        switch self {
        case .tool, .thinking: return true
        case .user, .assistant, .notice: return false
        }
    }
}

// MARK: - The list

public struct ConversationList: View {
    private let entries: [ConversationEntry]
    private let isWorking: Bool
    private let emptyTitle: String
    private let emptyDetail: String

    /// The tool calls and thoughts the reader opened. Here, not in the
    /// rows: a lazy stack lets go of a row that scrolls away, and the
    /// entries are replaced under it each time claude's file grows.
    @State private var opened: Set<String> = []
    /// False once the reader scrolled up: the list then stays where they are.
    @State private var atBottom = true

    /// The scroll view's own space: where the end of the conversation is measured.
    private static let scroll = "loom.conversation.scroll"
    private static let endID = "loom.conversation.end"

    /// What changes when the conversation gains something at its end.
    private struct Tail: Equatable {
        let count: Int
        let lastID: String?
        let isWorking: Bool
    }

    /// The scrolling list of a conversation, newest at the bottom and kept
    /// there while the reader is at the bottom.
    public init(entries: [ConversationEntry], isWorking: Bool, emptyTitle: String, emptyDetail: String) {
        self.entries = entries
        self.isWorking = isWorking
        self.emptyTitle = emptyTitle
        self.emptyDetail = emptyDetail
    }

    public var body: some View {
        if entries.isEmpty {
            empty
        } else {
            GeometryReader { viewport in
                list(viewport: viewport.size)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: DefaultTheme.space(6)) {
            Text(emptyTitle)
                .themeFont(size: 15, weight: .semibold)
                .foregroundStyle(DefaultTheme.primaryText)
            Text(emptyDetail)
                .themeFont(size: 12)
                .foregroundStyle(DefaultTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(DefaultTheme.space(24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func list(viewport: CGSize) -> some View {
        let margin: CGFloat = DefaultTheme.space(20)
        let bubble: CGFloat = ConversationLayout.bubbleWidth(viewportWidth: viewport.width, margin: margin)
        // A call without a result is still running only in the turn being
        // written: one left open by an interruption never ran to its end.
        let lastUser: Int = entries.lastIndex(where: { $0.kind.isUser }) ?? -1
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    // Lazy: a long conversation holds more paragraphs than
                    // the Markdown cache, and only the rows on screen may ask it.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            ConversationEntryRow(entry: entry,
                                                 isOpen: opened.contains(entry.id),
                                                 isRunning: isWorking && index > lastUser,
                                                 bubbleWidth: bubble,
                                                 onToggle: { toggle(entry.id) })
                                .padding(.top, gap(before: index))
                        }
                        if isWorking {
                            StatusLabel(.working)
                                .padding(.top, DefaultTheme.space(14))
                        }
                    }
                    .padding(.vertical, DefaultTheme.space(16))
                    // Outside the lazy stack, and last: the end must report
                    // where it is even a long way under the viewport, and
                    // scrolling to it must show everything above it.
                    endMarker(viewportHeight: viewport.height)
                }
                .frame(maxWidth: ConversationLayout.columnWidth)
                .padding(.horizontal, margin)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .coordinateSpace(name: Self.scroll)
            // The anchor holds the bottom when the content grows; this covers
            // what it does not see. A reader who scrolled up is never moved.
            .onChange(of: tail) { _, _ in
                guard atBottom else { return }
                proxy.scrollTo(Self.endID, anchor: .bottom)
            }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom {
                    JumpToLatestButton {
                        withAnimation(.hover) { proxy.scrollTo(Self.endID, anchor: .bottom) }
                    }
                    .padding(.trailing, DefaultTheme.space(16))
                    .padding(.bottom, DefaultTheme.space(12))
                }
            }
        }
    }

    private var tail: Tail {
        Tail(count: entries.count, lastID: entries.last?.id, isWorking: isWorking)
    }

    /// Folded rows sit close to each other; a message keeps its distance.
    private func gap(before index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        let tight = entries[index].kind.isFolded && entries[index - 1].kind.isFolded
        return tight ? DefaultTheme.space(4) : DefaultTheme.space(14)
    }

    private func toggle(_ id: String) {
        if opened.contains(id) {
            opened.remove(id)
        } else {
            opened.insert(id)
        }
    }

    private func endMarker(viewportHeight: CGFloat) -> some View {
        Color.clear
            .frame(height: 1)
            .background {
                GeometryReader { end in
                    let pinned = ConversationLayout.isAtBottom(
                        contentEnd: end.frame(in: .named(Self.scroll)).maxY,
                        viewportHeight: viewportHeight)
                    // Written only when it flips: the end moves with every
                    // point scrolled, and a state write there would re-run
                    // the list per frame.
                    Color.clear.onChange(of: pinned, initial: true) { _, now in
                        if atBottom != now { atBottom = now }
                    }
                }
            }
            .id(Self.endID)
    }
}

// MARK: - Rows

private struct ConversationEntryRow: View {
    let entry: ConversationEntry
    let isOpen: Bool
    let isRunning: Bool
    let bubbleWidth: CGFloat
    let onToggle: () -> Void

    var body: some View {
        switch entry.kind {
        case .assistant(let text):
            MarkdownBlockView(text, size: 13)
                .scrollingCode()
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .user(let text):
            UserBubble(text: text, maxWidth: bubbleWidth)
        case .thinking(let text):
            ThoughtRow(text: text, isOpen: isOpen, onToggle: onToggle)
        case .tool(let call):
            ToolCallRow(call: call, isOpen: isOpen, isRunning: isRunning, onToggle: onToggle)
        case .notice(let text):
            Text(text)
                .themeFont(size: 10.5, design: .monospaced)
                .foregroundStyle(DefaultTheme.mutedText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

/// What the user sent, set to the trailing side. Plain text, not Markdown:
/// a user's "*" is a "*".
private struct UserBubble: View {
    let text: String
    let maxWidth: CGFloat

    var body: some View {
        Text(text)
            .themeFont(size: 13)
            .foregroundStyle(DefaultTheme.primaryText)
            .textSelection(.enabled)
            .padding(.horizontal, DefaultTheme.space(12))
            .padding(.vertical, DefaultTheme.space(10))
            .background(DefaultTheme.surfaceRaised,
                        in: RoundedRectangle(cornerRadius: DefaultTheme.radius(10)))
            .frame(maxWidth: maxWidth, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// The line a folded row shows, and the button that opens it. The label is
/// not selectable: text selection would take the click.
private struct FoldedRowHeader<Content: View>: View {
    let isOpen: Bool
    let isError: Bool
    let onToggle: () -> Void
    @ViewBuilder let label: () -> Content
    @State private var hovered = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: DefaultTheme.space(6)) {
                AppIcon(isOpen ? "chevron.down" : "chevron.right", size: 11)
                    .foregroundStyle(DefaultTheme.mutedText)
                label()
                Spacer(minLength: 0)
            }
            .foregroundStyle(ink)
            .padding(.horizontal, DefaultTheme.space(6))
            .frame(height: DefaultTheme.size(24))
            .background(hovered ? DefaultTheme.wash2 : Color.clear,
                        in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
    }

    private var ink: Color {
        if isError { return DefaultTheme.danger }
        return hovered ? DefaultTheme.primaryText : DefaultTheme.secondaryText
    }
}

/// One tool call: its summary on a line, its input and its result under it
/// once opened.
private struct ToolCallRow: View {
    let call: ConversationEntry.ToolCall
    let isOpen: Bool
    let isRunning: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DefaultTheme.space(6)) {
            FoldedRowHeader(isOpen: isOpen, isError: call.isError, onToggle: onToggle) {
                AppIcon(ConversationLayout.toolIcon(for: call.name), size: 13)
                Text(call.summary)
                    .themeFont(size: 11.5, design: .monospaced)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if call.result == nil, isRunning {
                    ProgressView().controlSize(.mini)
                }
            }
            .help(call.summary)
            if isOpen {
                VStack(alignment: .leading, spacing: DefaultTheme.space(6)) {
                    if !call.input.isEmpty {
                        ToolTextBlock(text: call.input, isError: false)
                    }
                    if let result = call.result, !result.isEmpty {
                        ToolTextBlock(text: result, isError: call.isError)
                    }
                }
                // Under the summary, past the chevron.
                .padding(.leading, DefaultTheme.space(23))
                .padding(.bottom, DefaultTheme.space(4))
            }
        }
    }
}

/// A tool's input or result: as tall as its text up to `maxHeight`, then it
/// scrolls on its own — a long file read must not push the answer off screen.
private struct ToolTextBlock: View {
    let text: String
    let isError: Bool

    private static let maxHeight: CGFloat = 240

    var body: some View {
        ScrollView(.vertical) {
            Text(text)
                .themeFont(size: 11.5, design: .monospaced)
                .foregroundStyle(isError ? DefaultTheme.danger : DefaultTheme.primaryText.opacity(0.85))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DefaultTheme.space(10))
        }
        .frame(maxHeight: Self.maxHeight)
        // A scroll view takes all the height it is offered: asked for its
        // ideal one, it is its text's, and the frame above caps it.
        .fixedSize(horizontal: false, vertical: true)
        .background(DefaultTheme.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
    }
}

/// claude's thinking: a closed line until the reader asks for it.
private struct ThoughtRow: View {
    let text: String
    let isOpen: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DefaultTheme.space(6)) {
            FoldedRowHeader(isOpen: isOpen, isError: false, onToggle: onToggle) {
                Text("Thought")
                    .themeFont(size: 12)
                    .italic()
                    .foregroundStyle(DefaultTheme.mutedText)
            }
            if isOpen {
                Text(text)
                    .themeFont(size: 12)
                    .foregroundStyle(DefaultTheme.secondaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, DefaultTheme.space(23))
                    .padding(.bottom, DefaultTheme.space(4))
            }
        }
    }
}

/// Shown once the reader scrolled up: the way back to what claude says now.
private struct JumpToLatestButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            AppIcon("arrow.down", size: 14)
                .foregroundStyle(hovered ? DefaultTheme.primaryText : DefaultTheme.secondaryText)
                .frame(width: DefaultTheme.size(28), height: DefaultTheme.size(28))
                .background(DefaultTheme.surfaceRaised, in: Circle())
                .overlay(Circle().strokeBorder(hovered ? DefaultTheme.line3 : DefaultTheme.line2, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
        .help("Jump to latest")
    }
}

// MARK: - The composer

public struct ConversationComposer: View {
    @Binding private var text: String
    private let placeholder: String
    private let isEnabled: Bool
    private let isSending: Bool
    private let focusRequest: Int
    private let onSend: () -> Void
    @FocusState private var focused: Bool

    /// The message field and its Send button. Return sends, Shift-Return
    /// breaks the line. `focusRequest`: bump it to give the field the keyboard.
    public init(text: Binding<String>, placeholder: String, isEnabled: Bool, isSending: Bool,
                focusRequest: Int = 0, onSend: @escaping () -> Void) {
        _text = text
        self.placeholder = placeholder
        self.isEnabled = isEnabled
        self.isSending = isSending
        self.focusRequest = focusRequest
        self.onSend = onSend
    }

    private var canSend: Bool {
        isEnabled && !isSending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: DefaultTheme.space(8)) {
            // Never disabled: a message can be written while claude works,
            // only its sending waits.
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .themeFont(size: 13)
                .foregroundStyle(DefaultTheme.primaryText)
                .lineLimit(1...8)
                .focused($focused)
                .onKeyPress(.return, phases: [.down, .repeat]) { press in
                    handleReturn(press)
                }
                // Reached only if the key press above was not offered Return.
                .onSubmit { send() }
                // One line of text sits level with the button beside it.
                .padding(.vertical, DefaultTheme.space(5))
            sendControl
        }
        .padding(.horizontal, DefaultTheme.space(12))
        .padding(.vertical, DefaultTheme.space(10))
        .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(10)))
        .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(10))
            .strokeBorder(focused ? DefaultTheme.line2 : DefaultTheme.line, lineWidth: 1))
        .fieldEdge(radius: 10)
        // The same column as the messages above.
        .frame(maxWidth: ConversationLayout.columnWidth)
        .padding(.horizontal, DefaultTheme.space(20))
        .padding(.top, DefaultTheme.space(6))
        .padding(.bottom, DefaultTheme.space(14))
        .frame(maxWidth: .infinity)
        // The terminal takes the keyboard whenever no field holds it: the
        // composer asks for it by name, on arriving and when told to.
        .onAppear { focused = true }
        .onChange(of: focusRequest) { focused = true }
    }

    @ViewBuilder
    private var sendControl: some View {
        if isSending {
            ProgressView()
                .controlSize(.small)
                .frame(width: DefaultTheme.size(26), height: DefaultTheme.size(26))
        } else {
            SendButton(isEnabled: canSend, action: send)
        }
    }

    private func send() {
        guard canSend else { return }
        onSend()
    }

    private func handleReturn(_ press: KeyPress) -> KeyPress.Result {
        // Return first confirms what an input method is composing.
        if isComposing { return .ignored }
        if press.modifiers.contains(.shift) {
            breakLine()
            return .handled
        }
        // Option-Return is already a line break to a text field.
        if press.modifiers.contains(.option) || press.modifiers.contains(.control) {
            return .ignored
        }
        // A held key sends once.
        if press.phase == .down { send() }
        return .handled
    }

    private var isComposing: Bool {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        return editor.hasMarkedText()
    }

    /// Shift-Return is Return to a text field, which ends the editing. The
    /// line break is asked of the field's editor instead, which puts it
    /// where the caret is.
    private func breakLine() {
        let inserted = NSApp.sendAction(Selector(("insertNewlineIgnoringFieldEditor:")),
                                        to: nil, from: nil)
        if !inserted { text.append("\n") }
    }
}

/// The one call to action of the chat: round, accent-filled when there is
/// something to send.
private struct SendButton: View {
    let isEnabled: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            AppIcon("arrow.up", size: 14)
                .foregroundStyle(isEnabled ? DefaultTheme.accentText : DefaultTheme.mutedText)
                .frame(width: DefaultTheme.size(26), height: DefaultTheme.size(26))
                .background(isEnabled ? DefaultTheme.accent : DefaultTheme.surfaceRaised, in: Circle())
                .brightness(isEnabled && hovered ? 0.06 : 0)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
        .help("Send")
    }
}
