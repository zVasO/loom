import Testing
import LoomCore
import LoomPersistence
import LoomTerminal
import Foundation

// Seam: the TranscriptSink protocol + the actual file contents on disk (DAT-01).

@Suite("FileTranscriptSink — transcripts on disk")
struct FileTranscriptSinkTests {

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-transcripts-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("the raw stream is complete on disk after finish (DAT-01, NFR-R)")
    func fluxBrutIntegral() async throws {
        let dir = makeDirectory()
        let sink = try FileTranscriptSink(directory: dir)
        sink.append(ArraySlice("first batch ".utf8), terminal: .primary)
        sink.append(ArraySlice("second batch".utf8), terminal: .primary)
        await sink.finish(terminal: .primary)

        let raw = try String(contentsOf: dir.appendingPathComponent("terminal-0-1.raw"), encoding: .utf8)
        #expect(raw == "first batch second batch", "every byte received is on disk, in order")
    }

    @Test("the cleaned version has no ANSI sequences left: ready for search")
    func versionNettoyee() async throws {
        let dir = makeDirectory()
        let sink = try FileTranscriptSink(directory: dir)
        sink.append(ArraySlice("\u{1B}[32mgreen\u{1B}[0m and \u{1B}]0;title\u{07}normal\r\n".utf8),
                    terminal: .primary)
        await sink.finish(terminal: .primary)

        let plain = try String(contentsOf: dir.appendingPathComponent("terminal-0-1.txt"), encoding: .utf8)
        #expect(plain == "green and normal\n", "colors, OSC and CR stripped; only the text remains")
    }

    @Test("rotation: past the threshold, a new file takes over (DAT-01)")
    func rotationParTaille() async throws {
        let dir = makeDirectory()
        let sink = try FileTranscriptSink(directory: dir, rotateAt: 16)
        sink.append(ArraySlice("0123456789ABCDEF".utf8), terminal: .primary)   // fills file 1
        sink.append(ArraySlice("next".utf8), terminal: .primary)               // must open file 2
        await sink.finish(terminal: .primary)

        let first = try String(contentsOf: dir.appendingPathComponent("terminal-0-1.raw"), encoding: .utf8)
        let second = try String(contentsOf: dir.appendingPathComponent("terminal-0-2.raw"), encoding: .utf8)
        #expect(first == "0123456789ABCDEF")
        #expect(second == "next", "nothing is lost at rotation")
    }
}
