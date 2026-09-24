import Foundation

/// What an extension says about itself, read from `loom-extension.json` at the
/// root of its folder (ADR-0011). Validated before anything is served: an id
/// that could not be a URL host, an entry that leaves the folder or a bridge
/// version this Loom does not speak refuse the whole extension.
public struct ExtensionManifest: Codable, Equatable, Sendable {
    public static let fileName = "loom-extension.json"
    /// The bridge version this Loom speaks (`loomApi`).
    public static let supportedAPIVersion = 1

    /// Reverse-DNS, lowercase (`dev.loom.jira-board`): it becomes the host of
    /// the extension's origin, `loom-ext://<id>/`.
    public var id: String
    public var name: String
    public var version: String
    public var description: String?
    public var author: String?
    /// An SF Symbol name, shown in the Extensions sidebar and the palette.
    public var icon: String?
    /// The page the view opens, relative to the extension's folder.
    public var entry: String
    public var loomApi: Int
    public var permissions: ExtensionPermissions
    public var contributes: Contributions

    public struct Contributions: Codable, Equatable, Sendable {
        /// Commands listed in the ⌘K palette; running one opens the
        /// extension's view and sends it a `command` event.
        public var commands: [Command]

        public init(commands: [Command] = []) { self.commands = commands }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            commands = try container.decodeIfPresent([Command].self, forKey: .commands) ?? []
        }
    }

    public struct Command: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    public init(id: String, name: String, version: String, description: String? = nil,
                author: String? = nil, icon: String? = nil, entry: String = "index.html",
                loomApi: Int = ExtensionManifest.supportedAPIVersion,
                permissions: ExtensionPermissions = .empty,
                contributes: Contributions = Contributions()) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.author = author
        self.icon = icon
        self.entry = entry
        self.loomApi = loomApi
        self.permissions = permissions
        self.contributes = contributes
    }

    /// `entry`, `permissions` and `contributes` may be left out: an extension
    /// that asks for nothing declares nothing.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        entry = try container.decodeIfPresent(String.self, forKey: .entry) ?? "index.html"
        loomApi = try container.decode(Int.self, forKey: .loomApi)
        permissions = try container.decodeIfPresent(ExtensionPermissions.self, forKey: .permissions) ?? .empty
        contributes = try container.decodeIfPresent(Contributions.self, forKey: .contributes) ?? Contributions()
    }

    // MARK: - Loading

    /// Reads and validates the manifest of the folder `root`.
    public static func load(from root: URL) throws -> ExtensionManifest {
        let file = root.appendingPathComponent(fileName)
        guard let data = FileManager.default.contents(atPath: file.path) else {
            throw ManifestError.missingFile(root.path)
        }
        let manifest: ExtensionManifest
        do {
            manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
        } catch let error as ManifestError {
            throw error
        } catch {
            throw ManifestError.malformed(Self.describe(error))
        }
        try manifest.validate()
        return manifest
    }

    // MARK: - Validation

    public func validate() throws {
        guard Self.isValidID(id) else {
            throw ManifestError.invalid(field: "id", reason:
                "must be reverse-DNS in lowercase (letters, digits, hyphens), like dev.example.jira-board")
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 60 else {
            throw ManifestError.invalid(field: "name", reason: "must be 1 to 60 characters")
        }
        guard !version.trimmingCharacters(in: .whitespaces).isEmpty, version.count <= 40 else {
            throw ManifestError.invalid(field: "version", reason: "must be 1 to 40 characters")
        }
        guard loomApi == Self.supportedAPIVersion else {
            throw ManifestError.unsupportedAPI(loomApi)
        }
        guard Self.isValidEntry(entry) else {
            throw ManifestError.invalid(field: "entry", reason:
                "must be an .html file inside the extension's folder (no leading /, no ..)")
        }
        if let icon, !Self.matches(#"^[a-z0-9]+(\.[a-z0-9]+)*$"#, icon) || icon.count > 64 {
            throw ManifestError.invalid(field: "icon", reason: "must be an SF Symbol name")
        }
        try permissions.validate()
        var seen = Set<String>()
        for command in contributes.commands {
            guard Self.matches(#"^[a-z0-9][a-z0-9._-]{0,63}$"#, command.id) else {
                throw ManifestError.invalid(field: "contributes.commands", reason:
                    "command id \"\(command.id)\" must be lowercase letters, digits, . _ -")
            }
            guard seen.insert(command.id).inserted else {
                throw ManifestError.invalid(field: "contributes.commands", reason:
                    "command id \"\(command.id)\" is declared twice")
            }
            let title = command.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 80 else {
                throw ManifestError.invalid(field: "contributes.commands", reason:
                    "command \"\(command.id)\" needs a title of 1 to 80 characters")
            }
        }
    }

    /// Lowercase because it is a URL host, and WebKit lowercases hosts: an
    /// uppercase id would never match its own origin.
    public static func isValidID(_ id: String) -> Bool {
        id.count <= 100
            && matches(#"^[a-z0-9]+(-[a-z0-9]+)*(\.[a-z0-9]+(-[a-z0-9]+)*)+$"#, id)
    }

    static func isValidEntry(_ entry: String) -> Bool {
        guard !entry.isEmpty, !entry.hasPrefix("/"), !entry.contains("\\") else { return false }
        let components = entry.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") })
        else { return false }
        let lower = entry.lowercased()
        return lower.hasSuffix(".html") || lower.hasSuffix(".htm")
    }

    static func matches(_ pattern: String, _ string: String) -> Bool {
        string.range(of: pattern, options: .regularExpression) != nil
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _):
            return "missing field \"\(key.stringValue)\""
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "wrong type at \"\(path)\""
        case DecodingError.dataCorrupted(let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? "not valid JSON" : "\(context.debugDescription) at \"\(path)\""
        default:
            return String(describing: error)
        }
    }
}

public enum ManifestError: Error, Equatable, CustomStringConvertible {
    case missingFile(String)
    case malformed(String)
    case invalid(field: String, reason: String)
    case unsupportedAPI(Int)

    public var description: String {
        switch self {
        case .missingFile(let path):
            return "No \(ExtensionManifest.fileName) in \(path)"
        case .malformed(let detail):
            return "\(ExtensionManifest.fileName) could not be read: \(detail)"
        case .invalid(let field, let reason):
            return "\(ExtensionManifest.fileName): \(field) \(reason)"
        case .unsupportedAPI(let version):
            return "This extension targets bridge version \(version); this Loom speaks version \(ExtensionManifest.supportedAPIVersion)"
        }
    }
}
