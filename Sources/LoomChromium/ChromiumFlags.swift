import Foundation

/// What the agent's Chromium may reach (ADR-0016): everything, or the
/// machine itself plus the hosts the person listed. Equal modes launch with
/// equal flags; a different one relaunches the process.
public enum ChromiumNetworkMode: Equatable, Sendable {
    case open
    case localOnly(allowedHosts: [String])
}

public enum ChromiumFlagsError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Local-only mode without a listening fence: fail closed, launch nothing.
    case fenceRequired

    public var description: String {
        switch self {
        case .fenceRequired:
            return "local sites only needs Loom's proxy fence, and it is not listening: nothing is launched"
        }
    }
}

/// The command line of the agent's Chromium (ADR-0016, step-0 probes).
/// `--user-data-dir` is the launch plan's (ChromiumLaunchPlan.spawnArguments).
///
/// The CDP harness (Tests/AgentBrowserCDP/lib/flags.mjs, written out to
/// fixtures/flags.json) runs Chromium 141 with the same set, the full browser
/// and the headless shell; ChromiumFlagsTests compares the two. Loom adds
/// `--no-proxy-server` in open mode (the harness passes it on its own) and
/// disables two more features (DialMediaRouteProvider,
/// AutofillServerCommunication): no traffic the harness measured is let back.
public enum ChromiumFlags {

    /// Never passed, checked by a test (and by the CDP harness, whose
    /// fixtures/flags.json lists the same):
    /// - `--no-sandbox`, `--single-process`, `--no-zygote`: pages are
    ///   untrusted; the renderer sandbox and process isolation stay on.
    /// - `--remote-debugging-port`, `--remote-debugging-address`: any local
    ///   process could drive a logged-in profile.
    /// - `--enable-automation`: an infobar and a fingerprint, for nothing.
    /// - `--disable-popup-blocking`: popups go through the navigation policy.
    /// - `--disable-web-security`, `--allow-running-insecure-content`: the
    ///   pages under test must meet the web as their users do.
    public static let forbidden: Set<String> = [
        "--no-sandbox", "--remote-debugging-port", "--remote-debugging-address", "--enable-automation",
        "--disable-popup-blocking", "--disable-web-security", "--single-process", "--no-zygote",
        "--allow-running-insecure-content",
    ]

    /// True for a forbidden switch, with or without a value.
    public static func isForbidden(_ flag: String) -> Bool {
        let name = flag.split(separator: "=", maxSplits: 1).first.map(String.init) ?? flag
        return forbidden.contains(name)
    }

    /// Every launch, whatever the binary and the network. The CDP harness
    /// launches with the same (Tests/AgentBrowserCDP/lib/flags.mjs).
    public static let common: [String] = [
        // CDP over fds 3 and 4: no TCP listener.
        "--remote-debugging-pipe",
        "--no-first-run",
        "--no-default-browser-check",
        "--no-service-autorun",
        // Cookies under a fixed key, readable on disk like WebKit's store (ADR-0016):
        // the real Keychain would prompt in the name of Google Chrome for Testing.
        "--use-mock-keychain",
        "--password-store=basic",
        // Pages keep running while the panel is hidden or another session's window is in front.
        "--disable-background-timer-throttling",
        "--disable-renderer-backgrounding",
        "--disable-backgrounding-occluded-windows",
        // Pipelined input and pushState loops are never throttled; no hang dialog.
        "--disable-ipc-flooding-protection",
        "--disable-hang-monitor",
        // A bfcache restore fires no `load`: navigate_back would have nothing to settle on.
        "--disable-back-forward-cache",
        // (hover: hover) and (pointer: fine) match, as on a Mac with a trackpad.
        "--blink-settings=primaryHoverType=2,availableHoverTypes=2,primaryPointerType=4,availablePointerTypes=4",
        // innerWidth == clientWidth, as with macOS overlay scrollbars.
        "--hide-scrollbars",
        "--force-color-profile=srgb",
        "--mute-audio",
        "--deny-permission-prompts",
        // No traffic of Chromium's own (NFR-S): components, field trials, metrics,
        // Safe Browsing, sync, extensions.
        "--disable-background-networking",
        "--disable-component-update",
        "--disable-field-trial-config",
        "--disable-breakpad",
        "--disable-client-side-phishing-detection",
        "--disable-component-extensions-with-background-pages",
        "--disable-default-apps",
        "--disable-extensions",
        "--disable-sync",
        "--metrics-recording-only",
        "--disable-search-engine-choice-screen",
        // One --disable-features only: Chromium reads the last one.
        "--disable-features=NetworkTimeServiceQuerying,Translate,OptimizationHints,MediaRouter,"
            + "DialMediaRouteProvider,AutofillServerCommunication",
    ]

    /// The headless shell is headless by construction and takes the plain
    /// switch; a full browser runs the new headless mode.
    public static func headless(kind: ChromiumExecutable.Kind) -> [String] {
        switch kind {
        case .headlessShell: return ["--headless"]
        case .fullBrowser: return ["--headless=new"]
        }
    }

    /// Open: no proxy at all, so a developer's system proxy never sees the
    /// agent's pages. Local-only: the fence as proxy with loopback and the
    /// allowed hosts bypassing it, QUIC and DNS prefetch off, and WebRTC kept
    /// to the proxy — both spellings, since the full browser honours one and
    /// the shell the other.
    public static func network(_ mode: ChromiumNetworkMode, fence: ChromiumFence?) throws -> [String] {
        switch mode {
        case .open:
            return ["--no-proxy-server"]
        case .localOnly(let allowedHosts):
            guard let fence, fence.isListening else { throw ChromiumFlagsError.fenceRequired }
            return fence.launchArguments(allowedHosts: allowedHosts) + [
                "--disable-quic",
                "--dns-prefetch-disable",
                "--webrtc-ip-handling-policy=disable_non_proxied_udp",
                "--force-webrtc-ip-handling-policy=disable_non_proxied_udp",
            ]
        }
    }

    /// The whole set. Throws `fenceRequired` for local-only without a
    /// listening fence: no launch is better than an open one.
    public static func arguments(kind: ChromiumExecutable.Kind, network mode: ChromiumNetworkMode,
                                 fence: ChromiumFence?, cacheDirectory: URL?) throws -> [String] {
        let networkFlags = try network(mode, fence: fence)
        var result = common + headless(kind: kind) + networkFlags
        if let cacheDirectory {
            result.append("--disk-cache-dir=\(cacheDirectory.path)")
        }
        return result
    }
}
