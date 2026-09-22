import LoomCore
import Foundation

// Transcript seam (locally substitutable). Adapters: FileTranscriptSink (prod, 250 ms
// batching, 10 MB rotation, raw stream + de-ANSI-fied version for FTS5 — DAT-01) and
// MemoryTranscriptSink (test).

public protocol TranscriptSink: Sendable {
    /// Called on the session queue, BEFORE parsing (an engine crash loses no byte
    /// already read — NFR-R). Must copy and return immediately.
    /// Never throws: a transcript failure degrades into a notice, it does not kill the session.
    func append(_ bytes: ArraySlice<UInt8>, terminal: TerminalID)
    /// Barrier: flush and close. After returning, the files are complete on disk.
    func finish(terminal: TerminalID) async
}

/// Keeps nothing. The fallback when a session's own sink cannot be created —
/// where a shared file sink, with its flush timer, used to be built at
/// launch although per-session sinks replaced it (August P2-11).
public struct NullTranscriptSink: TranscriptSink {
    public init() {}
    public func append(_ bytes: ArraySlice<UInt8>, terminal: TerminalID) {}
    public func finish(terminal: TerminalID) async {}
}
