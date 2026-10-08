import Testing
@testable import LoomChromium
import LoomCore
import Darwin
import Dispatch
import Foundation

// Seam: ChromiumBrowser and ChromiumPool against a peer that plays Chromium
// on the far ends of two real pipes, in this process. It records every
// command and answers it — by default as Chromium would, or as a test says.
// No process, no network: every byte on the wire is the test's choice.

// MARK: - The router

@Suite("ChromiumBrowser — the root session and its router", .serialized, .timeLimit(.minutes(1)))
struct ChromiumBrowserTests {

    @Test("start: discovery, paused auto-attach on pages, downloads and six permissions denied, browser-wide")
    func demarrage() async throws {
        let peer = try BrowserPeer()
        defer { peer.finish() }
        let browser = peer.browser()
        try await browser.start()

        let startBurst: [String] = ["Target.setDiscoverTargets", "Target.setAutoAttach", "Browser.setDownloadBehavior"]
            + Array(repeating: "Browser.setPermission", count: 6)
        #expect(peer.methods() == startBurst)
        let discover = try #require(peer.received("Target.setDiscoverTargets").first)
        #expect(discover.params["discover"] as? Bool == true)
        #expect(filterType(discover.params) == "page")
        let attach = try #require(peer.received("Target.setAutoAttach").first)
        #expect(attach.params["autoAttach"] as? Bool == true)
        #expect(attach.params["waitForDebuggerOnStart"] as? Bool == true, "a popup never runs before its policy check")
        #expect(attach.params["flatten"] as? Bool == true)
        #expect(filterType(attach.params) == "page")
        let download = try #require(peer.received("Browser.setDownloadBehavior").first)
        #expect(download.params["behavior"] as? String == "deny")
        #expect(download.params["eventsEnabled"] as? Bool == true)
        #expect(download.params["browserContextId"] == nil)
        let permissions = peer.received("Browser.setPermission")
        #expect(permissions.compactMap(permissionName) == ["camera", "microphone", "geolocation", "notifications",
                                                            "midi", "display-capture"])
        #expect(permissions.allSatisfy { $0.params["setting"] as? String == "denied" })
        #expect(peer.received().allSatisfy { $0.session == nil }, "all on the browser session")

        await browser.shutdown(grace: .milliseconds(500))
        #expect(browser.isClosed)
        #expect(!peer.received("Browser.close").isEmpty, "a clean close first")
    }

    @Test("a permission name Chromium refuses is only logged; a refused download denial fails the start")
    func demarrageRefuse() async throws {
        let lenient = try BrowserPeer { received in
            guard received.method == "Browser.setPermission", permissionName(received) == "display-capture" else {
                return nil
            }
            return [BrowserPeer.error(received, "Invalid PermissionDescriptor name")]
        }
        defer { lenient.finish() }
        try await lenient.browser().start()

        let strict = try BrowserPeer { received in
            guard received.method == "Browser.setDownloadBehavior" else { return nil }
            return [BrowserPeer.error(received, "Browser context management is not supported.")]
        }
        defer { strict.finish() }
        do {
            try await strict.browser().start()
            Issue.record("downloads not denied, yet started")
        } catch let error as ChromiumBrowserError {
            guard case .startFailed(let method, _) = error else {
                Issue.record("\(error)")
                return
            }
            #expect(method == "Browser.setDownloadBehavior")
        }
    }

    @Test("createTarget: a window of its own, paused, joined with its attach before or after the reply")
    func creationDansLesDeuxOrdres() async throws {
        for attachFirst in [false, true] {
            let peer = try BrowserPeer { received in
                guard received.method == "Target.createTarget" else { return nil }
                let reply = BrowserPeer.reply(received, #"{"targetId":"T7"}"#)
                let attach = BrowserPeer.attached(targetId: "T7", session: "S7")
                return attachFirst ? [attach, reply] : [reply, attach]
            }
            defer { peer.finish() }
            let browser = peer.browser()
            try await browser.start()
            let owner = RecordingOwner()

            let target = try await browser.createTarget(owner: owner)
            #expect(target == ChromiumTarget(targetId: "T7", sessionId: CDPSessionID("S7"), browserContextId: nil))
            let create = try #require(peer.received("Target.createTarget").first)
            #expect(create.params["url"] as? String == "about:blank")
            #expect(create.params["newWindow"] as? Bool == true, "a background tab of a shared window stops rendering")
            #expect(create.params["browserContextId"] == nil)
            #expect(browser.targets(of: owner) == [target])
            #expect(owner.journal.isEmpty, "a target it created is returned, not announced")
            #expect(peer.received("Runtime.runIfWaitingForDebugger").isEmpty, "paused until its owner resumes it")

            browser.resume(target)
            let resumed = await eventually { peer.received("Runtime.runIfWaitingForDebugger").first?.session == "S7" }
            #expect(resumed)
            #expect(peer.closedTargets().isEmpty)
            await browser.shutdown(grace: .milliseconds(500))
        }
    }

    @Test("an attach that comes well after the reply still reaches its createTarget")
    func attacheTardive() async throws {
        let peer = try BrowserPeer { received in
            guard received.method == "Target.createTarget" else { return nil }
            return [BrowserPeer.reply(received, #"{"targetId":"T8"}"#)]
        }
        defer { peer.finish() }
        let browser = peer.browser()
        try await browser.start()
        let owner = RecordingOwner()

        async let created = browser.createTarget(owner: owner)
        let asked = await eventually { !peer.received("Target.createTarget").isEmpty }
        #expect(asked)
        try await Task.sleep(for: .milliseconds(50))
        peer.emit(BrowserPeer.attached(targetId: "T8", session: "S8"))
        let target = try await created
        #expect(target.sessionId == CDPSessionID("S8"))
        await browser.shutdown(grace: .milliseconds(500))
    }

    @Test("a target never attached: createTarget gives up, and the tab is closed")
    func jamaisAttache() async throws {
        let peer = try BrowserPeer { received in
            guard received.method == "Target.createTarget" else { return nil }
            return [BrowserPeer.reply(received, #"{"targetId":"T9"}"#)]
        }
        defer { peer.finish() }
        let browser = peer.browser()
        try await browser.start()
        let owner = RecordingOwner()

        await #expect(throws: ChromiumBrowserError.attachTimedOut(targetId: "T9")) {
            try await browser.createTarget(owner: owner, timeout: .milliseconds(200))
        }
        let closed = await eventually { peer.closedTargets() == ["T9"] }
        #expect(closed)
        #expect(browser.targets(of: owner).isEmpty)
        await browser.shutdown(grace: .milliseconds(500))
    }

    @Test("only http(s) and about:blank are opened: file:, data:, chrome:, javascript: never reach Chromium")
    func schemasRefuses() async throws {
        for url in ["about:blank", "ABOUT:BLANK", "https://example.test/", "http://localhost:3000/app",
                    "HTTPS://EXAMPLE.TEST"] {
            #expect(ChromiumBrowser.isOpenable(url), "\(url)")
        }
        for url in ["file:///etc/hosts", "data:text/html,hi", "chrome://version", "javascript:alert(1)",
                    "about:srcdoc", "about:blank#x", "blob:https://example.test/1", "ftp://example.test/",
                    "http://", "vscode:extension", ""] {
            #expect(!ChromiumBrowser.isOpenable(url), "\(url)")
        }

        let peer = try BrowserPeer()
        defer { peer.finish() }
        let browser = peer.browser()
        try await browser.start()
        let owner = RecordingOwner()
        await #expect(throws: ChromiumBrowserError.refusedURL("javascript:alert(1)")) {
            try await browser.createTarget(url: "javascript:alert(1)", owner: owner)
        }
        await #expect(throws: ChromiumBrowserError.refusedURL("file:///etc/hosts")) {
            try await browser.createTarget(url: "file:///etc/hosts", owner: owner)
        }
        #expect(peer.received("Target.createTarget").isEmpty)
        await browser.shutdown(grace: .milliseconds(500))
    }

    @Test("a popup reaches its opener's owner at once, while the opener's own call waits on it: no deadlock")
    func popupSansInterblocage() async throws {
        let pendingOpen = Box<Int?>(nil)
        let peer = try BrowserPeer { received in
            switch received.method {
            case "Runtime.evaluate":
                // window.open: the popup attaches paused, and this call waits until it runs.
                pendingOpen.set(received.id)
                return [BrowserPeer.attached(targetId: "POP", session: "SPOP", opener: "T1", url: "")]
            case "Runtime.runIfWaitingForDebugger" where received.session == "SPOP":
                var frames = [BrowserPeer.reply(received)]
                if let id = pendingOpen.get() {
                    frames.append(#"{"id":\#(id),"result":{"result":{"type":"object"}},"sessionId":"S1"}"#)
                }
                return frames
            default:
                return nil
            }
        }
        defer { peer.finish() }
        let browser = peer.browser()
        try await browser.start()
        let owner = RecordingOwner()
        // On the reader queue: the per-target init would be posted here, then the run.
        owner.whenAttached { [weak browser] popup in
            _ = browser?.resume(popup)
        }
        let opener = try await browser.createTarget(owner: owner)
        #expect(opener.targetId == "T1")

        let open = browser.connection.post("Runtime.evaluate", ["expression": "window.open('https://example.test/')"],
                                           session: opener.sessionId, options: bounded())
        _ = try await open.value()
        #expect(owner.journal == ["attached:POP:SPOP:T1"])
        let popup = try #require(browser.targets(of: owner).first(where: { $0.targetId == "POP" }))
        #expect(popup.sessionId == CDPSessionID("SPOP"))
        #expect(!peer.closedTargets().contains("POP"))
        await browser.shutdown(grace: .milliseconds(500))
    }

    @Test("a tab nobody owns is closed: an unknown opener's popup at once, the startup tab once one of ours exists")
    func ongletsSansProprietaire() async throws {
        let peer = try BrowserPeer { received in
            guard received.method == "Target.setAutoAttach" else { return nil }
            // Auto-attach reaches the tab Chromium opened at startup, already running.
            return [BrowserPeer.attached(targetId: "STARTUP", session: "S0", waiting: false),
                    BrowserPeer.reply(received)]
        }
        defer { peer.finish() }
        let browser = peer.browser()
        try await browser.start()

        peer.emit(BrowserPeer.attached(targetId: "STRAY", session: "SX", opener: "NOBODY"))
        let strayClosed = await eventually { peer.closedTargets().contains("STRAY") }
        #expect(strayClosed)
        #expect(!peer.closedTargets().contains("STARTUP"), "never the browser's last window")

        let owner = RecordingOwner()
        let ours = try await browser.createTarget(owner: owner)
        let startupClosed = await eventually { peer.closedTargets().contains("STARTUP") }
        #expect(startupClosed)
        #expect(!peer.closedTargets().contains(ours.targetId))
        #expect(owner.journal.isEmpty)
        await browser.shutdown(grace: .milliseconds(500))
    }

    @Test("target events go to their owner only: title and url, downloads by frame, a crash, a detach")
    func routage() async throws {
        let peer = try BrowserPeer { received in
            // Pending calls that only a crash or a detach will end.
            received.method == "Runtime.evaluate" ? [] : nil
        }
        defer { peer.finish() }
        let browser = peer.browser()
        try await browser.start()
        let first = RecordingOwner()
        let second = RecordingOwner()
        let a = try await browser.createTarget(owner: first)
        let b = try await browser.createTarget(owner: second)
        #expect([a.targetId, b.targetId] == ["T1", "T2"])
        first.own(frame: "FRAME-IN-T1", in: a.targetId)

        peer.emit(#"{"method":"Target.targetInfoChanged","params":{"targetInfo":{"targetId":"T1","type":"page","title":"App","url":"https://app.test/","attached":true}}}"#,
                  #"{"method":"Browser.downloadWillBegin","params":{"frameId":"T2","guid":"g1","url":"https://app.test/export.csv","suggestedFilename":"export.csv"}}"#,
                  #"{"method":"Browser.downloadWillBegin","params":{"frameId":"FRAME-IN-T1","guid":"g2","url":"https://app.test/report.pdf","suggestedFilename":"report.pdf"}}"#,
                  #"{"method":"Browser.downloadWillBegin","params":{"frameId":"UNKNOWN","guid":"g3","url":"https://app.test/x","suggestedFilename":"x"}}"#)
        let routed = await eventually { first.journal.count == 2 && second.journal.count == 1 }
        #expect(routed)
        #expect(first.journal == ["info:T1:https://app.test/:App", "download:T1:https://app.test/report.pdf"])
        #expect(second.journal == ["download:T2:https://app.test/export.csv"])

        // A crash fails the session's pending calls, then reaches its owner; the target stays.
        let onA = browser.connection.post("Runtime.evaluate", [:], session: a.sessionId, options: bounded())
        let onB = browser.connection.post("Runtime.evaluate", [:], session: b.sessionId, options: bounded())
        peer.emit(#"{"method":"Target.targetCrashed","params":{"targetId":"T1","status":"crashed","errorCode":11}}"#)
        #expect(await failure(of: onA) == CDPError.interrupted(.crashed))
        let crashed = await eventually { first.journal.last == "crashed:T1" }
        #expect(crashed)
        #expect(browser.targets(of: first) == [a], "Page.reload brings a crashed page back")

        // A detach likewise, and the target is forgotten; its later destruction says nothing more.
        peer.emit(#"{"method":"Target.detachedFromTarget","params":{"sessionId":"S2","targetId":"T2"}}"#)
        #expect(await failure(of: onB) == CDPError.interrupted(.detached))
        let detached = await eventually { second.journal.last == "detached:T2" }
        #expect(detached)
        #expect(browser.targets(of: second).isEmpty)
        peer.emit(#"{"method":"Target.targetDestroyed","params":{"targetId":"T2"}}"#)
        try await Task.sleep(for: .milliseconds(50))
        #expect(second.journal.count == 2)
        #expect(first.journal.count == 3)
        await browser.shutdown(grace: .milliseconds(500))
    }

    @Test("the browser gone: every owner hears it once, nothing more is created, a late owner hears it at once")
    func mortDuNavigateur() async throws {
        let peer = try BrowserPeer()
        defer { peer.finish() }
        let browser = peer.browser()
        try await browser.start()
        let holder = RecordingOwner()
        let watcher = RecordingOwner()
        _ = try await browser.createTarget(owner: holder)
        browser.addOwner(watcher)

        peer.hangUp()
        let reason = await browser.waitUntilClosed()
        #expect(reason.hasPrefix("Chromium stopped"))
        #expect(browser.isClosed)
        #expect(holder.journal == ["closed"])
        #expect(watcher.journal == ["closed"])
        #expect(browser.targets(of: holder).isEmpty)

        do {
            _ = try await browser.createTarget(owner: holder)
            Issue.record("a tab created on a closed browser")
        } catch let error as ChromiumBrowserError {
            guard case .closed = error else {
                Issue.record("\(error)")
                return
            }
        }
        let late = RecordingOwner()
        browser.addOwner(late)
        #expect(late.journal == ["closed"])
        #expect(holder.journal == ["closed"], "once")
    }

    @Test("a private context: disposed with the session, downloads and permissions denied in it, its tabs made in it")
    func contextePrive() async throws {
        let peer = try BrowserPeer()
        defer { peer.finish() }
        let browser = peer.browser()
        try await browser.start()

        let context = try await browser.createBrowserContext()
        #expect(context == "CTX1")
        let create = try #require(peer.received("Target.createBrowserContext").first)
        #expect(create.params["disposeOnDetach"] as? Bool == true)
        let inContext = peer.received().filter { $0.params["browserContextId"] as? String == "CTX1" }
        let contextBurst: [String] = ["Browser.setDownloadBehavior"]
            + Array(repeating: "Browser.setPermission", count: 6)
        #expect(inContext.map(\.method) == contextBurst)

        let owner = RecordingOwner()
        let target = try await browser.createTarget(browserContextId: context, owner: owner)
        #expect(target.browserContextId == "CTX1")
        #expect(peer.received("Target.createTarget").first?.params["browserContextId"] as? String == "CTX1")

        browser.disposeBrowserContext(context)
        let disposed = await eventually {
            peer.received("Target.disposeBrowserContext").first?.params["browserContextId"] as? String == "CTX1"
        }
        #expect(disposed)
        await browser.shutdown(grace: .milliseconds(500))
    }

    @Test("a context whose downloads cannot be denied is refused and disposed")
    func contexteSansRefusDesTelechargements() async throws {
        let peer = try BrowserPeer { received in
            guard received.method == "Browser.setDownloadBehavior", received.params["browserContextId"] != nil else {
                return nil
            }
            return [BrowserPeer.error(received, "no such context")]
        }
        defer { peer.finish() }
        let browser = peer.browser()
        try await browser.start()
        do {
            _ = try await browser.createBrowserContext()
            Issue.record("a context that downloads")
        } catch let error as ChromiumBrowserError {
            guard case .contextSetupFailed = error else {
                Issue.record("\(error)")
                return
            }
        }
        let disposed = await eventually { !peer.received("Target.disposeBrowserContext").isEmpty }
        #expect(disposed)
        await browser.shutdown(grace: .milliseconds(500))
    }
}

// MARK: - The pool

@Suite("ChromiumPool — one Chromium per profile, leased", .serialized, .timeLimit(.minutes(1)))
struct ChromiumPoolLeaseTests {

    @Test("concurrent first acquires share one launch; the last release starts the idle grace, then it stops")
    func lancementPartageEtInactivite() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = FakeLauncher()
        defer { launcher.finish() }
        let profiles = ChromiumProfiles(root: root)
        let pool = makePool(launcher, profiles: profiles, idle: .milliseconds(150))
        let identifier = UUID()
        let key = ChromiumProfileKey.project(identifier)

        async let first = pool.acquire(key)
        async let second = pool.acquire(key)
        let leases = try await [first, second]
        #expect(launcher.count == 1, "one launch for both")
        #expect(leases[0].browser === leases[1].browser)
        #expect(leases[0].browserContextId == nil, "a project's tabs live in its profile")
        #expect(await pool.leaseCount(key) == 2)

        let request = try #require(launcher.requests.first)
        #expect(request.userDataDirectory == profiles.profileDirectory(for: identifier))
        #expect(request.arguments.contains("--headless"))
        #expect(request.arguments.contains("--no-proxy-server"))
        #expect(request.arguments.contains("--disk-cache-dir=\(profiles.cacheDirectory(for: identifier).path)"))
        #expect(profiles.wasPrepared(identifier), "first-use clearing before the first launch")
        #expect(!launcher.peer(0).received("Target.setAutoAttach").isEmpty, "started by the pool")

        await pool.release(leases[0])
        await pool.release(leases[0])
        try await Task.sleep(for: .milliseconds(300))
        #expect(await pool.isRunning(key), "a lease is still held")
        #expect(await pool.leaseCount(key) == 1, "released twice, counted once")

        await pool.release(leases[1])
        let stopped = await eventuallyAsync { await !pool.isRunning(key) }
        #expect(stopped)
        let closed = await eventually { leases[0].browser.isClosed }
        #expect(closed)

        let again = try await pool.acquire(key)
        #expect(launcher.count == 2)
        #expect(again.browser !== leases[0].browser)
        await pool.shutdownAll(grace: .milliseconds(300))
    }

    @Test("a Chromium under the version floor is stopped, and the error says what to do")
    func versionPlancher() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = FakeLauncher()
        defer { launcher.finish() }
        launcher.setMajor(110)
        let pool = makePool(launcher, profiles: ChromiumProfiles(root: root))
        let key = ChromiumProfileKey.project(UUID())

        await #expect(throws: ChromiumPoolError.unsupportedVersion(product: "HeadlessChrome/110.0.0.0")) {
            try await pool.acquire(key)
        }
        let browser = try #require(launcher.lastBrowser)
        #expect(browser.isClosed)
        let stillRunning = await pool.isRunning(key)
        #expect(!stillRunning)
        #expect(ChromiumPoolError.unsupportedVersion(product: "Chrome/110").description.contains("120 or newer"))
        await pool.shutdownAll(grace: .milliseconds(300))
    }

    @Test("a profile held by a stale Chromium: one sweep, one retry; failing twice is reported")
    func profilOccupe() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = FakeLauncher()
        defer { launcher.finish() }
        let pool = makePool(launcher, profiles: ChromiumProfiles(root: root))
        let inUse = ChromiumProcessError.exitedBeforeReady(
            .status(21), stderrTail: "[ERROR:process_singleton_posix.cc] Failed to create SingletonLock: File exists")

        launcher.failNext(with: inUse)
        let lease = try await pool.acquire(.project(UUID()))
        #expect(launcher.count == 2, "retried once")
        #expect(!lease.browser.isClosed)

        launcher.failNext(with: inUse)
        launcher.failNext(with: inUse)
        do {
            _ = try await pool.acquire(.project(UUID()))
            Issue.record("launched on a profile in use")
        } catch let error as ChromiumPoolError {
            guard case .launchFailed(let detail) = error else {
                Issue.record("\(error)")
                return
            }
            #expect(detail.contains("before answering"))
        }
        #expect(launcher.count == 4, "never more than one retry")
        await pool.shutdownAll(grace: .milliseconds(300))
    }

    @Test("more than three deaths in five minutes stop the relaunches, with the way out")
    func bouclePlantages() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = FakeLauncher()
        defer { launcher.finish() }
        let pool = makePool(launcher, profiles: ChromiumProfiles(root: root))
        let key = ChromiumProfileKey.project(UUID())

        for round in 1...4 {
            let lease = try await pool.acquire(key)
            launcher.peer(round - 1).hangUp()   // Chromium dies
            let noticed = await eventuallyAsync { await !pool.isRunning(key) }
            #expect(noticed, "death \(round)")
            await pool.release(lease)   // of a dead process: nothing
        }
        do {
            _ = try await pool.acquire(key)
            Issue.record("a fifth launch")
        } catch let error as ChromiumPoolError {
            guard case .keepsStopping = error else {
                Issue.record("\(error)")
                return
            }
            #expect(error.description.hasPrefix("Chromium keeps stopping ("))
            #expect(error.description.hasSuffix("Settings ▸ Agents can switch the agent browser to WebKit"))
        }
        #expect(launcher.count == 4)
        // Another profile is not held back by this one's loop.
        _ = try await pool.acquire(.project(UUID()))
        #expect(launcher.count == 5)
        await pool.shutdownAll(grace: .milliseconds(300))
    }

    @Test("local-only: the fence is the proxy; another mode relaunches, the same mode does not")
    func modeLocal() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = FakeLauncher()
        defer { launcher.finish() }
        let pool = makePool(launcher, profiles: ChromiumProfiles(root: root),
                            network: .localOnly(allowedHosts: ["api.test"]))
        let key = ChromiumProfileKey.project(UUID())

        let lease = try await pool.acquire(key)
        let port = try #require(await pool.fencePort)
        let arguments = try #require(launcher.requests.first).arguments
        #expect(arguments.contains("--proxy-server=http://127.0.0.1:\(port)"))
        #expect(arguments.contains(where: { $0.hasPrefix("--proxy-bypass-list=<-loopback>;") && $0.hasSuffix(";api.test") }))
        #expect(arguments.contains("--webrtc-ip-handling-policy=disable_non_proxied_udp"))
        #expect(arguments.contains("--force-webrtc-ip-handling-policy=disable_non_proxied_udp"))
        #expect(!arguments.contains("--no-proxy-server"))
        let owner = RecordingOwner()
        lease.browser.addOwner(owner)

        await pool.setNetworkMode(.localOnly(allowedHosts: ["api.test"]))
        #expect(launcher.count == 1)
        #expect(!lease.browser.isClosed)

        await pool.setNetworkMode(.open)
        #expect(lease.browser.isClosed)
        #expect(owner.journal == ["closed"], "its pages reload at the next command")
        #expect(await pool.fencePort == nil, "the port is let go")
        #expect(await pool.networkMode == .open)

        _ = try await pool.acquire(key)
        #expect(launcher.count == 2)
        #expect(launcher.requests[1].arguments.contains("--no-proxy-server"))
        await pool.release(lease)
        await pool.shutdownAll(grace: .milliseconds(300))
    }

    @Test("private sessions share one process, a context each, disposed at release; the folder goes with it")
    func sessionsPrivees() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = FakeLauncher()
        defer { launcher.finish() }
        let profiles = ChromiumProfiles(root: root)
        let pool = makePool(launcher, profiles: profiles)

        let a = try await pool.acquire(.privateShared)
        let b = try await pool.acquire(.privateShared)
        #expect(launcher.count == 1)
        let contextA = try #require(a.browserContextId)
        let contextB = try #require(b.browserContextId)
        #expect(contextA != contextB)
        let request = try #require(launcher.requests.first)
        let folder = request.userDataDirectory
        #expect(folder.deletingLastPathComponent().path == profiles.privateRoot.path)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(!request.arguments.contains(where: { $0.hasPrefix("--disk-cache-dir=") }))

        await pool.release(a)
        let disposed = await eventually {
            launcher.peer(0).received("Target.disposeBrowserContext")
                .contains(where: { $0.params["browserContextId"] as? String == contextA })
        }
        #expect(disposed)
        #expect(await pool.isRunning(.privateShared))

        await pool.shutdownAll(grace: .milliseconds(300))
        #expect(b.browser.isClosed)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test("clearing a profile stops its process and empties it; removing it deletes it")
    func viderEtSupprimer() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = FakeLauncher()
        defer { launcher.finish() }
        let profiles = ChromiumProfiles(root: root)
        let pool = makePool(launcher, profiles: profiles)
        let identifier = UUID()
        let key = ChromiumProfileKey.project(identifier)

        let lease = try await pool.acquire(key)
        let cookies = profiles.profileDirectory(for: identifier).appendingPathComponent("Default/Cookies")
        try FileManager.default.createDirectory(at: cookies.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("session=1".utf8).write(to: cookies)

        try await pool.clearProfile(identifier)
        #expect(lease.browser.isClosed)
        #expect(!FileManager.default.fileExists(atPath: cookies.path))
        #expect(FileManager.default.fileExists(atPath: profiles.profileDirectory(for: identifier).path))

        _ = try await pool.acquire(key)
        #expect(launcher.count == 2)
        try await pool.removeProfile(identifier)
        let runningAfterRemoval = await pool.isRunning(key)
        #expect(!runningAfterRemoval)
        #expect(!FileManager.default.fileExists(atPath: profiles.profileDirectory(for: identifier).path))
        await pool.shutdownAll(grace: .milliseconds(300))
    }

    @Test("no executable: a clear error, nothing launched; after shutdownAll, nothing launches")
    func sansExecutableEtApresArret() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = FakeLauncher()
        defer { launcher.finish() }
        let pool = makePool(launcher, profiles: ChromiumProfiles(root: root), executable: nil)

        await #expect(throws: ChromiumPoolError.noExecutable) {
            try await pool.acquire(.privateShared)
        }
        #expect(launcher.count == 0)
        #expect(ChromiumPoolError.noExecutable.description.contains("switch the agent browser to WebKit"))

        await pool.shutdownAll(grace: .milliseconds(100))
        await #expect(throws: ChromiumPoolError.shutDown) {
            try await pool.acquire(.project(UUID()))
        }
    }

    @Test("browser tools off: nothing launches, a running process stops; back on, it launches again")
    func outilsCoupes() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = FakeLauncher()
        defer { launcher.finish() }
        let pool = makePool(launcher, profiles: ChromiumProfiles(root: root))
        let key = ChromiumProfileKey.project(UUID())
        _ = try await pool.acquire(key)
        #expect(launcher.count == 1)

        await pool.setLaunchesAllowed(false)
        await pool.stop(key, reason: "Browser tools were turned off")
        // An acquire that was under way when the tools went off comes back here.
        await #expect(throws: ChromiumPoolError.toolsOff) {
            try await pool.acquire(key)
        }
        #expect(launcher.count == 1, "no relaunch after the stop")
        #expect(ChromiumPoolError.toolsOff.description.contains("Browser tools are turned off"))

        await pool.setLaunchesAllowed(true)
        _ = try await pool.acquire(key)
        #expect(launcher.count == 2)
        await pool.shutdownAll(grace: .milliseconds(300))
    }

    @Test("a stop Loom chose keeps the project's session cookies for its next launch; Clear data forgets them")
    func cookiesDeSession() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = FakeLauncher(answer: { received in
            guard received.method == "Storage.getCookies" else { return nil }
            return [BrowserPeer.reply(received, #"{"cookies":[{"name":"sess","value":"abc","domain":"127.0.0.1","path":"/","expires":-1,"session":true},{"name":"keep","value":"1","domain":"127.0.0.1","path":"/","expires":1e10,"session":false}]}"#)]
        })
        defer { launcher.finish() }
        let profiles = ChromiumProfiles(root: root)
        let pool = makePool(launcher, profiles: profiles)
        let identifier = UUID()
        let key = ChromiumProfileKey.project(identifier)
        _ = try await pool.acquire(key)

        await pool.stop(key, reason: "Browser tools were turned off")
        _ = try await pool.acquire(key)
        let restored = launcher.peer(1).received("Storage.setCookies")
        #expect(restored.count == 1, "put back before the browser is handed out")
        let names = (restored.first?.params["cookies"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        #expect(names == ["sess"], "the session cookies only: the others are on disk")

        try await pool.clearProfile(identifier)
        _ = try await pool.acquire(key)
        #expect(launcher.peer(2).received("Storage.setCookies").isEmpty, "signed out: nothing comes back")
        await pool.shutdownAll(grace: .milliseconds(300))
    }

    @Test("a private folder left by a Loom that died is swept when the pool starts")
    func balayageAuDemarrage() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = ChromiumProfiles(root: root)
        let leftover = try profiles.makePrivateDirectory()
        let launcher = FakeLauncher()
        defer { launcher.finish() }
        _ = makePool(launcher, profiles: profiles)
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }
}

// MARK: - A real Chromium

/// LOOM_CHROMIUM: the path of a Chromium-family binary (a headless shell is fastest).
private let realChromium: String? = {
    guard let path = ProcessInfo.processInfo.environment["LOOM_CHROMIUM"], !path.isEmpty,
          FileManager.default.isExecutableFile(atPath: path) else { return nil }
    return path
}()

@Suite("ChromiumPool on a real Chromium (LOOM_CHROMIUM)", .serialized, .timeLimit(.minutes(1)),
       .enabled(if: realChromium != nil))
struct ChromiumRealBrowserTests {

    @Test("launch, a paused tab resumed and evaluated, a private context, then a clean shutdown")
    func vraiNavigateur() async throws {
        let path = try #require(realChromium)
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = ChromiumExecutable(url: URL(fileURLWithPath: path),
                                            kind: ChromiumLocator.kind(ofExecutableAt: path), source: .userChoice)
        let pool = ChromiumPool(profiles: ChromiumProfiles(root: root), network: .open, executable: { executable })

        let lease = try await pool.acquire(.project(UUID()))
        #expect(lease.browser.version.isSupported)
        #expect(lease.browser.pid != nil)
        let owner = RecordingOwner()
        let target = try await lease.browser.createTarget(owner: owner)
        _ = try await lease.browser.resume(target).value()
        let evaluated = try await lease.browser.connection.call("Runtime.evaluate",
                                                                ["expression": "1 + 1", "returnByValue": true],
                                                                session: target.sessionId, options: bounded())
        #expect(evaluated.object("result")?.int("value") == 2)

        let privateLease = try await pool.acquire(.privateShared)
        let context = try #require(privateLease.browserContextId)
        let privateTarget = try await privateLease.browser.createTarget(browserContextId: context, owner: owner)
        _ = try await privateLease.browser.resume(privateTarget).value()

        await pool.shutdownAll(grace: .seconds(5))
        #expect(lease.browser.isClosed)
        #expect(privateLease.browser.isClosed)
        #expect(owner.journal.filter { $0 == "closed" }.count == 2, "each browser told its owner once")
    }
}

// MARK: - Tooling

/// Plays Chromium on the far ends of two pipes, on a thread of its own:
/// reads what Loom writes to Chromium's fd 3, answers on its fd 4.
private final class BrowserPeer: @unchecked Sendable {

    struct Received: @unchecked Sendable {
        let id: Int
        let method: String
        let params: [String: Any]
        let session: String?
    }

    /// Frames to send for a command, in one write; nil: the default answer.
    typealias Answer = @Sendable (Received) -> [String]?

    let loomRead: Int32
    let loomWrite: Int32
    private let commands: Int32
    private let replies: Int32
    private let answer: Answer?
    private let lock = NSLock()
    private var log: [Received] = []
    private var repliesOpen = true
    private var stopped = false
    private var finished = false
    private var nextTarget = 0
    private var nextContext = 0
    private let served = DispatchSemaphore(value: 0)

    init(answer: Answer? = nil) throws {
        var toChromium: [Int32] = [-1, -1]
        var fromChromium: [Int32] = [-1, -1]
        let made = SpawnLock.withLock { () -> Bool in
            guard pipe(&toChromium) == 0 else { return false }
            guard pipe(&fromChromium) == 0 else {
                _ = close(toChromium[0])
                _ = close(toChromium[1])
                return false
            }
            for descriptor in toChromium + fromChromium {
                _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            }
            return true
        }
        guard made else { throw PeerFailure() }
        commands = toChromium[0]
        loomWrite = toChromium[1]
        loomRead = fromChromium[0]
        replies = fromChromium[1]
        _ = fcntl(replies, F_SETNOSIGPIPE, 1)
        self.answer = answer
        let thread = Thread { [self] in self.serve() }
        thread.start()
    }

    /// The browser on Loom's ends; once per peer (its connection owns them).
    func browser(major: Int = 141) -> ChromiumBrowser {
        let connection = CDPConnection(read: loomRead, write: loomWrite, label: "peer-\(loomRead)")
        let version = ChromiumVersion(product: "HeadlessChrome/\(major).0.0.0", major: major, userAgent: "",
                                      protocolVersion: "1.3")
        return ChromiumBrowser(connection: connection, version: version)
    }

    func received(_ method: String? = nil) -> [Received] {
        lock.lock()
        defer { lock.unlock() }
        guard let method else { return log }
        return log.filter { $0.method == method }
    }

    func methods() -> [String] {
        received().map(\.method)
    }

    func closedTargets() -> [String] {
        received("Target.closeTarget").compactMap { $0.params["targetId"] as? String }
    }

    /// Events, in one write.
    func emit(_ frames: String...) {
        send(frames)
    }

    func send(_ frames: [String]) {
        var bytes = Data()
        for frame in frames {
            bytes.append(contentsOf: Array(frame.utf8))
            bytes.append(UInt8(0))
        }
        lock.lock()
        defer { lock.unlock() }
        guard repliesOpen else { return }
        let descriptor = replies
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, base + offset, raw.count - offset)
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    /// Chromium's fd 4 closes, as when it dies: Loom reads EOF.
    func hangUp() {
        lock.lock()
        if repliesOpen {
            repliesOpen = false
            _ = close(replies)
        }
        lock.unlock()
    }

    func finish() {
        lock.lock()
        let first = !finished
        finished = true
        stopped = true
        lock.unlock()
        guard first else { return }
        _ = served.wait(timeout: .now() + .seconds(2))
        hangUp()
        _ = close(commands)
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func serve() {
        var framer = CDPFramer()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while !isStopped {
            var waiting = pollfd(fd: commands, events: Int16(POLLIN), revents: 0)
            guard poll(&waiting, 1, 20) > 0 else { continue }
            let count = read(commands, &buffer, buffer.count)
            // Loom closed its end: Chromium exits.
            if count <= 0 { break }
            let frames = framer.feed(Data(buffer[0..<count]))
            for frame in frames {
                guard let message = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any],
                      let id = message["id"] as? Int, let method = message["method"] as? String else { continue }
                let received = Received(id: id, method: method, params: (message["params"] as? [String: Any]) ?? [:],
                                        session: message["sessionId"] as? String)
                lock.lock()
                log.append(received)
                lock.unlock()
                if let scripted = answer?(received) {
                    if !scripted.isEmpty { send(scripted) }
                    continue
                }
                answerByDefault(received)
            }
        }
        hangUp()
        served.signal()
    }

    /// What Chromium answers: a target and its attach, a context, a close
    /// followed by the exit, `{}` for the rest.
    private func answerByDefault(_ received: Received) {
        switch received.method {
        case "Target.createTarget":
            let number = lock.withLock { () -> Int in
                nextTarget += 1
                return nextTarget
            }
            let context = received.params["browserContextId"] as? String
            send([Self.reply(received, #"{"targetId":"T\#(number)"}"#),
                  Self.attached(targetId: "T\(number)", session: "S\(number)", context: context)])
        case "Target.createBrowserContext":
            let number = lock.withLock { () -> Int in
                nextContext += 1
                return nextContext
            }
            send([Self.reply(received, #"{"browserContextId":"CTX\#(number)"}"#)])
        case "Browser.close":
            send([Self.reply(received)])
            hangUp()
        default:
            send([Self.reply(received)])
        }
    }

    static func reply(_ received: Received, _ result: String = "{}") -> String {
        if let session = received.session {
            return #"{"id":\#(received.id),"result":\#(result),"sessionId":"\#(session)"}"#
        }
        return #"{"id":\#(received.id),"result":\#(result)}"#
    }

    static func error(_ received: Received, _ message: String) -> String {
        if let session = received.session {
            return #"{"id":\#(received.id),"error":{"code":-32000,"message":"\#(message)"},"sessionId":"\#(session)"}"#
        }
        return #"{"id":\#(received.id),"error":{"code":-32000,"message":"\#(message)"}}"#
    }

    static func attached(targetId: String, session: String, opener: String? = nil, url: String = "about:blank",
                         context: String? = nil, waiting: Bool = true) -> String {
        var info = #""targetId":"\#(targetId)","type":"page","title":"","url":"\#(url)","attached":true"#
        if let opener {
            info += #","openerId":"\#(opener)","canAccessOpener":true"#
        }
        if let context {
            info += #","browserContextId":"\#(context)""#
        }
        return #"{"method":"Target.attachedToTarget","params":{"sessionId":"\#(session)","targetInfo":{\#(info)},"waitingForDebugger":\#(waiting)}}"#
    }
}

private struct PeerFailure: Error {}

/// Writes what it hears, one line per call.
private final class RecordingOwner: ChromiumTargetOwner, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    private var onAttach: (@Sendable (ChromiumTarget) -> Void)?
    private var frames: [String: String] = [:]

    var journal: [String] {
        lock.withLock { entries }
    }

    func whenAttached(_ action: @escaping @Sendable (ChromiumTarget) -> Void) {
        lock.withLock { onAttach = action }
    }

    func own(frame: String, in targetId: String) {
        lock.withLock { frames[frame] = targetId }
    }

    private func note(_ entry: String) {
        lock.withLock { entries.append(entry) }
    }

    func attached(target: ChromiumTarget, openerTargetId: String?, url: String) {
        note("attached:\(target.targetId):\(target.sessionId.rawValue):\(openerTargetId ?? "-")")
        let action = lock.withLock { onAttach }
        action?(target)
    }

    func targetInfoChanged(targetId: String, url: String, title: String) {
        note("info:\(targetId):\(url):\(title)")
    }

    func detached(targetId: String) {
        note("detached:\(targetId)")
    }

    func crashed(targetId: String) {
        note("crashed:\(targetId)")
    }

    func downloadStarted(targetId: String, url: String) {
        note("download:\(targetId):\(url)")
    }

    func browserClosed(reason: String) {
        note("closed")
    }

    func target(ofFrame frameId: String) -> String? {
        lock.withLock { frames[frameId] }
    }
}

/// Launches a peer in place of Chromium; can fail on demand, or play an old version.
private final class FakeLauncher: @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [BrowserPeer] = []
    private var browsers: [ChromiumBrowser] = []
    private var requestLog: [ChromiumLaunchRequest] = []
    private var failures: [Error] = []
    private var major = 141
    /// What its peers answer before their defaults.
    private let answer: BrowserPeer.Answer?

    init(answer: BrowserPeer.Answer? = nil) {
        self.answer = answer
    }

    var requests: [ChromiumLaunchRequest] {
        lock.withLock { requestLog }
    }

    var count: Int {
        requests.count
    }

    var lastBrowser: ChromiumBrowser? {
        lock.withLock { browsers.last }
    }

    /// The peer of the n-th successful launch.
    func peer(_ index: Int) -> BrowserPeer {
        lock.withLock { peers[index] }
    }

    func failNext(with error: Error) {
        lock.withLock { failures.append(error) }
    }

    func setMajor(_ value: Int) {
        lock.withLock { major = value }
    }

    var launcher: ChromiumLauncher {
        { request in try await self.launch(request) }
    }

    func launch(_ request: ChromiumLaunchRequest) async throws -> ChromiumBrowser {
        lock.lock()
        requestLog.append(request)
        let failure: Error? = failures.isEmpty ? nil : failures.removeFirst()
        let version = major
        lock.unlock()
        if let failure { throw failure }
        // A launch takes a while: concurrent acquires overlap it.
        try await Task.sleep(for: .milliseconds(30))
        let peer = try BrowserPeer(answer: answer)
        let browser = peer.browser(major: version)
        lock.lock()
        peers.append(peer)
        browsers.append(browser)
        lock.unlock()
        return browser
    }

    func finish() {
        let all = lock.withLock { peers }
        for peer in all {
            peer.finish()
        }
    }
}

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.withLock { value }
    }

    func set(_ newValue: Value) {
        lock.withLock { value = newValue }
    }
}

private let fakeShell = ChromiumExecutable(url: URL(fileURLWithPath: "/opt/fake/chrome-headless-shell"),
                                           kind: .headlessShell, source: .userChoice)

private func makePool(_ launcher: FakeLauncher, profiles: ChromiumProfiles,
                      network: ChromiumNetworkMode = .open, idle: Duration = .seconds(60),
                      executable: ChromiumExecutable? = fakeShell) -> ChromiumPool {
    ChromiumPool(profiles: profiles, network: network, executable: { executable }, idleGrace: idle,
                 readyTimeout: .seconds(5), launcher: launcher.launcher)
}

private func makeTemporaryRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("loom-pool-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func bounded() -> CDPCallOptions {
    CDPCallOptions(deadline: ContinuousClock.now + .seconds(5))
}

private func filterType(_ params: [String: Any]) -> String? {
    (params["filter"] as? [[String: Any]])?.first?["type"] as? String
}

private func permissionName(_ received: BrowserPeer.Received) -> String? {
    (received.params["permission"] as? [String: Any])?["name"] as? String
}

/// The error a reply ends with; nil if it succeeds.
private func failure(of reply: CDPReply) async -> CDPError? {
    do {
        _ = try await reply.value()
        return nil
    } catch let error as CDPError {
        return error
    } catch {
        return nil
    }
}

private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<400 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

private func eventuallyAsync(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<400 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
