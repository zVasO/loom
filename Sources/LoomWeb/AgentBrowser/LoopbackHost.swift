import Foundation

/// The addresses that never leave the machine: where a dev server listens.
/// Shared by the address bar (http, not https, for them) and the agent's
/// browser (pure, tested).
public enum LoopbackHost {

    /// localhost, *.localhost, 127.x.x.x, ::1 (bracketed or not), 0.0.0.0.
    public static func isLoopback(_ host: String) -> Bool {
        var name = host.lowercased()
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        if name == "localhost" || name.hasSuffix(".localhost") || name == "::1" || name == "0.0.0.0" {
            return true
        }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy { UInt8($0) != nil }
    }

    /// The host of an address typed without a scheme: "localhost:5173/app" →
    /// "localhost", "[::1]:8000" → "[::1]". nil when there is none.
    public static func host(ofAddress input: String) -> String? {
        let authority = input.prefix { !"/?#".contains($0) }
        guard !authority.isEmpty else { return nil }
        let hostPort = authority.split(separator: "@").last.map(String.init) ?? String(authority)
        if hostPort.hasPrefix("[") {
            guard let end = hostPort.firstIndex(of: "]") else { return nil }
            return String(hostPort[...end])
        }
        let host = hostPort.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first
        return host.map(String.init).flatMap { $0.isEmpty ? nil : $0 }
    }
}
