import Testing
@testable import LoomChromium
import Foundation

// The agent's Chromium command line, for each binary and network mode. The
// fence is a real one (a listener on 127.0.0.1, nothing leaves the machine).

/// The CDP harness's copy of the flags (Tests/AgentBrowserCDP), when present.
private let flagsFixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("AgentBrowserCDP/fixtures/flags.json")

private let kinds: [ChromiumExecutable.Kind] = [.headlessShell, .fullBrowser("Google Chrome for Testing")]

@Suite("ChromiumFlags — the agent's Chromium command line", .serialized)
struct ChromiumFlagsTests {

    @Test("the forbidden switches hold the four the ADR names, and the sandbox's company")
    func interditsNommes() {
        #expect(ChromiumFlags.forbidden.isSuperset(of: ["--no-sandbox", "--remote-debugging-port",
                                                        "--enable-automation", "--disable-popup-blocking"]))
        #expect(ChromiumFlags.forbidden.isSuperset(of: ["--remote-debugging-address", "--disable-web-security",
                                                        "--single-process", "--no-zygote"]))
        #expect(ChromiumFlags.isForbidden("--remote-debugging-port=9222"), "with a value too")
        #expect(ChromiumFlags.isForbidden("--no-sandbox"))
        #expect(!ChromiumFlags.isForbidden("--remote-debugging-pipe"))
    }

    @Test("no forbidden switch, for any binary, in any network mode")
    func jamaisUnInterdit() throws {
        let fence = try ChromiumFence.start()
        defer { fence.stop() }
        let modes: [ChromiumNetworkMode] = [.open, .localOnly(allowedHosts: []),
                                            .localOnly(allowedHosts: ["api.test", "*.staging.test"])]
        for kind in kinds {
            for mode in modes {
                let cache = URL(fileURLWithPath: "/tmp/loom-cache", isDirectory: true)
                let arguments = try ChromiumFlags.arguments(kind: kind, network: mode, fence: fence,
                                                            cacheDirectory: cache)
                for argument in arguments {
                    #expect(!ChromiumFlags.isForbidden(argument), "\(argument) for \(kind), \(mode)")
                }
                #expect(arguments.contains("--remote-debugging-pipe"), "the pipe, never a port")
                #expect(Set(arguments).count == arguments.count, "no switch twice")
            }
        }
    }

    @Test("the headless shell takes --headless, a full browser --headless=new")
    func headlessSelonLeBinaire() throws {
        let shell = try ChromiumFlags.arguments(kind: .headlessShell, network: .open, fence: nil, cacheDirectory: nil)
        #expect(shell.contains("--headless"))
        #expect(!shell.contains("--headless=new"))
        let full = try ChromiumFlags.arguments(kind: .fullBrowser("Chromium"), network: .open, fence: nil,
                                               cacheDirectory: nil)
        #expect(full.contains("--headless=new"))
        #expect(!full.contains("--headless"))
    }

    @Test("open mode: no proxy at all, and none of local-only's switches")
    func modeOuvert() throws {
        let arguments = try ChromiumFlags.arguments(kind: .headlessShell, network: .open, fence: nil,
                                                    cacheDirectory: nil)
        #expect(arguments.contains("--no-proxy-server"))
        #expect(!arguments.contains(where: { $0.hasPrefix("--proxy-server=") || $0.hasPrefix("--proxy-bypass-list=") }))
        #expect(!arguments.contains("--disable-quic"))
    }

    @Test("local-only: the fence as proxy, loopback and the hosts let through, QUIC, DNS prefetch and WebRTC held")
    func modeLocal() throws {
        let fence = try ChromiumFence.start()
        defer { fence.stop() }
        for kind in kinds {
            let arguments = try ChromiumFlags.arguments(kind: kind, network: .localOnly(allowedHosts: ["api.test"]),
                                                        fence: fence, cacheDirectory: nil)
            #expect(arguments.contains("--proxy-server=http://127.0.0.1:\(fence.port)"))
            #expect(arguments.contains(
                "--proxy-bypass-list=<-loopback>;localhost;*.localhost;127.0.0.0/8;[::1];0.0.0.0;api.test"))
            #expect(arguments.contains("--disable-quic"))
            #expect(arguments.contains("--dns-prefetch-disable"))
            // The full browser honours one spelling, the shell the other: both, always.
            #expect(arguments.contains("--webrtc-ip-handling-policy=disable_non_proxied_udp"))
            #expect(arguments.contains("--force-webrtc-ip-handling-policy=disable_non_proxied_udp"))
            #expect(!arguments.contains("--no-proxy-server"))
        }
    }

    @Test("local-only without a listening fence launches nothing")
    func sansClotureRien() throws {
        #expect(throws: ChromiumFlagsError.fenceRequired) {
            _ = try ChromiumFlags.arguments(kind: .headlessShell, network: .localOnly(allowedHosts: []),
                                            fence: nil, cacheDirectory: nil)
        }
        let stopped = try ChromiumFence.start()
        stopped.stop()
        #expect(throws: ChromiumFlagsError.fenceRequired) {
            _ = try ChromiumFlags.arguments(kind: .fullBrowser("Chromium"), network: .localOnly(allowedHosts: []),
                                            fence: stopped, cacheDirectory: nil)
        }
    }

    @Test("the switches the probes measured are all there, as measured")
    func drapeauxMesures() throws {
        let arguments = try ChromiumFlags.arguments(kind: .headlessShell, network: .open, fence: nil,
                                                    cacheDirectory: nil)
        for flag in ["--no-first-run", "--no-default-browser-check", "--use-mock-keychain", "--hide-scrollbars",
                     "--mute-audio", "--disable-back-forward-cache", "--disable-background-timer-throttling",
                     "--disable-renderer-backgrounding", "--disable-backgrounding-occluded-windows",
                     "--disable-ipc-flooding-protection", "--deny-permission-prompts",
                     "--disable-background-networking", "--disable-component-update", "--disable-default-apps",
                     "--disable-sync", "--metrics-recording-only", "--disable-breakpad",
                     "--disable-client-side-phishing-detection", "--disable-field-trial-config"] {
            #expect(arguments.contains(flag), "\(flag)")
        }
        #expect(arguments.contains(
            "--blink-settings=primaryHoverType=2,availableHoverTypes=2,primaryPointerType=4,availablePointerTypes=4"))
        #expect(arguments.filter { $0.hasPrefix("--disable-features=") }.count == 1, "Chromium reads the last one only")
        let features = try #require(arguments.first(where: { $0.hasPrefix("--disable-features=") }))
        // Built outside #expect, each typed: `map(String.init)` against a
        // literal is more than the type checker likes in one expression.
        let names: [Substring] = features.dropFirst("--disable-features=".count).split(separator: ",")
        let disabled: Set<String> = Set(names.map { String($0) })
        let expected: Set<String> = [
            "NetworkTimeServiceQuerying", "Translate", "OptimizationHints", "MediaRouter", "DialMediaRouteProvider",
            "AutofillServerCommunication",
        ]
        #expect(disabled == expected)
    }

    @Test("a cache folder becomes --disk-cache-dir; the launch plan adds the profile, never a second pipe")
    func cacheEtProfil() throws {
        let cache = URL(fileURLWithPath: "/tmp/loom profiles/cache/A", isDirectory: true)
        let arguments = try ChromiumFlags.arguments(kind: .headlessShell, network: .open, fence: nil,
                                                    cacheDirectory: cache)
        #expect(arguments.contains("--disk-cache-dir=/tmp/loom profiles/cache/A"), "one argv entry, spaces and all")
        let plan = ChromiumLaunchPlan(executable: URL(fileURLWithPath: "/opt/chrome-headless-shell"),
                                      arguments: arguments,
                                      userDataDirectory: URL(fileURLWithPath: "/tmp/loom profiles/profiles/A"))
        let spawned = plan.spawnArguments
        #expect(spawned.filter { $0 == "--remote-debugging-pipe" }.count == 1)
        #expect(spawned.contains("--user-data-dir=/tmp/loom profiles/profiles/A"))
    }

    @Test("the CDP harness launches with the same switches", .enabled(if: FileManager.default.fileExists(atPath: flagsFixture.path)))
    func memesDrapeauxQueLeBanc() throws {
        let data = try Data(contentsOf: flagsFixture)
        let json = try JSONSerialization.jsonObject(with: data)
        var forbiddenListed: [String] = []
        var harness = Set<String>()
        collectFlags(json, into: &harness, forbidden: &forbiddenListed, underForbidden: false)
        try #require(!harness.isEmpty, "flags.json lists no switch")

        if !forbiddenListed.isEmpty {
            #expect(Set(forbiddenListed) == ChromiumFlags.forbidden, "the forbidden lists agree")
        }
        let fence = try ChromiumFence.start()
        defer { fence.stop() }
        var ours = Set<String>()
        for kind in kinds {
            for mode in [ChromiumNetworkMode.open, .localOnly(allowedHosts: [])] {
                let arguments = try ChromiumFlags.arguments(kind: kind, network: mode, fence: fence,
                                                            cacheDirectory: nil)
                for argument in arguments {
                    #expect(!isForbiddenBy(forbiddenListed, argument), "\(argument) is on the harness's forbidden list")
                }
                ours.formUnion(arguments.map(normalized))
            }
        }
        // What the harness adds for its own environment, never Loom's to ship.
        let harnessOnly: Set<String> = ["--no-sandbox", "--font-render-hinting=none", "--disable-lcd-text",
                                        "--user-data-dir", "--disk-cache-dir", "--host-resolver-rules"]
        // Loom's own: the transport the harness's launcher may add unlisted, and
        // no proxy in open mode, which the harness passes by itself.
        let loomOnly: Set<String> = ["--remote-debugging-pipe", "--no-proxy-server"]
        let theirs = Set(harness.map(normalized)).subtracting(harnessOnly)

        // Disabled features: at least every one the harness disables.
        let featuresName = "--disable-features"
        #expect(features(in: theirs).isSubset(of: features(in: ours)),
                "a feature the harness disables is enabled by Loom")
        let oursCompared = ours.filter { !$0.hasPrefix(featuresName) }
        let theirsCompared = theirs.filter { !$0.hasPrefix(featuresName) }

        #expect(oursCompared.subtracting(theirsCompared).subtracting(loomOnly).sorted() == [],
                "switches Loom passes that the harness never measured")
        #expect(theirsCompared.subtracting(oursCompared).sorted() == [],
                "switches the harness measured that Loom does not pass")
    }
}

/// Every "--switch" string in the JSON, wherever it sits — but not in a
/// comment ("$comment") nor a sentence; those under a "forbidden" key apart.
private func collectFlags(_ value: Any, into flags: inout Set<String>, forbidden: inout [String],
                          underForbidden: Bool) {
    if let text = value as? String {
        guard text.hasPrefix("--"), !text.contains(where: { $0.isWhitespace }) else { return }
        if underForbidden { forbidden.append(text) } else { flags.insert(text) }
    } else if let array = value as? [Any] {
        for element in array {
            collectFlags(element, into: &flags, forbidden: &forbidden, underForbidden: underForbidden)
        }
    } else if let object = value as? [String: Any] {
        for (key, element) in object where !key.hasPrefix("$") {
            let isForbidden = underForbidden || key.lowercased().contains("forbidden")
            collectFlags(element, into: &flags, forbidden: &forbidden, underForbidden: isForbidden)
        }
    }
}

/// The harness's own rule: a forbidden switch, alone or with a value.
private func isForbiddenBy(_ forbidden: [String], _ argument: String) -> Bool {
    forbidden.contains(where: { argument == $0 || argument.hasPrefix($0 + "=") })
}

/// The features a normalized `--disable-features=` entry names.
private func features(in flags: Set<String>) -> Set<String> {
    let prefix = "--disable-features="
    var result = Set<String>()
    for flag in flags where flag.hasPrefix(prefix) {
        for name in flag.dropFirst(prefix.count).split(separator: ",") {
            result.insert(String(name))
        }
    }
    return result
}

/// Values that differ per launch compared by name; comma lists as sorted
/// sets. "--user-data-dir=" (a prefix, value to come) counts as the name.
private func normalized(_ flag: String) -> String {
    guard let equals = flag.firstIndex(of: "=") else { return flag }
    let name = String(flag[..<equals])
    let value = String(flag[flag.index(after: equals)...])
    switch name {
    case "--proxy-server", "--user-data-dir", "--disk-cache-dir", "--proxy-bypass-list", "--host-resolver-rules":
        return name
    case "--disable-features", "--enable-features", "--blink-settings":
        return name + "=" + value.split(separator: ",").map(String.init).sorted().joined(separator: ",")
    default:
        return flag
    }
}
