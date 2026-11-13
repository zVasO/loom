import LoomAgents
import LoomCore
import LoomTerminal
import LoomUI
import SwiftUI

/// The chat view of a session (ADR-0023): the conversation of its native
/// session, read from claude's own file, over a composer whose messages go
/// to claude through the session's terminal. A second view of the same
/// session, never a second source: nothing is kept here that the file or
/// the terminal does not hold.
@MainActor
struct SessionChatPane: View {
    let model: AppModel
    let sessionID: SessionID
    /// The way back to the terminal, where a permission prompt is answered.
    let onShowTerminal: () -> Void

    @State private var entries: [ConversationEntry] = []
    /// The conversation `entries` were read from: another one empties the list.
    @State private var shownNative: SessionID?
    @State private var draft = ""
    @State private var isSending = false
    @State private var sendFailed = false
    /// What the journal last said the session waits on, and the state it
    /// said it under.
    @State private var journal: JournalAnswer?

    private struct JournalAnswer: Equatable {
        var wait: AppModel.SessionWait
        var state: SessionState?
    }

    private var item: AppModel.SessionItem? {
        model.sessions.first { $0.id == sessionID }
    }

    /// The conversation the process serves: another one after a `/resume`
    /// or a `/clear` typed in the terminal.
    private var nativeID: SessionID { model.nativeSessionID(for: sessionID) }

    /// The process runs: the file may still grow, and claude can be written to.
    private var isLive: Bool {
        guard let item, !item.isDormant else { return false }
        switch item.state {
        case .starting, .working, .needsInput, .idle: return true
        case .draft, .completed, .failed, .interrupted, .archived: return false
        }
    }

    /// What the session waits on, once the journal has answered for the
    /// state it is in now: an answer read under another state says nothing
    /// of this one.
    private var knownWait: AppModel.SessionWait? {
        guard let journal, journal.state == item?.state else { return nil }
        return journal.wait
    }

    /// A tool call of the turn being written has no result yet: what a
    /// permission prompt, when one is up, is about.
    private var hasOpenToolCall: Bool {
        for entry in entries.reversed() {
            switch entry.kind {
            case .user:
                return false
            case .tool(let call):
                if call.result == nil { return true }
            case .assistant, .thinking, .notice:
                continue
            }
        }
        return false
    }

    /// A permission prompt is up in the terminal, the only place that draws
    /// it — or may still be.
    private var waitsOnPermission: Bool {
        guard isLive, let reason = knownWait else { return false }
        if item?.state == .needsInput { return reason != .question }
        // Left unanswered, a prompt does not stay `needsInput`: on the
        // terminal's silence the state goes to `idle`. The journal still
        // holds the request, and the call it is about still has no result.
        return item?.state != .working && reason == .permission && hasOpenToolCall
    }

    /// A line typed over a permission prompt would answer it: while the
    /// session waits, the composer sends only once the journal has said it
    /// waits on a question.
    private var canSend: Bool {
        guard isLive, !waitsOnPermission else { return false }
        if item?.state == .needsInput { return knownWait == .question }
        return true
    }

    /// What restarts the reading: another native file, or the process ending.
    private struct FollowKey: Equatable {
        var native: SessionID
        var live: Bool
    }

    /// What asks the journal again: the session's state, or any transition.
    private struct WaitKey: Equatable {
        var state: SessionState?
        var tick: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            ConversationList(entries: entries, isWorking: item?.state == .working,
                             emptyTitle: "No conversation yet",
                             emptyDetail: "What you and claude say will show here. The first message can be sent from below.")
            banner
            // The composer sets itself in the list's column.
            ConversationComposer(text: $draft,
                                 placeholder: isLive ? "Message claude" : "This session has ended",
                                 isEnabled: canSend, isSending: isSending, onSend: { send() })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DefaultTheme.contentBackground)
        .task(id: FollowKey(native: nativeID, live: isLive)) { await follow() }
        .task(id: WaitKey(state: item?.state, tick: model.transitionTick)) { await readWait() }
        // The failure is about the text as it was sent: edited, it is a new message.
        .onChange(of: draft) {
            if sendFailed { sendFailed = false }
        }
    }

    @ViewBuilder
    private var banner: some View {
        if waitsOnPermission {
            ChatBanner(text: "claude is asking for a permission in the terminal.",
                       isError: false, actionTitle: "Open terminal", action: onShowTerminal)
        } else if sendFailed {
            ChatBanner(text: "claude did not take the message — it is still in the field.",
                       isError: true, actionTitle: nil, action: nil)
        }
    }

    // MARK: Reading

    /// Follows the conversation's file as claude writes it. Finding the file
    /// and reading it are synchronous disk work: off the main actor, like
    /// the ring's read. Every second while the process runs — faster while
    /// claude works, which is when the file grows; once for a session that
    /// has ended.
    private func follow() async {
        let native = nativeID
        if shownNative != native {
            // Another conversation: what the list held is not its.
            shownNative = native
            if !entries.isEmpty { entries = [] }
        }
        var reader = ClaudeConversation.Reader()
        // Found once: looking for it lists every folder of ~/.claude/projects.
        var file: URL?
        repeat {
            let before = reader
            let known = file
            let result: ConversationRead = await Task.detached(priority: .utility) { () -> ConversationRead in
                var next = before
                // claude writes the file at the first message: until then, keep looking.
                guard let url = known ?? ClaudeNativeSessions.path(for: native) else {
                    return ConversationRead(reader: next, file: nil, changed: false)
                }
                let changed = next.refresh(from: url)
                return ConversationRead(reader: next, file: url, changed: changed)
            }.value
            guard !Task.isCancelled else { return }   // a restarted read wins
            reader = result.reader
            file = result.file
            if result.changed, entries != reader.entries { entries = reader.entries }
            guard isLive else { return }
            let pause: Duration = item?.state == .working ? .milliseconds(400) : .seconds(1)
            try? await Task.sleep(for: pause)
        } while !Task.isCancelled
    }

    /// Asks the journal what the session waits on: a question leaves
    /// claude's input field free, a permission prompt does not, and the
    /// state does not tell them apart.
    private func readWait() async {
        let state = item?.state
        let reason = await model.sessionWait(sessionID)
        guard !Task.isCancelled else { return }
        let answer = JournalAnswer(wait: reason, state: state)
        if journal != answer { journal = answer }
    }

    // MARK: Sending

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !isSending, !text.isEmpty else { return }
        isSending = true
        sendFailed = false
        Task {
            let taken = await deliver(text)
            isSending = false
            if taken {
                draft = ""
            } else {
                sendFailed = true
            }
        }
    }

    /// Hands the message to claude through the session's terminal: a
    /// bracketed paste, so its line breaks stay one message, then Return.
    /// False when nothing was typed.
    private func deliver(_ text: String) async -> Bool {
        guard let state = item?.state else { return false }
        switch state {
        case .working:
            // claude queues what is typed while it works: no prompt to wait for.
            guard let surface = await model.surface(for: sessionID) else { return false }
            surface.send(KeyTranslator.paste(text, bracketed: true) + "\r")
            return true
        case .needsInput:
            // Asked again at the moment of typing: the session may have moved
            // on to a permission prompt since the composer last looked.
            guard await model.sessionWait(sessionID) == .question else { return false }
            return await model.submitWhenReady(text, to: sessionID, timeout: .seconds(15))
        case .starting, .idle:
            // A prompt left unanswered reads `idle`: asked again here too.
            let reason = await model.sessionWait(sessionID)
            if reason == .permission, hasOpenToolCall { return false }
            return await model.submitWhenReady(text, to: sessionID, timeout: .seconds(15))
        case .draft, .completed, .failed, .interrupted, .archived:
            return false
        }
    }
}

/// What one read off the main actor hands back.
private struct ConversationRead: Sendable {
    var reader: ClaudeConversation.Reader
    var file: URL?
    var changed: Bool
}

/// One line between the conversation and the composer, in their column.
@MainActor
private struct ChatBanner: View {
    let text: String
    let isError: Bool
    let actionTitle: String?
    let action: (() -> Void)?

    /// The reading measure of the list and of the composer (LoomUI's
    /// `ConversationLayout`): a column's width, which no theme scales.
    private static let columnWidth: CGFloat = 760

    var body: some View {
        HStack(spacing: DefaultTheme.space(8)) {
            if !isError {
                Circle().fill(DefaultTheme.badgeColor(for: .needsInput)).frame(width: 6, height: 6)
            }
            Text(text)
                .themeFont(size: 12)
                .foregroundStyle(isError ? DefaultTheme.danger : DefaultTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let actionTitle, let action {
                GhostButton(actionTitle, systemImage: "terminal", action: action)
            }
        }
        // The composer's own inset, then the list's margin: the line starts
        // where the composer's text does.
        .padding(.horizontal, DefaultTheme.space(12))
        .frame(maxWidth: Self.columnWidth)
        .padding(.horizontal, DefaultTheme.space(20))
        .padding(.top, DefaultTheme.space(8))
        .frame(maxWidth: .infinity)
    }
}
