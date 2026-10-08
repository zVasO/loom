#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

/// One call in flight. Resolved once — by its reply, its deadline, an
/// interruption, the pipe closing or the caller's cancellation, whichever
/// comes first; the others find nothing left to resolve.
public final class CDPReply: @unchecked Sendable {
    public let id: Int
    public let method: String

    private weak var connection: CDPConnection?
    private let lock = NSLock()
    private var outcome: Result<CDPObject, CDPError>?
    private var waiters: [CheckedContinuation<CDPObject, Error>] = []

    init(id: Int, method: String, connection: CDPConnection?) {
        self.id = id
        self.method = method
        self.connection = connection
    }

    /// The reply's `result` object. Cancelling the waiting task gives the
    /// call up (`CDPError.cancelled`) and its late reply is dropped by id.
    public func value() async throws -> CDPObject {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CDPObject, Error>) in
                self.lock.lock()
                if let outcome = self.outcome {
                    self.lock.unlock()
                    CDPReply.resume(continuation, with: outcome)
                    return
                }
                self.waiters.append(continuation)
                self.lock.unlock()
            }
        } onCancel: {
            // Runs first when the task is already cancelled: the outcome is
            // then set before the continuation above is ever stored.
            self.connection?.abandon(self.id)
            self.resolve(.failure(.cancelled))
        }
    }

    /// The first outcome wins. Each continuation leaves the list under the
    /// lock before it is resumed, so none is resumed twice.
    func resolve(_ result: Result<CDPObject, CDPError>) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = result
        let waiting = waiters
        waiters = []
        lock.unlock()
        for continuation in waiting {
            Self.resume(continuation, with: result)
        }
    }

    private static func resume(_ continuation: CheckedContinuation<CDPObject, Error>,
                               with result: Result<CDPObject, CDPError>) {
        switch result {
        case .success(let object): continuation.resume(returning: object)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}

/// The DevTools protocol over `--remote-debugging-pipe` (ADR-0016).
///
/// One reader queue does everything that must stay in wire order: it cuts
/// the frames, parses them, hands each event to its session's sink
/// synchronously, then resumes the replies. A reply is therefore never
/// resumed before the events Chromium sent ahead of it were applied — the
/// invariant `settle` relies on to never race a navigation it has not seen.
/// Writes go through their own queue, one `write()` loop per post or batch.
public final class CDPConnection: @unchecked Sendable {

    private struct Pending {
        let reply: CDPReply
        let session: CDPSessionID?
        let interruptible: Set<CDPInterruption>
        let timer: DispatchWorkItem?
    }

    private struct RawSubscription: Sendable {
        let queue: DispatchQueue
        let handler: @Sendable (Data) -> Void
    }

    public let label: String
    private let readDescriptor: Int32
    private let writeDescriptor: Int32
    private let log: @Sendable (String) -> Void
    private let readQueue: DispatchQueue
    private let writeQueue: DispatchQueue

    // Guarded by `lock`.
    private let lock = NSLock()
    private var nextID = 0
    private var pending: [Int: Pending] = [:]
    private var rootSink: (any CDPEventSink)?
    private var sessionSinks: [CDPSessionID: any CDPEventSink] = [:]
    private var rawSubscriptions: [String: RawSubscription] = [:]
    /// Set once nothing more may be posted: `close()`, a failed write or EOF.
    private var closedReason: String?
    private var started = false
    private var onClose: (@Sendable (String) -> Void)?

    // Confined to `readQueue` (set up by `start` before the source runs).
    private var framer: CDPFramer
    private var readSource: DispatchSourceRead?
    private var readBuffer = [UInt8](repeating: 0, count: 64 << 10)
    private var finished = false

    // Confined to `writeQueue`: the descriptor number is never written to
    // once closed — the next pipe or file opened may already reuse it.
    private var writeClosed = false

    /// `read`: the fd Chromium writes (its fd 4); `write`: the fd Chromium
    /// reads (its fd 3). The connection owns both and closes both.
    public init(read: Int32, write: Int32, label: String, maxFrameBytes: Int = 256 << 20,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.readDescriptor = read
        self.writeDescriptor = write
        self.label = label
        self.log = log
        self.framer = CDPFramer(maxFrameBytes: maxFrameBytes)
        self.readQueue = DispatchQueue(label: "app.loom.cdp.read.\(label)", qos: .userInitiated)
        self.writeQueue = DispatchQueue(label: "app.loom.cdp.write.\(label)", qos: .userInitiated)
        #if canImport(Darwin)
        // A write after Chromium died must fail with EPIPE, not kill Loom.
        _ = fcntl(write, F_SETNOSIGPIPE, 1)
        #endif
    }

    deinit {
        // Dropped without close(): both ends still close, so Chromium exits.
        if let readSource {
            readSource.cancel()
        } else if !finished {
            closePipeEnd(readDescriptor)
        }
        if !writeClosed {
            closePipeEnd(writeDescriptor)
        }
        for entry in pending.values {
            entry.timer?.cancel()
            entry.reply.resolve(.failure(.disconnected("the connection was released")))
        }
    }

    /// Starts reading. `onClose` runs once, on the reader queue, when the pipe
    /// ends (EOF, a read error — a frame over the limit fails its own call
    /// only), after every pending call has failed with `.disconnected`.
    public func start(onClose: @escaping @Sendable (String) -> Void) {
        lock.lock()
        let alreadyStarted = started
        started = true
        if !alreadyStarted {
            self.onClose = onClose
        }
        lock.unlock()
        guard !alreadyStarted else { return }

        let descriptor = readDescriptor
        // Non-blocking: a wake-up with nothing to read must not stall the queue.
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: readQueue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        // The read end is closed here and only here: never under a live source.
        source.setCancelHandler { closePipeEnd(descriptor) }
        readSource = source
        source.activate()
    }

    public var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closedReason != nil
    }

    // MARK: - Calls

    @discardableResult
    public func post(_ method: String, _ params: [String: Any] = [:],
                     session: CDPSessionID? = nil, options: CDPCallOptions = CDPCallOptions()) -> CDPReply {
        post(batch: [(method, params)], session: session, options: options)[0]
    }

    /// All frames in ONE write(): `mouseMoved` + `mousePressed` +
    /// `mouseReleased` reach Chromium together, with no scheduling gap
    /// between them, and the target-init burst costs one syscall.
    public func post(batch: [(String, [String: Any])], session: CDPSessionID?,
                     options: CDPCallOptions) -> [CDPReply] {
        guard !batch.isEmpty else { return [] }
        lock.lock()
        let firstID = nextID + 1
        nextID += batch.count
        lock.unlock()

        // Encoded outside the lock: a function declaration can be tens of KB.
        var replies: [CDPReply] = []
        var outgoing: [CDPReply] = []
        var refused: [CDPReply] = []
        var frames = Data()
        for (offset, command) in batch.enumerated() {
            let reply = CDPReply(id: firstID + offset, method: command.0, connection: self)
            replies.append(reply)
            var message: [String: Any] = ["id": reply.id, "method": command.0, "params": command.1]
            if let session {
                message["sessionId"] = session.rawValue
            }
            if let frame = try? CDPFramer.encode(message) {
                frames.append(frame)
                outgoing.append(reply)
            } else {
                refused.append(reply)
            }
        }
        for reply in refused {
            // What Chromium itself answers to params it cannot read.
            reply.resolve(.failure(.protocolError(method: reply.method, code: -32602,
                                                  message: "params are not valid JSON")))
        }
        guard !outgoing.isEmpty else { return replies }

        let fireAt = options.deadline.map { CDPConnection.dispatchTime($0) }
        var timers: [DispatchWorkItem] = []
        lock.lock()
        let closed = closedReason
        if closed == nil {
            // Registered BEFORE the write is queued: a reply can never come
            // back for an id nobody is waiting on yet.
            for reply in outgoing {
                var timer: DispatchWorkItem?
                if fireAt != nil {
                    let id = reply.id
                    let item = DispatchWorkItem { [weak self] in self?.expire(id) }
                    timers.append(item)
                    timer = item
                }
                pending[reply.id] = Pending(reply: reply, session: session,
                                            interruptible: options.interruptible, timer: timer)
            }
        }
        lock.unlock()

        if let closed {
            for reply in outgoing {
                reply.resolve(.failure(.disconnected(closed)))
            }
            return replies
        }
        if let fireAt {
            // On the reader queue: a reply already read when the deadline
            // passes is resolved first, in wire order.
            for timer in timers {
                readQueue.asyncAfter(deadline: fireAt, execute: timer)
            }
        }
        let ids = outgoing.map { $0.id }
        let payload = frames
        writeQueue.async { self.transmit(payload, ids: ids) }
        return replies
    }

    public func call(_ method: String, _ params: [String: Any] = [:], session: CDPSessionID? = nil,
                     options: CDPCallOptions = CDPCallOptions()) async throws -> CDPObject {
        try await post(method, params, session: session, options: options).value()
    }

    // MARK: - Routing

    /// nil `session` = the browser (root) session. Takes effect for the very
    /// next frame read, including when set from a sink on the reader queue —
    /// how a router hands a freshly attached target its own sink.
    public func setSink(_ sink: CDPEventSink?, for session: CDPSessionID?) {
        lock.lock()
        let replaced: (any CDPEventSink)?
        if let session {
            replaced = sessionSinks[session]
            sessionSinks[session] = sink
        } else {
            replaced = rootSink
            rootSink = sink
        }
        lock.unlock()
        // Let go past the lock: a sink's deinit may call back in.
        withExtendedLifetime(replaced) {}
    }

    /// Raw handler for one event method (e.g. "Page.screencastFrame"), called
    /// with the frame's bytes before any JSON parsing, on the given queue.
    /// Such frames skip the in-order rule and never reach a sink: a screencast
    /// frame is megabytes of base64 the reader queue has no use for.
    public func subscribeRaw(method: String, queue: DispatchQueue,
                             _ handler: @escaping @Sendable (Data) -> Void) {
        lock.lock()
        let replaced = rawSubscriptions.updateValue(RawSubscription(queue: queue, handler: handler), forKey: method)
        lock.unlock()
        withExtendedLifetime(replaced) {}
    }

    public func unsubscribeRaw(method: String) {
        lock.lock()
        let removed = rawSubscriptions.removeValue(forKey: method)
        lock.unlock()
        withExtendedLifetime(removed) {}
    }

    /// Fails now the pending calls of `session` whose `interruptible` contains
    /// `reason`: a dialog opened, and an `Input.*` waiting behind it would
    /// only be answered once someone handles the dialog. Their late replies
    /// are dropped by id.
    public func interrupt(session: CDPSessionID, _ reason: CDPInterruption) {
        let entries = takeAll { $0.session == session && $0.interruptible.contains(reason) }
        for entry in entries {
            entry.reply.resolve(.failure(.interrupted(reason)))
        }
    }

    /// Every pending call of `session`, whatever it accepts: the target
    /// detached or crashed, nothing will answer them.
    public func failAll(session: CDPSessionID, _ error: CDPError) {
        let entries = takeAll { $0.session == session }
        for entry in entries {
            entry.reply.resolve(.failure(error))
        }
    }

    /// Closes our write end: Chromium reads EOF on its fd 3 and exits by
    /// itself. Pending calls fail now; the writes already queued go out
    /// first (one stuck on a wedged Chromium waits for the process to be
    /// killed). The reader runs on until Chromium's end closes too, then
    /// `onClose` runs.
    public func close() {
        lock.lock()
        if closedReason == nil {
            closedReason = "the connection was closed"
        }
        let reason = closedReason ?? ""
        let entries = pending.values.sorted { $0.reply.id < $1.reply.id }
        pending.removeAll()
        lock.unlock()
        for entry in entries {
            entry.timer?.cancel()
            entry.reply.resolve(.failure(.disconnected(reason)))
        }
        closeWriteEnd()
    }

    // MARK: - Pending entries

    /// From `CDPReply` when its task is cancelled.
    func abandon(_ id: Int) {
        _ = take(id)
    }

    private func take(_ id: Int) -> Pending? {
        lock.lock()
        let entry = pending.removeValue(forKey: id)
        lock.unlock()
        entry?.timer?.cancel()
        return entry
    }

    private func takeAll(where matches: (Pending) -> Bool) -> [Pending] {
        lock.lock()
        let ids = pending.compactMap { matches($0.value) ? $0.key : nil }
        var taken: [Pending] = []
        for id in ids {
            if let entry = pending.removeValue(forKey: id) {
                taken.append(entry)
            }
        }
        lock.unlock()
        for entry in taken {
            entry.timer?.cancel()
        }
        return taken.sorted { $0.reply.id < $1.reply.id }
    }

    /// On the reader queue.
    private func expire(_ id: Int) {
        guard let entry = take(id) else { return }
        entry.reply.resolve(.failure(.timeout(method: entry.reply.method)))
    }

    /// A deadline on the dispatch clock. Capped at a day so the nanoseconds
    /// fit; a past deadline fires at once.
    private static func dispatchTime(_ deadline: ContinuousClock.Instant) -> DispatchTime {
        let left = ContinuousClock.now.duration(to: deadline)
        guard left > .zero else { return DispatchTime.now() }
        let parts = left.components
        let seconds = min(parts.seconds, 86_400)
        let nanoseconds = Int(seconds) * 1_000_000_000 + Int(parts.attoseconds / 1_000_000_000)
        return DispatchTime.now() + DispatchTimeInterval.nanoseconds(nanoseconds)
    }

    // MARK: - Reader queue

    private func readAvailable() {
        guard !finished else { return }
        let descriptor = readDescriptor
        var failure: Int32 = 0
        let count = readBuffer.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            let count = readPipeEnd(descriptor, base, buffer.count)
            if count < 0 {
                failure = errno
            }
            return count
        }
        if count == 0 {
            finish("Chromium closed the pipe")
            return
        }
        if count < 0 {
            if failure == EAGAIN || failure == EINTR { return }
            finish("reading the pipe failed: \(String(cString: strerror(failure)))")
            return
        }
        for piece in framer.read(Data(readBuffer[0..<count])) {
            switch piece {
            case .frame(let frame):
                route(frame)
            case .oversized(let head, let length):
                // One answer too big (a page's 300 MB string) fails its own
                // call: the other sessions on this Chromium keep their pipe.
                log("cdp[\(label)]: a frame of \(length) bytes dropped (over \(framer.maxFrameBytes))")
                fail(replyIn: head, message: "the answer was \(length / (1 << 20)) MB, "
                        + "over the \(framer.maxFrameBytes / (1 << 20)) MB Loom reads")
            }
        }
    }

    /// A reply Loom cannot read fails its call at once (its id is in the
    /// frame's first bytes: Chromium writes `{"id":N,` first), rather than
    /// leaving it to wait out its deadline.
    private func fail(replyIn head: Data, message: String) {
        guard let id = Self.leadingID(head), let entry = take(id) else { return }
        entry.reply.resolve(.failure(.protocolError(method: entry.reply.method, code: CDPError.unreadableCode,
                                                    message: message)))
    }

    private func route(_ frame: Data) {
        let leading = Self.leadingMethod(frame)
        if let leading, let subscription = rawSubscription(leading) {
            let handler = subscription.handler
            subscription.queue.async { handler(frame) }
            return
        }
        guard let inbound = CDPInbound.parse(frame) else {
            log("cdp[\(label)]: unreadable frame of \(frame.count) bytes dropped")
            fail(replyIn: frame.prefix(CDPFramer.headBytes), message: "the answer was not readable JSON")
            return
        }
        switch inbound {
        case .result(let id, let result):
            guard let entry = take(id) else { return }   // timed out, cancelled or interrupted
            entry.reply.resolve(.success(result))
        case .failure(let id, let code, let message):
            guard let entry = take(id) else { return }
            entry.reply.resolve(.failure(.protocolError(method: entry.reply.method, code: code,
                                                        message: message)))
        case .event(let method, let params, let session):
            // A subscribed method Chromium did not write first still goes raw.
            if method != leading, let subscription = rawSubscription(method) {
                let handler = subscription.handler
                subscription.queue.async { handler(frame) }
                return
            }
            // Synchronously, lock released: the sink may post or interrupt.
            sink(for: session)?.handle(method: method, params: params, session: session)
        }
    }

    private func sink(for session: CDPSessionID?) -> (any CDPEventSink)? {
        lock.lock()
        defer { lock.unlock() }
        if let session {
            return sessionSinks[session]
        }
        return rootSink
    }

    private func rawSubscription(_ method: String) -> RawSubscription? {
        lock.lock()
        defer { lock.unlock() }
        return rawSubscriptions[method]
    }

    private static let methodLead = Array(#"{"method":""#.utf8)
    private static let idLead = Array(#"{"id":"#.utf8)

    /// The id of a frame that starts `{"id":N` (a reply), nil otherwise.
    static func leadingID(_ frame: Data) -> Int? {
        let lead = idLead
        let bytes = Array(frame.prefix(lead.count + 19))
        guard bytes.count > lead.count, Array(bytes[..<lead.count]) == lead else { return nil }
        var id = 0
        var digits = 0
        for byte in bytes[lead.count...] {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { break }
            guard digits < 15 else { return nil }
            id = id * 10 + Int(byte - UInt8(ascii: "0"))
            digits += 1
        }
        return digits > 0 ? id : nil
    }

    /// The method of a frame that starts `{"method":"X"`. Chromium writes an
    /// event's method first, so a raw subscription is matched before any parse.
    static func leadingMethod(_ frame: Data) -> String? {
        let lead = methodLead
        guard frame.count > lead.count else { return nil }
        return frame.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            for index in 0..<lead.count where raw[index] != lead[index] {
                return nil
            }
            let limit = min(raw.count, lead.count + 256)
            var end = lead.count
            while end < limit {
                let byte = raw[end]
                if byte == UInt8(ascii: "\"") {
                    return String(decoding: raw[lead.count..<end], as: UTF8.self)
                }
                if byte == UInt8(ascii: "\\") { return nil }
                end += 1
            }
            return nil
        }
    }

    /// The pipe is gone: everything pending fails, `onClose` runs once.
    private func finish(_ reason: String) {
        guard !finished else { return }
        finished = true
        readSource?.cancel()
        readSource = nil
        lock.lock()
        if closedReason == nil {
            closedReason = reason
        }
        let entries = pending.values.sorted { $0.reply.id < $1.reply.id }
        pending.removeAll()
        let notify = onClose
        onClose = nil
        // Sinks often hold the connection: letting go breaks the cycle. They
        // are released past the lock, since a sink's deinit may call back in.
        let released = (rootSink, sessionSinks, rawSubscriptions)
        rootSink = nil
        sessionSinks.removeAll()
        rawSubscriptions.removeAll()
        lock.unlock()
        for entry in entries {
            entry.timer?.cancel()
            entry.reply.resolve(.failure(.disconnected(reason)))
        }
        closeWriteEnd()
        log("cdp[\(label)]: \(reason)")
        notify?(reason)
        withExtendedLifetime(released) {}
    }

    // MARK: - Write queue

    private func transmit(_ frames: Data, ids: [Int]) {
        let failure: String
        if writeClosed {
            failure = "the connection was closed"
        } else if let code = Self.writeAll(frames, to: writeDescriptor) {
            failure = "writing the pipe failed: \(String(cString: strerror(code)))"
            writeClosed = true
            closePipeEnd(writeDescriptor)
            lock.lock()
            if closedReason == nil {
                closedReason = failure
            }
            lock.unlock()
            log("cdp[\(label)]: \(failure)")
        } else {
            return
        }
        for id in ids {
            take(id)?.reply.resolve(.failure(.disconnected(failure)))
        }
    }

    private func closeWriteEnd() {
        writeQueue.async {
            guard !self.writeClosed else { return }
            self.writeClosed = true
            closePipeEnd(self.writeDescriptor)
        }
    }

    /// nil once every byte is written, else the errno. The descriptor is
    /// blocking: a short write only means the pipe was full, and the loop
    /// goes on where it stopped.
    private static func writeAll(_ data: Data, to descriptor: Int32) -> Int32? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32? in
            guard let base = raw.baseAddress else { return nil }
            var offset = 0
            while offset < raw.count {
                let written = writePipeEnd(descriptor, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                let code = written < 0 ? errno : EIO
                if code == EINTR { continue }
                if code == EAGAIN {
                    // Someone made it non-blocking after all: wait for room.
                    var waiting = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&waiting, 1, 1_000)
                    continue
                }
                return code
            }
            return nil
        }
    }
}

// Outside the class: there, `close` would name `CDPConnection.close()`.

private func closePipeEnd(_ descriptor: Int32) {
    _ = close(descriptor)
}

private func readPipeEnd(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    read(descriptor, buffer, count)
}

private func writePipeEnd(_ descriptor: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    write(descriptor, buffer, count)
}
