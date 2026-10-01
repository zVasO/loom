import Darwin
import Foundation

/// The client side of the wire: connect, write one request line, read one
/// response line, close. Blocking and dependency-free on purpose — a CLI
/// invocation lives for one call, and the MCP server can afford one
/// connection per tool call on a local socket.
public struct APIClient: Sendable {
    public var socketPath: String
    public var token: String
    /// Ceiling on the wait for a response; nil = the method's own budget
    /// (`APIMethod.clientTimeout`): metadata answers in milliseconds, a page
    /// load may take seconds.
    public var timeout: Duration?

    public init(socketPath: String, token: String, timeout: Duration? = nil) {
        self.socketPath = socketPath
        self.token = token
        self.timeout = timeout
    }

    /// From the environment Loom gives its agents (`LOOM_SOCKET`,
    /// `LOOM_SESSION_TOKEN`); nil outside a Loom session.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> APIClient? {
        guard let socket = environment[APIProtocol.socketEnvironmentKey],
              let token = environment[APIProtocol.sessionTokenEnvironmentKey],
              !socket.isEmpty, !token.isEmpty else { return nil }
        return APIClient(socketPath: socket, token: token)
    }

    public enum ClientError: Error, Equatable, Sendable {
        case socketPathTooLong
        case connectionFailed(errno: Int32)
        case writeFailed(errno: Int32)
        /// The server hung up without answering: an unknown token, or a
        /// server that does not serve requests.
        case rejected
        case timedOut
        case malformedResponse
    }

    /// One call: the typed result, or the server's error as thrown `APIError`.
    public func call<Result: Decodable>(_ method: APIMethod, params: JSONValue = .object([:]),
                                        as type: Result.Type = Result.self) throws -> Result {
        let response = try send(APIRequest(method: method, params: params))
        if let error = response.error { throw error }
        guard let result = response.result else { throw ClientError.malformedResponse }
        return try result.decode(type)
    }

    public func call<Params: Encodable, Result: Decodable>(_ method: APIMethod, _ params: Params,
                                                           as type: Result.Type = Result.self) throws -> Result {
        try call(method, params: try JSONValue.from(params), as: type)
    }

    /// The raw exchange: a response, whatever it carries, within this
    /// client's timeout or else the method's budget.
    public func send(_ request: APIRequest) throws -> APIResponse {
        try send(request, timeout: timeout
                 ?? APIMethod(rawValue: request.method)?.clientTimeout
                 ?? .seconds(5))
    }

    public func send(_ request: APIRequest, timeout: Duration) throws -> APIResponse {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ClientError.connectionFailed(errno: errno) }
        defer { close(descriptor) }
        // A write after Loom hung up must fail, not kill the process — for
        // `loom mcp`, that would take every Loom tool of the session with it.
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ClientError.socketPathTooLong
        }
        socketPath.withCString { source in
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.baseAddress!.assumingMemoryBound(to: CChar.self)
                    .update(from: source, count: strlen(source) + 1)
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw ClientError.connectionFailed(errno: errno) }

        let line = try APIEnvelope.requestLine(token: token, request: request)
        try line.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                guard written > 0 else { throw ClientError.writeFailed(errno: errno) }
                offset += written
            }
        }

        var received = Data()
        // Large reads, and the newline searched only in the bytes just read:
        // a multi-megabyte answer used to be rescanned from its start after
        // every 4 KB, quadratic, eating the deadline.
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let deadline = ContinuousClock.now + timeout
        while true {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw ClientError.timedOut }
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(clamping: remaining.components.seconds * 1000
                                     + remaining.components.attoseconds / 1_000_000_000_000_000)
            let ready = poll(&poller, 1, max(milliseconds, 1))
            if ready == 0 { throw ClientError.timedOut }
            if ready < 0 { if errno == EINTR { continue }; throw ClientError.connectionFailed(errno: errno) }
            let count = read(descriptor, &chunk, chunk.count)
            if count == 0 { throw ClientError.rejected }
            if count < 0 { if errno == EINTR { continue }; throw ClientError.connectionFailed(errno: errno) }
            let scanFrom = received.endIndex
            received.append(contentsOf: chunk[0..<count])
            if let newline = received[scanFrom...].firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = received[received.startIndex..<newline]
                // An answer to another request — one written late, after its
                // asker gave up, onto a descriptor since reused — is never ours.
                guard let response = try? APIEnvelope.decodeResponse(Data(lineData)),
                      response.id == request.id else {
                    throw ClientError.malformedResponse
                }
                return response
            }
        }
    }
}
