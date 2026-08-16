import Testing
import LoomWeb
import Foundation

// WEB-05 : au plus N webviews vivantes, LRU ; les onglets au-delà sont suspendus
// (URL conservée) — la continuité de connexion vient du data store partagé, pas
// de la webview. Logique pure, testée sans WebKit.

@Suite("BrowserTabsModel — hygiène mémoire LRU")
struct BrowserTabsModelTests {

    @Test("au plus N onglets vivants : le moins récemment utilisé est suspendu")
    func plafondDOngletsVivants() throws {
        var model = BrowserTabsModel(maxLiveTabs: 2)
        let a = model.openTab(url: URL(string: "https://github.com")!)
        let b = model.openTab(url: URL(string: "https://docs.swift.org")!)
        let c = model.openTab(url: URL(string: "https://developer.apple.com")!)

        #expect(model.tabs.count == 3, "les trois onglets existent")
        #expect(model.liveTabIDs.count == 2, "mais seuls deux sont vivants")
        #expect(!model.isLive(a), "le premier ouvert, jamais revisité, est suspendu")
        #expect(model.isLive(b) && model.isLive(c))
        #expect(model.tab(a)?.url == URL(string: "https://github.com")!,
                "l'URL de l'onglet suspendu est conservée pour le rechargement")
    }

    @Test("activer un onglet suspendu le ressuscite et suspend le LRU")
    func reactivationLRU() throws {
        var model = BrowserTabsModel(maxLiveTabs: 2)
        let a = model.openTab(url: URL(string: "https://a.example")!)
        let b = model.openTab(url: URL(string: "https://b.example")!)
        let c = model.openTab(url: URL(string: "https://c.example")!)   // a suspendu

        model.activate(a)

        #expect(model.isLive(a), "réactivé : l'onglet revit")
        #expect(!model.isLive(b), "b devient le moins récemment utilisé, suspendu à son tour")
        #expect(model.isLive(c))
        #expect(model.activeTab == a)
    }

    @Test("fermer un onglet libère sa place sans toucher aux autres")
    func fermeture() throws {
        var model = BrowserTabsModel(maxLiveTabs: 2)
        let a = model.openTab(url: URL(string: "https://a.example")!)
        let b = model.openTab(url: URL(string: "https://b.example")!)
        _ = b
        model.close(a)

        #expect(model.tabs.count == 1)
        #expect(model.activeTab != a)
    }
}
