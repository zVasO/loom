import BunshinCore
import BunshinTerminal
import Dispatch
import Foundation

// Adapters de test au seam PTY (docs/design/session-runtime.md §Tests) :
// aucun process réel, l'ordre des événements est piloté par le test.

public final class ScriptedPTYHost: PTYHost, @unchecked Sendable {
    public init() {}

    private let lock = NSLock()
    private var sink: (@Sendable (PTYEvent) -> Void)?
    private var queue: DispatchQueue?
    public struct SignalDelivery: Equatable {
        public let signal: PTYSignal
        public let scope: PTYSignalScope
        public init(signal: PTYSignal, scope: PTYSignalScope) {
            self.signal = signal
            self.scope = scope
        }
    }

    public private(set) var writtenBytes: [UInt8] = []
    public private(set) var receivedSignals: [SignalDelivery] = []
    public private(set) var openedEnvironment: [String: String] = [:]
    public private(set) var closeCount = 0

    fileprivate func recordClose() {
        lock.lock()
        closeCount += 1
        lock.unlock()
    }

    fileprivate func releaseSink() {
        lock.lock()
        sink = nil
        lock.unlock()
    }

    public func open(command: Command,
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

    /// Réaction scriptée aux signaux (« l'agent sort sur SIGINT », « ignore tout sauf SIGKILL »…).
    public var onSignal: (@Sendable (PTYSignal, ScriptedPTYHost) -> Void)?

    // Pilotage par le test : chaque événement part sur la queue de session, comme en prod.
    // `exit` livre terminated puis EOF (l'ordre courant) ; pour l'ordre adverse, composer
    // avec les primitives brutes deliverTerminated/emit/emitEOF.
    public func emit(_ text: String) { deliver(.bytes(Array(text.utf8))) }
    public func emitEOF() { deliver(.endOfFile) }
    public func exit(code: Int32) {
        deliver(.terminated(ExitStatus(code: code)))
        deliver(.endOfFile)
    }
    public func exit(bySignal signal: Int32) {
        deliver(.terminated(ExitStatus(code: nil, signal: signal)))
        deliver(.endOfFile)
    }
    public func deliverTerminated(code: Int32) { deliver(.terminated(ExitStatus(code: code))) }

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

    fileprivate func record(signal: PTYSignal, scope: PTYSignalScope) {
        lock.lock()
        receivedSignals.append(SignalDelivery(signal: signal, scope: scope))
        let handler = onSignal
        lock.unlock()
        handler?(signal, self)
    }
}

private final class ScriptedChannel: PTYChannel, @unchecked Sendable {
    private weak var host: ScriptedPTYHost?
    init(host: ScriptedPTYHost) { self.host = host }
    func write(_ bytes: ArraySlice<UInt8>) { host?.record(write: bytes) }
    public func resize(to geometry: TerminalGeometry) {}
    func signal(_ signal: PTYSignal, scope: PTYSignalScope) { host?.record(signal: signal, scope: scope) }
    func close() {
        host?.releaseSink()
        host?.recordClose()
    }
    var capabilities: PTYCapabilities { [.signals, .cpuSampling] }
    var processGroup: pid_t? { 4242 }
    func cpuFraction() -> Double { 0 }
}

/// Moteur de test : buffer de lignes en clair, pas d'ANSI hors CR/LF. Rend les
/// assertions d'écran lisibles sans dépendre du parseur d'un tiers.
public final class LineEngine: TerminalEngine {
    private let geometry: TerminalGeometry
    private var text = ""
    private var revision: UInt64 = 0

    public init(geometry: TerminalGeometry) { self.geometry = geometry }

    public func feed(_ bytes: ArraySlice<UInt8>) {
        text += String(decoding: bytes, as: UTF8.self)
        revision += 1
    }

    public func snapshot() -> TerminalScreen {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in TerminalLine(cells: line.map { TerminalCell(character: $0) }) }
        return TerminalScreen(geometry: geometry,
                              lines: lines,
                              cursor: CursorPosition(col: 0, row: max(0, lines.count - 1)),
                              revision: revision)
    }

    public func resize(to geometry: TerminalGeometry) {}
    public func takeDirtyRows() -> IndexSet { IndexSet() }
    public func setScrollback(_ lines: Int) {}
}

public final class MemoryTranscriptSink: TranscriptSink, @unchecked Sendable {
    public init() {}

    private let lock = NSLock()
    private var bytes: [UInt8] = []
    public private(set) var isFinished = false
    /// Vrai si un append est arrivé APRÈS finish() — violation de la barrière de drainage.
    public private(set) var appendedAfterFinish = false

    public var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }

    public func append(_ bytes: ArraySlice<UInt8>, terminal: TerminalID) {
        lock.lock()
        if isFinished { appendedAfterFinish = true }
        self.bytes.append(contentsOf: bytes)
        lock.unlock()
    }

    public func finish(terminal: TerminalID) async {
        lock.withLock { isFinished = true }
    }
}
