import Testing
import LoomCore
import LoomTerminal
import LoomTerminalTestSupport
import Foundation

// Tests au seam convenu : l'interface publique de SessionRuntime, via ScriptedPTYHost.
// Aucun test ne franchit la queue de session ni ne touche le moteur.

@Suite("SessionRuntime — cycle de vie")
struct SessionRuntimeTests {

    @Test("launch démarre l'agent et émet .started en premier")
    func launchEmetStarted() async throws {
        let pty = ScriptedPTYHost()
        let (_, events) = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree")),
            using: SessionRuntime.Dependencies(ptyHost: pty, transcript: MemoryTranscriptSink()))

        var iterator = events.makeAsyncIterator()
        guard case .started = await iterator.next() else {
            Issue.record("le premier événement doit être .started")
            return
        }
    }

    @Test("l'exit conclut : transcript complet et flushé avant .terminated, flux terminé après")
    func exitConclutAvecTranscriptComplet() async throws {
        let pty = ScriptedPTYHost()
        let transcript = MemoryTranscriptSink()
        let (_, events) = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree")),
            using: SessionRuntime.Dependencies(ptyHost: pty, transcript: transcript))

        var iterator = events.makeAsyncIterator()
        guard case .started = await iterator.next() else {
            Issue.record("pas de .started")
            return
        }

        pty.emit("Analyse du dépôt…\r\n")
        pty.emit("Correctif appliqué, 42 tests verts.\r\n")
        pty.exit(code: 0)

        guard case .terminated(let report) = await iterator.next() else {
            Issue.record("l'exit du process doit émettre .terminated")
            return
        }
        #expect(report.exitStatus.code == 0)
        #expect(transcript.isFinished, "le transcript est flushé et fermé AVANT .terminated (NFR-R)")
        #expect(transcript.text.contains("42 tests verts"),
                "aucun octet émis avant l'exit ne manque au transcript")
        #expect(await iterator.next() == nil, "le flux se termine juste après .terminated")
    }

    @Test("un agent sourd à SIGINT et SIGTERM finit SIGKILLé, dans l'ordre de l'échelle (SES-06)")
    func escaladeJusquAuKill() async throws {
        let pty = ScriptedPTYHost()
        pty.onSignal = { signal, host in
            if case .kill = signal { host.exit(bySignal: 9) }   // seul SIGKILL a raison de lui
        }
        let (runtime, _) = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree")),
            using: SessionRuntime.Dependencies(ptyHost: pty, transcript: MemoryTranscriptSink()))

        let ladder = ShutdownLadder(steps: [
            .init(signal: .interrupt, scope: .process, grace: .milliseconds(20)),
            .init(signal: .terminate, scope: .group, grace: .milliseconds(20)),
            .init(signal: .kill, scope: .group, grace: .milliseconds(200)),
        ])
        let report = await runtime.stop(ladder)

        // SES-06 : SIGINT gracieux à l'agent seul, l'escalade frappe le groupe entier.
        #expect(pty.receivedSignals == [
            .init(signal: .interrupt, scope: .process),
            .init(signal: .terminate, scope: .group),
            .init(signal: .kill, scope: .group),
        ])
        #expect(report.exitStatus.code == nil)
        #expect(report.exitStatus.signal == 9)
    }

    @Test("l'escalade s'arrête dès que l'agent sort")
    func escaladeInterrompueParLaSortie() async throws {
        let pty = ScriptedPTYHost()
        pty.onSignal = { signal, host in
            if case .interrupt = signal { host.exit(code: 130) }   // agent poli
        }
        let (runtime, _) = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree")),
            using: SessionRuntime.Dependencies(ptyHost: pty, transcript: MemoryTranscriptSink()))

        let report = await runtime.stop(.graceful)

        #expect(pty.receivedSignals == [.init(signal: .interrupt, scope: .process)],
                "ni SIGTERM ni SIGKILL pour un agent qui obéit, et le SIGINT ne frappe que l'agent")
        #expect(report.exitStatus.code == 130)
    }

    @Test("les octets du PTY alimentent le moteur ; snapshot() rend l'écran courant")
    func snapshotRefleteLEcran() async throws {
        let pty = ScriptedPTYHost()
        let (runtime, events) = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree")),
            using: SessionRuntime.Dependencies(ptyHost: pty,
                                               transcript: MemoryTranscriptSink(),
                                               makeEngine: { geometry, _ in LineEngine(geometry: geometry) }))
        var iterator = events.makeAsyncIterator()
        guard case .started = await iterator.next() else {
            Issue.record("pas de .started")
            return
        }

        pty.emit("Analyse du dépôt…\r\n")
        pty.emit("Correctif appliqué.")

        let screen = await runtime.snapshot()
        let texts = screen.lines.map(\.text)
        #expect(texts.contains("Analyse du dépôt…"))
        #expect(texts.contains("Correctif appliqué."), "le dernier chunk est déjà parsé au retour du snapshot")
    }

    @Test("sans configuration, le moteur de production parse la sortie (défaut SwiftTerm)")
    func moteurParDefaut() async throws {
        let pty = ScriptedPTYHost()
        let (runtime, events) = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree")),
            using: SessionRuntime.Dependencies(ptyHost: pty, transcript: MemoryTranscriptSink()))
        var iterator = events.makeAsyncIterator()
        guard case .started = await iterator.next() else {
            Issue.record("pas de .started")
            return
        }

        pty.emit("\u{1B}[32mprêt\u{1B}[0m")
        let screen = await runtime.snapshot()
        #expect(screen.lines[0].text.hasPrefix("prêt"), "le défaut n'est pas un écran vierge : SwiftTerm parse")
        #expect(screen.lines[0].cells[0].style.foreground == .ansi(2))
    }

    @Test("le runtime échantillonne : octets, silence, queue d'écran (STA-02)")
    func echantillonnageHeuristique() async throws {
        let pty = ScriptedPTYHost()
        var plan = SessionLaunchPlan(command: Command(executable: "/fake/codex"),
                                     workingDirectory: URL(fileURLWithPath: "/tmp/worktree"))
        plan.samplingInterval = .milliseconds(30)
        let (_, events) = try SessionRuntime.launch(
            plan,
            using: SessionRuntime.Dependencies(ptyHost: pty,
                                               transcript: MemoryTranscriptSink(),
                                               makeEngine: { geometry, _ in LineEngine(geometry: geometry) }))

        pty.emit("invite $ ")

        var sawActivity = false
        var sawQuietTail = false
        for await event in events {
            if case .activity(let sample) = event {
                sawActivity = true
                if sample.bytesSinceLastSample == 0,
                   sample.silence >= .milliseconds(30),
                   sample.visibleTail.last?.hasPrefix("invite $") == true {
                    sawQuietTail = true
                    break
                }
            }
        }
        #expect(sawActivity, "des échantillons arrivent sur le flux d'événements")
        #expect(sawQuietTail, "après le calme : zéro octet, silence mesuré, motif d'invite visible")
    }

    @Test("des octets tardifs après l'exit sont drainés avant la conclusion (course EOF/exit)")
    func drainageAvantConclusion() async throws {
        let pty = ScriptedPTYHost()
        let transcript = MemoryTranscriptSink()
        let (_, events) = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree")),
            using: SessionRuntime.Dependencies(ptyHost: pty, transcript: transcript))
        var iterator = events.makeAsyncIterator()
        guard case .started = await iterator.next() else {
            Issue.record("pas de .started")
            return
        }

        // Ordre adverse documenté par la recherche (§7.4) : l'exit arrive AVANT
        // les derniers octets du PTY, l'EOF ferme la marche.
        pty.deliverTerminated(code: 0)
        pty.emit("dernier lot d'octets en vol")
        pty.emitEOF()

        guard case .terminated = await iterator.next() else {
            Issue.record("pas de .terminated")
            return
        }
        #expect(transcript.text.contains("dernier lot d'octets en vol"),
                "les octets en vol après l'exit font partie du transcript")
        #expect(!transcript.appendedAfterFinish,
                "aucun octet n'est écrit après la fermeture du transcript (barrière)")
        #expect(pty.closeCount == 1, "le canal PTY est fermé à la conclusion")
    }

    @Test("deux stop() concurrents ne rejouent pas l'échelle : un seul SIGINT part")
    func stopConcurrentsSingleFlight() async throws {
        let pty = ScriptedPTYHost()
        pty.onSignal = { signal, host in
            guard case .interrupt = signal else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(30)) {
                host.exit(code: 130)
            }
        }
        let (runtime, _) = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree")),
            using: SessionRuntime.Dependencies(ptyHost: pty, transcript: MemoryTranscriptSink()))

        async let first = runtime.stop(.graceful)     // confirmation utilisateur
        async let second = runtime.stop(.graceful)    // fermeture de l'app au même moment
        let (r1, r2) = await (first, second)

        #expect(pty.receivedSignals == [.init(signal: .interrupt, scope: .process)],
                "le second appel attend l'issue du premier, il ne re-signale pas")
        #expect(r1.exitStatus.code == 130)
        #expect(r2.exitStatus.code == 130, "tous les appelants reçoivent le même rapport")
    }

    @Test("stop() annulé n'invente pas d'issue : il attend la vraie sortie")
    func stopAnnuleAttendLaVraieSortie() async throws {
        let pty = ScriptedPTYHost()
        pty.onSignal = { signal, host in
            if case .kill = signal { host.exit(bySignal: 9) }
        }
        let (runtime, _) = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude"),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree")),
            using: SessionRuntime.Dependencies(ptyHost: pty, transcript: MemoryTranscriptSink()))

        let ladder = ShutdownLadder(steps: [
            .init(signal: .interrupt, scope: .process, grace: .milliseconds(50)),
            .init(signal: .kill, scope: .group, grace: .milliseconds(200)),
        ])
        let stopTask = Task { await runtime.stop(ladder) }
        try await Task.sleep(for: .milliseconds(10))
        stopTask.cancel()

        let report = await stopTask.value
        #expect(report.exitStatus.signal == 9,
                "malgré l'annulation de la tâche, le rapport est l'issue réelle du process")
    }

    @Test("l'environnement enfant est complet : PATH garanti, l'overlay de la session gagne")
    func environnementCompletAvecPath() async throws {
        let pty = ScriptedPTYHost()
        _ = try SessionRuntime.launch(
            SessionLaunchPlan(command: Command(executable: "/fake/claude",
                                               environment: ["LOOM_EXTRA": "oui", "LANG": "fr_FR.UTF-8"]),
                              workingDirectory: URL(fileURLWithPath: "/tmp/worktree")),
            using: SessionRuntime.Dependencies(ptyHost: pty, transcript: MemoryTranscriptSink()))

        #expect(pty.openedEnvironment["PATH"]?.isEmpty == false,
                "SwiftTerm omet PATH ; le runtime doit le garantir (recherche §7.3)")
        #expect(pty.openedEnvironment["LOOM_EXTRA"] == "oui", "les variables de la session passent")
        #expect(pty.openedEnvironment["LANG"] == "fr_FR.UTF-8", "l'overlay gagne sur la base en cas de collision")
        #expect(pty.openedEnvironment["TERM"] == "xterm-256color", "la base terminal est posée")
    }
}
