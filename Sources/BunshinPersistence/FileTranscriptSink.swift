import BunshinCore
import BunshinTerminal
import Dispatch
import Foundation

/// Puits de transcript de production (DAT-01) : flux brut + version dé-ANSI-isée
/// pour la recherche, rotation par taille, batch d'écriture (250 ms par défaut).
/// `append` est appelé sur la queue de session et rend la main immédiatement ;
/// les écritures partent sur une queue disque dédiée. Ne lève jamais après init :
/// une panne d'écriture dégrade, elle ne tue pas la session (NFR-R).
public final class FileTranscriptSink: TranscriptSink, @unchecked Sendable {

    private let directory: URL
    private let rotateAt: Int
    private let queue = DispatchQueue(label: "app.bunshin.transcript")
    private let flushTimer: DispatchSourceTimer

    // Confinés à `queue`.
    private var buffers: [TerminalID: Data] = [:]
    private var rawHandles: [TerminalID: FileHandle] = [:]
    private var plainHandles: [TerminalID: FileHandle] = [:]
    private var writtenInCurrentFile: [TerminalID: Int] = [:]
    private var fileIndex: [TerminalID: Int] = [:]

    public init(directory: URL, rotateAt: Int = 10_000_000,
                flushInterval: Duration = .milliseconds(250)) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        self.rotateAt = rotateAt
        flushTimer = DispatchSource.makeTimerSource(queue: queue)
        let interval = Double(flushInterval.components.seconds)
            + Double(flushInterval.components.attoseconds) / 1e18
        flushTimer.schedule(deadline: .now() + interval, repeating: interval)
        flushTimer.setEventHandler { [weak self] in self?.flushAll() }
        flushTimer.activate()
    }

    deinit {
        flushTimer.cancel()
    }

    public func append(_ bytes: ArraySlice<UInt8>, terminal: TerminalID) {
        let copy = Data(bytes)
        queue.async { self.buffers[terminal, default: Data()].append(copy) }
    }

    public func finish(terminal: TerminalID) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.flush(terminal: terminal)
                try? self.rawHandles.removeValue(forKey: terminal)?.close()
                try? self.plainHandles.removeValue(forKey: terminal)?.close()
                continuation.resume()
            }
        }
    }

    // MARK: - Sur la queue disque

    private func flushAll() {
        for terminal in buffers.keys { flush(terminal: terminal) }
    }

    private func flush(terminal: TerminalID) {
        guard var pending = buffers[terminal], !pending.isEmpty else { return }
        buffers[terminal] = Data()
        while !pending.isEmpty {
            let remaining = rotateAt - (writtenInCurrentFile[terminal] ?? rotateAt)
            if remaining <= 0 {
                rotate(terminal: terminal)
                continue
            }
            let chunk = pending.prefix(remaining)
            pending.removeFirst(chunk.count)
            write(chunk, terminal: terminal)
        }
    }

    private func rotate(terminal: TerminalID) {
        try? rawHandles.removeValue(forKey: terminal)?.close()
        try? plainHandles.removeValue(forKey: terminal)?.close()
        writtenInCurrentFile[terminal] = 0
    }

    private func write(_ data: Data, terminal: TerminalID) {
        if rawHandles[terminal] == nil { openFiles(terminal: terminal) }
        guard let raw = rawHandles[terminal], let plain = plainHandles[terminal] else { return }
        try? raw.write(contentsOf: data)
        let stripped = Self.strippingANSI(data)
        if !stripped.isEmpty { try? plain.write(contentsOf: stripped) }
        writtenInCurrentFile[terminal, default: 0] += data.count
    }

    private func openFiles(terminal: TerminalID) {
        let index = (fileIndex[terminal] ?? 0) + 1
        fileIndex[terminal] = index
        writtenInCurrentFile[terminal] = 0
        let base = "terminal-\(terminal.rawValue)-\(index)"
        for (suffix, keyPath) in [("raw", \FileTranscriptSink.rawHandles),
                                  ("txt", \FileTranscriptSink.plainHandles)] {
            let url = directory.appendingPathComponent("\(base).\(suffix)")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            self[keyPath: keyPath][terminal] = try? FileHandle(forWritingTo: url)
        }
    }

    /// Retire CSI (`ESC [ … lettre`), OSC (`ESC ] … BEL|ST`), les autres échappements
    /// courts et le retour chariot — ne garde que le texte pour la FTS (DAT-01).
    static func strippingANSI(_ data: Data) -> Data {
        var output = Data(capacity: data.count)
        var index = data.startIndex
        while index < data.endIndex {
            let byte = data[index]
            if byte == 0x1B {
                index = data.index(after: index)
                guard index < data.endIndex else { break }
                switch data[index] {
                case UInt8(ascii: "["):
                    index = data.index(after: index)
                    while index < data.endIndex, !(0x40...0x7E).contains(data[index]) {
                        index = data.index(after: index)
                    }
                    if index < data.endIndex { index = data.index(after: index) }
                case UInt8(ascii: "]"):
                    index = data.index(after: index)
                    while index < data.endIndex, data[index] != 0x07, data[index] != 0x1B {
                        index = data.index(after: index)
                    }
                    if index < data.endIndex, data[index] == 0x07 {
                        index = data.index(after: index)
                    } else if index < data.endIndex {
                        index = data.index(after: index)   // ESC
                        if index < data.endIndex, data[index] == UInt8(ascii: "\\") {
                            index = data.index(after: index)
                        }
                    }
                default:
                    index = data.index(after: index)   // échappement court (ESC x)
                }
                continue
            }
            if byte == 0x0D {   // CR : le LF suffit à la version texte
                index = data.index(after: index)
                continue
            }
            output.append(byte)
            index = data.index(after: index)
        }
        return output
    }
}
