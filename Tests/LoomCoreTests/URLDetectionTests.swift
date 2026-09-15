import Testing
import LoomCore

// Seam: from raw text to the URLs a click may open. Anchored on the scheme,
// so everything that merely LOOKS like a host must stay untouched — terminal
// output is full of file names and package identifiers.

@Suite("BareURL — URLs in plain text")
struct URLDetectionTests {

    private func found(_ text: String) -> [String] {
        BareURL.ranges(in: Array(text)).map { String(Array(text)[$0]) }
    }

    @Test func trouveUneURLSimple() {
        #expect(found("voir https://example.com/a ici") == ["https://example.com/a"])
    }

    @Test func trouveHttpEtPlusieursURL() {
        #expect(found("http://a.io et https://b.io/x")
            == ["http://a.io", "https://b.io/x"])
    }

    @Test func ignoreCeQuiRessembleAUnHote() {
        #expect(found("AppModel.swift, com.apple.dt et 1.18.0").isEmpty)
        #expect(found("example.com").isEmpty)
    }

    @Test func laPonctuationFinaleResteHorsDuLien() {
        #expect(found("lis https://example.com/a.") == ["https://example.com/a"])
        #expect(found("https://example.com/a, puis") == ["https://example.com/a"])
    }

    @Test func uneParentheseFermanteNonAppariereEstRendueALaPhrase() {
        #expect(found("(https://example.com/a)") == ["https://example.com/a"])
    }

    @Test func uneParentheseAppariereResteDansLeLien() {
        #expect(found("https://ex.com/a_(b) fin") == ["https://ex.com/a_(b)"])
    }

    @Test func lesGuillemetsEtChevronsBornentLeLien() {
        #expect(found("\"https://example.com/a\"") == ["https://example.com/a"])
        #expect(found("<https://example.com/a>") == ["https://example.com/a"])
    }

    @Test func leSchemaSeulNeFaitPasUnLien() {
        #expect(found("https:// et voila").isEmpty)
    }

    @Test func leSchemaEstInsensibleALaCasse() {
        #expect(found("HTTPS://Example.com/A") == ["HTTPS://Example.com/A"])
    }

    @Test func fonctionneSurUneChaineCommeSurUnTableau() {
        let text = "voir https://example.com ici"
        #expect(text[BareURL.ranges(in: text)[0]] == "https://example.com")
    }
}
