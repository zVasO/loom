import CryptoKit
import Foundation
import WebKit

/// Where the agent's browser keeps its cookies and storage (ADR-0014): never
/// the user's store (WEB-02 is the user's browser). One persistent store per
/// project, so a login to the app under test survives from one session to
/// the next; a private, forgotten store for a session without a project and
/// for every review — code under review is not trusted with a profile.
public enum AgentBrowserProfile {

    public enum Kind: Equatable, Sendable {
        /// The project's own store, under this identifier.
        case project(UUID)
        case `private`
    }

    public static func kind(projectID: UUID?, isReview: Bool) -> Kind {
        guard !isReview, let projectID else { return .private }
        return .project(storeIdentifier(forProject: projectID))
    }

    /// Deterministic, distinct per project, never the project's own UUID (a
    /// future user profile keyed by it must not collide): a name-based UUID.
    public static func storeIdentifier(forProject project: UUID) -> UUID {
        let name = "app.loom.agent-browser/" + project.uuidString.lowercased()
        var bytes = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5 (name-based)
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    @MainActor
    public static func dataStore(for kind: Kind) -> WKWebsiteDataStore {
        switch kind {
        case .project(let identifier): return WKWebsiteDataStore(forIdentifier: identifier)
        case .private: return .nonPersistent()
        }
    }

    /// Cleared from a project's store the first time an app run uses it:
    /// what a page could leave behind to intercept the NEXT session's pages
    /// (a service worker, cached responses). Logins — cookies, local storage,
    /// IndexedDB — stay.
    public static let clearedOnFirstUse: Set<String> = [
        WKWebsiteDataTypeServiceWorkerRegistrations,
        WKWebsiteDataTypeFetchCache,
        WKWebsiteDataTypeDiskCache,
        WKWebsiteDataTypeMemoryCache,
        WKWebsiteDataTypeOfflineWebApplicationCache,
    ]

    @MainActor
    public static func clearCaches(of store: WKWebsiteDataStore) async {
        await store.removeData(ofTypes: clearedOnFirstUse, modifiedSince: .distantPast)
    }

    /// Everything the agent's browser kept for a project — "Clear agent
    /// browser data" in Settings. The live store is emptied in place.
    @MainActor
    public static func clearAll(of store: WKWebsiteDataStore) async {
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    /// Every agent profile on disk emptied — removed projects' included. Only
    /// the agent's browser uses identifier stores in Loom; none is created.
    @MainActor
    public static func clearAllProjectStores() async {
        for identifier in await existingStoreIdentifiers() {
            await clearAll(of: WKWebsiteDataStore(forIdentifier: identifier))
        }
    }

    @MainActor
    static func existingStoreIdentifiers() async -> [UUID] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.fetchAllDataStoreIdentifiers { identifiers in
                continuation.resume(returning: identifiers)
            }
        }
    }

    /// Every project store that exists on disk among these projects', emptied
    /// — never creating one that does not.
    @MainActor
    public static func clearProjectStores(_ projects: [UUID]) async {
        let wanted = Set(projects.map(storeIdentifier(forProject:)))
        for identifier in await existingStoreIdentifiers() where wanted.contains(identifier) {
            await clearAll(of: WKWebsiteDataStore(forIdentifier: identifier))
        }
    }
}
