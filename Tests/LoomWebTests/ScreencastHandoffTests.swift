import Testing
import Foundation
import LoomChromium
@testable import LoomWeb

// The agent's page moves between the side panel and the stack's Agent tab:
// the view leaving must not stop the frames of the view that took the tab.
@Suite("Screencast — one tab, two views in turn")
struct ScreencastHandoffTests {

    private func connection() throws -> (CDPConnection, [Int32]) {
        var toChromium: [Int32] = [0, 0]
        var fromChromium: [Int32] = [0, 0]
        guard pipe(&toChromium) == 0, pipe(&fromChromium) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let connection = CDPConnection(read: fromChromium[0], write: toChromium[1], label: "handoff-test")
        return (connection, [toChromium[0], fromChromium[1]])
    }

    @Test("the view that let go of a tab another view took does not stop its screencast")
    func handoff() throws {
        let (connection, ends) = try connection()
        defer {
            connection.close()
            ends.forEach { close($0) }
        }
        let session = CDPSessionID("tab-1")
        let panel = ScreencastStream(label: "panel")
        let tab = ScreencastStream(label: "tab")
        let router = ScreencastRouter.shared
        router.register(panel, connection: connection, session: session)
        router.register(tab, connection: connection, session: session)
        #expect(!router.unregister(panel, connection: connection, session: session),
                "the tab's view shows it now: its frames keep coming")
        #expect(router.unregister(tab, connection: connection, session: session),
                "the last view: the screencast may stop")
        #expect(router.unregister(tab, connection: connection, session: session), "nothing registered: free")
    }
}
