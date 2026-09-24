import Testing
import LoomExtensions
import LoomAPI
import Foundation

// Seam: an extension's own storage (a JSON file, real disk) and its secrets
// (the Keychain behind a protocol). The Keychain itself is only touched when
// LOOM_KEYCHAIN_TESTS=1 — it can prompt, and CI has no one to click.

@Suite("Extensions — storage")
struct ExtensionStorageTests {

    private func file() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-storage-\(UUID().uuidString)/storage.json")
    }

    @Test("a value survives a new instance; null deletes it")
    func persistance() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let storage = ExtensionStorage(file: url)
        try storage.set(.object(["board": .number(12)]), for: "config")
        #expect(try ExtensionStorage(file: url).value(for: "config") == .object(["board": .number(12)]))
        try storage.set(.null, for: "config")
        #expect(try ExtensionStorage(file: url).value(for: "config") == nil)
    }

    @Test("the cap refuses a write and keeps what was there")
    func plafond() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let storage = ExtensionStorage(file: url, limitBytes: 64)
        try storage.set(.string("small"), for: "a")
        #expect(throws: BridgeError.self) {
            try storage.set(.string(String(repeating: "x", count: 100)), for: "b")
        }
        #expect(try storage.value(for: "a") == .string("small"))
        #expect(try storage.value(for: "b") == nil)
    }

    @Test("an empty key is refused")
    func cleVide() {
        #expect(throws: BridgeError.self) { try ExtensionStorage(file: file()).value(for: "") }
    }
}

@Suite("Extensions — secrets")
struct SecretStoreTests {

    @Test("secrets are kept per extension, and removal takes them all")
    func parExtension() throws {
        let store = InMemorySecretStore()
        try store.setSecret("t1", "token", for: "dev.example.a")
        try store.setSecret("t2", "token", for: "dev.example.b")
        #expect(try store.secret("token", for: "dev.example.a") == "t1")
        try store.setSecret("t1b", "token", for: "dev.example.a")
        #expect(try store.secret("token", for: "dev.example.a") == "t1b")
        try store.deleteAll(for: "dev.example.a")
        #expect(try store.secret("token", for: "dev.example.a") == nil)
        #expect(try store.secret("token", for: "dev.example.b") == "t2")
    }

    @Test("a key is short and plain; a value is capped")
    func politique() {
        #expect(throws: BridgeError.self) { try SecretPolicy.validate(key: "") }
        #expect(throws: BridgeError.self) { try SecretPolicy.validate(key: "a/b") }
        #expect(throws: Never.self) { try SecretPolicy.validate(key: "jira.api-token_1") }
        #expect(throws: BridgeError.self) {
            try SecretPolicy.validate(value: String(repeating: "x", count: SecretPolicy.maxValueBytes + 1))
        }
    }

    @Test("the Keychain stores, replaces and deletes (LOOM_KEYCHAIN_TESTS=1)",
          .enabled(if: ProcessInfo.processInfo.environment["LOOM_KEYCHAIN_TESTS"] == "1"))
    func trousseau() throws {
        let store = KeychainSecretStore()
        let id = "dev.loom.tests-\(UUID().uuidString.prefix(8).lowercased())"
        defer { try? store.deleteAll(for: id) }
        try store.setSecret("first", "token", for: id)
        try store.setSecret("second", "token", for: id)
        try store.setSecret("other", "email", for: id)
        #expect(try store.secret("token", for: id) == "second")
        try store.deleteSecret("token", for: id)
        #expect(try store.secret("token", for: id) == nil)
        try store.deleteAll(for: id)
        #expect(try store.secret("email", for: id) == nil)
    }
}
