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
    /// Sent, not yet in claude's file: shown at once, paler, until it is.
    private let pending: [ConversationEntry]
    private let emptyTitle: String
    private let emptyDetail: String

    /// The tool calls and thoughts the reader opened. Here, not in the
    /// rows: a lazy stack lets go of a row that scrolls away, and the
    /// entries are replaced under it each time claude's file grows.
    @State private var opened: Set<String> = []
    /// False once the reader scrolled up: the list then stays where they are.
    @State private var atBottom = true
    /// How many of the last rows are laid out.
    @State private var shown = ConversationList.page
    /// The one row whose text can be selected: the one the pointer rests
    /// on. Selectable text is a platform view per paragraph, and a list
    /// where every row had it cost a third of each scrolled frame.
    @State private var armed: String?
    @State private var arming: Task<Void, Never>?

    /// The scroll view's own space: where the end of the conversation is measured.
    private static let scroll = "loom.conversation.scroll"
    private static let endID = "loom.conversation.end"

    /// What changes when the conversation gains something at its end.
    private struct Tail: Equatable {
        let count: Int
        let lastID: String?
        let isWorking: Bool
        let pending: Int
    }

    /// The scrolling list of a conversation, newest at the bottom and kept
    /// there while the reader is at the bottom.
    public init(entries: [ConversationEntry], isWorking: Bool, pending: [ConversationEntry] = [],
                emptyTitle: String, emptyDetail: String) {
        self.entries = entries
        self.isWorking = isWorking
        self.pending = pending
        self.emptyTitle = emptyTitle
        self.emptyDetail = emptyDetail
    }

    public var body: some View {
        if entries.isEmpty, pending.isEmpty {
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
                    // Never lazy: a lazy stack anchored at the bottom opened
                    // on an empty viewport — black until a scroll — whenever
                    // its guess of the rows' heights was off. The last
                    // messages are laid out whole instead, and the earlier
                    // ones come a page at a time, on request.
                    VStack(alignment: .leading, spacing: 0) {
                        if hiddenCount > 0 {
                            EarlierMessagesButton(count: hiddenCount) { shown += Self.page * 2 }
                                .padding(.bottom, DefaultTheme.space(14))
                        }
                        rows(lastUser: lastUser, bubble: bubble)
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
            // On arriving, and when the pane changes size: to the end, once
            // laid out — what the anchor alone sometimes misses.
            .onAppear { pin(proxy) }
            .onChange(of: viewport) { _, _ in if atBottom { pin(proxy) } }
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

    /// To the end of the conversation, once the list is laid out — and once
    /// more a moment later, for rows that took their height late.
    private func pin(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async { proxy.scrollTo(Self.endID, anchor: .bottom) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard atBottom else { return }
            proxy.scrollTo(Self.endID, anchor: .bottom)
        }
    }

    /// How many of the last rows are laid out; a click on "earlier
    /// messages" brings twice as many more. Every row laid out is paid for
    /// at each scrolled frame, read or not: measured on the tour's Mac,
    /// 80 rows of Markdown took 15 ms of a frame's 16, 30 take 2.
    private static let page = 30

    /// The pointer came onto a row, or left it. A row is armed for
    /// selection once the pointer has rested on it a moment — never while
    /// rows only pass under it, as they do while the list scrolls — and
    /// stays so until another one is: a selection outlives the pointer.
    private func hover(_ inside: Bool, on id: String) {
        arming?.cancel()
        guard inside, armed != id else { return }
        arming = Task {
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            armed = id
        }
    }
    private var hiddenCount: Int { max(0, entries.count - shown) }

    /// The rows, in either stack.
    @ViewBuilder
    private func rows(lastUser: Int, bubble: CGFloat) -> some View {
        ForEach(Array(entries.enumerated()).dropFirst(hiddenCount), id: \.element.id) { index, entry in
            ConversationEntryRow(entry: entry,
                                 isOpen: opened.contains(entry.id),
                                 isRunning: isWorking && index > lastUser,
                                 bubbleWidth: bubble,
                                 isSelectable: armed == entry.id,
                                 onToggle: { toggle(entry.id) })
                // A value: when claude's file grows, only the
                // rows that changed are drawn again.
                .equatable()
                .onHover { hover($0, on: entry.id) }
                .padding(.top, gap(before: index))
        }
        ForEach(pending) { sent in
            UserBubble(text: sent.userText, images: sent.images, key: sent.id, maxWidth: bubble)
                .opacity(0.6)
                .padding(.top, DefaultTheme.space(14))
        }
        if isWorking {
            StatusLabel(.working)
                .padding(.top, DefaultTheme.space(14))
        }
    }

    private var tail: Tail {
        Tail(count: entries.count, lastID: entries.last?.id, isWorking: isWorking, pending: pending.count)
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

private struct ConversationEntryRow: View, Equatable {
    let entry: ConversationEntry
    let isOpen: Bool
    let isRunning: Bool
    let bubbleWidth: CGFloat
    /// Its text can be selected: the row the pointer rests on.
    var isSelectable = false
    /// Outside the comparison: it only reaches the list's own state.
    let onToggle: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry && lhs.isOpen == rhs.isOpen && lhs.isRunning == rhs.isRunning
            && lhs.bubbleWidth == rhs.bubbleWidth && lhs.isSelectable == rhs.isSelectable
    }

    var body: some View {
        // Through the environment: every text of the row follows.
        if isSelectable {
            content.textSelection(.enabled)
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch entry.kind {
        case .assistant(let text):
            MarkdownBlockView(text, size: 13)
                .scrollingCode()
                .frame(maxWidth: .infinity, alignment: .leading)
        case .user(let text):
            UserBubble(text: text, images: entry.images, key: entry.id, maxWidth: bubbleWidth)
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
    var images: [Data] = []
    var key = ""
    let maxWidth: CGFloat

    var body: some View {
        VStack(alignment: .trailing, spacing: DefaultTheme.space(6)) {
            if !images.isEmpty {
                MessageImages(key: key, images: images)
            }
            if !text.isEmpty {
                Text(text)
                    .themeFont(size: 13)
                    .foregroundStyle(DefaultTheme.primaryText)
                    .padding(.horizontal, DefaultTheme.space(12))
                    .padding(.vertical, DefaultTheme.space(10))
                    .background(DefaultTheme.surfaceRaised,
                                in: RoundedRectangle(cornerRadius: DefaultTheme.radius(10)))
            }
        }
        .frame(maxWidth: maxWidth, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

extension ConversationEntry {
    /// A user's message's text; empty for anything else.
    var userText: String {
        if case .user(let text) = kind { return text }
        return ""
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
                summary
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
                        ToolTextBlock(text: call.input, isError: false, isShell: call.name == "Bash")
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

extension ToolCallRow {
    /// "Bash docker exec …": the command in the theme's colours.
    var summary: Text {
        if call.name == "Bash", call.summary.hasPrefix("Bash ") {
            return Text("Bash ") + Text(ShellHighlighter.attributed(String(call.summary.dropFirst(5))))
        }
        return Text(call.summary)
    }
}

/// A tool's input or result: as tall as its text up to `maxHeight`, then it
/// scrolls on its own — a long file read must not push the answer off screen.
private struct ToolTextBlock: View {
    let text: String
    let isError: Bool
    /// A shell command: in colours.
    var isShell = false

    private static let maxHeight: CGFloat = 240

    var body: some View {
        ScrollView(.vertical) {
            (isShell && !isError ? Text(ShellHighlighter.attributed(text)) : Text(text))
                .themeFont(size: 11.5, design: .monospaced)
                .foregroundStyle(isError ? DefaultTheme.danger : DefaultTheme.primaryText.opacity(0.85))
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, DefaultTheme.space(23))
                    .padding(.bottom, DefaultTheme.space(4))
            }
        }
    }
}

/// At the top of a long conversation: the messages before the ones shown.
private struct EarlierMessagesButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Show earlier messages (\(count))")
                .themeFont(size: 11.5)
                .foregroundStyle(DefaultTheme.secondaryText)
                .padding(.horizontal, DefaultTheme.space(10))
                .frame(height: DefaultTheme.size(24))
                .background(DefaultTheme.surfaceRaised, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
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
    /// Pasted or dropped images, sent with the message.
    @Binding private var images: [ComposerImage]
    @State private var pasteWatch = ComposerPasteWatch()
    private let placeholder: String
    private let isEnabled: Bool
    private let isSending: Bool
    private let focusRequest: Int
    private let onSend: () -> Void
    /// Set while claude works: Stop interrupts its turn, and "Send now"
    /// interrupts it to send the message at once rather than after it.
    private let onStop: (() -> Void)?
    private let onSendNow: (() -> Void)?
    @FocusState private var focused: Bool

    /// The message field and its Send button. Return sends, Shift-Return
    /// breaks the line. `focusRequest`: bump it to give the field the keyboard.
    public init(text: Binding<String>, images: Binding<[ComposerImage]> = .constant([]),
                placeholder: String, isEnabled: Bool, isSending: Bool,
                focusRequest: Int = 0, onStop: (() -> Void)? = nil, onSendNow: (() -> Void)? = nil,
                onSend: @escaping () -> Void) {
        _text = text
        _images = images
        self.placeholder = placeholder
        self.isEnabled = isEnabled
        self.isSending = isSending
        self.focusRequest = focusRequest
        self.onStop = onStop
        self.onSendNow = onSendNow
        self.onSend = onSend
    }

    private var canSend: Bool {
        isEnabled && !isSending
            && (!images.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DefaultTheme.space(10)) {
            if !images.isEmpty {
                ComposerImageStrip(images: $images)
            }
            field
        }
        .padding(.horizontal, DefaultTheme.space(12))
        .padding(.vertical, DefaultTheme.space(10))
        .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(10)))
        .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(10))
            .strokeBorder(focused ? DefaultTheme.line2 : DefaultTheme.line, lineWidth: 1))
        .fieldEdge(radius: 10)
        // ⌘V with a picture: a thumbnail above the field.
        .onAppear {
            pasteWatch.start(isFocused: { focused }, onImages: { images.append(contentsOf: $0) })
        }
        .onDisappear { pasteWatch.stop() }
        .modifier(ComposerPlacement(focusRequest: focusRequest, focused: $focused))
    }

    private var field: some View {
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
                // Escape stops claude while it works, and is always taken:
                // left to the window, it leaves full screen.
                .onKeyPress(.escape) {
                    if isComposing { return .ignored }
                    onStop?()
                    return .handled
                }
                // Reached only if the key press above was not offered Return.
                .onSubmit { send() }
                // One line of text sits level with the button beside it.
                .padding(.vertical, DefaultTheme.space(5))
            sendControl
        }
    }
}

/// The composer's column and its keyboard: where it sits, and when it
/// takes the keyboard.
private struct ComposerPlacement: ViewModifier {
    let focusRequest: Int
    var focused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        content
        // The same column as the messages above.
        .frame(maxWidth: ConversationLayout.columnWidth)
        .padding(.horizontal, DefaultTheme.space(20))
        .padding(.top, DefaultTheme.space(6))
        .padding(.bottom, DefaultTheme.space(14))
        .frame(maxWidth: .infinity)
        // The terminal takes the keyboard whenever no field holds it: the
        // composer asks for it by name, on arriving and when told to. Not
        // from under an overlay of the window (the ⌘K palette), like the
        // terminal: the chat view may arrive under it — ⌘⇧M, a session
        // opened a moment ago — and what is typed in the palette is not a
        // message for claude.
        .onAppear { if !WindowOverlay.isUp { focused.wrappedValue = true } }
        .onChange(of: focusRequest) { if !WindowOverlay.isUp { focused.wrappedValue = true } }
        // The overlay is gone. When it left the keyboard to no one, the
        // composer has it, as a terminal would: asked once the overlay's
        // own field has left the window, and never taken from a view that
        // holds it.
        .onReceive(NotificationCenter.default.publisher(for: .loomWindowOverlayLowered)) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard let window = NSApp.mainWindow,
                      window.firstResponder == nil || window.firstResponder === window else { return }
                focused.wrappedValue = true
            }
        }
    }
}

extension ConversationComposer {

    @ViewBuilder
    private var sendControl: some View {
        if isSending {
            ProgressView()
                .controlSize(.small)
                .frame(width: DefaultTheme.size(26), height: DefaultTheme.size(26))
        } else {
            HStack(spacing: DefaultTheme.space(6)) {
                if let onSendNow, canSend {
                    ComposerIconButton(icon: "bolt", help: "Send now — interrupts claude, then sends",
                                       action: onSendNow)
                }
                if let onStop {
                    ComposerIconButton(icon: "stop.fill", help: "Stop claude (Esc in the terminal)",
                                       action: onStop)
                }
                SendButton(isEnabled: canSend, help: onSendNow == nil ? "Send"
                           : "Send — claude reads it once its turn ends", action: send)
            }
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
    var help = "Send"
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
        .help(help)
    }
}

/// A round secondary control beside Send: Stop, Send now.
private struct ComposerIconButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            AppIcon(icon, size: 12)
                .foregroundStyle(hovered ? DefaultTheme.primaryText : DefaultTheme.secondaryText)
                .frame(width: DefaultTheme.size(26), height: DefaultTheme.size(26))
                .background(DefaultTheme.surfaceRaised, in: Circle())
                .overlay(Circle().strokeBorder(hovered ? DefaultTheme.line3 : DefaultTheme.line2, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
        .help(help)
    }
}

// MARK: - A choice claude asks for

/// What claude asks in its terminal — a permission, a question with
/// options — set in the chat, with a button per option. The app reads it
/// off the screen and types the answer; the view only shows it.
public struct ConversationPromptCard: View {
    public struct Option: Identifiable, Equatable {
        public let number: Int
        public let label: String
        public var id: Int { number }
        public init(number: Int, label: String) {
            self.number = number
            self.label = label
        }
    }

    private let question: String
    private let context: [String]
    private let options: [Option]
    private let selected: Int?
    private let onChoose: (Option) -> Void
    private let onShowTerminal: () -> Void

    public init(question: String, context: [String], options: [Option], selected: Int?,
                onChoose: @escaping (Option) -> Void, onShowTerminal: @escaping () -> Void) {
        self.question = question
        self.context = context
        self.options = options
        self.selected = selected
        self.onChoose = onChoose
        self.onShowTerminal = onShowTerminal
    }

    /// The dialog's lines; under "Bash command", the command in colours.
    private var contextText: Text {
        var text = Text("")
        for (index, line) in context.enumerated() {
            if index > 0 { text = text + Text("\n") }
            let isCommand = index == 1 && context.first?.lowercased().hasPrefix("bash") == true
            text = text + (isCommand ? Text(ShellHighlighter.attributed(line)) : Text(line))
        }
        return text
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DefaultTheme.space(10)) {
            HStack(spacing: DefaultTheme.space(8)) {
                Circle().fill(DefaultTheme.badgeColor(for: .needsInput)).frame(width: 7, height: 7)
                Text(question)
                    .themeFont(size: 13, weight: .semibold)
                    .foregroundStyle(DefaultTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(action: onShowTerminal) {
                    AppIcon("terminal", size: 12).foregroundStyle(DefaultTheme.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Show the terminal")
            }
            if !context.isEmpty {
                contextText
                    .themeFont(size: 11.5, design: .monospaced)
                    .foregroundStyle(DefaultTheme.primaryText.opacity(0.85))
                    .textSelection(.enabled)
                    .lineLimit(10)
                    // Its lines, even in a short pane: the list above gives way.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DefaultTheme.space(10))
                    .background(DefaultTheme.surfaceRaised,
                                in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
            }
            VStack(alignment: .leading, spacing: DefaultTheme.space(4)) {
                ForEach(options) { option in
                    PromptOptionButton(option: option, isFirst: option.number == 1,
                                       isSelected: option.number == selected) { onChoose(option) }
                }
            }
        }
        .padding(DefaultTheme.space(12))
        .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(10)))
        .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(10))
            .strokeBorder(DefaultTheme.badgeColor(for: .needsInput).opacity(0.6), lineWidth: 1))
        .frame(maxWidth: ConversationLayout.columnWidth)
        .padding(.horizontal, DefaultTheme.space(20))
        .padding(.top, DefaultTheme.space(8))
        .frame(maxWidth: .infinity)
    }
}

private struct PromptOptionButton: View {
    let option: ConversationPromptCard.Option
    let isFirst: Bool
    let isSelected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: DefaultTheme.space(8)) {
                Text("\(option.number)")
                    .themeFont(size: 11, weight: .semibold, design: .monospaced)
                    .foregroundStyle(isFirst ? DefaultTheme.accentText : DefaultTheme.secondaryText)
                    .frame(width: DefaultTheme.size(18), height: DefaultTheme.size(18))
                    .background(isFirst ? DefaultTheme.accent : DefaultTheme.surfaceRaised,
                                in: RoundedRectangle(cornerRadius: DefaultTheme.radius(4)))
                Text(option.label)
                    .themeFont(size: 12.5, weight: isSelected ? .medium : .regular)
                    .foregroundStyle(DefaultTheme.primaryText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DefaultTheme.space(8))
            .padding(.vertical, DefaultTheme.space(6))
            .background(hovered ? DefaultTheme.wash2 : Color.clear,
                        in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
    }
}
