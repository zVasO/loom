import Testing
import LoomCore
import Foundation

// Seam: the calendar-day keys, in UTC so they stay deterministic.

@Suite("UsageDay — civil-day keys")
struct UsageDayTests {

    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    @Test("the last 7 keys span a month change, oldest first")
    func fenetreSurDeuxMois() {
        let sep3 = Date(timeIntervalSince1970: 1_788_436_800)   // 2026-09-03 12:00 UTC
        #expect(UsageDay.keys(lastDays: 7, endingAt: sep3, calendar: utc) == [
            "2026-08-28", "2026-08-29", "2026-08-30", "2026-08-31",
            "2026-09-01", "2026-09-02", "2026-09-03",
        ])
    }

    @Test("a key reads back as a midnight date in the same calendar")
    func allerRetour() {
        let date = UsageDay.date(forKey: "2026-02-28", calendar: utc)
        #expect(date.map { UsageDay.key(for: $0, calendar: utc) } == "2026-02-28")
        #expect(UsageDay.date(forKey: "not-a-day", calendar: utc) == nil)
    }
}
