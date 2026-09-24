import Foundation

/// `http.fetch`: the only way an extension reaches the network (ADR-0011).
/// The page itself cannot — its content security policy and a content rule
/// list block every http(s) load — so what leaves goes through here, to the
/// hosts the user consented to, with no cookie jar and no cache.
public struct BridgeHTTPRequest: Codable, Equatable, Sendable {
    public var url: String
    public var method: String?
    public var headers: [String: String]?
    public var body: String?
    /// `"utf8"` (default) or `"base64"`.
    public var bodyEncoding: String?

    public init(url: String, method: String? = nil, headers: [String: String]? = nil,
                body: String? = nil, bodyEncoding: String? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.bodyEncoding = bodyEncoding
    }
}

public struct BridgeHTTPResponse: Codable, Equatable, Sendable {
    public var status: Int
    /// Where the answer came from, after redirections.
    public var url: String
    /// Lowercased names.
    public var headers: [String: String]
    public var body: String
    /// `"utf8"` when the body is text, `"base64"` otherwise.
    public var bodyEncoding: String

    public init(status: Int, url: String, headers: [String: String], body: String, bodyEncoding: String) {
        self.status = status
        self.url = url
        self.headers = headers
        self.body = body
        self.bodyEncoding = bodyEncoding
    }
}

public enum HTTPProxyPolicy {
    public static let allowedMethods: Set<String> = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"]
    public static let maxRequestBody = 1 << 20
    public static let maxResponseBody = 8 << 20
    public static let timeout: TimeInterval = 30

    /// Headers a page never sets: the transport's own, and the ones that would
    /// pass for the browser or the user's session.
    static let forbiddenRequestHeaders: Set<String> = [
        "host", "cookie", "cookie2", "origin", "referer", "content-length", "connection",
        "keep-alive", "transfer-encoding", "te", "trailer", "upgrade", "expect", "via",
    ]

    public static func urlRequest(_ request: BridgeHTTPRequest, allowed: [HostPattern]) throws -> URLRequest {
        guard let url = URL(string: request.url), url.scheme != nil, url.host != nil else {
            throw BridgeError(.invalidParams, "http.fetch needs an absolute https URL")
        }
        guard HostPattern.allows(url, allowed) else {
            throw BridgeError(.forbidden,
                              "\(url.host ?? request.url) is not among the hosts this extension may reach (https only)")
        }
        let method = (request.method ?? "GET").uppercased()
        guard allowedMethods.contains(method) else {
            throw BridgeError(.invalidParams, "method \(method) is not allowed")
        }
        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        urlRequest.httpMethod = method
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in sanitizedRequestHeaders(request.headers ?? [:]) {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        if let body = request.body {
            let data: Data
            switch request.bodyEncoding ?? "utf8" {
            case "utf8":
                data = Data(body.utf8)
            case "base64":
                guard let decoded = Data(base64Encoded: body) else {
                    throw BridgeError(.invalidParams, "the body is not valid base64")
                }
                data = decoded
            default:
                throw BridgeError(.invalidParams, "bodyEncoding is \"utf8\" or \"base64\"")
            }
            guard data.count <= maxRequestBody else {
                throw BridgeError(.tooLarge, "the request body is over \(maxRequestBody) bytes")
            }
            guard method != "GET", method != "HEAD" else {
                throw BridgeError(.invalidParams, "a \(method) request has no body")
            }
            urlRequest.httpBody = data
        }
        return urlRequest
    }

    public static func sanitizedRequestHeaders(_ headers: [String: String]) -> [String: String] {
        headers.filter { name, value in
            let lower = name.lowercased()
            return !forbiddenRequestHeaders.contains(lower)
                && !lower.hasPrefix("sec-") && !lower.hasPrefix("proxy-")
                && !name.isEmpty && !name.contains(where: { $0 == ":" || $0.isNewline || $0.isWhitespace })
                && !value.contains(where: \.isNewline)
        }
    }

    public static func sanitizedResponseHeaders(_ headers: [AnyHashable: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (name, value) in headers {
            guard let name = name as? String else { continue }
            let lower = name.lowercased()
            guard lower != "set-cookie", lower != "set-cookie2" else { continue }
            result[lower] = "\(value)"
        }
        return result
    }

    /// Text when it decodes as UTF-8, base64 otherwise.
    public static func encodeBody(_ data: Data) -> (body: String, encoding: String) {
        if let text = String(data: data, encoding: .utf8) { return (text, "utf8") }
        return (data.base64EncodedString(), "base64")
    }
}

/// Performs `http.fetch` calls: one URLSession per request, ephemeral, no
/// cookies, no cache, each redirection re-checked against the allowlist.
public final class ExtensionHTTPClient: @unchecked Sendable {
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    public func perform(_ request: BridgeHTTPRequest, allowed: [HostPattern]) async throws -> BridgeHTTPResponse {
        let urlRequest = try HTTPProxyPolicy.urlRequest(request, allowed: allowed)
        guard let config = configuration.copy() as? URLSessionConfiguration else {
            throw BridgeError(.internalError, "no session configuration")
        }
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = HTTPProxyPolicy.timeout
        config.timeoutIntervalForResource = HTTPProxyPolicy.timeout
        let redirectGuard = RedirectGuard(allowed: allowed)
        let session = URLSession(configuration: config, delegate: redirectGuard, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest, delegate: redirectGuard)
        } catch {
            throw BridgeError(.network, error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw BridgeError(.network, "the host did not answer in HTTP")
        }
        guard data.count <= HTTPProxyPolicy.maxResponseBody else {
            throw BridgeError(.tooLarge, "the response is over \(HTTPProxyPolicy.maxResponseBody) bytes")
        }
        let (body, encoding) = HTTPProxyPolicy.encodeBody(data)
        return BridgeHTTPResponse(status: http.statusCode,
                                  url: http.url?.absoluteString ?? request.url,
                                  headers: HTTPProxyPolicy.sanitizedResponseHeaders(http.allHeaderFields),
                                  body: body, bodyEncoding: encoding)
    }
}

/// Follows a redirection only to a host the extension may reach; otherwise the
/// 3xx itself is the answer.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let allowed: [HostPattern]

    init(allowed: [HostPattern]) {
        self.allowed = allowed
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.follow(request, allowed: allowed))
    }

    static func follow(_ request: URLRequest, allowed: [HostPattern]) -> URLRequest? {
        guard let url = request.url, HostPattern.allows(url, allowed) else { return nil }
        var next = request
        next.httpShouldHandleCookies = false
        next.setValue(nil, forHTTPHeaderField: "Cookie")
        return next
    }
}
