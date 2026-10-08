import CryptoKit
import Foundation
import LoomCore

/// The `chrome-headless-shell` Loom downloads on a click (ADR-0016, NFR-S:
/// nothing is fetched unless the person asks). Pinned to this version of
/// Loom: the size and SHA-256 below, compiled into the notarized app, are
/// the trust root — the archive is never updated on its own.
public struct ChromiumDownloadPin: Sendable, Equatable {
    /// Chrome for Testing's version: the one Playwright 1.56 drives, which
    /// the CDP harness and the CI's end-to-end tests run against.
    public static let version = "141.0.7390.37"

    public let version: String
    /// Chrome for Testing's platform name: `mac-arm64` or `mac-x64`.
    public let platform: String
    public let url: URL
    /// Lowercase hex.
    public let sha256: String
    public let sizeBytes: Int64

    public init(version: String, platform: String, url: URL, sha256: String, sizeBytes: Int64) {
        self.version = version
        self.platform = platform
        self.url = url
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
    }

    /// The folder the archive unpacks to — the layout `ChromiumLocator`
    /// looks for under the download directory.
    public var folderName: String { "chrome-headless-shell-\(platform)" }

    public var executableRelativePath: String { folderName + "/chrome-headless-shell" }

    /// The build this Mac runs natively.
    public static func current(for architecture: ChromiumLocator.Architecture = .current) -> ChromiumDownloadPin {
        switch architecture {
        case .arm64:
            return pin(platform: "mac-arm64", sha256: "54e85f6626aacac3c2d04077dffbab6f52ed393b5c29994fad85d99c04b38860",
                       sizeBytes: 93_605_553)
        case .x86_64:
            return pin(platform: "mac-x64", sha256: "5bf32c2321a9562a74508b113437f990eb2fd61216248bbc8b6af818f2c7e622",
                       sizeBytes: 97_835_209)
        }
    }

    private static func pin(platform: String, sha256: String, sizeBytes: Int64) -> ChromiumDownloadPin {
        let address = "https://storage.googleapis.com/chrome-for-testing-public/\(version)/\(platform)/"
            + "chrome-headless-shell-\(platform).zip"
        // A constant address: it always parses.
        return ChromiumDownloadPin(version: version, platform: platform, url: URL(string: address)!,
                                   sha256: sha256, sizeBytes: sizeBytes)
    }

    /// "94 MB", for the button.
    public var sizeDescription: String {
        "\(Int((Double(sizeBytes) / 1_000_000).rounded())) MB"
    }
}

/// What Loom installed, next to it: `installed.json`.
public struct ChromiumInstallRecord: Codable, Sendable, Equatable {
    public static let fileName = "installed.json"

    public var version: String
    public var platform: String
    public var sha256: String
    public var installedAt: Date
    /// What the code signature check said, for the Settings.
    public var signature: String?

    public init(version: String, platform: String, sha256: String, installedAt: Date, signature: String?) {
        self.version = version
        self.platform = platform
        self.sha256 = sha256
        self.installedAt = installedAt
        self.signature = signature
    }

    /// Nil when there is none or it cannot be read.
    public static func read(from directory: URL) -> ChromiumInstallRecord? {
        let file = directory.appendingPathComponent(fileName, isDirectory: false)
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ChromiumInstallRecord.self, from: data)
    }

    public func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: directory.appendingPathComponent(Self.fileName, isDirectory: false), options: .atomic)
    }
}

public enum ChromiumInstallError: Error, Equatable, Sendable {
    case network(String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch(expected: String, actual: String)
    case unpack(String)
    /// The archive did not hold the executable where it should.
    case layout(String)
    case cancelled
    /// Remove while an agent's Chromium runs.
    case inUse
    case disk(String)

    /// For the Settings, in the person's words.
    public var message: String {
        switch self {
        case .network(let reason):
            return "The download failed: \(reason)"
        case .sizeMismatch, .checksumMismatch:
            return "The download didn't match Loom's checksum — nothing was installed."
        case .unpack(let reason):
            return "The download could not be unpacked: \(reason)"
        case .layout(let reason):
            return "The download is not the expected chrome-headless-shell: \(reason)"
        case .cancelled:
            return "Download cancelled."
        case .inUse:
            return "An agent's browser is using it: close the sessions using Chromium first."
        case .disk(let reason):
            return "It could not be written to disk: \(reason)"
        }
    }
}

/// The steps between a downloaded archive and a binary the locator finds,
/// each testable on its own. Off the main thread: hashing 95 MB takes a
/// moment.
public enum ChromiumInstaller {

    /// Lowercase hex SHA-256, read in chunks.
    public static func sha256(of file: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The archive is the pinned one, byte for byte.
    public static func verify(_ archive: URL, pin: ChromiumDownloadPin) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard size == pin.sizeBytes else {
            throw ChromiumInstallError.sizeMismatch(expected: pin.sizeBytes, actual: size)
        }
        let digest = try sha256(of: archive)
        guard digest == pin.sha256.lowercased() else {
            throw ChromiumInstallError.checksumMismatch(expected: pin.sha256, actual: digest)
        }
    }

    /// `ditto -x -k`: the archive into an empty folder, executable bits and
    /// symlinks kept (Foundation has no unzip).
    public static func unpack(_ archive: URL, into folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, folder.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let (status, errors): (Int32, String) = try await withCheckedThrowingContinuation { continuation in
            do {
                try ProcessDrain.launch(process, stdout: stdout, stderr: stderr) { status, _, err in
                    continuation.resume(returning: (status, String(decoding: err, as: UTF8.self)))
                }
            } catch {
                continuation.resume(throwing: ChromiumInstallError.unpack(String(describing: error)))
            }
        }
        guard status == 0 else {
            let reason = errors.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ChromiumInstallError.unpack(reason.isEmpty ? "ditto exited with \(status)" : reason)
        }
    }

    /// Moves the unpacked build from `staging` to its place under `root` (the
    /// download directory), replacing what was there, and records it. Returns
    /// the executable.
    @discardableResult
    public static func place(staging: URL, root: URL, pin: ChromiumDownloadPin,
                             signature: String?, now: Date = Date()) throws -> URL {
        let fileManager = FileManager.default
        let unpacked = staging.appendingPathComponent(pin.folderName, isDirectory: true)
        let executable = unpacked.appendingPathComponent("chrome-headless-shell", isDirectory: false)
        guard ChromiumLocator.isExecutableFile(executable.path) else {
            throw ChromiumInstallError.layout("no executable \(pin.executableRelativePath) in the archive")
        }
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let destination = root.appendingPathComponent(pin.folderName, isDirectory: true)
            if fileManager.fileExists(atPath: destination.path) {
                // Aside first, so a failed move leaves the old build whole.
                let aside = root.appendingPathComponent(".old-\(UUID().uuidString)", isDirectory: true)
                try fileManager.moveItem(at: destination, to: aside)
                do {
                    try fileManager.moveItem(at: unpacked, to: destination)
                } catch {
                    try? fileManager.moveItem(at: aside, to: destination)
                    throw error
                }
                try? fileManager.removeItem(at: aside)
            } else {
                try fileManager.moveItem(at: unpacked, to: destination)
            }
            try ChromiumInstallRecord(version: pin.version, platform: pin.platform, sha256: pin.sha256,
                                      installedAt: now, signature: signature).write(to: root)
            var folder = root
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
            return destination.appendingPathComponent("chrome-headless-shell", isDirectory: false)
        } catch let error as ChromiumInstallError {
            throw error
        } catch {
            throw ChromiumInstallError.disk(error.localizedDescription)
        }
    }

    /// What Loom installed under `root`, if its executable is still there.
    public static func installed(root: URL) -> (record: ChromiumInstallRecord, executable: URL)? {
        guard let record = ChromiumInstallRecord.read(from: root) else { return nil }
        let executable = root
            .appendingPathComponent("chrome-headless-shell-\(record.platform)", isDirectory: true)
            .appendingPathComponent("chrome-headless-shell", isDirectory: false)
        guard ChromiumLocator.isExecutableFile(executable.path) else { return nil }
        return (record, executable)
    }

    /// Everything Loom downloaded: the builds, the record, leftovers of an
    /// interrupted install. Profiles live elsewhere and stay.
    public static func remove(root: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else { return }
        let names = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where name.hasPrefix("chrome-headless-shell-") || name.hasPrefix(".old-")
            || name.hasPrefix(".staging-") || name.hasPrefix(".download-") || name == ChromiumInstallRecord.fileName {
            do {
                try fileManager.removeItem(at: root.appendingPathComponent(name))
            } catch {
                throw ChromiumInstallError.disk(error.localizedDescription)
            }
        }
    }

    /// Leftovers of an install that did not finish (Loom quit mid-way).
    public static func sweepLeftovers(root: URL) {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where name.hasPrefix(".old-") || name.hasPrefix(".staging-") || name.hasPrefix(".download-") {
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
        }
    }
}
