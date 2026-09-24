import Foundation
import LoomAPI

/// An extension's own key-value store: one JSON file, outside the extension's
/// folder so an update never wipes it and a linked source folder stays clean.
/// Capped, because a page could otherwise fill the disk one `set` at a time.
public final class ExtensionStorage: @unchecked Sendable {
    public let file: URL
    public let limitBytes: Int
    public static let maxKeyLength = 256

    private let lock = NSLock()
    private var values: [String: JSONValue]?

    public init(file: URL, limitBytes: Int = 1 << 20) {
        self.file = file
        self.limitBytes = limitBytes
    }

    public func value(for key: String) throws -> JSONValue? {
        try Self.validate(key)
        return lock.withLock { loaded()[key] }
    }

    /// `nil` or `null` deletes the key.
    public func set(_ value: JSONValue?, for key: String) throws {
        try Self.validate(key)
        try lock.withLock {
            var next = loaded()
            if let value, value != .null {
                next[key] = value
            } else {
                next.removeValue(forKey: key)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(next)
            guard data.count <= limitBytes else {
                throw BridgeError(.tooLarge, "the extension's storage would be over \(limitBytes) bytes")
            }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            values = next
        }
    }

    public var keys: [String] {
        lock.withLock { loaded().keys.sorted() }
    }

    private func loaded() -> [String: JSONValue] {
        if let values { return values }
        let read = FileManager.default.contents(atPath: file.path)
            .flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) } ?? [:]
        values = read
        return read
    }

    static func validate(_ key: String) throws {
        guard !key.isEmpty, key.count <= maxKeyLength else {
            throw BridgeError(.invalidParams, "a storage key is 1 to \(maxKeyLength) characters")
        }
    }
}
