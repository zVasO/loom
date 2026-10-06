import Testing
import LoomChromium
import LoomCore
import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Seam: the connection's public API against a peer that plays Chromium on
// the far ends of two real pipes — it reads the commands Chromium would read
// on its fd 3 and writes the replies and events Chromium would write on its
// fd 4. No process, no network: every byte on the wire is the test's choice.

@Suite("CDPConnection — the DevTools pipe", .serialized, .timeLimit(.minutes(1)))
struct CDPConnectionTests {

    private let page = CDPSessionID("PAGE-1")
    private let other = CDPSessionID("PAGE-2")

    /// Every wait in these tests ends: a bug shows up as a timeout, never a hang.
    private func bounded(_ interruptible: Set<CDPInterruption> = []) -> CDPCallOptions {
        CDPCallOptions(deadline: ContinuousClock.now + .seconds(2), interruptible: interruptible)
    }

    @Test("a call goes out as {id, method, params, sessionId} and gets its reply's result")
    func appelEtReponse() async throws {
        let peer = try FakeChromium()
        let connection = peer.connection()
        connection.start(onClose: { _ in })
        defer { connection.close(); peer.finish() }

        let reply = connection.post("Runtime.evaluate", ["expression": "1+1"], session: page, options: bounded())
        let command = try #require(peer.nextCommand())
        #expect(command["id"] as? Int == 1, "ids start at 1")
        #expect(reply.id == 1)
        #expect(command["method"] as? String == "Runtime.evaluate")
        #expect((command["params"] as? [String: Any])?["expression"] as? String == "1+1")
        #expect(command["sessionId"] as? String == "PAGE-1")

        peer.send(#"{"id":1,"result":{"result":{"type":"number","value":2}},"sessionId":"PAGE-1"}"#)
        let result = try await reply.value()
        #expect(result.object("result")?.string("type") == "number")
        #expect(result.object("result")?.int("value") == 2)
    }

    @Test("replies are matched by id, whatever their order; a browser call carries no sessionId")
    func reponsesDansLeDesordre() async throws {
        let peer = try FakeChromium()
        let connection = peer.connection()
        connection.start(onClose: { _ in })
        defer { connection.close(); peer.finish() }

        let targets = connection.post("Target.getTargets", options: bounded())
        let version = connection.post("Browser.getVersion", options: bounded())
        let first = try #require(peer.nextCommand())
        let second = try #require(peer.nextCommand())
        #expect(!first.keys.contains("sessionId"))
        #expect(!second.keys.contains("sessionId"))

        peer.send(#"{"id":2,"result":{"product":"HeadlessChrome/131.0.6778.0"}}"#,
                  #"{"id":1,"result":{"targetInfos":[{"targetId":"T1","type":"page"}]}}"#)
        let versionResult = try await version.value()
        let targetsResult = try await targets.value()
        #expect(versionResult.string("product") == "HeadlessChrome/131.0.6778.0")
        #expect(targetsResult.objects("targetInfos")?.first?.string("targetId") == "T1")
    }

    @Test("an error reply becomes CDPError.protocolError with the call's method")
    func erreurDeProtocole() async throws {
        let peer = try FakeChromium()
        let connection = peer.connection()
        connection.start(onClose: { _ in })
        defer { connection.close(); peer.finish() }

        let reply = connection.post("Runtime.callFunctionOn", ["functionDeclaration": "() => 1"],
                                    session: page, options: bounded())
        peer.send(#"{"id":1,"error":{"code":-32000,"message":"Cannot find context with specified id"},"sessionId":"PAGE-1"}"#)
        let error = await failure(of: reply)
        #expect(error == CDPError.protocolError(method: "Runtime.callFunctionOn", code: -32000,
                                                message: "Cannot find context with specified id"))
    }

    @Test("events reach their session's sink in wire order, before the reply that follows them")
    func evenementsAvantLaReponse() async throws {
        let peer = try FakeChromium()
        let connection = peer.connection()
        let journal = Journal()
        // The page sink is slow on purpose: the reply still waits for it.
        connection.setSink(RecordingSink("page", journal: journal, pause: 20_000), for: page)
        connection.setSink(RecordingSink("browser", journal: journal), for: nil)
        connection.start(onClose: { _ in })
        defer { connection.close(); peer.finish() }

        let click = connection.post("Input.dispatchMouseEvent", ["type": "mouseReleased"],
                                    session: page, options: bounded())
        let waiter = Task {
            _ = try await click.value()
            journal.append("reply")
        }
        let command = try #require(peer.nextCommand())
        let id = try #require(command["id"] as? Int)
        peer.send(#"{"method":"Page.frameRequestedNavigation","params":{"n":1},"sessionId":"PAGE-1"}"#,
                  #"{"method":"Target.targetInfoChanged","params":{"n":2}}"#,
                  #"{"method":"Page.frameStartedLoading","params":{"n":3},"sessionId":"PAGE-1"}"#,
                  #"{"id":\#(id),"result":{},"sessionId":"PAGE-1"}"#)
        try await waiter.value

        #expect(journal.entries == [
            "page:Page.frameRequestedNavigation:1",
            "browser:Target.targetInfoChanged:2",
            "page:Page.frameStartedLoading:3",
            "reply",
        ], "the woken caller already sees the navigation it caused")
    }

    @Test("a sink set from a sink receives the very next frame of its session")
    func puitsPoseDepuisUnPuits() async throws {
        let peer = try FakeChromium()
        let connection = peer.connection()
        let journal = Journal()
        let pageSink = RecordingSink("page", journal: journal)
        let session = page
        // What the browser router does on attach, on the reader queue.
        let router = RecordingSink("browser", journal: journal) { [weak connection] method in
            if method == "Target.attachedToTarget" {
                connection?.setSink(pageSink, for: session)
            }
        }
        connection.setSink(router, for: nil)
        connection.start(onClose: { _ in })
        defer { connection.close(); peer.finish() }

        peer.send(#"{"method":"Page.lifecycleEvent","params":{"n":0},"sessionId":"PAGE-1"}"#,
                  #"{"method":"Target.attachedToTarget","params":{"sessionId":"PAGE-1"}}"#,
                  #"{"method":"Page.lifecycleEvent","params":{"n":1},"sessionId":"PAGE-1"}"#)
        let arrived = await pollUntil { journal.entries.count == 2 }
        #expect(arrived)
        #expect(journal.entries == ["browser:Target.attachedToTarget", "page:Page.lifecycleEvent:1"],
                "before the attach nobody listens to that session: its event is dropped")
    }

    @Test("a batch goes out in ONE write, its frames in order")
    func lotEnUneEcriture() async throws {
        let peer = try FakeChromium()
        let connection = peer.connection()
        connection.start(onClose: { _ in })
        defer { connection.close(); peer.finish() }

        let replies = connection.post(batch: [
            ("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": 10, "y": 20]),
            ("Input.dispatchMouseEvent", ["type": "mousePressed", "x": 10, "y": 20, "button": "left", "clickCount": 1]),
            ("Input.dispatchMouseEvent", ["type": "mouseReleased", "x": 10, "y": 20, "button": "left", "clickCount": 1]),
        ], session: page, options: bounded())
        #expect(replies.map { $0.id } == [1, 2, 3])

        // Under PIPE_BUF a write() is atomic: one read gets all of it, or
        // the frames left in separate writes.
        let chunk = try #require(peer.nextChunk())
        #expect(chunk.filter { $0 == 0 }.count == 3, "three frames in one read: they left in one write()")
        var framer = CDPFramer()
        let frames = try framer.feed(chunk)
        let types = frames.compactMap { frame -> String? in
            let message = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any]
            return (message?["params"] as? [String: Any])?["type"] as? String
        }
        #expect(types == ["mouseMoved", "mousePressed", "mouseReleased"])

        peer.send(#"{"id":1,"result":{}}"#, #"{"id":2,"result":{}}"#, #"{"id":3,"result":{}}"#)
        for reply in replies {
            _ = try await reply.value()
        }
    }

    @Test("a call past its deadline fails with .timeout; its late reply is dropped")
    func delaiDepasse() async throws {
        let peer = try FakeChromium()
        let connection = peer.connection()
        connection.start(onClose: { _ in })
        defer { connection.close(); peer.finish() }

        let started = ContinuousClock.now
        let reply = connection.post("Runtime.evaluate", ["expression": "new Promise(() => {})"],
                                    options: CDPCallOptions(deadline: ContinuousClock.now + .milliseconds(50)))
        let error = await failure(of: reply)
        let waited = started.duration(to: ContinuousClock.now)
        #expect(error == CDPError.timeout(method: "Runtime.evaluate"))
        #expect(waited >= Duration.milliseconds(40), "not before its deadline")
        #expect(waited < Duration.seconds(1))

        peer.send(#"{"id":1,"result":{}}"#)
        let next = connection.post("Browser.getVersion", options: bounded())
        peer.send(#"{"id":2,"result":{"product":"HeadlessChrome/131.0.6778.0"}}"#)
        let version = try await next.value()
        #expect(version.string("product") == "HeadlessChrome/131.0.6778.0", "the late reply did not take its place")
    }

    @Test("a dialog interrupts only that session's calls that accept it; their late replies are dropped")
    func interruptionCiblee() async throws {
        let peer = try FakeChromium()
        let connection = peer.connection()
        let session = page
        // What PageSignals does on the reader queue when a dialog opens.
        let sink = RecordingSink("page", journal: Journal()) { [weak connection] method in
            if method == "Page.javascriptDialogOpening" {
                connection?.interrupt(session: session, .dialogOpened)
            }
        }
        connection.setSink(sink, for: page)
        connection.start(onClose: { _ in })
        defer { connection.close(); peer.finish() }

        let click = connection.post("Input.dispatchMouseEvent", ["type": "mousePressed"],
                                    session: page, options: bounded([.dialogOpened, .navigated]))
        let navigation = connection.post("Page.navigate", ["url": "https://example.test/"],
                                         session: page, options: bounded([.navigated]))
        let elsewhere = connection.post("Input.dispatchMouseEvent", ["type": "mousePressed"],
                                        session: other, options: bounded([.dialogOpened]))

        peer.send(#"{"method":"Page.javascriptDialogOpening","params":{"type":"alert","message":"hi"},"sessionId":"PAGE-1"}"#)
        let error = await failure(of: click)
        #expect(error == CDPError.interrupted(.dialogOpened))

        // The click's own reply comes once the dialog is handled: dropped by id.
        peer.send(#"{"id":1,"result":{}}"#,
                  #"{"id":2,"result":{"frameId":"F1"},"sessionId":"PAGE-1"}"#,
                  #"{"id":3,"result":{},"sessionId":"PAGE-2"}"#)
        let navigated = try await navigation.value()
        #expect(navigated.string("frameId") == "F1")
        _ = try await elsewhere.value()
    }

    @Test("failAll ends every pending call of one session, and only those")
    func toutEchoueSurUneSession() async throws {
        let peer = try FakeChromium()
        let connection = peer.connection()
        connection.start(onClose: { _ in })
        defer { connection.close(); peer.finish() }

        let detached = connection.post("Runtime.evaluate", session: page, options: bounded())
        let alive = connection.post("Runtime.evaluate", session: other, options: bounded())
        connection.failAll(session: page, .interrupted(.detached))
        let error = await failure(of: detached)
        #expect(error == CDPError.interrupted(.detached))

        peer.send(#"{"id":2,"result":{},"sessionId":"PAGE-2"}"#)
        _ = try await alive.value()
    }

    @Test("a cancelled wait throws .cancelled; its late reply is dropped and the next call works")
    func annulation() async throws {
        let peer = try FakeChromium()
        let connection = peer.connection()
        connection.start(onClose: { _ in })
        defer { connection.close(); peer.finish() }

        let reply = connection.post("Runtime.evaluate", ["expression": "new Promise(() => {})"],
                                    session: page, options: bounded())
        let waiter = Task { try await reply.value() }
        waiter.cancel()
        switch await waiter.result {
        case .success:
            Issue.record("a cancelled wait returned a value")
        case .failure(let error):
            #expect(error as? CDPError == CDPError.cancelled)
        }

        peer.send(#"{"id":1,"result":{"result":{"type":"undefined"}},"sessionId":"PAGE-1"}"#)
        let next = connection.post("Browser.getVersion", options: bounded())
        peer.send(#"{"id":2,"result":{"product":"HeadlessChrome/131.0.6778.0"}}"#)
        let version = try await next.value()
        #expect(version.string("product") == "HeadlessChrome/131.0.6778.0")
    }

    @Test("EOF fails every pending call with .disconnected and calls onClose once")
    func finDuFlux() async throws {
        let peer = try FakeChromium()
        defer { peer.finish() }
        let connection = peer.connection()
        let closes = Journal()
        connection.start(onClose: { reason in closes.append(reason) })

        let version = connection.post("Browser.getVersion", options: bounded())
        let navigation = connection.post("Page.navigate", ["url": "about:blank"], session: page, options: bounded())
        peer.hangUp()

        let versionError = await failure(of: version)
        let navigationError = await failure(of: navigation)
        #expect(isDisconnected(versionError))
        #expect(isDisconnected(navigationError))
        let closed = await pollUntil { closes.entries.count == 1 }
        #expect(closed)
        #expect(connection.isClosed)

        let late = connection.post("Browser.getVersion", options: bounded())
        let lateError = await failure(of: late)
        #expect(isDisconnected(lateError), "nothing more goes out on a dead pipe")
        try await Task.sleep(for: .milliseconds(30))
        #expect(closes.entries.count == 1, "onClose runs once")
    }

    @Test("close() ends Chromium's input: it reads EOF, and pending and later calls fail")
    func fermeture() async throws {
        let peer = try FakeChromium()
        defer { peer.finish() }
        let connection = peer.connection()
        connection.start(onClose: { _ in })

        let closing = connection.post("Browser.close", options: bounded())
        _ = peer.nextCommand()
        connection.close()
        #expect(connection.isClosed)
        let closingError = await failure(of: closing)
        #expect(isDisconnected(closingError))
        #expect(peer.seesEndOfStream(), "Chromium reads EOF on its fd 3 and exits by itself")

        let late = connection.post("Browser.getVersion", options: bounded())
        let lateError = await failure(of: late)
        #expect(isDisconnected(lateError))
    }

    @Test("a frame over the size limit ends the connection")
    func trameTropGrandeFerme() async throws {
        let peer = try FakeChromium()
        defer { peer.finish() }
        let connection = peer.connection(maxFrameBytes: 64)
        let closes = Journal()
        connection.start(onClose: { reason in closes.append(reason) })

        let capture = connection.post("Page.captureScreenshot", session: page, options: bounded())
        peer.sendBytes(Data(repeating: UInt8(ascii: "x"), count: 100))
        let error = await failure(of: capture)
        #expect(isDisconnected(error))
        let closed = await pollUntil { closes.entries.count == 1 }
        #expect(closed)
        #expect(connection.isClosed)
    }

    @Test("a reply split across writes is joined, and an unreadable frame is skipped")
    func reponseCoupee() async throws {
        let peer = try FakeChromium()
        let connection = peer.connection()
        connection.start(onClose: { _ in })
        defer { connection.close(); peer.finish() }

        let reply = connection.post("DOM.getDocument", session: page, options: bounded())
        peer.send("not json")
        let bytes = Array(#"{"id":1,"result":{"root":{"nodeName":"HTML"}},"sessionId":"PAGE-1"}"#.utf8)
        peer.sendBytes(Data(bytes[0..<20]))
        try await Task.sleep(for: .milliseconds(20))
        var tail = Data(bytes[20...])
        tail.append(UInt8(0))
        peer.sendBytes(tail)

        let result = try await reply.value()
        #expect(result.object("root")?.string("nodeName") == "HTML")
    }

    @Test("a raw subscription gets the frame's bytes unparsed, and no sink ever sees it")
    func abonnementBrut() async throws {
        let peer = try FakeChromium()
        let connection = peer.connection()
        let journal = Journal()
        let frames = Collected()
        connection.setSink(RecordingSink("page", journal: journal), for: page)
        connection.subscribeRaw(method: "Page.screencastFrame", queue: DispatchQueue(label: "test.cdp.frames")) { data in
            frames.append(data)
        }
        connection.start(onClose: { _ in })
        defer { connection.close(); peer.finish() }

        // Not even JSON past the method: proof that nothing parsed it.
        let screencast = #"{"method":"Page.screencastFrame","params":{"data":"iVBORw0KGgo="#
        peer.send(screencast,
                  #"{"method":"Page.screencastVisibilityChanged","params":{"visible":true},"sessionId":"PAGE-1"}"#)
        let arrived = await pollUntil { frames.all.count == 1 && journal.entries.count == 1 }
        #expect(arrived)
        #expect(frames.all.first == Data(screencast.utf8))
        #expect(journal.entries == ["page:Page.screencastVisibilityChanged"],
                "only the subscribed method goes raw: the other screencast events still reach the sink")
    }
}

// MARK: - Tooling

private struct PipeFailure: Error {}

/// Plays Chromium on the far ends of two pipes: reads what Loom writes to
/// Chromium's fd 3, writes what Chromium would write on its fd 4.
private final class FakeChromium: @unchecked Sendable {
    /// Loom's ends, owned by the connection once handed to it.
    let loomRead: Int32
    let loomWrite: Int32
    private let commands: Int32
    private let replies: Int32
    private var framer = CDPFramer()
    private var queued: [Data] = []
    private var commandsOpen = true
    private var repliesOpen = true

    init() throws {
        var toChromium: [Int32] = [-1, -1]
        var fromChromium: [Int32] = [-1, -1]
        // As in production: close-on-exec under the spawn lock, so a child
        // spawned by another test cannot hold these pipes open.
        let made = SpawnLock.withLock { () -> Bool in
            guard pipe(&toChromium) == 0 else { return false }
            guard pipe(&fromChromium) == 0 else {
                _ = close(toChromium[0])
                _ = close(toChromium[1])
                return false
            }
            for descriptor in toChromium + fromChromium {
                _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            }
            return true
        }
        guard made else { throw PipeFailure() }
        commands = toChromium[0]
        loomWrite = toChromium[1]
        loomRead = fromChromium[0]
        replies = fromChromium[1]
        #if canImport(Darwin)
        _ = fcntl(replies, F_SETNOSIGPIPE, 1)
        #endif
    }

    func connection(maxFrameBytes: Int = 256 << 20) -> CDPConnection {
        CDPConnection(read: loomRead, write: loomWrite, label: "test-\(loomRead)", maxFrameBytes: maxFrameBytes)
    }

    /// The next command Loom wrote, parsed; nil if none comes within `timeout` ms.
    func nextCommand(timeout: Int32 = 2_000) -> [String: Any]? {
        while queued.isEmpty {
            guard let chunk = nextChunk(timeout: timeout),
                  let frames = try? framer.feed(chunk) else { return nil }
            queued.append(contentsOf: frames)
        }
        let frame = queued.removeFirst()
        return (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any]
    }

    /// One read() of what Loom wrote; nil on timeout or end of stream.
    func nextChunk(timeout: Int32 = 2_000) -> Data? {
        var waiting = pollfd(fd: commands, events: Int16(POLLIN), revents: 0)
        guard poll(&waiting, 1, timeout) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        let count = read(commands, &buffer, buffer.count)
        guard count > 0 else { return nil }
        return Data(buffer[0..<count])
    }

    /// Drains what Loom wrote until EOF — what Chromium sees once Loom closes
    /// its end. False if the pipe stays open past `timeout` ms.
    func seesEndOfStream(timeout: Int32 = 2_000) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            var waiting = pollfd(fd: commands, events: Int16(POLLIN), revents: 0)
            guard poll(&waiting, 1, timeout) > 0 else { return false }
            let count = read(commands, &buffer, buffer.count)
            if count == 0 { return true }
            if count < 0 { return false }
        }
    }

    /// The frames NUL-terminated, all in ONE write: a burst as Chromium sends it.
    func send(_ frames: String...) {
        var bytes = Data()
        for frame in frames {
            bytes.append(contentsOf: Array(frame.utf8))
            bytes.append(UInt8(0))
        }
        sendBytes(bytes)
    }

    func sendBytes(_ bytes: Data) {
        let descriptor = replies
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, base + offset, raw.count - offset)
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    /// Chromium's fd 4 closes, as when it dies: Loom reads EOF.
    func hangUp() {
        if repliesOpen {
            repliesOpen = false
            _ = close(replies)
        }
    }

    func finish() {
        hangUp()
        if commandsOpen {
            commandsOpen = false
            _ = close(commands)
        }
    }
}

private final class Journal: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func append(_ item: String) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var entries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Data] = []

    func append(_ item: Data) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var all: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// Writes "name:method" (":n" when the params carry one) to the journal.
private final class RecordingSink: CDPEventSink, @unchecked Sendable {
    private let name: String
    private let journal: Journal
    private let pause: UInt32
    private let onEvent: (@Sendable (String) -> Void)?

    init(_ name: String, journal: Journal, pause: UInt32 = 0, onEvent: (@Sendable (String) -> Void)? = nil) {
        self.name = name
        self.journal = journal
        self.pause = pause
        self.onEvent = onEvent
    }

    func handle(method: String, params: CDPObject, session: CDPSessionID?) {
        if pause > 0 {
            usleep(pause)
        }
        let suffix = params.int("n").map { ":\($0)" } ?? ""
        journal.append("\(name):\(method)\(suffix)")
        onEvent?(method)
    }
}

/// The error a reply ends with; nil if it succeeds.
private func failure(of reply: CDPReply) async -> CDPError? {
    do {
        _ = try await reply.value()
        return nil
    } catch let error as CDPError {
        return error
    } catch {
        return nil
    }
}

private func isDisconnected(_ error: CDPError?) -> Bool {
    if case .some(.disconnected(_)) = error { return true }
    return false
}

private func pollUntil(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<400 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
