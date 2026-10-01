import Foundation

// The browser methods' parameters (ADR-0014): Playwright MCP's names, which
// agents are trained on. `target` is a ref from the latest snapshot (`e12`)
// or a CSS selector; `ref`, Playwright's older name for it, is accepted.
// `element` is the agent's own description of the element, echoed back.
// Numbers are Doubles on the wire: JSON has no integers.

/// Any browser method's session: omitted under a session token (yours).
public struct APIBrowserSessionParams: Codable, Equatable, Sendable {
    public var sessionId: String?
    public init(sessionId: String? = nil) { self.sessionId = sessionId }
}

public struct APIBrowserNavigateParams: Codable, Equatable, Sendable {
    public var sessionId: String?
    public var url: String
    public init(sessionId: String? = nil, url: String) {
        self.sessionId = sessionId
        self.url = url
    }
}

public struct APIBrowserSnapshotParams: Codable, Equatable, Sendable {
    public var sessionId: String?
    public var target: String?
    public var ref: String?
    public var depth: Double?
}

public struct APIBrowserClickParams: Codable, Equatable, Sendable {
    public var sessionId: String?
    public var element: String?
    public var target: String?
    public var ref: String?
    public var doubleClick: Bool?
    public var button: String?
    public var modifiers: [String]?
}

public struct APIBrowserTypeParams: Codable, Equatable, Sendable {
    public var sessionId: String?
    public var element: String?
    public var target: String?
    public var ref: String?
    public var text: String
    public var submit: Bool?
}

public struct APIBrowserSelectOptionParams: Codable, Equatable, Sendable {
    public var sessionId: String?
    public var element: String?
    public var target: String?
    public var ref: String?
    public var values: [String]
}

public struct APIBrowserTargetParams: Codable, Equatable, Sendable {
    public var sessionId: String?
    public var element: String?
    public var target: String?
    public var ref: String?
}

public struct APIBrowserPressKeyParams: Codable, Equatable, Sendable {
    public var sessionId: String?
    public var key: String
}

public struct APIBrowserWaitForParams: Codable, Equatable, Sendable {
    public var sessionId: String?
    public var time: Double?
    public var text: String?
    public var textGone: String?
    public var timeout: Double?
}

public struct APIBrowserScreenshotParams: Codable, Equatable, Sendable {
    public var sessionId: String?
    public var element: String?
    public var target: String?
    public var ref: String?
    /// png (default) or jpeg.
    public var type: String?
}

public struct APIBrowserConsoleParams: Codable, Equatable, Sendable {
    public var sessionId: String?
    /// error, warning, info (default), debug — each includes the more severe.
    public var level: String?
    /// Also the messages from before the last navigation.
    public var all: Bool?
}

public struct APIBrowserNetworkParams: Codable, Equatable, Sendable {
    public var sessionId: String?
    /// Only the requests whose URL contains this.
    public var filter: String?
}

public struct APIBrowserEvaluateParams: Codable, Equatable, Sendable {
    public var sessionId: String?
    /// `() => …`, or `(element) => …` with a target.
    public var function: String
    public var element: String?
    public var target: String?
    public var ref: String?
}

public struct APIBrowserHandleDialogParams: Codable, Equatable, Sendable {
    public var sessionId: String?
    public var accept: Bool
    public var promptText: String?
}

public struct APIBrowserTabsParams: Codable, Equatable, Sendable {
    public var sessionId: String?
    /// list, new, select, close.
    public var action: String
    public var index: Double?
    public var url: String?
}

/// A tool's answer meant to be read: Markdown, and maybe an image beside it.
/// The MCP server shows the text as is and the image as an image.
public struct APIToolContent: Codable, Equatable, Sendable {
    public var text: String
    public var image: APIImageRef?

    public init(text: String, image: APIImageRef? = nil) {
        self.text = text
        self.image = image
    }
}

/// An image the app wrote under its screenshots directory.
public struct APIImageRef: Codable, Equatable, Sendable {
    public var path: String
    public var mimeType: String
    public var width: Int
    public var height: Int

    public init(path: String, mimeType: String, width: Int, height: Int) {
        self.path = path
        self.mimeType = mimeType
        self.width = width
        self.height = height
    }
}

/// The only image files a client reads on the app's word: under the
/// screenshots directory (symlinks resolved on both sides — a temporary
/// directory is itself a symlink on macOS), an image type, a bounded size.
public enum APIImageFile {
    public static let maxBytes = 5_000_000
    public static let mimeTypes: Set<String> = ["image/png", "image/jpeg"]

    /// The resolved file, or nil when it is anywhere else or anything else.
    public static func validated(_ image: APIImageRef, root: URL,
                                 sizeOf: (URL) -> Int? = { url in
                                     (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                                 }) -> URL? {
        guard mimeTypes.contains(image.mimeType) else { return nil }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let file = URL(fileURLWithPath: image.path).resolvingSymlinksInPath().standardizedFileURL
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard file.path.hasPrefix(prefix) else { return nil }
        guard let size = sizeOf(file), size > 0, size <= maxBytes else { return nil }
        return file
    }
}
