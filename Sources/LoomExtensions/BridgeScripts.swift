import Foundation

/// What a page is handed before its own scripts run, and how events reach it.
public struct BridgeBoot: Codable, Equatable, Sendable {
    public var extensionId: String
    public var loomApi: Int
    public var theme: BridgeTheme

    public init(extensionId: String, loomApi: Int = ExtensionManifest.supportedAPIVersion,
                theme: BridgeTheme) {
        self.extensionId = extensionId
        self.loomApi = loomApi
        self.theme = theme
    }
}

public enum BridgeScripts {
    /// The document-start user script: the boot values, then the SDK. JSON is
    /// a valid JavaScript expression, so the boot object needs no escaping of
    /// its own.
    public static func userScript(boot: BridgeBoot) -> String {
        "window.__loomBoot = \(json(boot) ?? "{}");\n" + LoomSDKScript.source
    }

    /// `window.__loomEmit("<event as JSON text>")` — the event travels as one
    /// JSON string literal, so nothing in it is ever evaluated as code.
    public static func emit(_ event: BridgeEvent) -> String {
        guard let text = json(event), let literal = json(text) else {
            return "void 0;"
        }
        return "window.__loomEmit && window.__loomEmit(\(literal));"
    }

    static func json<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
