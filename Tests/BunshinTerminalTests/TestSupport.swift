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

    /// Réaction scriptée aux signaux (« l'agent sort sur SIGINT », « ignore tout sauf SIGKILL »…).
    var onSignal: (@Sendable (PTYSignal, ScriptedPTYHost) -> Void)?

    // Pilotage par le test : chaque événement part sur la queue de session, comme en prod.
    func emit(_ text: String) { deliver(.bytes(Array(text.utf8))) }
    func emitEOF() { deliver(.endOfFile) }
    func exit(code: Int32) { deliver(.terminated(ExitStatus(code: code))) }
    func exit(bySignal signal: Int32) { deliver(.terminated(ExitStatus(code: nil, signal: signal))) }

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
        let handler = onSignal
        lock.unlock()
        handler?(signal, self)
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

/// Moteur de test : buffer de lignes en clair, pas d'ANSI hors CR/LF. Rend les
/// assertions d'écran lisibles sans dépendre du parseur d'un tiers.
final class LineEngine: TerminalEngine {
    private let geometry: TerminalGeometry
    private var text = ""
    private var revision: UInt64 = 0

    init(geometry: TerminalGeometry) { self.geometry = geometry }

    func feed(_ bytes: ArraySlice<UInt8>) {
        text += String(decoding: bytes, as: UTF8.self)
        revision += 1
    }

    func snapshot() -> TerminalScreen {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in TerminalLine(cells: line.map { TerminalCell(character: $0) }) }
        return TerminalScreen(geometry: geometry,
                              lines: lines,
                              cursor: CursorPosition(col: 0, row: max(0, lines.count - 1)),
                              revision: revision)
    }

    func resize(cols: Int, rows: Int) {}
    func takeDirtyRows() -> IndexSet { IndexSet() }
    func setScrollback(_ lines: Int) {}
    var title: String { "" }
    var delegate: TerminalEngineDelegate?
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
