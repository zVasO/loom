import LoomCore
import Foundation

// Seam du transcript (local-substitutable). Adapters : FileTranscriptSink (prod, batch
// 250 ms, rotation 10 Mo, flux brut + version dé-ANSI-isée pour FTS5 — DAT-01) et
// MemoryTranscriptSink (test, avec mode défaillant pour vérifier la dégradation en notice).

public protocol TranscriptSink: Sendable {
    /// Appelé sur la queue de session, AVANT le parsing (un crash du moteur ne perd
    /// aucun octet déjà lu — NFR-R). Doit copier et rendre la main immédiatement.
    /// Ne lève jamais : une panne de transcript dégrade en notice, elle ne tue pas la session.
    func append(_ bytes: ArraySlice<UInt8>, terminal: TerminalID)
    /// Barrière : flush et fermeture. Après retour, les fichiers sont complets sur disque.
    func finish(terminal: TerminalID) async
}
