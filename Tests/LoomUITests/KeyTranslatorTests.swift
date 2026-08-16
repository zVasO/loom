import Testing
@testable import LoomUI

/// SES-05bis : la frappe va directement au champ de saisie de l'agent — la vue
/// capture les touches et le traducteur les convertit en octets pour le PTY.
@Suite("KeyTranslator — du clavier aux octets PTY")
struct KeyTranslatorTests {

    @Test("les caractères imprimables passent tels quels (AZERTY inclus)")
    func caracteresImprimables() {
        #expect(KeyTranslator.bytes(keyCode: 0, characters: "a", option: false) == "a")
        #expect(KeyTranslator.bytes(keyCode: 0, characters: "é", option: false) == "é")
    }

    @Test("Entrée envoie CR — c'est la validation du champ de l'agent")
    func entree() {
        #expect(KeyTranslator.bytes(keyCode: 36, characters: "\r", option: false) == "\r")
    }

    @Test("Option+Entrée envoie ESC CR — saut de ligne dans le champ de l'agent")
    func optionEntree() {
        #expect(KeyTranslator.bytes(keyCode: 36, characters: "\r", option: true) == "\u{1b}\r")
    }

    @Test("effacement arrière envoie DEL, pas BS")
    func effacement() {
        #expect(KeyTranslator.bytes(keyCode: 51, characters: "\u{8}", option: false) == "\u{7f}")
    }

    @Test("les flèches deviennent des séquences CSI")
    func fleches() {
        #expect(KeyTranslator.bytes(keyCode: 126, characters: "", option: false) == "\u{1b}[A")
        #expect(KeyTranslator.bytes(keyCode: 125, characters: "", option: false) == "\u{1b}[B")
        #expect(KeyTranslator.bytes(keyCode: 124, characters: "", option: false) == "\u{1b}[C")
        #expect(KeyTranslator.bytes(keyCode: 123, characters: "", option: false) == "\u{1b}[D")
    }

    @Test("Échap et Tab passent en contrôle brut")
    func echapEtTab() {
        #expect(KeyTranslator.bytes(keyCode: 53, characters: "\u{1b}", option: false) == "\u{1b}")
        #expect(KeyTranslator.bytes(keyCode: 48, characters: "\t", option: false) == "\t")
    }

    @Test("Ctrl+C arrive déjà en ETX dans characters et passe tel quel")
    func controle() {
        #expect(KeyTranslator.bytes(keyCode: 8, characters: "\u{3}", option: false) == "\u{3}")
    }

    @Test("une frappe sans caractère ni touche spéciale ne produit rien")
    func toucheMuette() {
        #expect(KeyTranslator.bytes(keyCode: 63, characters: "", option: false) == nil)
    }
}
