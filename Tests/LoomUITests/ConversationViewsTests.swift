import Testing
@testable import LoomUI

// Seam: the chat view's pure decisions — which icon a tool call gets, when
// the list still follows the end of the conversation, how wide a user's
// bubble may be. The views themselves are not rendered here.
@Suite("ConversationLayout — the chat view's arithmetic")
struct ConversationLayoutTests {

    @Test("a tool gets the icon of its family, a wrench when it has none")
    func toolIcons() {
        #expect(ConversationLayout.toolIcon(for: "Bash") == "terminal")
        #expect(ConversationLayout.toolIcon(for: "Read") == "doc.text")
        #expect(ConversationLayout.toolIcon(for: "Edit") == "pencil")
        #expect(ConversationLayout.toolIcon(for: "Write") == "pencil")
        #expect(ConversationLayout.toolIcon(for: "Grep") == "magnifyingglass")
        #expect(ConversationLayout.toolIcon(for: "Glob") == "magnifyingglass")
        #expect(ConversationLayout.toolIcon(for: "Task") == "person.2")
        #expect(ConversationLayout.toolIcon(for: "Agent") == "person.2")
        #expect(ConversationLayout.toolIcon(for: "WebFetch") == "globe")
        #expect(ConversationLayout.toolIcon(for: "WebSearch") == "globe")
        #expect(ConversationLayout.toolIcon(for: "mcp__loom__browser_open") == "wrench")
    }

    @Test("the list follows while the end is within a line or two of the viewport")
    func followsNearTheEnd() {
        #expect(ConversationLayout.isAtBottom(contentEnd: 600, viewportHeight: 600))
        #expect(ConversationLayout.isAtBottom(contentEnd: 320, viewportHeight: 600),
                "a conversation shorter than the pane is at its end")
        #expect(ConversationLayout.isAtBottom(contentEnd: 640, viewportHeight: 600))
        #expect(!ConversationLayout.isAtBottom(contentEnd: 700, viewportHeight: 600),
                "a reader who scrolled up is left where they are")
    }

    @Test("a bubble takes four fifths of the column, and the column stops at 760")
    func bubbleWidths() {
        #expect(ConversationLayout.bubbleWidth(viewportWidth: 540, margin: 20) == 400)
        #expect(ConversationLayout.bubbleWidth(viewportWidth: 2000, margin: 20) == 608)
        #expect(ConversationLayout.bubbleWidth(viewportWidth: 10, margin: 20) == 0)
    }
}
