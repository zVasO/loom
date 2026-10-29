import Testing
import Foundation
import LoomCore
@testable import LoomGit

// A schedule an agent proposed waits on the person (ADR-0020).
@Suite("Review schedules — agents' proposals")
struct ReviewScheduleProposalTests {

    @Test("a proposed schedule does not run; a changed one runs as validated, and remembers it ran")
    func schedules() {
        let project = ProjectID(UUID())
        let validated = ReviewSchedule(name: "Morning", targets: [ReviewScheduleTarget(projectID: project)])
        var changed = validated
        changed.hour = 7
        let created = ReviewSchedule.proposing(ReviewSchedule(name: "Agent's"), over: nil, by: "agent")
        var state = ReviewScheduleState(schedules: [ReviewSchedule.proposing(changed, over: validated, by: "agent"), created])
        #expect(state.runnable.map(\.name) == ["Morning"])
        #expect(state.runnable.first?.hour == 9)
        let now = Date()
        state.markRan(validated.id, at: now)
        #expect(state.runnable.first?.lastRunAt == now, "the validated version remembers the run")
        #expect(state.schedules[0].lastRunAt == now)
    }

}
