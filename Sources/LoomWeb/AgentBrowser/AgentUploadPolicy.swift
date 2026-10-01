import Foundation

/// Which files the agent may hand a page's file chooser (pure, tested). An
/// upload to a remote page is a way out of the machine, so the roots are
/// narrow: the session's working tree, and a folder of Loom's the agent
/// copies files into on purpose — never the shared temporary directory,
/// never a directory (a `webkitdirectory` input would take a whole tree).
public struct AgentUploadPolicy: Equatable, Sendable {
    public let roots: [URL]

    public init(roots: [URL]) {
        self.roots = roots.map { $0.resolvingSymlinksInPath().standardizedFileURL }
    }

    public enum Refusal: Error, Equatable {
        case missing(String)
        case directory(String)
        case outside(String)
        case tooMany
    }

    /// The files, resolved — symlinks followed, so a link inside a root to a
    /// file outside it is refused — or why not.
    public func validate(_ paths: [String], allowsMultiple: Bool,
                         exists: (URL) -> (exists: Bool, isDirectory: Bool) = AgentUploadPolicy.probe)
        -> Result<[URL], Refusal> {
        if paths.count > 1, !allowsMultiple { return .failure(.tooMany) }
        var accepted: [URL] = []
        for path in paths {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            // Outside first: whether a file exists elsewhere is none of the page's business.
            let inside = roots.contains { root in
                let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
                return url.path.hasPrefix(base)
            }
            guard inside else { return .failure(.outside(path)) }
            let status = exists(url)
            guard status.exists else { return .failure(.missing(path)) }
            guard !status.isDirectory else { return .failure(.directory(path)) }
            accepted.append(url)
        }
        return .success(accepted)
    }

    public static func probe(_ url: URL) -> (exists: Bool, isDirectory: Bool) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return (exists, isDirectory.boolValue)
    }

    public static func message(for refusal: Refusal, roots: [URL]) -> String {
        switch refusal {
        case .missing(let path): return "no file at \(path)"
        case .directory(let path): return "\(path) is a folder: pass files"
        case .tooMany: return "this file input takes one file"
        case .outside(let path):
            return "\(path) is outside what the agent may upload — copy it into "
                + roots.map(\.path).joined(separator: " or ") + " first"
        }
    }
}
