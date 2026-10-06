import Testing
@testable import LoomChromium
import Darwin
import Foundation

// The fence against the real kernel: a TCP client on 127.0.0.1 stands in for
// Chromium's proxy connections. Nothing leaves the machine.

@Suite("ChromiumFence — the local-only proxy", .serialized)
struct ChromiumFenceTests {

    @Test("a connection is accepted, then closed at once: the client reads EOF")
    func connexionFermee() throws {
        let fence = try ChromiumFence.start()
        defer { fence.stop() }
        #expect(fence.port != 0)
        #expect(fence.isListening)

        let client = FenceClient.dial(fence.port)
        try #require(client.descriptor >= 0, "connection refused (errno \(client.failure))")
        defer { close(client.descriptor) }
        var count = -1
        let elapsed = ContinuousClock().measure { count = FenceClient.readOnce(client.descriptor) }
        #expect(count == 0, "end of file, nothing written back")
        #expect(elapsed < .seconds(2))
        #expect(FenceClient.waitUntil { fence.refusedConnections == 1 })
    }

    @Test("several waiting connections are all closed")
    func plusieursConnexions() throws {
        let fence = try ChromiumFence.start()
        defer { fence.stop() }
        let clients = (0..<5).map { _ in FenceClient.dial(fence.port) }
        defer { for client in clients where client.descriptor >= 0 { close(client.descriptor) } }
        for client in clients {
            try #require(client.descriptor >= 0)
            #expect(FenceClient.readOnce(client.descriptor) == 0)
        }
        #expect(FenceClient.waitUntil { fence.refusedConnections == 5 })
    }

    @Test("the proxy flags: the fence, then loopback and the allowed hosts as given, in order")
    func argumentsDeLancement() throws {
        let fence = try ChromiumFence.start()
        defer { fence.stop() }
        #expect(fence.proxyServer == "http://127.0.0.1:\(fence.port)")
        #expect(fence.launchArguments(allowedHosts: ["*.staging.example.com", "api.test"]) == [
            "--proxy-server=http://127.0.0.1:\(fence.port)",
            "--proxy-bypass-list=<-loopback>;localhost;*.localhost;127.0.0.0/8;[::1];0.0.0.0;*.staging.example.com;api.test",
        ])
        #expect(fence.launchArguments(allowedHosts: []) == [
            "--proxy-server=http://127.0.0.1:\(fence.port)",
            "--proxy-bypass-list=<-loopback>;localhost;*.localhost;127.0.0.0/8;[::1];0.0.0.0",
        ])
    }

    @Test("a host the bypass list cannot carry is left out, so it stays blocked")
    func hotesNonPortables() throws {
        let fence = try ChromiumFence.start()
        defer { fence.stop() }
        let arguments = fence.launchArguments(allowedHosts: ["", "*", "<local>", "a.test;b.test", "a.test,b.test",
                                                             "two words", " kept.test "])
        #expect(arguments.last == "--proxy-bypass-list=<-loopback>;localhost;*.localhost;127.0.0.0/8;[::1];0.0.0.0;kept.test")
    }

    @Test("two fences hold two different ports")
    func deuxPorts() throws {
        let first = try ChromiumFence.start()
        defer { first.stop() }
        let second = try ChromiumFence.start()
        defer { second.stop() }
        #expect(first.port != second.port)
    }

    @Test("once stopped, the port refuses connections")
    func arretFermeLePort() throws {
        let fence = try ChromiumFence.start()
        let port = fence.port
        fence.stop()
        #expect(!fence.isListening)
        let client = FenceClient.dial(port)
        if client.descriptor >= 0 { close(client.descriptor) }
        #expect(client.descriptor < 0)
        #expect(client.failure == ECONNREFUSED)
        fence.stop()   // a second stop is harmless
    }

    @Test("only the loopback names of the bypass list count as never fenced")
    func bouclesJamaisCloturees() {
        for host in ["localhost", "app.localhost", "127.0.0.1", "127.0.0.2", "0.0.0.0", "::1", "[::1]", "LOCALHOST"] {
            #expect(ChromiumFence.bypassesAsLoopback(host), "\(host)")
        }
        for host in ["example.com", "127.0.0", "127.0.0.256", "169.254.169.254", "localhost.example.com", "10.0.0.1"] {
            #expect(!ChromiumFence.bypassesAsLoopback(host), "\(host)")
        }
    }
}

/// A plain blocking TCP client, bounded in time: a test that hangs is worse
/// than one that fails.
private enum FenceClient {

    static func dial(_ port: UInt16) -> (descriptor: Int32, failure: Int32) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return (-1, errno) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            close(descriptor)
            return (-1, code)
        }
        return (descriptor, 0)
    }

    /// One read: 0 at EOF, -1 on error or after the 3 s receive timeout.
    static func readOnce(_ descriptor: Int32) -> Int {
        var buffer = [UInt8](repeating: 0, count: 64)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            return count
        }
    }

    static func waitUntil(_ condition: () -> Bool) -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            usleep(10_000)
        }
        return condition()
    }
}
