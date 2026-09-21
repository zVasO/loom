import Testing
import LoomAPI
import LoomCore
import Foundation

// Seam: the wire contract of ADR-0010, as a client and a server both read it.
// Nothing here touches a socket — that is LoomIPCTests' job.

@Suite("LoomAPI — wire contract")
struct APIProtocolTests {

    @Test("a JSON value survives the round trip, nesting included")
    func jsonValueAllerRetour() throws {
        let value: JSONValue = .object([
            "n": .number(42), "s": .string("x"), "b": .bool(true), "z": .null,
            "a": .array([.number(1), .object(["k": .string("v")])]),
        ])
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
        #expect(value["a"] != nil)
        #expect(value["s"]?.stringValue == "x")
    }

    @Test("typed models cross the JSON value both ways")
    func modelesTypes() throws {
        let params = APISetBadgesParams(sessionId: nil, badges: ["review", "urgent"])
        let value = try JSONValue.from(params)
        #expect(value["badges"] == .array([.string("review"), .string("urgent")]))
        #expect(try value.decode(APISetBadgesParams.self) == params)
    }

    @Test("a request line carries the token and the request; params default to an empty object")
    func ligneDeRequete() throws {
        let request = APIRequest(id: "r1", method: .badgeList)
        let line = try APIEnvelope.requestLine(token: "tok", request: request)
        #expect(line.last == UInt8(ascii: "\n"), "one line, newline-terminated")
        let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(object[APIEnvelope.tokenKey] as? String == "tok")
        let inner = try #require(object[APIEnvelope.requestKey] as? [String: Any])
        #expect(inner["method"] as? String == "badge.list")

        let bare = Data(#"{"id":"r2","method":"loom.version"}"#.utf8)
        let decoded = try JSONDecoder().decode(APIRequest.self, from: bare)
        #expect(decoded.params == .object([:]), "a request without params is a request with none")
    }

    @Test("a response line decodes to a result or an error, never both")
    func ligneDeReponse() throws {
        let ok = try APIEnvelope.decodeResponse(Data(#"{"id":"r1","result":{"x":1}}"#.utf8))
        #expect(ok.result == .object(["x": .number(1)]))
        #expect(ok.error == nil)
        let failed = try APIEnvelope.decodeResponse(
            Data(#"{"id":"r1","error":{"code":"forbidden","message":"no"}}"#.utf8))
        #expect(failed.error?.code == .forbidden)
        #expect(failed.result == nil)
    }

    @Test("bad params become invalidParams, not a crash")
    func parametresInvalides() {
        let request = APIRequest(id: "r", method: .sessionSetTitle, params: .object(["title": .number(3)]))
        #expect(throws: APIError.self) { try request.decodeParams(APISetTitleParams.self) }
    }

    @Test("only the listing of every session demands the global token")
    func portees() {
        #expect(APIMethod.sessionsList.requiresGlobalScope)
        for method in APIMethod.allCases where method != .sessionsList {
            #expect(!method.requiresGlobalScope, "\(method.rawValue) works under a session token")
        }
    }

    @Test("a badge color is #RRGGBB, nothing else")
    func couleurDeBadge() {
        #expect(APIBadge.isValidColor("#4CC38A"))
        #expect(APIBadge.isValidColor("#4cc38a"))
        #expect(!APIBadge.isValidColor("4CC38A"))
        #expect(!APIBadge.isValidColor("#4CC38"))
        #expect(!APIBadge.isValidColor("#GGGGGG"))
    }

    @Test("the client finds its way from the environment Loom gives an agent")
    func clientDepuisLEnvironnement() {
        #expect(APIClient.fromEnvironment([:]) == nil, "outside Loom: no client")
        let client = APIClient.fromEnvironment([APIProtocol.socketEnvironmentKey: "/tmp/loom.sock",
                                                APIProtocol.sessionTokenEnvironmentKey: "t"])
        #expect(client?.socketPath == "/tmp/loom.sock")
        #expect(client?.token == "t")
    }
}
