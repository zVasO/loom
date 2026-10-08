import Testing
import LoomChromium
import Foundation

// Seam: the `--remote-debugging-pipe` wire (JSON + NUL). A read ends at any
// byte, so the framer is fed chunks cut wherever the tests choose.

@Suite("CDPFramer — NUL-delimited frames")
struct CDPFramerTests {

    @Test("a frame split across reads is joined")
    func trameCoupee() throws {
        var framer = CDPFramer()
        let first = framer.feed(Data(#"{"id":1,"res"#.utf8))
        let second = framer.feed(Data(#"ult":{}}"#.utf8))
        let third = framer.feed(Data([0]))
        #expect(first.isEmpty)
        #expect(second.isEmpty, "no NUL yet: the frame is still incomplete")
        #expect(texts(third) == [#"{"id":1,"result":{}}"#])
    }

    @Test("several frames in one chunk come out in wire order, the tail waits")
    func plusieursTramesUnMorceau() throws {
        var framer = CDPFramer()
        let first = framer.feed(Data("{\"a\":1}\0{\"b\":2}\0{\"c\"".utf8))
        let second = framer.feed(Data(":3}\0".utf8))
        #expect(texts(first) == [#"{"a":1}"#, #"{"b":2}"#])
        #expect(texts(second) == [#"{"c":3}"#])
    }

    @Test("a character split across chunks arrives whole")
    func caractereCoupe() throws {
        let frame = Array("{\"t\":\"élan\"}\0".utf8)
        let lead = try #require(frame.firstIndex(of: 0xC3))
        var framer = CDPFramer()
        let first = framer.feed(Data(frame[...lead]))
        let second = framer.feed(Data(frame[(lead + 1)...]))
        #expect(first.isEmpty)
        let joined = try #require(second.first)
        let object = try #require(try JSONSerialization.jsonObject(with: joined) as? [String: Any])
        #expect(object["t"] as? String == "élan")
    }

    @Test("empty frames carry nothing and are skipped")
    func tramesVides() throws {
        var framer = CDPFramer()
        let frames = framer.feed(Data("\0\0{}\0".utf8))
        #expect(texts(frames) == ["{}"])
    }

    @Test("a frame may reach the limit; one past it is dropped up to its NUL and named, and the next frames still come")
    func limiteDeTaille() throws {
        let atLimit = feeding([Data("12345678\0".utf8)], limit: 8)
        #expect(texts(atLimit) == ["12345678"])

        // Past the limit before its NUL: dropped as it arrives.
        var framer = CDPFramer(maxFrameBytes: 8)
        #expect(framer.read(Data("{\"id\":7,".utf8)).isEmpty)
        #expect(framer.read(Data("\"x\":1".utf8)).isEmpty)
        let ended = framer.read(Data("23}\0{}\0".utf8))
        #expect(ended == [.oversized(head: Data("{\"id\":7,\"x\":1".utf8), length: 16), .frame(Data("{}".utf8))])

        // Past it within one chunk: named in its place.
        var whole = CDPFramer(maxFrameBytes: 8)
        let pieces = whole.read(Data("{}\u{0}123456789\u{0}{\"a\":1}\u{0}".utf8))
        #expect(pieces == [.frame(Data("{}".utf8)), .oversized(head: Data("123456789".utf8), length: 9),
                           .frame(Data("{\"a\":1}".utf8))])
        #expect(texts(feeding([Data("{}\u{0}123456789\u{0}".utf8)], limit: 8)) == ["{}"])
    }

    @Test("encode writes one JSON object then a single NUL, and the framer reads it back")
    func encodageAllerRetour() throws {
        let message: [String: Any] = ["id": 7, "method": "Input.insertText", "params": ["text": "a\u{0}b"]]
        let encoded = try CDPFramer.encode(message)
        #expect(encoded.last == UInt8(0))
        #expect(encoded.filter { $0 == 0 }.count == 1, "JSON escapes a NUL inside a string: one terminator only")
        var framer = CDPFramer()
        let frames = framer.feed(encoded)
        let frame = try #require(frames.first)
        let object = try #require(try JSONSerialization.jsonObject(with: frame) as? [String: Any])
        #expect(object["id"] as? Int == 7)
        #expect(object["method"] as? String == "Input.insertText")
        #expect((object["params"] as? [String: Any])?["text"] as? String == "a\u{0}b")
    }

    @Test("a value JSON cannot carry is refused, never raised")
    func encodageRefuse() {
        #expect(throws: CDPFramer.Failure.notJSON) {
            _ = try CDPFramer.encode(["when": Date()])
        }
    }

    // MARK: - Tooling

    private func texts(_ frames: [Data]) -> [String] {
        frames.map { String(decoding: $0, as: UTF8.self) }
    }

    private func feeding(_ chunks: [Data], limit: Int) -> [Data] {
        var framer = CDPFramer(maxFrameBytes: limit)
        var frames: [Data] = []
        for chunk in chunks {
            frames += framer.feed(chunk)
        }
        return frames
    }
}
