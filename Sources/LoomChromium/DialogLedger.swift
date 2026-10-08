import Foundation

/// A JavaScript dialog as `Page.javascriptDialogOpening` announced it.
public struct PageDialog: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case alert, confirm, prompt, beforeunload
    }

    /// The ledger's own number, increasing per page: what an answer names
    /// so that it never lands on a later dialog.
    public let id: Int
    public let kind: Kind
    public let message: String
    public let defaultPrompt: String
    /// The URL of the dialog's frame.
    public let url: String
    /// Absent before Chromium 124.
    public let frameId: String?
    /// The frame's `securityOrigin` when it was seen committing: the banner
    /// names who speaks ("A frame embedded in …" for an opaque origin).
    public let frameOrigin: String?
    public let isMainFrame: Bool?

    public init(id: Int, kind: Kind, message: String, defaultPrompt: String = "", url: String = "",
                frameId: String? = nil, frameOrigin: String? = nil, isMainFrame: Bool? = nil) {
        self.id = id
        self.kind = kind
        self.message = message
        self.defaultPrompt = defaultPrompt
        self.url = url
        self.frameId = frameId
        self.frameOrigin = frameOrigin
        self.isMainFrame = isMainFrame
    }
}

/// Every dialog gets exactly one `Page.handleJavaScriptDialog` (ADR-0014):
/// from the agent, the person, or Loom itself — never two, never none while
/// the page lives. A second answer would land on the next dialog, or fail.
///
/// Pure: `PageSignals` holds it under its lock and sends what it returns.
public struct DialogLedger: Sendable {

    /// A page that opens dialogs in a loop: past this many in one document
    /// they are dismissed at once, like Safari's "prevent additional dialogs".
    public static let perDocumentLimit = 20

    public enum AutoReason: String, Sendable, Equatable {
        /// Over `perDocumentLimit` in this document: dismissed.
        case tooMany
        /// A beforeunload while the agent itself leaves the page: accepted.
        case agentLeaving
    }

    public enum DismissReason: String, Sendable, Equatable {
        /// The agent navigates away: dismissed, as a browser does.
        case navigation
        /// The page's process died: nothing to answer any more.
        case crash
        /// The target went away.
        case detach
        /// A new document committed: Chromium closed it already.
        case documentChanged
        /// Another dialog opened on the same page: this one was gone unseen.
        case superseded
    }

    /// The command that answers a dialog.
    public struct Reply: Sendable, Equatable {
        public static let method = "Page.handleJavaScriptDialog"

        public let dialogId: Int
        public let accept: Bool
        /// Sent only to accept a prompt.
        public let promptText: String?

        public var params: [String: Any] {
            var params: [String: Any] = ["accept": accept]
            if let promptText { params["promptText"] = promptText }
            return params
        }
    }

    public enum Decision: Sendable, Equatable {
        /// It waits for an answer: a modal state.
        case park(PageDialog)
        /// Loom answers it now, on the reader queue.
        case answer(PageDialog, Reply, AutoReason)
    }

    public struct Answered: Sendable, Equatable {
        public let dialog: PageDialog
        public let reply: Reply
    }

    public enum AnswerError: Error, Sendable, Equatable {
        case noDialog
        /// This dialog already got its answer (Playwright's "Cannot accept
        /// dialog which is already handled!").
        case alreadyHandled
        /// The answer names a dialog other than the one open.
        case otherDialog
    }

    /// The dialog waiting for an answer.
    public private(set) var open: PageDialog?
    /// Dialogs opened since the document committed.
    public private(set) var openedInDocument = 0
    /// Set while the agent navigates, goes back or reloads: the page's
    /// "leave site?" is accepted for it. A page-initiated leave stays modal.
    public var autoAcceptBeforeUnload = false

    private var lastId = 0
    /// Recently answered ids, oldest first: a late second answer is told so.
    private var answered: [Int] = []

    public init() {}

    /// `Page.javascriptDialogOpening`. `superseded` is a dialog that was
    /// still recorded as open: it closed unseen, nothing is sent for it (an
    /// answer now would land on the new one).
    public mutating func opening(type: String, message: String, defaultPrompt: String?, url: String,
                                 frameId: String?, frameOrigin: String? = nil,
                                 isMainFrame: Bool? = nil) -> (superseded: PageDialog?, decision: Decision) {
        lastId += 1
        openedInDocument += 1
        let dialog = PageDialog(id: lastId, kind: PageDialog.Kind(rawValue: type) ?? .alert, message: message,
                                defaultPrompt: defaultPrompt ?? "", url: url, frameId: frameId,
                                frameOrigin: frameOrigin, isMainFrame: isMainFrame)
        let superseded = open
        open = nil
        if dialog.kind == .beforeunload, autoAcceptBeforeUnload {
            return (superseded, .answer(dialog, settle(dialog, accept: true, promptText: nil), .agentLeaving))
        }
        if openedInDocument > Self.perDocumentLimit {
            return (superseded, .answer(dialog, settle(dialog, accept: false, promptText: nil), .tooMany))
        }
        open = dialog
        return (superseded, .park(dialog))
    }

    /// The agent's or the person's answer. `dialogId` nil: whichever is open.
    /// An accepted prompt without text answers "" — the WebKit engine's rule.
    public mutating func answer(accept: Bool, promptText: String?,
                                dialogId: Int? = nil) -> Result<Answered, AnswerError> {
        guard let dialog = open else {
            if let dialogId, answered.contains(dialogId) { return .failure(.alreadyHandled) }
            return .failure(.noDialog)
        }
        if let dialogId, dialogId != dialog.id {
            return .failure(answered.contains(dialogId) ? .alreadyHandled : .otherDialog)
        }
        open = nil
        return .success(Answered(dialog: dialog, reply: settle(dialog, accept: accept, promptText: promptText)))
    }

    /// Ends the open dialog without the page's say. A navigation sends a
    /// dismissal (the page is alive and waiting); a crash or a detach sends
    /// nothing (no one would read it); a commit means Chromium closed it.
    public mutating func dismiss(_ reason: DismissReason) -> (dialog: PageDialog, reply: Reply?)? {
        guard let dialog = open else { return nil }
        open = nil
        switch reason {
        case .navigation:
            return (dialog, settle(dialog, accept: false, promptText: nil))
        case .crash, .detach, .documentChanged, .superseded:
            remember(dialog.id)
            return (dialog, nil)
        }
    }

    /// `Page.javascriptDialogClosed`: the dialog that was still open, when
    /// something other than our answer closed it; nil after our own answer.
    public mutating func closed() -> PageDialog? {
        guard let dialog = open else { return nil }
        open = nil
        remember(dialog.id)
        return dialog
    }

    /// A main-frame commit: a new document, a new count. A dialog still
    /// recorded as open went with the old document.
    public mutating func documentCommitted() -> PageDialog? {
        openedInDocument = 0
        return dismiss(.documentChanged)?.dialog
    }

    private mutating func settle(_ dialog: PageDialog, accept: Bool, promptText: String?) -> Reply {
        remember(dialog.id)
        let text: String? = (accept && dialog.kind == .prompt) ? (promptText ?? "") : nil
        return Reply(dialogId: dialog.id, accept: accept, promptText: text)
    }

    private mutating func remember(_ id: Int) {
        answered.append(id)
        if answered.count > 64 { answered.removeFirst(answered.count - 64) }
    }
}
