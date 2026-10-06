import Foundation

/// A Chromium-family binary Loom can drive (ADR-0015), and where it was found.
public struct ChromiumExecutable: Sendable, Equatable {

    public enum Kind: Sendable, Equatable {
        /// `chrome-headless-shell`: headless by construction, it takes no headless flag.
        case headlessShell
        /// A whole browser, run with `--headless=new`. The name is for the Settings.
        case fullBrowser(String)
    }

    public enum Source: Sendable, Equatable {
        /// Picked by the person in the Settings.
        case userChoice
        /// The `chrome-headless-shell` Loom downloaded on a click.
        case loomDownload
        /// A browser in /Applications or ~/Applications.
        case installed
        /// A build Playwright installed for its own use.
        case playwrightCache
    }

    public let url: URL
    public let kind: Kind
    public let source: Source

    public init(url: URL, kind: Kind, source: Source) {
        self.url = url
        self.kind = kind
        self.source = source
    }
}

/// Finds the agent browser's binary on macOS. In order: the person's choice,
/// Loom's own download, an installed browser, Playwright's cache. Pure: the
/// disk, the home directory and the architecture are injected.
///
/// Brave is never picked on its own: its shields change what pages load, so
/// the agent would test a web the person's users do not see. Chosen
/// explicitly, it runs like any other.
public struct ChromiumLocator: Sendable {

    public enum Architecture: Sendable, Equatable {
        case arm64
        case x86_64

        public static var current: Architecture {
            #if arch(arm64)
            return .arm64
            #else
            return .x86_64
            #endif
        }
    }

    /// In order of preference. Chrome for Testing neither updates itself under
    /// a running Loom nor follows a brand's policies; Edge comes last.
    public static let installedBrowsers = ["Google Chrome for Testing", "Chromium", "Google Chrome", "Microsoft Edge"]

    public var homeDirectory: URL
    public var architecture: Architecture
    /// True for an executable regular file.
    public var fileExists: @Sendable (String) -> Bool
    /// The names in a directory; empty when there is none.
    public var directoryContents: @Sendable (String) -> [String]

    public init(homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
                architecture: Architecture = .current,
                fileExists: @escaping @Sendable (String) -> Bool = { ChromiumLocator.isExecutableFile($0) },
                directoryContents: @escaping @Sendable (String) -> [String] = {
                    ChromiumLocator.contents(ofDirectory: $0)
                }) {
        self.homeDirectory = homeDirectory
        self.architecture = architecture
        self.fileExists = fileExists
        self.directoryContents = directoryContents
    }

    /// The first candidate on disk. A choice that is no longer there (the app
    /// moved) falls back to the search rather than to WebKit.
    public func locate(userChoice: URL? = nil, downloadDirectory: URL? = nil) -> ChromiumExecutable? {
        candidates(userChoice: userChoice, downloadDirectory: downloadDirectory)
            .first(where: { fileExists($0.url.path) })
    }

    /// Every place looked at, in order: what the Settings can show when nothing is found.
    public func candidates(userChoice: URL? = nil, downloadDirectory: URL? = nil) -> [ChromiumExecutable] {
        var result: [ChromiumExecutable] = []
        if let userChoice {
            result.append(Self.describe(choice: userChoice))
        }
        if let downloadDirectory {
            let root = downloadDirectory.path
            for platform in platforms {
                result.append(Self.executable(root + "/chrome-headless-shell-\(platform)/chrome-headless-shell",
                                              .headlessShell, .loomDownload))
            }
        }
        let home = homeDirectory.path
        for name in Self.installedBrowsers {
            for applications in ["/Applications", home + "/Applications"] {
                result.append(Self.executable("\(applications)/\(name).app/Contents/MacOS/\(name)",
                                              .fullBrowser(name), .installed))
            }
        }
        result += playwrightCandidates(cache: home + "/Library/Caches/ms-playwright")
        return result
    }

    /// The headless shells first, then the full builds, each newest revision first.
    private func playwrightCandidates(cache: String) -> [ChromiumExecutable] {
        let revisions = directoryContents(cache)
        var result: [ChromiumExecutable] = []
        for revision in Self.newestFirst(revisions, prefix: "chromium_headless_shell-") {
            let base = cache + "/" + revision
            for build in builds(in: base, prefix: "chrome-headless-shell-mac") {
                result.append(Self.executable("\(base)/\(build)/chrome-headless-shell",
                                              .headlessShell, .playwrightCache))
            }
        }
        for revision in Self.newestFirst(revisions, prefix: "chromium-") {
            let base = cache + "/" + revision
            for build in builds(in: base, prefix: "chrome-mac") {
                // Newer Playwright releases ship Chrome for Testing in place of Chromium.
                for name in ["Chromium", "Google Chrome for Testing"] {
                    result.append(Self.executable("\(base)/\(build)/\(name).app/Contents/MacOS/\(name)",
                                                  .fullBrowser(name), .playwrightCache))
                }
            }
        }
        return result
    }

    /// The download's platform folders this Mac runs, native first: an arm64
    /// Mac also runs x64 builds under Rosetta, an Intel Mac never arm64 ones.
    private var platforms: [String] {
        switch architecture {
        case .arm64: return ["mac-arm64", "mac-x64"]
        case .x86_64: return ["mac-x64"]
        }
    }

    /// The platform folders of one Playwright revision, ranked like `platforms`.
    private func builds(in directory: String, prefix: String) -> [String] {
        let names = directoryContents(directory).filter { $0.hasPrefix(prefix) }.sorted()
        let arm = names.filter { $0.contains("arm64") }
        let other = names.filter { !$0.contains("arm64") }
        switch architecture {
        case .arm64: return arm + other
        case .x86_64: return other
        }
    }

    /// "chromium-1187" before "chromium-1155". A suffix that is not a revision
    /// is another layout, left alone.
    static func newestFirst(_ names: [String], prefix: String) -> [String] {
        let revisions = names.compactMap { name -> (name: String, revision: Int)? in
            guard name.hasPrefix(prefix), let revision = Int(name.dropFirst(prefix.count)) else { return nil }
            return (name, revision)
        }
        return revisions.sorted { $0.revision > $1.revision }.map { $0.name }
    }

    /// An app bundle stands for its executable, named like the bundle; the
    /// shell is told apart by its file name.
    static func describe(choice: URL) -> ChromiumExecutable {
        var path = choice.path
        if path.hasSuffix(".app"), let bundle = path.split(separator: "/").last {
            let name = String(bundle.dropLast(4))
            path += "/Contents/MacOS/" + name
        }
        return executable(path, kind(ofExecutableAt: path), .userChoice)
    }

    static func kind(ofExecutableAt path: String) -> ChromiumExecutable.Kind {
        let components = path.split(separator: "/").map(String.init)
        let fileName = components.last ?? path
        if fileName == "chrome-headless-shell" || fileName == "headless_shell" {
            return .headlessShell
        }
        if let bundle = components.last(where: { $0.hasSuffix(".app") }) {
            return .fullBrowser(String(bundle.dropLast(4)))
        }
        return .fullBrowser(fileName)
    }

    /// `isDirectory: false`: the plain initializer stats the disk to decide.
    private static func executable(_ path: String, _ kind: ChromiumExecutable.Kind,
                                   _ source: ChromiumExecutable.Source) -> ChromiumExecutable {
        ChromiumExecutable(url: URL(fileURLWithPath: path, isDirectory: false), kind: kind, source: source)
    }

    public static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    public static func contents(ofDirectory path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }
}
