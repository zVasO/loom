import Foundation

/// Hygiène mémoire du navigateur (WEB-05) : au plus `maxLiveTabs` webviews vivantes,
/// éviction LRU. Un onglet suspendu garde son URL — la continuité de connexion est
/// garantie par le `WKWebsiteDataStore` partagé, pas par la webview. Logique pure,
/// sans WebKit : la couche vue crée/détruit les webviews selon `liveTabIDs`.
public struct BrowserTabsModel: Sendable, Equatable {

    public struct TabID: Hashable, Sendable {
        let rawValue: UUID
    }

    public struct Tab: Sendable, Equatable {
        public let id: TabID
        public var url: URL
        public var title: String
    }

    public let maxLiveTabs: Int
    public private(set) var tabs: [Tab] = []
    public private(set) var activeTab: TabID?
    /// Du moins récemment utilisé au plus récent — les `maxLiveTabs` derniers vivent.
    private var usageOrder: [TabID] = []

    public init(maxLiveTabs: Int = 4) {
        self.maxLiveTabs = maxLiveTabs
    }

    public var liveTabIDs: Set<TabID> {
        Set(usageOrder.suffix(maxLiveTabs))
    }

    public func isLive(_ id: TabID) -> Bool {
        liveTabIDs.contains(id)
    }

    public func tab(_ id: TabID) -> Tab? {
        tabs.first { $0.id == id }
    }

    @discardableResult
    public mutating func openTab(url: URL) -> TabID {
        let tab = Tab(id: TabID(rawValue: UUID()), url: url, title: url.host() ?? url.absoluteString)
        tabs.append(tab)
        touch(tab.id)
        activeTab = tab.id
        return tab.id
    }

    public mutating func activate(_ id: TabID) {
        guard tab(id) != nil else { return }
        touch(id)
        activeTab = id
    }

    public mutating func close(_ id: TabID) {
        tabs.removeAll { $0.id == id }
        usageOrder.removeAll { $0 == id }
        if activeTab == id { activeTab = usageOrder.last }
    }

    public mutating func update(_ id: TabID, url: URL? = nil, title: String? = nil) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if let url { tabs[index].url = url }
        if let title { tabs[index].title = title }
    }

    private mutating func touch(_ id: TabID) {
        usageOrder.removeAll { $0 == id }
        usageOrder.append(id)
    }
}
