import BunshinCore
import BunshinTerminal
import Dispatch
import Foundation

// Adapters de test au seam PTY (docs/design/session-runtime.md §Tests) :
// aucun process réel, l'ordre des événements est piloté par le test.

final class ScriptedPTYHost: PTYHost, @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (PTYEvent) -> Void)?
    private var queue: DispatchQueue?
    private(set) var writtenBytes: [UInt8] = []
    private(set) var receivedSignals: [PTYSignal] = []
    private(set) var openedEnvironment: [String: String] = [:]

    func open(command: Command,
              workingDirectory: URL,
              environment: [String: String],
              geometry: TerminalGeometry,
              deliveringOn queue: DispatchQueue,
              sink: @escaping @Sendable (PTYEvent) -> Void) throws -> any PTYChannel {
        lock.lock()
        defer { lock.unlock() }
        self.sink = sink
        self.queue = queue
        self.openedEnvironment = environment
        return ScriptedChannel(host: self)
    }

    // Pilotage par le test : chaque événement part sur la queue de session, comme en prod.
    func emit(_ text: String) { deliver(.bytes(Array(text.utf8))) }
    func emitEOF() { deliver(.endOfFile) }
    func exit(code: Int32) { deliver(.terminated(ExitStatus(code: code))) }

    private func deliver(_ event: PTYEvent) {
        lock.lock()
        let (queue, sink) = (self.queue, self.sink)
        lock.unlock()
        queue?.async { sink?(event) }
    }

    fileprivate func record(write bytes: ArraySlice<UInt8>) {
        lock.lock()
        writtenBytes.append(contentsOf: bytes)
        lock.unlock()
    }

    fileprivate func record(signal: PTYSignal) {
        lock.lock()
        receivedSignals.append(signal)
        lock.unlock()
    }
}

private final class ScriptedChannel: PTYChannel, @unchecked Sendable {
    private weak var host: ScriptedPTYHost?
    init(host: ScriptedPTYHost) { self.host = host }
    func write(_ bytes: ArraySlice<UInt8>) { host?.record(write: bytes) }
    func resize(to geometry: TerminalGeometry) {}
    func signal(_ signal: PTYSignal) { host?.record(signal: signal) }
    func close() {}
    var capabilities: PTYCapabilities { [.signals, .cpuSampling] }
    var processGroup: pid_t? { 4242 }
    func cpuFraction() -> Double { 0 }
}

final class MemoryTranscriptSink: TranscriptSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private(set) var isFinished = false

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }

    func append(_ bytes: ArraySlice<UInt8>, terminal: TerminalID) {
        lock.lock()
        self.bytes.append(contentsOf: bytes)
        lock.unlock()
    }

    func finish(terminal: TerminalID) async {
        lock.lock()
        isFinished = true
        lock.unlock()
    }
}
