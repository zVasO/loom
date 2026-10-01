import Foundation
import WebKit

/// A value WebKit will deliver once — or never: a callback that may not come
/// (a page blocked on a dialog, a process that died) must not hold the agent's
/// command forever. The first resolution wins: WebKit's answer, the deadline,
/// a dialog opening, the page navigating away, or the task being cancelled.
final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?

    var isResolved: Bool { lock.withLock { result != nil } }

    func resolve(_ outcome: Result<Value, Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = outcome
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: outcome)
    }

    func value() async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        } onCancel: {
            resolve(.failure(CancellationError()))
        }
    }
}

/// Why a WebKit wait ended without WebKit's answer.
enum AgentInterruption: Error, Equatable {
    case deadline
    case dialogOpened
    case navigated
    case crashed
}

/// Talking to the page: the helper in Loom's content world, the agent's own
/// functions in the page's. Never the Swift async `evaluateJavaScript`
/// overload — typed `Any`, it traps when a script answers `undefined`; every
/// script here answers a JSON string.
@MainActor
enum AgentJS {

    /// Starts `body` and hands its answer to `box` — whatever the box waits on
    /// besides is the caller's (AgentBrowser.await).
    static func start(_ webView: WKWebView, body: String, arguments: [String: Any],
                      world: WKContentWorld, into box: OneShot<String>) {
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: world) { result in
            switch result {
            case .success(let value):
                box.resolve(.success(value as? String ?? "null"))
            case .failure(let error):
                box.resolve(.failure(mapped(error)))
            }
        }
    }

    /// WebKit's errors, in the agent's words. A script's own exception carries
    /// its message under a key WebKit documents only as a string.
    static func mapped(_ error: Error) -> Error {
        let nsError = error as NSError
        guard nsError.domain == WKError.errorDomain, let code = WKError.Code(rawValue: nsError.code) else {
            return AgentError.failed(error.localizedDescription)
        }
        switch code {
        case .javaScriptExceptionOccurred:
            let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            let line = nsError.userInfo["WKJavaScriptExceptionLineNumber"] as? Int
            return AgentError.invalid("JavaScript error: \(message)" + (line.map { " (line \($0))" } ?? ""))
        case .javaScriptResultTypeIsUnsupported:
            return AgentError.failed("the script answered something that is not JSON")
        case .webContentProcessTerminated, .webViewInvalidated:
            return AgentError.unavailable("the page's process stopped; it is being reloaded")
        default:
            return AgentError.failed(error.localizedDescription)
        }
    }

    /// The helper's answer: `{ok…}` fields, or its `{error}` as an AgentError.
    static func decode(_ json: String) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw AgentError.failed("the page answered something unexpected")
        }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "failed"
            switch error["code"] as? String {
            case "notFound": throw AgentError.notFound(message)
            case "invalid", "ambiguous", "notSelect", "optionNotFound", "notEditable": throw AgentError.invalid(message)
            case "helperMissing": throw HelperMissing()
            default: throw AgentError.failed(message)
            }
        }
        return object
    }

    struct HelperMissing: Error {}

    /// A command's arguments as the helper reads them.
    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
