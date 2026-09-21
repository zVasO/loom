import LoomAPI
import Foundation

/// Where the socket is and which token to speak with — from the flags, then
/// the environment Loom gives its agents, then Loom's support directory.
public struct Connection: Equatable, Sendable {
    public var socketPath: String
    public var token: String

    public init(socketPath: String, token: String) {
        self.socketPath = socketPath
        self.token = token
    }

    public enum ResolutionError: Error, Equatable, CustomStringConvertible {
        case noSocket
        case noToken
        case globalTokenUnreadable(String)

        public var description: String {
            switch self {
            case .noSocket:
                return "no socket: run inside a Loom session (LOOM_SOCKET) or pass --socket <path>"
            case .noToken:
                return "no token: run inside a Loom session (LOOM_SESSION_TOKEN), pass --token <token>, or --global"
            case .globalTokenUnreadable(let path):
                return "the global token could not be read at \(path) — has Loom been launched once?"
            }
        }
    }

    /// Loom's support directory: `LOOM_SUPPORT_DIR` (tests) or the standard one.
    public static func supportDirectory(environment: [String: String]) -> URL {
        if let injected = environment["LOOM_SUPPORT_DIR"], !injected.isEmpty {
            return URL(fileURLWithPath: injected)
        }
        let home = environment["HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/Loom")
    }

    /// `--socket`, `--token` and `--global` win over the environment; the
    /// global token is read from `api-token` beside Loom's database.
    public static func resolve(socket: String?, token: String?, global: Bool,
                               environment: [String: String],
                               readFile: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }) throws -> Connection {
        let support = supportDirectory(environment: environment)
        let socketPath = socket
            ?? environment[APIProtocol.socketEnvironmentKey].flatMap { $0.isEmpty ? nil : $0 }
            ?? (FileManager.default.fileExists(atPath: support.appendingPathComponent("loom.sock").path)
                ? support.appendingPathComponent("loom.sock").path : nil)
        guard let socketPath else { throw ResolutionError.noSocket }

        if let token { return Connection(socketPath: socketPath, token: token) }
        if global {
            let url = support.appendingPathComponent("api-token")
            let read = readFile(url)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !read.isEmpty else { throw ResolutionError.globalTokenUnreadable(url.path) }
            return Connection(socketPath: socketPath, token: read)
        }
        if let own = environment[APIProtocol.sessionTokenEnvironmentKey], !own.isEmpty {
            return Connection(socketPath: socketPath, token: own)
        }
        throw ResolutionError.noToken
    }

    public var client: APIClient { APIClient(socketPath: socketPath, token: token) }
}
