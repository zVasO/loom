import Testing
import BunshinAgents
import BunshinCore
import Foundation

// Seam : l'interface publique de l'adapter. Les attendus viennent de la doc
// officielle du CLI (docs/research/claude-code-hooks.md), pas du code.

@Suite("ClaudeCodeAdapter — traduction vers le CLI")
struct ClaudeCodeAdapterTests {

    @Test("le lancement impose l'UUID de session : la Reprise est déterministe")
    func lancementImposeLUuid() {
        let id = SessionID()
        let adapter = ClaudeCodeAdapter()
        let command = adapter.launchCommand(session: id, initialPrompt: "corrige le bug de cache")

        #expect(command.executable == "claude")
        #expect(command.arguments.contains("--session-id"))
        #expect(command.arguments.contains(id.rawValue.uuidString),
                "l'ID est imposé au lancement — plus de fenêtre de crash avant SessionStart (recherche §5)")
        #expect(command.arguments.last == "corrige le bug de cache", "le prompt initial part en argument")
    }

    @Test("les hooks sont injectés par --settings inline, jamais dans les settings globaux (STA-01)")
    func hooksInjectesParSettings() throws {
        let wiring = ClaudeCodeAdapter.HookWiring(
            helper: URL(fileURLWithPath: "/Library/Application Support/Bunshin/bunshin-hook"),
            socket: URL(fileURLWithPath: "/tmp/bunshin.sock"),
            token: "jeton-secret-42")
        let adapter = ClaudeCodeAdapter(hooks: wiring)
        let command = adapter.launchCommand(session: SessionID(), initialPrompt: nil)

        guard let flagIndex = command.arguments.firstIndex(of: "--settings"),
              command.arguments.indices.contains(flagIndex + 1) else {
            Issue.record("--settings absent de la commande")
            return
        }
        let json = try #require(command.arguments[flagIndex + 1].data(using: .utf8))
        let settings = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let hooks = try #require(settings["hooks"] as? [String: Any])

        for event in ["SessionStart", "UserPromptSubmit", "Stop", "Notification", "PermissionRequest", "SessionEnd"] {
            let entries = try #require(hooks[event] as? [[String: Any]], "hook \(event) manquant")
            let hookList = try #require(entries.first?["hooks"] as? [[String: Any]])
            let commandLine = try #require(hookList.first?["command"] as? String)
            #expect(commandLine.contains("bunshin-hook"), "la commande de \(event) appelle le binaire helper")
            #expect(commandLine.contains("jeton-secret-42"), "le token de session voyage avec \(event)")
            #expect(commandLine.contains("/tmp/bunshin.sock"), "le helper de \(event) connaît le socket")
        }
    }

    @Test("la Reprise relance la session native par son UUID (UC-7)")
    func repriseParUuid() {
        let id = SessionID()
        let command = ClaudeCodeAdapter().resumeCommand(session: id)
        #expect(command.executable == "claude")
        #expect(command.arguments == ["--resume", id.rawValue.uuidString])
    }

    @Test("les payloads de hooks deviennent les événements du réducteur (STA-01)")
    func payloadsDeviennentDesEvenements() throws {
        func payload(_ fields: [String: Any]) -> Data {
            var base: [String: Any] = ["session_id": "abc", "cwd": "/tmp"]
            base.merge(fields) { _, new in new }
            return try! JSONSerialization.data(withJSONObject: base)
        }

        #expect(ClaudeCodeAdapter.interpret(payload(["hook_event_name": "UserPromptSubmit"]))
                == .hook(.userPromptSubmit))
        #expect(ClaudeCodeAdapter.interpret(payload([
            "hook_event_name": "Stop",
            "last_assistant_message": "Deux options s'offrent à nous. Laquelle préfères-tu ?",
        ])) == .hook(.stop(awaitsReply: true)), "Stop + question = needs_input, via le classifieur")
        #expect(ClaudeCodeAdapter.interpret(payload([
            "hook_event_name": "Stop",
            "last_assistant_message": "Correctif appliqué, tests verts.",
        ])) == .hook(.stop(awaitsReply: false)))
        #expect(ClaudeCodeAdapter.interpret(payload(["hook_event_name": "PermissionRequest"]))
                == .hook(.permissionRequested))
        #expect(ClaudeCodeAdapter.interpret(payload([
            "hook_event_name": "Notification", "notification_type": "permission_prompt",
        ])) == .hook(.permissionRequested))
        #expect(ClaudeCodeAdapter.interpret(payload([
            "hook_event_name": "Notification", "notification_type": "auth_success",
        ])) == nil, "une notification sans valeur d'état est ignorée")
        #expect(ClaudeCodeAdapter.interpret(Data("pas du json".utf8)) == nil,
                "un payload corrompu ne produit jamais de transition")
    }
}
