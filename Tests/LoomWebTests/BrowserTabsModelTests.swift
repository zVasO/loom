import Testing
import LoomWeb
import Foundation

// WEB-05: at most N live webviews, LRU; tabs beyond that are suspended
// (URL kept) — connection continuity comes from the shared data store, not
// from the webview. Pure logic, tested without WebKit.

@Suite("BrowserTabsModel — LRU memory hygiene")
struct BrowserTabsModelTests {

    @Test("at most N live tabs: the least recently used is suspended")
    func plafondDOngletsVivants() throws {
        var model = BrowserTabsModel(maxLiveTabs: 2)
        let a = model.openTab(url: URL(string: "https://github.com")!)
        let b = model.openTab(url: URL(string: "https://docs.swift.org")!)
        let c = model.openTab(url: URL(string: "https://developer.apple.com")!)

        #expect(model.tabs.count == 3, "all three tabs exist")
        #expect(model.liveTabIDs.count == 2, "but only two are live")
        #expect(!model.isLive(a), "the first one opened, never revisited, is suspended")
        #expect(model.isLive(b) && model.isLive(c))
        #expect(model.tab(a)?.url == URL(string: "https://github.com")!,
                "the suspended tab's URL is kept for reloading")
    }

    @Test("activating a suspended tab resurrects it and suspends the LRU")
    func reactivationLRU() throws {
        var model = BrowserTabsModel(maxLiveTabs: 2)
        let a = model.openTab(url: URL(string: "https://a.example")!)
        let b = model.openTab(url: URL(string: "https://b.example")!)
        let c = model.openTab(url: URL(string: "https://c.example")!)   // a suspended

        model.activate(a)

        #expect(model.isLive(a), "reactivated: the tab lives again")
        #expect(!model.isLive(b), "b becomes the least recently used, suspended in turn")
        #expect(model.isLive(c))
        #expect(model.activeTab == a)
    }

    @Test("closing a tab frees its slot without touching the others")
    func fermeture() throws {
        var model = BrowserTabsModel(maxLiveTabs: 2)
        let a = model.openTab(url: URL(string: "https://a.example")!)
        let b = model.openTab(url: URL(string: "https://b.example")!)
        _ = b
        model.close(a)

        #expect(model.tabs.count == 1)
        #expect(model.activeTab != a)
    }

    @Test("closing every tab at once revives none on the way")
    func fermetureDeTous() {
        var model = BrowserTabsModel(maxLiveTabs: 2)
        for name in ["a", "b", "c", "d"] { model.openTab(url: URL(string: "https://\(name).example")!) }
        model.closeAll()
        #expect(model.tabs.isEmpty)
        #expect(model.liveTabIDs.isEmpty)
        #expect(model.activeTab == nil)
    }
}

/// WEB-06: the address bar accepts WORDS — a search engine (Google) takes
/// over when the input is not an address.
@Suite("Address or search")
struct AdresseOuRechercheTests {

    @Test("a full URL passes through as-is")
    func urlComplete() {
        #expect(BrowserController.normalize("https://github.com/pulls")?.absoluteString
                == "https://github.com/pulls")
    }

    @Test("a bare domain becomes https")
    func domaineNu() {
        #expect(BrowserController.normalize("github.com/pulls")?.absoluteString
                == "https://github.com/pulls")
    }

    @Test("words become a Google search")
    func motsVersRecherche() {
        #expect(BrowserController.normalize("claude code hooks")?.absoluteString
                == "https://www.google.com/search?q=claude%20code%20hooks")
    }

    @Test("a single word without a dot is also a search")
    func motSeul() {
        #expect(BrowserController.normalize("swiftterm")?.absoluteString
                == "https://www.google.com/search?q=swiftterm")
    }

    @Test("localhost remains an address — in http, where dev servers listen")
    func localhost() {
        #expect(BrowserController.normalize("localhost:5173")?.absoluteString
                == "http://localhost:5173")
    }

    @Test("every loopback host is http; an explicit https stays; a lookalike is a search")
    func boucleLocaleEnHttp() {
        #expect(BrowserController.normalize("127.0.0.1:8000/api")?.absoluteString == "http://127.0.0.1:8000/api")
        #expect(BrowserController.normalize("[::1]:5173")?.absoluteString == "http://[::1]:5173")
        #expect(BrowserController.normalize("app.localhost:3000")?.absoluteString == "http://app.localhost:3000")
        #expect(BrowserController.normalize("0.0.0.0:3000")?.absoluteString == "http://0.0.0.0:3000")
        #expect(BrowserController.normalize("https://localhost:8443")?.absoluteString == "https://localhost:8443")
        #expect(BrowserController.normalize("localhostfoo")?.absoluteString
                == "https://www.google.com/search?q=localhostfoo")
        #expect(BrowserController.normalize("about:blank")?.absoluteString == "about:blank")
    }
}
