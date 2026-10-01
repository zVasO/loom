import LoomAPI
import LoomCore
import Dispatch
import Foundation

/// Server for agent hooks (ADR-0005): Unix socket with 0600 permissions, one JSON
/// line `{token, payload}` per hook. The token is verified BEFORE any delivery —
/// a payload with an unknown token never gets past the server (NFR-S).
///
/// The same socket serves the agents API (ADR-0010): a line carrying `request`
/// instead of `payload` is answered with one response line on the same
/// connection. Its token is checked first too — an unknown one gets the
/// connection closed, never an answer.
///
/// BSD sockets + DispatchSource implementation, deliberately dependency-free:
/// a local line-by-line stream justifies neither SwiftNIO nor Network.framework.
public final class HookSocketServer: @unchecked Sendable {

    public typealias Validate = @Sendable (_ token: String) -> SessionID?
    public typealias Handler = @Sendable (_ session: SessionID, _ payload: Data) -> Void
    /// The scope a token opens for the API — `nil` = unknown token. Without
    /// one, session tokens (`validate`) open their session's scope and no
    /// token is global.
    public typealias Authorize = @Sendable (_ token: String) -> APIScope?
    /// Answers a request under its scope. Runs off the IPC queue — on
    /// whatever actor the handler needs — and its answer goes back to the
    /// connection that asked, if it is still there.
    /// A handler may take seconds (a page loading in the agent's browser):
    /// the connection is tagged, so a late answer never reaches a stranger.
    public typealias RequestHandler = @Sendable (_ scope: APIScope, _ request: APIRequest) async -> APIResponse

    /// A client that sends this much without a newline is not speaking the
    /// protocol: it is dropped rather than buffered without end.
    public static let maxLineBytes = 8 << 20

    private let socketPath: URL
    private let validate: Validate
    private let handler: Handler
    private let authorize: Authorize?
    private let requests: RequestHandler?
    private let queue = DispatchQueue(label: "app.loom.ipc")
    private var listeningDescriptor: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    /// Per client: its read source, the bytes not yet delivered, how far into
    /// them the last drain looked without finding a newline, and the
    /// connection's generation — a descriptor number is reused by the next
    /// client the moment its previous owner hangs up.
    private var connections: [Int32: (source: DispatchSourceRead, buffer: Data, scanned: Int,
                                      generation: UInt64)] = [:]
    private var nextGeneration: UInt64 = 0

    public init(socketPath: URL, validate: @escaping Validate, handler: @escaping Handler,
                authorize: Authorize? = nil, requests: RequestHandler? = nil) {
        self.socketPath = socketPath
        self.validate = validate
        self.handler = handler
        self.authorize = authorize
        self.requests = requests
    }

    public func start() throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw IPCError.socketCreationFailed(errno: errno) }

        // NEVER steal the socket of a live instance: the unlink below would
        // orphan its server and leave all its hooks failing with errno 61. A
        // dead file (nobody answering), however, is a wreck to be replaced.
        if FileManager.default.fileExists(atPath: socketPath.path),
           Self.isServerAlive(at: socketPath.path) {
            close(descriptor)
            throw IPCError.anotherInstanceRunning(socketPath.path)
        }
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

    // MARK: - On the IPC queue

    private func acceptConnection() {
        let client = accept(listeningDescriptor, nil, nil)
        guard client >= 0 else { return }
        // A reply written after the client hung up must fail, not kill Loom;
        // and a client that stops reading must not stall this queue — every
        // session's hooks go through it: non-blocking, each reply bounded as
        // a whole (see reply).
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        source.setEventHandler { [weak self] in self?.readFrom(client) }
        source.setCancelHandler { close(client) }
        nextGeneration += 1
        connections[client] = (source, Data(), 0, nextGeneration)
        source.activate()
    }

    private func readFrom(_ client: Int32) {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = read(client, &chunk, chunk.count)
        // Non-blocking: nothing to read yet is not a hang-up.
        if count < 0, errno == EAGAIN || errno == EINTR { return }
        guard count > 0 else {
            connections[client]?.source.cancel()
            connections[client] = nil
            return
        }
        connections[client]?.buffer.append(contentsOf: chunk[0..<count])
        drainLines(from: client)
        if let pending = connections[client]?.buffer.count, pending > Self.maxLineBytes {
            drop(client)
        }
    }

    /// Lines are cut out of the connection's buffer IN PLACE. The buffer is
    /// checked out of the dictionary for the drain, so its storage has one
    /// owner and each cut is a memmove — a second reference (a `while let`
    /// binding) made Data copy the whole buffer before every cut. The scan
    /// resumes where the last one stopped: a large payload arriving in 4 KB
    /// events is not rescanned from its start on each of them.
    private func drainLines(from client: Int32) {
        guard var buffer = connections[client]?.buffer else { return }
        var scanned = connections[client]?.scanned ?? 0
        connections[client]?.buffer = Data()
        let newlineByte = UInt8(ascii: "\n")
        while let newline = buffer[(buffer.startIndex + scanned)...].firstIndex(of: newlineByte) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            scanned = 0
            deliver(line, from: client)
            // A rejected request dropped the connection: nothing to put back.
            guard connections[client] != nil else { return }
        }
        connections[client]?.buffer = buffer
        connections[client]?.scanned = buffer.count
    }

    private func deliver(_ line: Data, from client: Int32) {
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let fields = object as? [String: Any],
              let token = fields[APIEnvelope.tokenKey] as? String else {
            return   // corrupted line: silence, never a delivery
        }
        if let payload = fields[APIEnvelope.hookPayloadKey] {
            // A scalar payload would raise in JSONSerialization — an
            // Objective-C exception no `try?` catches.
            guard let session = validate(token),
                  JSONSerialization.isValidJSONObject(payload),
                  let payloadData = try? JSONSerialization.data(withJSONObject: payload) else {
                return   // unknown token or malformed payload: silence, never a delivery
            }
            handler(session, payloadData)
        } else if let request = fields[APIEnvelope.requestKey] {
            answer(request, token: token, from: client)
        }
    }

    // MARK: - Requests (ADR-0010)

    private func scope(for token: String) -> APIScope? {
        if let authorize { return authorize(token) }
        return validate(token).map { APIScope.session($0) }
    }

    private func answer(_ request: Any, token: String, from client: Int32) {
        // The token first, the request never before: an unknown token is not
        // told what went wrong — the connection just ends (NFR-S).
        guard let requests, let scope = scope(for: token) else {
            drop(client)
            return
        }
        guard JSONSerialization.isValidJSONObject(request),
              let data = try? JSONSerialization.data(withJSONObject: request),
              let decoded = try? JSONDecoder().decode(APIRequest.self, from: data) else {
            let id = (request as? [String: Any])?["id"] as? String ?? ""
            reply(APIResponse(id: id, error: APIError(code: .invalidRequest,
                                                      message: "not a request: {id, method, params}")),
                  to: client, generation: connections[client]?.generation)
            return
        }
        let generation = connections[client]?.generation
        Task { [weak self] in
            let response = await requests(scope, decoded)
            self?.queue.async { self?.reply(response, to: client, generation: generation) }
        }
    }

    /// On the IPC queue. A client gone since it asked gets nothing — its
    /// descriptor may already belong to someone else, which the generation
    /// tells apart. A reply holds the queue `replyDeadline` at most, however
    /// slowly its client reads: past it, the client is dropped.
    private func reply(_ response: APIResponse, to client: Int32, generation: UInt64?) {
        guard let connection = connections[client], connection.generation == generation,
              let line = try? APIEnvelope.responseLine(response) else { return }
        let giveUp = ContinuousClock.now + Self.replyDeadline
        let complete = line.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let written = write(client, buffer.baseAddress! + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else if written < 0, errno == EAGAIN {
                    let left = ContinuousClock.now.duration(to: giveUp)
                    guard left > .zero else { return false }
                    let milliseconds = left.components.seconds * 1_000
                        + left.components.attoseconds / 1_000_000_000_000_000
                    var poller = pollfd(fd: client, events: Int16(POLLOUT), revents: 0)
                    if poll(&poller, 1, max(Int32(clamping: milliseconds), 1)) < 0, errno != EINTR { return false }
                } else {
                    return false   // gone: give up on it
                }
            }
            return true
        }
        if !complete { drop(client) }
    }

    /// The whole of one reply, written to a client that reads slowly.
    static let replyDeadline: Duration = .seconds(2)

    private func drop(_ client: Int32) {
        connections[client]?.source.cancel()
        connections[client] = nil
    }
}

public enum IPCError: Error, Sendable {
    case socketCreationFailed(errno: Int32)
    case socketPathTooLong(String)
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)
    /// A server already answers on this path: another instance of the app is running.
    case anotherInstanceRunning(String)
}

extension HookSocketServer {
    /// Liveness probe: `connect` succeeds ⇔ a server is listening behind the file.
    static func isServerAlive(at path: String) -> Bool {
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { close(probe) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        path.withCString { source in
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.baseAddress!.assumingMemoryBound(to: CChar.self)
                    .update(from: source, count: strlen(source) + 1)
            }
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }
}
