import Testing
import BunshinCore
import BunshinPersistence
import BunshinTerminal
import Foundation

// Seam : le protocole TranscriptSink + le contenu réel des fichiers sur disque (DAT-01).

@Suite("FileTranscriptSink — transcripts sur disque")
struct FileTranscriptSinkTests {

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bunshin-transcripts-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("le flux brut est intégral sur disque après finish (DAT-01, NFR-R)")
    func fluxBrutIntegral() async throws {
        let dir = makeDirectory()
        let sink = try FileTranscriptSink(directory: dir)
        sink.append(ArraySlice("premier lot ".utf8), terminal: .primary)
        sink.append(ArraySlice("second lot".utf8), terminal: .primary)
        await sink.finish(terminal: .primary)

        let raw = try String(contentsOf: dir.appendingPathComponent("terminal-0-1.raw"), encoding: .utf8)
        #expect(raw == "premier lot second lot", "chaque octet reçu est sur disque, dans l'ordre")
    }

    @Test("la version nettoyée n'a plus de séquences ANSI : prête pour la recherche")
    func versionNettoyee() async throws {
        let dir = makeDirectory()
        let sink = try FileTranscriptSink(directory: dir)
        sink.append(ArraySlice("\u{1B}[32mvert\u{1B}[0m et \u{1B}]0;titre\u{07}normal\r\n".utf8),
                    terminal: .primary)
        await sink.finish(terminal: .primary)

        let plain = try String(contentsOf: dir.appendingPathComponent("terminal-0-1.txt"), encoding: .utf8)
        #expect(plain == "vert et normal\n", "couleurs, OSC et CR retirés ; le texte seul reste")
    }

    @Test("rotation : au-delà du seuil, un nouveau fichier prend la suite (DAT-01)")
    func rotationParTaille() async throws {
        let dir = makeDirectory()
        let sink = try FileTranscriptSink(directory: dir, rotateAt: 16)
        sink.append(ArraySlice("0123456789ABCDEF".utf8), terminal: .primary)   // remplit le fichier 1
        sink.append(ArraySlice("suite".utf8), terminal: .primary)              // doit ouvrir le 2
        await sink.finish(terminal: .primary)

        let first = try String(contentsOf: dir.appendingPathComponent("terminal-0-1.raw"), encoding: .utf8)
        let second = try String(contentsOf: dir.appendingPathComponent("terminal-0-2.raw"), encoding: .utf8)
        #expect(first == "0123456789ABCDEF")
        #expect(second == "suite", "rien n'est perdu à la rotation")
    }
}
