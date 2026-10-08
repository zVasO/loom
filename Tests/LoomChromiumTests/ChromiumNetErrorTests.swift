import Testing
import LoomChromium
import Foundation

// Seam: the agent reads the same failure whichever engine loaded the page.
// The expected strings are the WebKit engine's (AgentBrowser's failure(_:)).

@Suite("ChromiumNetError — net::ERR_* in the agent's words")
struct ChromiumNetErrorTests {

    private func message(_ errorText: String, _ address: String?, localOnly: Bool = false) -> String? {
        ChromiumNetError.message(errorText: errorText, url: address.flatMap { URL(string: $0) }, localOnly: localOnly)
    }

    @Test("a refused connection asks whether the dev server runs")
    func connexionRefusee() {
        #expect(message("net::ERR_CONNECTION_REFUSED", "http://localhost:5173/app")
                == "nothing is listening on localhost:5173 — is the dev server running?")
        #expect(message("net::ERR_CONNECTION_REFUSED", "http://[::1]:3000/")
                == "nothing is listening on [::1]:3000 — is the dev server running?")
        #expect(message("net::ERR_CONNECTION_REFUSED", "http://localhost/")
                == "nothing is listening on localhost — is the dev server running?")
    }

    @Test("an unknown host, an offline Mac, a timeout")
    func hoteEtReseau() {
        #expect(message("net::ERR_NAME_NOT_RESOLVED", "https://nowhere.invalid/") == "unknown host nowhere.invalid")
        #expect(message("net::ERR_INTERNET_DISCONNECTED", "https://example.com/")
                == "example.com: the Internet connection appears to be offline")
        #expect(message("net::ERR_CONNECTION_TIMED_OUT", "http://10.0.0.9:8080/") == "10.0.0.9:8080 did not answer in time")
        #expect(message("net::ERR_TIMED_OUT", "http://localhost:8080/") == "localhost:8080 did not answer in time")
    }

    @Test("TLS failures name their code and point to http")
    func tls() {
        #expect(message("net::ERR_CERT_AUTHORITY_INVALID", "https://localhost:8443/")
                == "the TLS connection to localhost:8443 failed (ERR_CERT_AUTHORITY_INVALID) "
                + "— a local dev server usually speaks http")
        #expect(message("net::ERR_SSL_PROTOCOL_ERROR", "https://localhost:5173/")
                == "the TLS connection to localhost:5173 failed (ERR_SSL_PROTOCOL_ERROR) "
                + "— a local dev server usually speaks http")
    }

    @Test("a dropped connection, with the fence named only where it may be the cause")
    func connexionCoupee() {
        #expect(message("net::ERR_EMPTY_RESPONSE", "http://localhost:3000/")
                == "localhost:3000 closed the connection without answering")
        #expect(message("net::ERR_CONNECTION_CLOSED", "http://localhost:3000/") == "localhost:3000 closed the connection")
        #expect(message("net::ERR_CONNECTION_RESET", "http://localhost:3000/") == "the connection to localhost:3000 was reset")
        #expect(message("net::ERR_EMPTY_RESPONSE", "http://localhost:3000/", localOnly: true)
                == "localhost:3000 closed the connection without answering",
                "loopback goes direct: it never meets the fence")
        #expect(message("net::ERR_EMPTY_RESPONSE", "http://example.com/", localOnly: true)
                == "example.com closed the connection without answering (or it is outside local sites only: "
                + "Loom's Settings ▸ Agents lists the hosts it lets through)")
    }

    @Test("in local-only mode, a proxy, tunnel or client block is the fence: blocked")
    func bloqueParLaCloture() {
        let blocked = "example.com is outside local sites only (Loom's Settings ▸ Agents lists the hosts it lets through)"
        for code in ["net::ERR_TUNNEL_CONNECTION_FAILED", "net::ERR_PROXY_CONNECTION_FAILED", "net::ERR_BLOCKED_BY_CLIENT"] {
            #expect(message(code, "https://example.com/login", localOnly: true) == blocked, "\(code)")
        }
    }

    @Test("outside local-only mode, a proxy failure is the person's own proxy")
    func proxyHorsCloture() {
        #expect(message("net::ERR_PROXY_CONNECTION_FAILED", "https://example.com/")
                == "the network proxy could not be reached to load example.com")
        #expect(message("net::ERR_TUNNEL_CONNECTION_FAILED", "https://example.com/")
                == "the network proxy refused the connection to example.com")
        #expect(message("net::ERR_BLOCKED_BY_CLIENT", "https://ads.example.com/") == "Loom's browser blocked ads.example.com")
    }

    @Test("an aborted load is not a failure, nor is an empty text")
    func annuleNEstPasUnEchec() {
        #expect(message("net::ERR_ABORTED", "http://localhost:3000/file.zip") == nil)
        #expect(message("ERR_ABORTED", nil) == nil)
        #expect(message("", "http://localhost:3000/") == nil)
    }

    @Test("schemes, files and refused ports")
    func schemasFichiersPorts() {
        #expect(message("net::ERR_UNKNOWN_URL_SCHEME", "vscode://file/a.swift") == "vscode://file/a.swift cannot be opened — http(s) only")
        #expect(message("net::ERR_FILE_NOT_FOUND", "file:///tmp/missing%20page.html") == "no file at /tmp/missing page.html")
        #expect(message("net::ERR_UNSAFE_PORT", "http://localhost:6000/")
                == "port 6000 is one browsers refuse to open — use another port")
    }

    @Test("anything else names the address and the code")
    func codeInconnu() {
        #expect(message("net::ERR_TOO_MANY_REDIRECTS", "https://a.test/loop") == "could not load https://a.test/loop: ERR_TOO_MANY_REDIRECTS")
        #expect(message("net::ERR_SOMETHING_NEW", nil) == "could not load the page: ERR_SOMETHING_NEW")
    }

    @Test("the code is read with or without its net:: prefix, and without a URL")
    func formesDuCode() {
        #expect(message("ERR_CONNECTION_REFUSED", "http://localhost:5173/")
                == "nothing is listening on localhost:5173 — is the dev server running?")
        #expect(message(" net::ERR_NAME_NOT_RESOLVED\n", "http://nowhere.invalid/") == "unknown host nowhere.invalid")
        #expect(message("net::ERR_CONNECTION_REFUSED", nil) == "nothing is listening on the page — is the dev server running?")
        #expect(message("net::ERR_PROXY_CONNECTION_FAILED", nil, localOnly: true)
                == "this address is outside local sites only (Loom's Settings ▸ Agents lists the hosts it lets through)")
    }
}
