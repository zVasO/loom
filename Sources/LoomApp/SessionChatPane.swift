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
    /// Sent and taken by claude, not yet in its file: shown at once.
    @State private var pending: [PendingMessage] = []
    /// Pasted or dropped, waiting in the composer.
    @State private var images: [ComposerImage] = []
    /// Something is dragged over the chat.
    @State private var dropping = false
    /// The session's terminal: where a choice claude asks for is read, and
    /// where its answer, Stop and the messages are typed.
    @State private var surface: TerminalSurface?
    /// An option clicked: the card waits for the screen to move on.
    @State private var answered: ClaudeTerminalPrompt?
    /// The choice the terminal's screen shows, read by `watchScreen`, not
    /// in the body: the screen changes several times a second.
    @State private var onScreen: ClaudeTerminalPrompt?

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

    /// The choice claude's screen shows now — a permission, a question with
    /// options — when the session is not working. Read off the terminal,
    /// which the pane watches for as long as it shows.
    private var prompt: ClaudeTerminalPrompt? {
        guard isLive, item?.state != .working, let onScreen, onScreen != answered else { return nil }
        return onScreen
    }

    /// A permission prompt is up in the terminal, the only place that draws
    /// it — or may still be.
    private var waitsOnPermission: Bool {
        if prompt != nil { return true }
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
                             pending: pending.map(\.entry),
                             emptyTitle: "No conversation yet",
                             emptyDetail: "What you and claude say will show here. The first message can be sent from below.")
            if let prompt {
                ConversationPromptCard(question: prompt.question, context: prompt.context,
                                       options: prompt.options.map { .init(number: $0.number, label: $0.label) },
                                       selected: prompt.selected,
                                       onChoose: { choose($0.number, in: prompt) },
                                       onShowTerminal: onShowTerminal)
            } else {
                banner
            }
            // The composer sets itself in the list's column.
            let working = isLive && item?.state == .working
            ConversationComposer(text: $draft, images: $images,
                                 placeholder: isLive ? "Message claude" : "This session has ended",
                                 isEnabled: canSend, isSending: isSending,
                                 onStop: working ? { stop() } : nil,
                                 onSendNow: working ? { sendNow() } : nil,
                                 onSend: { send() })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DefaultTheme.contentBackground)
        // An image dropped anywhere on the chat waits in the composer.
        .onDrop(of: ComposerImage.dropTypes, isTargeted: $dropping) { providers in
            Task {
                let found = await ComposerImage.load(from: providers)
                images.append(contentsOf: found)
            }
            return true
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: DefaultTheme.radius(14))
                    .strokeBorder(DefaultTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(DefaultTheme.accent.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: DefaultTheme.radius(14)))
                    .overlay {
                        Text("Drop to attach to your message")
                            .themeFont(size: 14, weight: .semibold)
                            .foregroundStyle(DefaultTheme.primaryText)
                    }
                    .padding(DefaultTheme.space(16))
                    .allowsHitTesting(false)
            }
        }
        .task(id: FollowKey(native: nativeID, live: isLive)) { await follow() }
        .task(id: WaitKey(state: item?.state, tick: model.transitionTick)) { await readWait() }
        // The terminal's screen, a few times a second, for as long as the
        // session runs: claude draws its choices there and nowhere else.
        .task(id: FollowKey(native: sessionID, live: isLive)) { await watchScreen() }
        // In claude's file at last: no longer shown as pending.
        .onChange(of: entries) { dropDelivered() }
        // The screen moved on from the prompt answered: a new one may come.
        .onChange(of: item?.state) { answered = nil }
        // The failure is about the text as it was sent: edited, it is a new message.
        // Kept per session as it is typed: another tab, another session and
        // back, the message waits where it was left.
        .onChange(of: draft) {
            if sendFailed { sendFailed = false }
            ChatDrafts.shared.text[sessionID] = draft.isEmpty ? nil : draft
        }
        .onChange(of: images) {
            ChatDrafts.shared.images[sessionID] = images.isEmpty ? nil : images
        }
        .onAppear { restoreDraft() }
        .onChange(of: sessionID) { restoreDraft() }
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
        // Where the last look at this conversation left it: back on the tab,
        // the list shows at once and only what claude wrote since is read.
        let kept = ChatReadCache.shared[native]
        if shownNative != native {
            // Another conversation: what the list held is not its.
            shownNative = native
            let restored = ClaudeConversation.mergingEchoes(kept?.reader.entries ?? [])
            if entries != restored { entries = restored }
        }
        var reader = kept?.reader ?? ClaudeConversation.Reader()
        // Found once: looking for it lists every folder of ~/.claude/projects.
        var file: URL? = kept?.file
        // Woken by claude's writes: what it says shows as it lands, not at
        // the next tick. The ticks stay, slower, for what the watch misses
        // (a file replaced under it).
        var wake: FileWake?
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
            if result.changed || kept == nil {
                ChatReadCache.shared[native] = ChatReadCache.Kept(reader: reader, file: file)
            }
            if result.changed {
                let shown = ClaudeConversation.mergingEchoes(reader.entries)
                if entries != shown { entries = shown }
            }
            guard isLive else { return }
            if wake == nil, let file { wake = FileWake(url: file) }
            if let wake {
                await wake.next(timeout: item?.state == .working ? .seconds(1) : .seconds(2))
            } else {
                try? await Task.sleep(for: .milliseconds(500))
            }
        } while !Task.isCancelled
    }

    /// Watches the session's screen while it runs, and reads the choice it
    /// shows. Off the body: only a prompt that changed is written.
    private func watchScreen() async {
        guard isLive, let found = await model.surface(for: sessionID) else {
            if onScreen != nil { onScreen = nil }
            return
        }
        surface = found
        async let watching: Void = found.attached(cadence: .preview(.milliseconds(200)))
        var revision: UInt64 = .max
        while !Task.isCancelled {
            let screen = found.screen
            if screen.revision != revision {
                revision = screen.revision
                let lines = screen.lines.map { String($0.cells.map(\.character)) }
                let read = ClaudeTerminalPrompt.parse(lines: lines)
                if onScreen != read { onScreen = read }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        await watching
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

    /// What was being written in this session when the chat was left.
    private func restoreDraft() {
        let text = ChatDrafts.shared.text[sessionID] ?? ""
        if draft != text { draft = text }
        let waiting = ChatDrafts.shared.images[sessionID] ?? []
        if images != waiting { images = waiting }
    }

    // MARK: Sending

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = images.map(\.url)
        guard canSend, !isSending, !text.isEmpty || !files.isEmpty else { return }
        isSending = true
        sendFailed = false
        Task {
            let taken = await deliver(text, attaching: files)
            isSending = false
            if taken { sent(text, files: files) } else { sendFailed = true }
        }
    }

    /// Taken by claude: the field empties, and the message shows at once.
    private func sent(_ text: String, files: [URL]) {
        draft = ""
        images = []
        let data = files.compactMap { try? Data(contentsOf: $0) }
        pending.append(PendingMessage(entry: ConversationEntry(id: "pending-\(UUID().uuidString)",
                                                               kind: .user(text), images: data),
                                      sentAt: Date()))
    }

    /// "Send now", while claude works: its turn is interrupted (Esc, as in
    /// the terminal), and the message goes in once the prompt is back —
    /// rather than queued behind the turn.
    private func sendNow() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = images.map(\.url)
        guard !isSending, !text.isEmpty || !files.isEmpty else { return }
        isSending = true
        sendFailed = false
        Task {
            await interrupt()
            let taken = await model.submitWhenReady(text, to: sessionID, attaching: files, timeout: .seconds(15))
            isSending = false
            if taken { sent(text, files: files) } else { sendFailed = true }
        }
    }

    /// Stop: Esc in claude's terminal ends its turn.
    private func stop() {
        Task { await interrupt() }
    }

    /// Esc, then a moment for claude to leave its turn: the state says so
    /// when the hooks are on; otherwise the readiness of `submitWhenReady`
    /// is what waits.
    private func interrupt() async {
        guard let surface = await model.surface(for: sessionID) else { return }
        surface.send("\u{1B}")
        for _ in 0..<30 where item?.state == .working {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// An option of the card: its key, typed into the terminal.
    private func choose(_ number: Int, in prompt: ClaudeTerminalPrompt) {
        guard let option = prompt.options.first(where: { $0.number == number }),
              let surface else { return }
        answered = prompt
        surface.send(ClaudeTerminalPrompt.answer(option))
    }

    /// A pending message is let go once claude's file holds it — its text,
    /// which claude may have prefixed with "[Image #1]", or for images
    /// alone, a message with images — or after half a minute.
    private func dropDelivered() {
        guard !pending.isEmpty else { return }
        let said = entries.suffix(40).filter { if case .user = $0.kind { return true } else { return false } }
        let now = Date()
        pending.removeAll { message in
            if now.timeIntervalSince(message.sentAt) > 30 { return true }
            let text = ClaudeConversation.comparable(message.text)
            return said.contains { entry in
                guard case .user(let written) = entry.kind,
                      (entry.timestamp ?? now) >= message.sentAt.addingTimeInterval(-5) else { return false }
                // Images alone: the next message with images is it.
                if text.isEmpty { return !entry.images.isEmpty }
                let shown = ClaudeConversation.comparable(written)
                return shown == text || shown.contains(text)
            }
        }
    }

    /// Hands the message to claude through the session's terminal: a
    /// bracketed paste, so its line breaks stay one message, then Return.
    /// False when nothing was typed.
    private func deliver(_ text: String, attaching files: [URL] = []) async -> Bool {
        guard let state = item?.state else { return false }
        switch state {
        case .working:
            // claude queues what is typed while it works: no prompt to wait for.
            guard let surface = await model.surface(for: sessionID) else { return false }
            await AppModel.type(text, attaching: files, into: surface)
            return true
        case .needsInput:
            // Asked again at the moment of typing: the session may have moved
            // on to a permission prompt since the composer last looked.
            guard await model.sessionWait(sessionID) == .question else { return false }
            return await model.submitWhenReady(text, to: sessionID, attaching: files, timeout: .seconds(15))
        case .starting, .idle:
            // A prompt left unanswered reads `idle`: asked again here too.
            let reason = await model.sessionWait(sessionID)
            if reason == .permission, hasOpenToolCall { return false }
            return await model.submitWhenReady(text, to: sessionID, attaching: files, timeout: .seconds(15))
        case .draft, .completed, .failed, .interrupted, .archived:
            return false
        }
    }
}

/// Wakes a reader when a file is written to, or after a timeout. The
/// kernel's watch (a vnode source) on the file claude appends to.
private final class FileWake: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    private var fired = false
    private var source: DispatchSourceFileSystemObject?

    init?(url: URL) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename],
            queue: .global(qos: .userInitiated))
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.setEventHandler { [weak self] in self?.wake() }
        source.resume()
    }

    deinit {
        source?.cancel()
        wake()
    }

    /// Returns at the next write, or after `timeout`.
    func next(timeout: Duration) async {
        let timer = Task { [weak self] in
            // Cancelled once a write has woken the reader: no wake of its
            // own then, or the next wait would return at once — a reader
            // spinning on the file.
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            self?.wake()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fired {
                fired = false
                lock.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
        timer.cancel()
    }

    private func wake() {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume()
        } else {
            fired = true
            lock.unlock()
        }
    }
}

/// The messages being written, by session: the chat view is rebuilt at
/// every tab switch, and a draft is not something to lose there.
@MainActor
private final class ChatDrafts {
    static let shared = ChatDrafts()
    var text: [SessionID: String] = [:]
    var images: [SessionID: [ComposerImage]] = [:]
}

/// The conversations the chat has read, by native session: a return to
/// the tab picks up where the reading stopped. A few, the latest kept.
@MainActor
private final class ChatReadCache {
    static let shared = ChatReadCache()
    struct Kept {
        var reader: ClaudeConversation.Reader
        var file: URL?
    }
    private var kept: [SessionID: Kept] = [:]
    private var order: [SessionID] = []
    private let limit = 8

    subscript(native: SessionID) -> Kept? {
        get { kept[native] }
        set {
            kept[native] = newValue
            order.removeAll { $0 == native }
            if newValue != nil { order.append(native) }
            while order.count > limit { kept[order.removeFirst()] = nil }
        }
    }
}

/// A message sent and not yet in claude's file.
private struct PendingMessage {
    var entry: ConversationEntry
    var sentAt: Date
    var text: String {
        if case .user(let text) = entry.kind { return text }
        return ""
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
