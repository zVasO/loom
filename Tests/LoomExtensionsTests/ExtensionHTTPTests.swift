import Testing
@testable import LoomExtensions
import Foundation

// Seam: `http.fetch` — the policy that turns a page's request into a
// URLRequest (or refuses it), and the client, run against a URLProtocol stub
// registered on its session configuration: no network, the real URLSession.

@Suite("Extensions — http.fetch policy")
struct HTTPProxyPolicyTests {

    private let allowed = [try! HostPattern("*.atlassian.net")]

    @Test("a host outside the allowlist, http, or a custom port is forbidden")
    func hotesRefuses() {
        for url in ["https://example.com/", "http://acme.atlassian.net/", "https://acme.atlassian.net:8080/",
                    "https://atlassian.net/"] {
            #expect(throws: BridgeError.self, "\(url)") {
                try HTTPProxyPolicy.urlRequest(BridgeHTTPRequest(url: url), allowed: allowed)
            }
        }
        #expect(throws: BridgeError.self) {
            try HTTPProxyPolicy.urlRequest(BridgeHTTPRequest(url: "not a url"), allowed: allowed)
        }
    }

    @Test("cookies, host and browser headers never leave; the page's own go through")
    func entetes() throws {
        let request = try HTTPProxyPolicy.urlRequest(BridgeHTTPRequest(
            url: "https://acme.atlassian.net/rest/api/3/myself",
            headers: ["Authorization": "Basic abc", "Accept": "application/json",
                      "Cookie": "session=1", "Host": "evil.com", "Origin": "https://x",
                      "Sec-Fetch-Mode": "cors", "Proxy-Authorization": "x", "X-Bad\nHeader": "v",
                      "X-Split": "a\r\nInjected: 1"]), allowed: allowed)
        let headers = request.allHTTPHeaderFields ?? [:]
        #expect(headers["Authorization"] == "Basic abc")
        #expect(headers["Accept"] == "application/json")
        for dropped in ["Cookie", "Host", "Origin", "Sec-Fetch-Mode", "Proxy-Authorization", "X-Split"] {
            #expect(headers[dropped] == nil, "\(dropped)")
        }
        #expect(request.httpShouldHandleCookies == false)
    }

    @Test("a body travels as UTF-8 or base64, capped, and never on a GET")
    func corps() throws {
        let post = try HTTPProxyPolicy.urlRequest(BridgeHTTPRequest(
            url: "https://acme.atlassian.net/x", method: "post", body: "{\"a\":1}"), allowed: allowed)
        #expect(post.httpMethod == "POST")
        #expect(post.httpBody == Data("{\"a\":1}".utf8))
        let binary = try HTTPProxyPolicy.urlRequest(BridgeHTTPRequest(
            url: "https://acme.atlassian.net/x", method: "PUT", body: "AAEC", bodyEncoding: "base64"),
            allowed: allowed)
        #expect(binary.httpBody == Data([0, 1, 2]))
        #expect(throws: BridgeError.self) {
            try HTTPProxyPolicy.urlRequest(BridgeHTTPRequest(url: "https://acme.atlassian.net/x", body: "x"),
                                           allowed: allowed)
        }
        #expect(throws: BridgeError.self) {
            try HTTPProxyPolicy.urlRequest(BridgeHTTPRequest(
                url: "https://acme.atlassian.net/x", method: "POST",
                body: String(repeating: "x", count: HTTPProxyPolicy.maxRequestBody + 1)), allowed: allowed)
        }
        #expect(throws: BridgeError.self) {
            try HTTPProxyPolicy.urlRequest(BridgeHTTPRequest(url: "https://acme.atlassian.net/x", method: "CONNECT"),
                                           allowed: allowed)
        }
    }

    @Test("a redirection is followed only to an allowed host")
    func redirections() {
        let inside = URLRequest(url: URL(string: "https://other.atlassian.net/next")!)
        #expect(RedirectGuard.follow(inside, allowed: allowed)?.url == inside.url)
        let outside = URLRequest(url: URL(string: "https://evil.example.com/steal")!)
        #expect(RedirectGuard.follow(outside, allowed: allowed) == nil)
        let downgraded = URLRequest(url: URL(string: "http://other.atlassian.net/next")!)
        #expect(RedirectGuard.follow(downgraded, allowed: allowed) == nil)
    }

    @Test("set-cookie never reaches the page; names come lowercased")
    func entetesDeReponse() {
        let headers = HTTPProxyPolicy.sanitizedResponseHeaders(
            ["Set-Cookie": "a=1", "Content-Type": "application/json", "X-Total": "3"])
        #expect(headers == ["content-type": "application/json", "x-total": "3"])
    }
}

/// Answers every request from a fixed table, by path.
final class StubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        switch url.path {
        case "/json":
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": "application/json", "Set-Cookie": "tracker=1",
                "X-Echo-Auth": request.value(forHTTPHeaderField: "Authorization") ?? "",
                "X-Echo-Cookie": request.value(forHTTPHeaderField: "Cookie") ?? "",
            ])!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
        case "/binary":
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: Data([0xFF, 0xFE, 0x00]))
        default:
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: Data())
        }
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Extensions — http.fetch client")
struct ExtensionHTTPClientTests {

    private func client() -> ExtensionHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return ExtensionHTTPClient(configuration: configuration)
    }

    private let allowed = [try! HostPattern("*.atlassian.net")]

    @Test("an allowed request comes back with its status, text body, and no set-cookie")
    func reponseTexte() async throws {
        let response = try await client().perform(BridgeHTTPRequest(
            url: "https://acme.atlassian.net/json", headers: ["Authorization": "Basic abc", "Cookie": "x=1"]),
            allowed: allowed)
        #expect(response.status == 200)
        #expect(response.body == #"{"ok":true}"#)
        #expect(response.bodyEncoding == "utf8")
        #expect(response.headers["set-cookie"] == nil)
        #expect(response.headers["x-echo-auth"] == "Basic abc")
        #expect(response.headers["x-echo-cookie"] == "", "the page's cookie never left")
    }

    @Test("a body that is not text comes back as base64")
    func reponseBinaire() async throws {
        let response = try await client().perform(BridgeHTTPRequest(url: "https://acme.atlassian.net/binary"),
                                                  allowed: allowed)
        #expect(response.bodyEncoding == "base64")
        #expect(Data(base64Encoded: response.body) == Data([0xFF, 0xFE, 0x00]))
    }

    @Test("a host outside the allowlist is refused before any request")
    func refusAvantEnvoi() async {
        await #expect(throws: BridgeError.self) {
            try await client().perform(BridgeHTTPRequest(url: "https://example.com/json"), allowed: allowed)
        }
    }
}
