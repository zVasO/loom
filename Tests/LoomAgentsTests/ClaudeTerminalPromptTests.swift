@testable import LoomAgents
import Testing

@Suite("ClaudeTerminalPrompt — a choice read off claude's screen")
struct ClaudeTerminalPromptTests {
    private let boxed = [
        "⏺ I'll push the branch.",
        "",
        "╭──────────────────────────────────────────────────────────╮",
        "│ Bash command                                             │",
        "│                                                          │",
        "│   git push origin main                                   │",
        "│   Push the branch to the remote                          │",
        "│                                                          │",
        "│ Do you want to proceed?                                  │",
        "│ ❯ 1. Yes                                                 │",
        "│   2. Yes, and don't ask again for git push commands in   │",
        "│   /Users/ada/loom                                        │",
        "│   3. No, and tell Claude what to do differently (esc)    │",
        "╰──────────────────────────────────────────────────────────╯",
        "",
    ]

    @Test("a boxed permission: its question, its context, three options, the marked one")
    func boxedPermission() throws {
        let prompt = try #require(ClaudeTerminalPrompt.parse(lines: boxed))
        #expect(prompt.question == "Do you want to proceed?")
        #expect(prompt.context == ["Bash command", "git push origin main", "Push the branch to the remote"])
        #expect(prompt.options.map(\.number) == [1, 2, 3])
        #expect(prompt.options[0].label == "Yes")
        #expect(prompt.options[1].label == "Yes, and don't ask again for git push commands in /Users/ada/loom")
        #expect(prompt.selected == 1)
        #expect(ClaudeTerminalPrompt.answer(prompt.options[2]) == "3")
    }

    @Test("the borderless dialog, with a hint under it")
    func borderless() throws {
        let screen = [
            "────────────────────────────────────────",
            " Edit file",
            " Sources/App.swift",
            "",
            " Do you want to make this edit to App.swift?",
            "   1. Yes",
            " ❯ 2. Yes, allow all edits during this session (shift+tab)",
            "   3. No, and tell Claude what to do differently (esc)",
            "",
            " Esc to cancel · Tab to amend",
        ]
        let prompt = try #require(ClaudeTerminalPrompt.parse(lines: screen))
        #expect(prompt.question == "Do you want to make this edit to App.swift?")
        #expect(prompt.context == ["Edit file", "Sources/App.swift"])
        #expect(prompt.options.count == 3)
        #expect(prompt.selected == 2)
    }

    @Test("a numbered list in an answer, under the input box, is no prompt")
    func listInAnswer() {
        let screen = [
            "⏺ Three steps:",
            "  1. Read the file",
            "  2. Change it",
            "",
            "╭────────────────────────────╮",
            "│ >                          │",
            "╰────────────────────────────╯",
            "  ? for shortcuts",
        ]
        #expect(ClaudeTerminalPrompt.parse(lines: screen) == nil)
    }

    @Test("options without the marker, or not numbered from 1, are no prompt")
    func strict() {
        #expect(ClaudeTerminalPrompt.parse(lines: ["Proceed?", "  1. Yes", "  2. No"]) == nil)
        #expect(ClaudeTerminalPrompt.parse(lines: ["Proceed?", "❯ 2. Yes", "  3. No"]) == nil)
        #expect(ClaudeTerminalPrompt.parse(lines: ["❯ 1. Yes", "  2. No"]) == nil)
    }

    @Test("a narrow terminal: the last option wraps onto a line of its own, and the dialog still reads")
    func wrappedLastOption() throws {
        let screen = [
            " Bash command",
            "",
            "   docker exec -it web sh",
            "",
            " Do you want to proceed?",
            " ❯ 1. Yes",
            "   2. Yes, and don't ask again for docker exec",
            "   commands in /Users/ada/loom",
            "   3. No, and tell Claude what to do",
            "   differently",
            "",
        ]
        let prompt = try #require(ClaudeTerminalPrompt.parse(lines: screen))
        #expect(prompt.options.count == 3)
        #expect(prompt.options[2].label == "No, and tell Claude what to do differently")
        #expect(prompt.context == ["Bash command", "docker exec -it web sh"])
    }

    @Test("a question with options and its navigation hints")
    func question() throws {
        let screen = [
            " Which database should the tests use?",
            "",
            " ❯ 1. SQLite",
            "      In memory, fastest",
            "   2. Postgres",
            "      What production runs",
            "   3. Type something.",
            "",
            " Enter to select · ↑/↓ to navigate · Esc to cancel",
        ]
        let prompt = try #require(ClaudeTerminalPrompt.parse(lines: screen))
        #expect(prompt.question == "Which database should the tests use?")
        #expect(prompt.options.map(\.number) == [1, 2, 3])
        #expect(prompt.options[0].label == "SQLite In memory, fastest")
    }
}
