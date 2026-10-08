import Testing
@testable import LoomChromium
import Foundation

// The search order on a disk made of the executables it holds: directories
// are what their paths imply. No real /Applications is ever read.

private struct LocatorDisk {
    var executables: Set<String>

    func locator(home: String = "/Users/ada",
                 architecture: ChromiumLocator.Architecture = .arm64) -> ChromiumLocator {
        let executables = self.executables
        return ChromiumLocator(
            homeDirectory: URL(fileURLWithPath: home, isDirectory: true),
            architecture: architecture,
            fileExists: { executables.contains($0) },
            directoryContents: { directory in
                let prefix = directory.hasSuffix("/") ? directory : directory + "/"
                var names = Set<String>()
                for path in executables where path.hasPrefix(prefix) {
                    if let first = path.dropFirst(prefix.count).split(separator: "/").first {
                        names.insert(String(first))
                    }
                }
                return names.sorted()
            })
    }
}

private func bundleExecutable(_ name: String, in directory: String = "/Applications") -> String {
    "\(directory)/\(name).app/Contents/MacOS/\(name)"
}

@Suite("ChromiumLocator — which Chromium the agent's browser runs")
struct ChromiumLocatorTests {

    private let download = URL(fileURLWithPath: "/Users/ada/Library/Application Support/Loom/chromium",
                               isDirectory: true)
    private var downloadedShell: String {
        download.path + "/chrome-headless-shell-mac-arm64/chrome-headless-shell"
    }
    private let playwright = "/Users/ada/Library/Caches/ms-playwright"

    @Test("nothing on disk: nil, and the Settings can still say where it looked")
    func rienSurLeDisque() {
        let locator = LocatorDisk(executables: []).locator()
        #expect(locator.locate(downloadDirectory: download) == nil)
        let looked = locator.candidates(downloadDirectory: download).map(\.url.path)
        #expect(looked.contains(bundleExecutable("Google Chrome")))
        #expect(looked.contains(downloadedShell))
    }

    @Test("the person's choice comes first, even before Loom's download")
    func choixDeLaPersonne() {
        let chosen = "/opt/tools/chrome-headless-shell"
        let locator = LocatorDisk(executables: [chosen, downloadedShell, bundleExecutable("Google Chrome")]).locator()

        let found = locator.locate(userChoice: URL(fileURLWithPath: chosen, isDirectory: false),
                                   downloadDirectory: download)

        #expect(found?.url.path == chosen)
        #expect(found?.source == .userChoice)
        #expect(found?.kind == .headlessShell)
    }

    @Test("a chosen app bundle stands for its executable — Brave too, when chosen")
    func bundleChoisi() {
        let brave = bundleExecutable("Brave Browser")
        let locator = LocatorDisk(executables: [brave]).locator()

        let bundle = URL(fileURLWithPath: "/Applications/Brave Browser.app", isDirectory: true)
        let found = locator.locate(userChoice: bundle)

        #expect(found?.url.path == brave)
        #expect(found?.kind == .fullBrowser("Brave Browser"))
        #expect(found?.source == .userChoice)
    }

    @Test("a choice no longer on disk falls back to the search")
    func choixDisparu() {
        let locator = LocatorDisk(executables: [bundleExecutable("Google Chrome")]).locator()

        let found = locator.locate(userChoice: URL(fileURLWithPath: "/Volumes/Gone/Chromium", isDirectory: false))

        #expect(found?.url.path == bundleExecutable("Google Chrome"))
        #expect(found?.source == .installed)
    }

    @Test("Loom's download comes before an installed browser")
    func telechargementAvantInstalle() {
        let locator = LocatorDisk(executables: [downloadedShell, bundleExecutable("Google Chrome for Testing")])
            .locator()

        let found = locator.locate(downloadDirectory: download)

        #expect(found?.url.path == downloadedShell)
        #expect(found?.kind == .headlessShell)
        #expect(found?.source == .loomDownload)
    }

    @Test("an arm64 Mac takes the native build first, an Intel Mac never an arm64 one")
    func architectureNative() {
        let x64 = download.path + "/chrome-headless-shell-mac-x64/chrome-headless-shell"
        let both = LocatorDisk(executables: [downloadedShell, x64])
        #expect(both.locator(architecture: .arm64).locate(downloadDirectory: download)?.url.path == downloadedShell)
        #expect(both.locator(architecture: .x86_64).locate(downloadDirectory: download)?.url.path == x64)

        let armOnly = LocatorDisk(executables: [downloadedShell])
        #expect(armOnly.locator(architecture: .x86_64).locate(downloadDirectory: download) == nil)
    }

    @Test("installed browsers in order: Chrome for Testing, Chromium, Google Chrome, Edge")
    func ordreDesNavigateurs() {
        var installed = Set(ChromiumLocator.installedBrowsers.map { bundleExecutable($0) })
        for expected in ChromiumLocator.installedBrowsers {
            let found = LocatorDisk(executables: installed).locator().locate()
            #expect(found?.url.path == bundleExecutable(expected))
            #expect(found?.kind == .fullBrowser(expected))
            #expect(found?.source == .installed)
            installed.remove(bundleExecutable(expected))
        }
        #expect(ChromiumLocator.installedBrowsers == ["Google Chrome for Testing", "Chromium",
                                                      "Google Chrome", "Microsoft Edge"])
    }

    @Test("~/Applications counts like /Applications; the preferred browser wins wherever it is")
    func applicationsPersonnelles() {
        let personal = bundleExecutable("Chromium", in: "/Users/ada/Applications")
        let locator = LocatorDisk(executables: [personal, bundleExecutable("Google Chrome")]).locator()

        #expect(locator.locate()?.url.path == personal)
    }

    @Test("Brave is never picked on its own")
    func braveJamaisAuto() {
        let locator = LocatorDisk(executables: [bundleExecutable("Brave Browser"),
                                                bundleExecutable("Brave Browser", in: "/Users/ada/Applications")])
            .locator()
        #expect(locator.locate() == nil)
    }

    @Test("an installed browser comes before Playwright's cache")
    func installeAvantPlaywright() {
        let cached = playwright + "/chromium_headless_shell-1187/chrome-headless-shell-mac-arm64/chrome-headless-shell"
        let locator = LocatorDisk(executables: [cached, bundleExecutable("Microsoft Edge")]).locator()

        #expect(locator.locate()?.source == .installed)
    }

    @Test("Playwright's cache: the newest headless shell, before any full build")
    func cachePlaywright() {
        let older = playwright + "/chromium_headless_shell-1155/chrome-headless-shell-mac-arm64/chrome-headless-shell"
        let newer = playwright + "/chromium_headless_shell-1187/chrome-headless-shell-mac-arm64/chrome-headless-shell"
        let full = playwright + "/chromium-1194/chrome-mac-arm64/Chromium.app/Contents/MacOS/Chromium"
        let locator = LocatorDisk(executables: [older, newer, full]).locator()

        let found = locator.locate()

        #expect(found?.url.path == newer)
        #expect(found?.kind == .headlessShell)
        #expect(found?.source == .playwrightCache)
    }

    @Test("Playwright's full build when it has no shell, Chromium or Chrome for Testing")
    func cachePlaywrightComplet() {
        let chromium = playwright + "/chromium-1187/chrome-mac/Chromium.app/Contents/MacOS/Chromium"
        let testing = playwright
            + "/chromium-1194/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"

        let older = LocatorDisk(executables: [chromium]).locator().locate()
        #expect(older?.url.path == chromium)
        #expect(older?.kind == .fullBrowser("Chromium"))

        let newest = LocatorDisk(executables: [chromium, testing]).locator().locate()
        #expect(newest?.url.path == testing, "revision 1194 before 1187")
        #expect(newest?.kind == .fullBrowser("Google Chrome for Testing"))
    }

    @Test("a revision folder that is not a number is another layout, left alone")
    func revisionsIllisibles() {
        let names = ["chromium-1187", "chromium-tip", "chromium-1194", "chromium_headless_shell-1200", ".links"]
        #expect(ChromiumLocator.newestFirst(names, prefix: "chromium-") == ["chromium-1194", "chromium-1187"])
    }

    @Test("the kind is read from the path: the shell, an app's name, a bare binary's name")
    func genreDuBinaire() {
        #expect(ChromiumLocator.kind(ofExecutableAt: "/x/chrome-headless-shell") == .headlessShell)
        #expect(ChromiumLocator.kind(ofExecutableAt: bundleExecutable("Google Chrome"))
                == .fullBrowser("Google Chrome"))
        #expect(ChromiumLocator.kind(ofExecutableAt: "/usr/local/bin/chromium") == .fullBrowser("chromium"))
    }
}
