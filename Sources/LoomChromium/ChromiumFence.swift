import LoomCore
import Darwin
import Dispatch
import Foundation

public enum ChromiumFenceError: Error, Equatable, Sendable {
    case socketFailed(errno: Int32)
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)
    case addressUnknown(errno: Int32)
}

/// The proxy Chromium is pointed at in local-only mode (ADR-0015): a TCP
/// listener Loom owns on 127.0.0.1, which accepts every connection and closes
/// it at once. Whatever the bypass list does not send direct fails there, and
/// fails fast. A "dead" port would do the same until another process took it;
/// this one is held for as long as the fence lives.
///
/// Fail closed: the caller launches nothing in local-only mode until `start()`
/// has returned a fence.
public final class ChromiumFence: @unchecked Sendable {

    /// Kernel-chosen, in host byte order.
    public let port: UInt16

    public var proxyServer: String { "http://127.0.0.1:\(port)" }

    /// The machine's own addresses that go direct, spelled out — the same as
    /// WebKit's local-only rules (AgentNetworkRules). `<-loopback>` drops
    /// Chromium's implicit set, which also sends link-local addresses
    /// (169.254.169.254, a cloud's metadata service) around the proxy.
    static let loopbackBypass = ["localhost", "*.localhost", "127.0.0.0/8", "[::1]", "0.0.0.0"]

    private let descriptor: Int32
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var refused = 0
    /// Left by the cancel handler, once the listener is closed.
    private let closed = DispatchGroup()

    private init(descriptor: Int32, port: UInt16) {
        self.descriptor = descriptor
        self.port = port
        queue = DispatchQueue(label: "app.loom.chromium.fence.\(port)")
    }

    deinit {
        // Never waits: the last reference may go on the fence's own queue.
        cancelSource()
    }

    public static func start() throws -> ChromiumFence {
        // Darwin has no SOCK_CLOEXEC: between socket() and FD_CLOEXEC a
        // forkpty on another thread would hand the listener to an agent, which
        // would hold the port past Loom (SpawnLock).
        SpawnLock.lock()
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        let socketErrno = errno
        if descriptor >= 0 { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        SpawnLock.unlock()
        guard descriptor >= 0 else { throw ChromiumFenceError.socketFailed(errno: socketErrno) }

        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        // accept() is drained until EAGAIN: it must never block the queue.
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(descriptor)
            throw ChromiumFenceError.bindFailed(errno: code)
        }
        guard listen(descriptor, SOMAXCONN) == 0 else {
            let code = errno
            close(descriptor)
            throw ChromiumFenceError.listenFailed(errno: code)
        }

        var named = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let gotName = withUnsafeMutablePointer(to: &named) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard gotName == 0, named.sin_port != 0 else {
            let code = errno
            close(descriptor)
            throw ChromiumFenceError.addressUnknown(errno: code)
        }

        let fence = ChromiumFence(descriptor: descriptor, port: UInt16(bigEndian: named.sin_port))
        fence.activate()
        return fence
    }

    /// The flags that route Chromium through the fence. Loopback and the
    /// person's hosts go direct; everything else meets a closed connection.
    /// A host the list cannot carry is left out, so it stays blocked: one
    /// holding a separator or a special rule (`*`, `<local>`) would open far
    /// more than itself.
    public func launchArguments(allowedHosts: [String]) -> [String] {
        let hosts = allowedHosts
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter(Self.isCarriable)
        let bypass = ["<-loopback>"] + Self.loopbackBypass + hosts
        return ["--proxy-server=\(proxyServer)", "--proxy-bypass-list=" + bypass.joined(separator: ";")]
    }

    /// Connections closed so far.
    public var refusedConnections: Int {
        lock.withLock { refused }
    }

    public var isListening: Bool {
        lock.withLock { source != nil }
    }

    /// Returns once the listener is closed: a connection after it is refused
    /// by the kernel. Not to be called from the fence's own queue.
    public func stop() {
        cancelSource()
        closed.wait()
    }

    // MARK: - Internals

    /// A host the bypass list sends direct without the person's say: what
    /// never reaches the fence.
    static func bypassesAsLoopback(_ host: String) -> Bool {
        var name = host.lowercased()
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        if name == "localhost" || name.hasSuffix(".localhost") || name == "::1" || name == "0.0.0.0" { return true }
        let octets = name.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets[0] == "127" && octets.allSatisfy { UInt8($0) != nil }
    }

    static func isCarriable(_ host: String) -> Bool {
        guard !host.isEmpty, host != "*" else { return false }
        return !host.contains(where: { $0.isWhitespace || ";,<>".contains($0) })
    }

    private func activate() {
        let descriptor = self.descriptor
        let closed = self.closed
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.refuseWaiting() }
        source.setCancelHandler {
            close(descriptor)
            closed.leave()
        }
        closed.enter()
        lock.withLock { self.source = source }
        source.activate()
    }

    private func cancelSource() {
        let source = lock.withLock { () -> DispatchSourceRead? in
            let current = self.source
            self.source = nil
            return current
        }
        source?.cancel()
    }

    /// On the fence's queue: every connection waiting, closed unread and
    /// unanswered. The cancel handler runs after this returns, so the
    /// listener is still ours here.
    private func refuseWaiting() {
        while true {
            // accept() makes a descriptor without close-on-exec: closed under
            // the lock, a forkpty never carries it into an agent, where the
            // request would hang instead of failing.
            SpawnLock.lock()
            let client = accept(descriptor, nil, nil)
            let acceptErrno = errno
            if client >= 0 { close(client) }
            SpawnLock.unlock()
            if client >= 0 {
                lock.withLock { refused += 1 }
                continue
            }
            if acceptErrno == EINTR || acceptErrno == ECONNABORTED { continue }
            return   // EAGAIN: none left; anything else, the next event retries
        }
    }
}
