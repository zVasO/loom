import Testing
import LoomExtensions
import Foundation

// Seam: the alarm scheduler (ADR-0012) on the real clock, with delays of a
// few tens of milliseconds — the bridge's one-second minimum is the bridge's
// rule, not the scheduler's.

@MainActor
@Suite("Extensions — alarms", .serialized)
struct ExtensionAlarmsTests {

    private final class Fired {
        var names: [String] = []
    }

    private func wait(_ milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    @Test("an alarm fires once, for its own extension, and leaves the list")
    func declenchement() async throws {
        let fired = Fired()
        let scheduler = ExtensionAlarmScheduler { id, name, _ in fired.names.append(id + "/" + name) }
        try scheduler.schedule("tick", at: Date().addingTimeInterval(0.05), for: "dev.example.a")
        #expect(scheduler.alarms(for: "dev.example.a").map(\.name) == ["tick"])
        #expect(scheduler.alarms(for: "dev.example.b").isEmpty)
        await wait(300)
        #expect(fired.names == ["dev.example.a/tick"])
        #expect(scheduler.alarms(for: "dev.example.a").isEmpty)
    }

    @Test("the same name replaces the alarm; clear and clearAll cancel")
    func remplacementEtAnnulation() async throws {
        let fired = Fired()
        let scheduler = ExtensionAlarmScheduler { _, name, _ in fired.names.append(name) }
        try scheduler.schedule("tick", at: Date().addingTimeInterval(0.05), for: "dev.example.a")
        try scheduler.schedule("tick", at: Date().addingTimeInterval(10), for: "dev.example.a")
        try scheduler.schedule("gone", at: Date().addingTimeInterval(0.05), for: "dev.example.a")
        scheduler.clear("gone", for: "dev.example.a")
        try scheduler.schedule("other", at: Date().addingTimeInterval(0.05), for: "dev.example.b")
        scheduler.clearAll(for: "dev.example.b")
        await wait(300)
        #expect(fired.names.isEmpty, "the replaced, the cleared and the cleared-all never fire")
        #expect(scheduler.alarms(for: "dev.example.a").map(\.name) == ["tick"])
        scheduler.clearAll(for: "dev.example.a")
    }

    @Test("an extension holds twenty alarms at most")
    func plafond() throws {
        let scheduler = ExtensionAlarmScheduler()
        for index in 0..<BridgeAlarmParams.maxAlarms {
            try scheduler.schedule("a\(index)", at: Date().addingTimeInterval(600), for: "dev.example.a")
        }
        #expect(throws: BridgeError.self) {
            try scheduler.schedule("one-more", at: Date().addingTimeInterval(600), for: "dev.example.a")
        }
        try scheduler.schedule("a0", at: Date().addingTimeInterval(900), for: "dev.example.a")
        scheduler.clearAll(for: "dev.example.a")
    }
}
