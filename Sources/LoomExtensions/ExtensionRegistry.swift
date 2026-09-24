import Foundation

/// An extension Loom knows: where its files are, whether it is on, what the
/// user granted, and whether it can run as it stands.
public struct InstalledExtension: Identifiable, Equatable, Sendable {
    public var id: String { manifest.id }
    public let manifest: ExtensionManifest
    /// The folder served — the installed copy, or the source folder of a link.
    public let root: URL
    /// Linked in development: served from its source folder, edits show on reload.
    public let isLinked: Bool
    public var enabled: Bool
    public var granted: ExtensionPermissions?
    public var status: Status

    public enum Status: Equatable, Sendable {
        case ready
        /// The manifest asks for more than the user granted: nothing runs
        /// until they approve the difference.
        case needsConsent(ExtensionPermissions)
        case disabled
    }

    /// What the extension runs with: its asks, cut down to the grant.
    public var effectivePermissions: ExtensionPermissions {
        manifest.permissions.intersection(granted)
    }

    public var isReady: Bool { status == .ready }
}

/// A folder that should have been an extension and is not — shown in
/// Settings, never silently dropped.
public struct ExtensionProblem: Identifiable, Equatable, Sendable {
    public var id: String { location.path }
    public let location: URL
    public let message: String
}

/// The extensions on disk and their state (ADR-0011):
/// - `<directory>/installed/<id>/` — copies, one folder per id;
/// - `<directory>/state.json` — enabled, granted permissions, linked folders;
/// - `<directory>/data/<id>/` — each extension's storage, kept across updates.
public final class ExtensionRegistry {
    public let directory: URL
    public var installedDirectory: URL { directory.appendingPathComponent("installed") }
    public var dataDirectory: URL { directory.appendingPathComponent("data") }
    public var stateFile: URL { directory.appendingPathComponent("state.json") }

    public private(set) var extensions: [InstalledExtension] = []
    public private(set) var problems: [ExtensionProblem] = []

    private let secrets: any SecretStore
    private var state = RegistryState()

    struct RegistryState: Codable, Equatable {
        var version = 1
        var extensions: [String: Entry] = [:]

        struct Entry: Codable, Equatable {
            var enabled: Bool
            var granted: ExtensionPermissions?
            /// Set for a linked extension: its source folder.
            var linkedPath: String?
        }
    }

    public enum RegistryError: Error, Equatable, CustomStringConvertible {
        case conflict(String)
        case notFound(String)

        public var description: String {
            switch self {
            case .conflict(let message), .notFound(let message): return message
            }
        }
    }

    public init(directory: URL, secrets: any SecretStore) {
        self.directory = directory
        self.secrets = secrets
    }

    public func extensionNamed(_ id: String) -> InstalledExtension? {
        extensions.first { $0.id == id }
    }

    // MARK: - Scan

    /// Reads the state file and every extension folder. Never throws: what
    /// cannot be read becomes a problem, and the rest still loads.
    public func scan() {
        state = FileManager.default.contents(atPath: stateFile.path)
            .flatMap { try? JSONDecoder().decode(RegistryState.self, from: $0) } ?? RegistryState()
        var found: [InstalledExtension] = []
        var problems: [ExtensionProblem] = []
        let fm = FileManager.default

        let folders = ((try? fm.contentsOfDirectory(at: installedDirectory, includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for folder in folders {
            do {
                let manifest = try ExtensionManifest.load(from: folder)
                guard manifest.id == folder.lastPathComponent else {
                    problems.append(ExtensionProblem(location: folder, message:
                        "The folder is named \(folder.lastPathComponent) but the manifest's id is \(manifest.id)"))
                    continue
                }
                if state.extensions[manifest.id]?.linkedPath != nil {
                    problems.append(ExtensionProblem(location: folder, message:
                        "\(manifest.id) is both installed and linked; the link wins"))
                    continue
                }
                found.append(make(manifest, root: folder, linked: false))
            } catch {
                problems.append(ExtensionProblem(location: folder, message: "\(error)"))
            }
        }

        for (id, entry) in state.extensions.sorted(by: { $0.key < $1.key }) {
            guard let path = entry.linkedPath else { continue }
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            do {
                let manifest = try ExtensionManifest.load(from: folder)
                guard manifest.id == id else {
                    problems.append(ExtensionProblem(location: folder, message:
                        "Linked as \(id), but the manifest's id is now \(manifest.id) — remove and link it again"))
                    continue
                }
                found.append(make(manifest, root: folder, linked: true))
            } catch {
                problems.append(ExtensionProblem(location: folder, message: "\(error)"))
            }
        }

        extensions = found.sorted {
            $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending
        }
        self.problems = problems
    }

    private func make(_ manifest: ExtensionManifest, root: URL, linked: Bool) -> InstalledExtension {
        let entry = state.extensions[manifest.id]
        // A copy dropped by hand has no entry yet: on, but granted nothing.
        let enabled = entry?.enabled ?? true
        let granted = entry?.granted
        let missing = manifest.permissions.missing(from: granted)
        let status: InstalledExtension.Status = !enabled ? .disabled
            : missing.isEmpty ? .ready : .needsConsent(missing)
        return InstalledExtension(manifest: manifest, root: root, isLinked: linked,
                                  enabled: enabled, granted: granted, status: status)
    }

    // MARK: - Changes

    /// Validates a folder before the consent sheet shows its permissions.
    public func inspect(_ folder: URL) throws -> ExtensionManifest {
        try ExtensionManifest.load(from: folder)
    }

    /// Copies `folder` in as `installed/<id>/`, replacing an older copy of the
    /// same id (its storage and secrets stay), and records the grant.
    @discardableResult
    public func install(from folder: URL, granting granted: ExtensionPermissions) throws -> InstalledExtension {
        let manifest = try inspect(folder)
        if state.extensions[manifest.id]?.linkedPath != nil {
            throw RegistryError.conflict("\(manifest.id) is linked from a development folder — remove the link first")
        }
        let fm = FileManager.default
        let destination = installedDirectory.appendingPathComponent(manifest.id, isDirectory: true)
        let source = folder.standardizedFileURL.resolvingSymlinksInPath()
        guard source.path != destination.standardizedFileURL.resolvingSymlinksInPath().path else {
            throw RegistryError.conflict("\(manifest.id) is already installed from this folder")
        }
        try fm.createDirectory(at: installedDirectory, withIntermediateDirectories: true)
        let staging = installedDirectory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.copyItem(at: source, to: staging)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: staging, to: destination)
        state.extensions[manifest.id] = RegistryState.Entry(
            enabled: true, granted: manifest.permissions.intersection(granted), linkedPath: nil)
        try saveState()
        scan()
        guard let installed = extensionNamed(manifest.id) else {
            throw RegistryError.notFound("\(manifest.id) could not be read back after installing")
        }
        return installed
    }

    /// Serves `folder` in place — for developing an extension.
    @discardableResult
    public func link(_ folder: URL, granting granted: ExtensionPermissions) throws -> InstalledExtension {
        let manifest = try inspect(folder)
        let copy = installedDirectory.appendingPathComponent(manifest.id)
        if FileManager.default.fileExists(atPath: copy.path) {
            throw RegistryError.conflict("\(manifest.id) is already installed — remove it before linking a development copy")
        }
        state.extensions[manifest.id] = RegistryState.Entry(
            enabled: true, granted: manifest.permissions.intersection(granted),
            linkedPath: folder.standardizedFileURL.path)
        try saveState()
        scan()
        guard let linked = extensionNamed(manifest.id) else {
            throw RegistryError.notFound("\(manifest.id) could not be read back after linking")
        }
        return linked
    }

    /// Removes the extension, its storage and its secrets. A linked source
    /// folder is never touched: it is the developer's.
    public func remove(_ id: String) throws {
        let entry = state.extensions[id]
        let fm = FileManager.default
        if entry?.linkedPath == nil {
            let copy = installedDirectory.appendingPathComponent(id)
            if fm.fileExists(atPath: copy.path) { try fm.removeItem(at: copy) }
        }
        let data = dataDirectory.appendingPathComponent(id)
        if fm.fileExists(atPath: data.path) { try fm.removeItem(at: data) }
        try? secrets.deleteAll(for: id)
        state.extensions.removeValue(forKey: id)
        try saveState()
        scan()
    }

    public func setEnabled(_ enabled: Bool, for id: String) throws {
        guard let current = extensionNamed(id) else { throw RegistryError.notFound("no extension \(id)") }
        var entry = state.extensions[id]
            ?? RegistryState.Entry(enabled: true, granted: nil, linkedPath: nil)
        entry.enabled = enabled
        if current.isLinked, entry.linkedPath == nil { entry.linkedPath = current.root.path }
        state.extensions[id] = entry
        try saveState()
        scan()
    }

    /// Records the user's consent: the grant becomes exactly the manifest's
    /// current asks — approving never grants more than is asked.
    public func approve(_ id: String) throws {
        guard let current = extensionNamed(id) else { throw RegistryError.notFound("no extension \(id)") }
        var entry = state.extensions[id]
            ?? RegistryState.Entry(enabled: true, granted: nil, linkedPath: nil)
        entry.granted = current.manifest.permissions
        if current.isLinked, entry.linkedPath == nil { entry.linkedPath = current.root.path }
        state.extensions[id] = entry
        try saveState()
        scan()
    }

    public func storageFile(for id: String) -> URL {
        dataDirectory.appendingPathComponent(id).appendingPathComponent("storage.json")
    }

    private func saveState() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: stateFile, options: .atomic)
    }
}
