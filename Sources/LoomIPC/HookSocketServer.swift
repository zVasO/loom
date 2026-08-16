import LoomCore
import Dispatch
import Foundation

/// Serveur des hooks agents (ADR-0005) : socket Unix en 0600, une ligne JSON
/// `{token, payload}` par hook. Le token est vérifié AVANT toute livraison —
/// un payload au token inconnu ne franchit jamais le serveur (NFR-S).
///
/// Implémentation sockets BSD + DispatchSource, délibérément sans dépendance :
/// un flux local ligne-à-ligne ne justifie ni SwiftNIO ni Network.framework.
public final class HookSocketServer: @unchecked Sendable {

    public typealias Validate = @Sendable (_ token: String) -> SessionID?
    public typealias Handler = @Sendable (_ session: SessionID, _ payload: Data) -> Void

    private let socketPath: URL
    private let validate: Validate
    private let handler: Handler
    private let queue = DispatchQueue(label: "app.loom.ipc")
    private var listeningDescriptor: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: (source: DispatchSourceRead, buffer: Data)] = [:]

    public init(socketPath: URL, validate: @escaping Validate, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.validate = validate
        self.handler = handler
    }

    public func start() throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw IPCError.socketCreationFailed(errno: errno) }

        unlink(socketPath.path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath.path
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(descriptor)
            throw IPCError.socketPathTooLong(path)
        }
        path.withCString { source in
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.baseAddress!.assumingMemoryBound(to: CChar.self)
                    .update(from: source, count: strlen(source) + 1)
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            close(descriptor)
            throw IPCError.bindFailed(errno: errno)
        }
        chmod(path, 0o600)
        guard listen(descriptor, 16) == 0 else {
            close(descriptor)
            throw IPCError.listenFailed(errno: errno)
        }

        listeningDescriptor = descriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.setCancelHandler { close(descriptor) }
        source.activate()
        acceptSource = source
    }

    public func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            for (_, connection) in connections { connection.source.cancel() }
            connections.removeAll()
            unlink(socketPath.path)
            listeningDescriptor = -1
        }
    }

    // MARK: - Sur la queue IPC

    private func acceptConnection() {
        let client = accept(listeningDescriptor, nil, nil)
        guard client >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        source.setEventHandler { [weak self] in self?.readFrom(client) }
        source.setCancelHandler { close(client) }
        connections[client] = (source, Data())
        source.activate()
    }

    private func readFrom(_ client: Int32) {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = read(client, &chunk, chunk.count)
        guard count > 0 else {
            connections[client]?.source.cancel()
            connections[client] = nil
            return
        }
        connections[client]?.buffer.append(contentsOf: chunk[0..<count])
        drainLines(from: client)
    }

    private func drainLines(from client: Int32) {
        guard var buffer = connections[client]?.buffer else { return }
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            deliver(Data(line))
        }
        connections[client]?.buffer = Data(buffer)
    }

    private func deliver(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let fields = object as? [String: Any],
              let token = fields["token"] as? String,
              let payload = fields["payload"],
              let session = validate(token),
              let payloadData = try? JSONSerialization.data(withJSONObject: payload) else {
            return   // token inconnu ou ligne corrompue : silence, jamais de livraison
        }
        handler(session, payloadData)
    }
}

public enum IPCError: Error, Sendable {
    case socketCreationFailed(errno: Int32)
    case socketPathTooLong(String)
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)
}
