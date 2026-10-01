import CoreGraphics
import Foundation

/// How much one answer may carry. Claude Code warns past ~10k tokens of tool
/// output and cuts at 25k: a snapshot is the big part, so it is the one cut.
public struct AgentBrowserLimits: Equatable, Sendable {
    public var snapshotChars = 30_000
    public var actionSnapshotChars = 20_000
    public var consoleChars = 20_000
    public var networkChars = 20_000
    public var evaluateChars = 20_000
    public var responseChars = 40_000
    public var eventLines = 20
    /// The longest image edge, in pixels — past it the model downscales anyway.
    public var imageMaxEdge: CGFloat = 1_568

    public init() {}
}

/// What `### Page` says about the current page.
public struct AgentPageSummary: Equatable, Sendable {
    public var url: String
    public var title: String
    public var httpStatus: Int?
    public var consoleErrors: Int
    public var consoleWarnings: Int
    public var viewport: CGSize?
    /// Not on screen: rendering and observers are paused by WebKit.
    public var hidden: Bool

    public init(url: String, title: String, httpStatus: Int? = nil, consoleErrors: Int = 0,
                consoleWarnings: Int = 0, viewport: CGSize? = nil, hidden: Bool = false) {
        self.url = url
        self.title = title
        self.httpStatus = httpStatus
        self.consoleErrors = consoleErrors
        self.consoleWarnings = consoleWarnings
        self.viewport = viewport
        self.hidden = hidden
    }
}

public struct AgentTabSummary: Equatable, Sendable {
    public var index: Int
    public var title: String
    public var url: String
    public var isCurrent: Bool
    public var hasDialog: Bool

    public init(index: Int, title: String, url: String, isCurrent: Bool, hasDialog: Bool = false) {
        self.index = index
        self.title = title
        self.url = url
        self.isCurrent = isCurrent
        self.hasDialog = hasDialog
    }
}

/// A dialog or chooser the page is blocked on.
public struct AgentModalState: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case alert
        case confirm
        case prompt(defaultText: String?)
        case fileChooser(multiple: Bool)
    }

    public var kind: Kind
    public var message: String
    /// The origin of the dialog's frame ("A frame embedded in <host>" for an
    /// opaque one): what the banner says, so a page cannot pass its words
    /// off as Loom's, nor an embedded frame as the page under test.
    public var host: String

    public init(kind: Kind, message: String, host: String) {
        self.kind = kind
        self.message = String(message.prefix(1_000))
        self.host = host
    }

    public var line: String {
        switch kind {
        case .alert, .confirm, .prompt:
            let name: String
            switch kind {
            case .alert: name = "alert"
            case .confirm: name = "confirm"
            default: name = "prompt"
            }
            return "- [\"\(name)\" dialog with message \(Self.quoted(message))]: can be handled by browser_handle_dialog"
        case .fileChooser(let multiple):
            return "- [File chooser\(multiple ? " (multiple files)" : "")]: file uploads are not supported yet; cancel it with browser_handle_dialog"
        }
    }

    static func quoted(_ text: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])
        let array = data.map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }
}

/// An image the app wrote, for the MCP server to show and the CLI to copy.
public struct AgentImage: Equatable, Sendable {
    public var url: URL
    public var mimeType: String
    public var width: Int
    public var height: Int

    public init(url: URL, mimeType: String, width: Int, height: Int) {
        self.url = url
        self.mimeType = mimeType
        self.width = width
        self.height = height
    }
}

/// A command's answer: Markdown for the agent, and maybe an image.
public struct AgentResult: Equatable, Sendable {
    public var text: String
    public var image: AgentImage?

    public init(text: String, image: AgentImage? = nil) {
        self.text = text
        self.image = image
    }
}

/// The Markdown every answer is made of — Playwright MCP's sections, which
/// agents are trained to read (pure, tested).
public enum AgentResponseBuilder {

    public static func render(result: String?, page: AgentPageSummary?, tabs: [AgentTabSummary],
                              modal: AgentModalState?, snapshot: String?, events: [String],
                              limits: AgentBrowserLimits = AgentBrowserLimits()) -> String {
        var head: [String] = []
        if let result, !result.isEmpty {
            head.append("### Result\n" + result)
        }
        if let page {
            var lines = ["- Page URL: \(page.url)", "- Page Title: \(page.title)"]
            if let viewport = page.viewport {
                lines.append("- Viewport: \(Int(viewport.width))×\(Int(viewport.height))")
            }
            if let status = page.httpStatus, !(200..<300).contains(status) {
                lines.append("- HTTP status: \(status)")
            }
            if page.consoleErrors > 0 || page.consoleWarnings > 0 {
                lines.append("- Console: \(page.consoleErrors) errors, \(page.consoleWarnings) warnings")
            }
            if page.hidden {
                lines.append("- Visibility: hidden (the panel is not on screen: animations and observers are paused)")
            }
            head.append("### Page\n" + lines.joined(separator: "\n"))
        }
        if tabs.count > 1 {
            let lines = tabs.map { tab in
                "- \(tab.index): " + (tab.isCurrent ? "(current) " : "") + "[\(tab.title)] (\(tab.url))"
                    + (tab.hasDialog ? " — dialog pending" : "")
            }
            head.append("### Open tabs\n" + lines.joined(separator: "\n"))
        }
        if let modal {
            head.append("### Modal state\n" + modal.line)
        }
        let shownEvents = events.suffix(limits.eventLines)
        var tail: [String] = []
        if !shownEvents.isEmpty {
            let omitted = events.count - shownEvents.count
            tail.append("### Events\n" + (omitted > 0 ? "- (\(omitted) earlier events omitted)\n" : "")
                        + shownEvents.map { "- " + $0 }.joined(separator: "\n"))
        }
        let fixed = (head + tail).joined(separator: "\n\n").count
        var sections = head
        // A modal blocks the page: there is no snapshot to take meanwhile.
        if modal == nil, let snapshot, !snapshot.isEmpty {
            // Room for the fences, the separators and the cut notice too.
            let room = max(0, limits.responseChars - fixed - 160)
            var body = snapshot
            if body.count > room {
                body = String(body.prefix(room)) + "\n- … (snapshot cut to fit the answer: call browser_snapshot with a target)"
            }
            sections.append("### Snapshot\n```yaml\n" + body + "\n```")
        }
        sections += tail
        let text = sections.joined(separator: "\n\n")
        return text.count > limits.responseChars ? String(text.prefix(limits.responseChars)) : text
    }
}
