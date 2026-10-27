import Foundation

/// The workflows, experts and connectors, one JSON file each under
/// `<support>/workflows/`: readable, diffable, copied by hand if need be.
/// A file that does not decode is left alone and skipped, never deleted.
public struct WorkflowLibraryStore: Sendable {
    public let root: URL

    public init(directory: URL) {
        root = directory
    }

    private var workflowsURL: URL { root.appendingPathComponent("workflows") }
    private var expertsURL: URL { root.appendingPathComponent("experts") }
    private var connectorsURL: URL { root.appendingPathComponent("connectors") }

    public func loadWorkflows() -> [Workflow] { load(from: workflowsURL) }
    public func loadExperts() -> [Expert] { load(from: expertsURL) }
    public func loadConnectors() -> [Connector] { load(from: connectorsURL) }

    public func save(_ workflow: Workflow) throws { try write(workflow, id: workflow.id, to: workflowsURL) }
    public func save(_ expert: Expert) throws { try write(expert, id: expert.id, to: expertsURL) }
    public func save(_ connector: Connector) throws { try write(connector, id: connector.id, to: connectorsURL) }

    public func deleteWorkflow(_ id: UUID) { remove(id, from: workflowsURL) }
    public func deleteExpert(_ id: UUID) { remove(id, from: expertsURL) }
    public func deleteConnector(_ id: UUID) { remove(id, from: connectorsURL) }

    /// Whether the library was ever written — the built-ins are copied in once.
    public var exists: Bool { FileManager.default.fileExists(atPath: workflowsURL.path) }

    private func load<T: Decodable>(from directory: URL) -> [T] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? WorkflowJSON.decoder.decode(T.self, from: Data(contentsOf: $0)) }
    }

    private func write<T: Encodable>(_ value: T, id: UUID, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try WorkflowJSON.encoder.encode(value)
            .write(to: directory.appendingPathComponent("\(id.uuidString).json"), options: .atomic)
    }

    private func remove(_ id: UUID, from directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id.uuidString).json"))
    }
}

/// A workflow with what it needs, in one file to share: its experts and its
/// connectors — never a secret, those stay in the Keychain of whoever set them.
public struct WorkflowBundle: Codable, Equatable, Sendable {
    public var workflow: Workflow
    public var experts: [Expert]
    public var connectors: [Connector]

    public init(workflow: Workflow, experts: [Expert], connectors: [Connector]) {
        self.workflow = workflow
        self.experts = experts
        self.connectors = connectors
    }

    /// The workflow and exactly the experts and connectors its steps name.
    public static func make(_ workflow: Workflow, experts: [Expert], connectors: [Connector]) -> WorkflowBundle {
        var expertIDs = Set<UUID>()
        var connectorIDs = Set<UUID>()
        for node in workflow.nodes {
            switch node.kind {
            case .agent(let config):
                if let id = config.expertID { expertIDs.insert(id) }
                connectorIDs.formUnion(config.connectorIDs)
            case .context(let config):
                connectorIDs.formUnion(config.connectorIDs)
            default:
                break
            }
        }
        let used = experts.filter { expertIDs.contains($0.id) }
        for expert in used { connectorIDs.formUnion(expert.connectorIDs) }
        return WorkflowBundle(workflow: workflow, experts: used,
                              connectors: connectors.filter { connectorIDs.contains($0.id) })
    }

    public func encoded() throws -> Data { try WorkflowJSON.encoder.encode(self) }

    /// A bundle file, or a bare workflow file.
    public static func decode(_ data: Data) throws -> WorkflowBundle {
        if let bundle = try? WorkflowJSON.decoder.decode(WorkflowBundle.self, from: data) { return bundle }
        let workflow = try WorkflowJSON.decoder.decode(Workflow.self, from: data)
        return WorkflowBundle(workflow: workflow, experts: [], connectors: [])
    }
}

public enum WorkflowJSON {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
