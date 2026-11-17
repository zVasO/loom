import SwiftUI

/// Colours for a shell command — `docker exec -it web sh -c "ls $HOME"` —
/// in the theme's own colours, so a command reads the same under every
/// theme as the rest of the app. A small tokenizer, not a shell: it knows
/// where a command starts (the line's start, after `|`, `&&`, `||`, `;`),
/// the CLIs whose second word is a subcommand, and what flags, strings,
/// variables, operators and comments look like.
public enum ShellHighlighter {
    public enum Kind: Equatable, Sendable {
        case command, subcommand, flag, string, variable, op, comment, plain
    }

    public struct Token: Equatable, Sendable {
        public let text: String
        public let kind: Kind
    }

    /// The CLIs whose next bare word is a subcommand: `git commit`,
    /// `docker exec`, `kubectl get`.
    static let withSubcommands: Set<String> = [
        "git", "docker", "podman", "docker-compose", "kubectl", "helm", "npm", "npx", "yarn", "pnpm",
        "bun", "deno", "swift", "cargo", "go", "gh", "brew", "pip", "pip3", "uv", "poetry", "systemctl",
        "launchctl", "terraform", "aws", "gcloud", "az", "xcrun", "apt", "apt-get", "dnf", "yum", "bundle",
        "rails", "mix", "dotnet", "flutter", "composer", "php", "rustup", "conda", "kubectx", "minikube",
        "colima", "tmux", "loom", "claude", "pod", "fastlane", "heroku", "vercel", "firebase", "supabase",
    ]
    /// Subcommands that take one more: `docker compose up`, `gh pr view`.
    static let nested: Set<String> = [
        "compose", "container", "image", "network", "volume", "system", "pr", "issue", "repo", "run",
        "workflow", "config", "remote", "stash", "submodule", "worktree", "package", "secret",
    ]
    /// Words that run the command after them: the command is the next word.
    static let prefixes: Set<String> = ["sudo", "env", "time", "nohup", "nice", "xargs", "command", "exec", "watch"]

    public static func tokens(_ source: String) -> [Token] {
        let characters = Array(source)
        var tokens: [Token] = []
        var index = 0
        var commandStart = true
        var expectsSub = false
        var subDepth = 0

        func emit(_ kind: Kind, _ from: Int, _ to: Int) {
            guard to > from else { return }
            tokens.append(Token(text: String(characters[from..<to]), kind: kind))
        }

        while index < characters.count {
            let character = characters[index]
            // Blanks, and a line break: a new command.
            if character == " " || character == "\t" || character == "\n" || character == "\\" {
                let start = index
                while index < characters.count,
                      characters[index] == " " || characters[index] == "\t" || characters[index] == "\n"
                        || characters[index] == "\\" {
                    if characters[index] == "\n", start == index || characters[index - 1] != "\\" {
                        commandStart = true
                        expectsSub = false
                    }
                    index += 1
                }
                emit(.plain, start, index)
                continue
            }
            if character == "#", index == 0 || characters[index - 1] == " " || characters[index - 1] == "\n" {
                let start = index
                while index < characters.count, characters[index] != "\n" { index += 1 }
                emit(.comment, start, index)
                continue
            }
            if character == "\"" || character == "'" {
                let start = index
                index += 1
                while index < characters.count, characters[index] != character {
                    if character == "\"", characters[index] == "\\" { index += 1 }
                    index += 1
                }
                index = min(index + 1, characters.count)
                // `FOO="a b" cmd`: the value of an assignment, the command still to come.
                let assigning = tokens.last.map { $0.kind == .variable && $0.text.hasSuffix("=") } ?? false
                emit(.string, start, index)
                if !assigning { commandStart = false }
                continue
            }
            if character == "$" {
                let start = index
                index += 1
                if index < characters.count, characters[index] == "(" {
                    index += 1
                    emit(.op, start, index)
                    commandStart = true
                    expectsSub = false
                    continue
                }
                if index < characters.count, characters[index] == "{" {
                    while index < characters.count, characters[index] != "}" { index += 1 }
                    index = min(index + 1, characters.count)
                } else if index < characters.count, "?#@*!$-0123456789".contains(characters[index]) {
                    index += 1
                } else {
                    while index < characters.count,
                          characters[index].isLetter || characters[index].isNumber || characters[index] == "_" {
                        index += 1
                    }
                }
                emit(.variable, start, index)
                continue
            }
            if "|&;<>()".contains(character) {
                let start = index
                index += 1
                while index < characters.count, "|&<>".contains(characters[index]) { index += 1 }
                let op = String(characters[start..<index])
                emit(.op, start, index)
                // A redirection's target is a path; the rest start a command.
                if !op.contains("<"), !op.contains(">") {
                    commandStart = true
                    expectsSub = false
                }
                continue
            }
            // A word: up to a blank or an operator.
            let start = index
            while index < characters.count, !" \t\n|&;<>()\"'".contains(characters[index]) {
                if characters[index] == "$" { break }
                index += 1
            }
            if index == start {
                index += 1
                emit(.plain, start, index)
                continue
            }
            let word = String(characters[start..<index])
            if commandStart {
                if let equals = word.firstIndex(of: "="), equals != word.startIndex,
                   word[..<equals].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                    // `FOO=bar cmd`: an assignment, the command comes after.
                    emit(.variable, start, index)
                    continue
                }
                emit(.command, start, index)
                let name = (word as NSString).lastPathComponent
                if prefixes.contains(name) { continue }
                commandStart = false
                expectsSub = withSubcommands.contains(name)
                subDepth = 0
                continue
            }
            if word.hasPrefix("-"), word.count > 1 {
                if let equals = word.firstIndex(of: "=") {
                    let split = start + word.distance(from: word.startIndex, to: equals)
                    emit(.flag, start, split)
                    emit(.plain, split, index)
                } else {
                    emit(.flag, start, index)
                }
                continue
            }
            if expectsSub, word.first?.isLetter == true {
                emit(.subcommand, start, index)
                subDepth += 1
                expectsSub = subDepth < 2 && nested.contains(word)
                continue
            }
            expectsSub = false
            emit(.plain, start, index)
        }
        return tokens
    }

    /// The command in the theme's colours, for a `Text`.
    @MainActor
    public static func attributed(_ source: String) -> AttributedString {
        var result = AttributedString()
        for token in tokens(source) {
            var piece = AttributedString(token.text)
            piece.foregroundColor = color(token.kind)
            result += piece
        }
        return result
    }

    @MainActor
    static func color(_ kind: Kind) -> Color {
        switch kind {
        case .command: DefaultTheme.accentInk
        case .subcommand: DefaultTheme.branch
        case .flag: DefaultTheme.badgeColor(for: .idle)
        case .string: DefaultTheme.badgeColor(for: .working)
        case .variable: DefaultTheme.badgeColor(for: .needsInput)
        case .op: DefaultTheme.secondaryText
        case .comment: DefaultTheme.mutedText
        case .plain: DefaultTheme.primaryText
        }
    }

    /// The fence languages that are a shell.
    public static func isShell(_ language: String) -> Bool {
        ["bash", "sh", "shell", "zsh", "console", "terminal", "shell-session", "fish", "ksh"]
            .contains(language.lowercased())
    }
}
