@testable import LoomUI
import Testing

@Suite("ShellHighlighter — a command in colours")
struct ShellHighlighterTests {
    private func kinds(_ source: String) -> [(String, ShellHighlighter.Kind)] {
        ShellHighlighter.tokens(source).filter { $0.kind != .plain || !$0.text.allSatisfy(\.isWhitespace) }
            .map { ($0.text, $0.kind) }
    }

    @Test("docker exec: the command, its subcommand, flags, then arguments")
    func dockerExec() {
        let found = kinds(#"docker exec -it web sh -c "ls $HOME""#)
        #expect(found.map(\.0) == ["docker", "exec", "-it", "web", "sh", "-c", #""ls $HOME""#])
        #expect(found.map(\.1) == [.command, .subcommand, .flag, .plain, .plain, .flag, .string])
    }

    @Test("a pipeline: each command after | or && is a command")
    func pipeline() {
        let found = kinds("git log --oneline | head -5 && echo $? > out.txt")
        #expect(found.map(\.1) == [.command, .subcommand, .flag, .op, .command, .flag, .op,
                                   .command, .variable, .op, .plain])
    }

    @Test("prefixes and assignments come before the command; nested subcommands")
    func prefixes() {
        let found = kinds("FOO=1 sudo docker compose up -d # start")
        #expect(found.map(\.1) == [.variable, .command, .command, .subcommand, .subcommand, .flag, .comment])
    }

    @Test("a flag's value is not the flag")
    func flagValue() {
        let found = kinds("swift test --filter=ShellHighlighterTests")
        #expect(found.map(\.0) == ["swift", "test", "--filter", "=ShellHighlighterTests"])
        #expect(found.map(\.1) == [.command, .subcommand, .flag, .plain])
    }

    @Test("the text is kept whole")
    func lossless() {
        let source = "cd ~/loom && FOO=\"a b\" ./run.sh 2>&1 | tee log # done\nls -la"
        #expect(ShellHighlighter.tokens(source).map(\.text).joined() == source)
    }
}
