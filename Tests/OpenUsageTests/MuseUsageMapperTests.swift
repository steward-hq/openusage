import XCTest
@testable import OpenUsage

final class MuseUsageMapperTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    func testMapsRealZeroAndBothResetFormats() throws {
        let now = date(2026, 9, 7, 22, 0)
        let text = """
        Current usage
        0%
        Resets at 2:52 AM
        Weekly limit
        29%
        Resets Sep 13 at 8:00 PM
        """

        let lines = try MuseUsageMapper.lines(from: text, now: now, calendar: calendar)

        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(progress(lines[0])?.label, "Session")
        XCTAssertEqual(progress(lines[0])?.used, 0)
        XCTAssertEqual(progress(lines[0])?.resetsAt, date(2026, 9, 8, 2, 52))
        XCTAssertEqual(progress(lines[0])?.periodDurationMs, MetricPeriod.sessionMs)
        XCTAssertEqual(progress(lines[1])?.label, "Weekly")
        XCTAssertEqual(progress(lines[1])?.used, 29)
        XCTAssertEqual(progress(lines[1])?.resetsAt, date(2026, 9, 13, 20, 0))
        XCTAssertEqual(progress(lines[1])?.periodDurationMs, MetricPeriod.weekMs)
    }

    func testClampsPercentagesAndRollsWeeklyResetIntoNextYear() throws {
        let now = date(2026, 12, 31, 22, 0)
        let text = """
        Current usage 123.5%
        Resets at 11:30 PM
        Weekly limit -4%
        Resets Jan 2 at 8:00 PM
        """

        let lines = try MuseUsageMapper.lines(from: text, now: now, calendar: calendar)

        XCTAssertEqual(progress(lines[0])?.used, 100)
        XCTAssertEqual(progress(lines[1])?.used, 0)
        XCTAssertEqual(progress(lines[1])?.resetsAt, date(2027, 1, 2, 20, 0))
    }

    func testPartialPageKeepsValidMeterWithoutFabricatingMalformedOne() throws {
        let lines = try MuseUsageMapper.lines(
            from: "Current usage 42%\nResets at 3:15 PM\nWeekly limit unavailable",
            now: date(2026, 9, 7, 12, 0),
            calendar: calendar
        )

        XCTAssertEqual(lines.map(\.label), ["Session"])
        XCTAssertEqual(progress(lines[0])?.used, 42)
    }

    func testPageWithoutAnyUsableQuotaIsInvalid() {
        XCTAssertThrowsError(
            try MuseUsageMapper.lines(
                from: "Current usage unavailable\nWeekly limit unavailable",
                now: date(2026, 9, 7, 12, 0),
                calendar: calendar
            )
        ) { error in
            XCTAssertEqual(error as? MuseDashboardUsageError, .invalidPage)
        }
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(
            calendar: calendar, timeZone: calendar.timeZone,
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    private func progress(
        _ line: MetricLine
    ) -> (label: String, used: Double, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(let label, let used, _, _, let resetsAt, let periodDurationMs, _) = line else {
            return nil
        }
        return (label, used, resetsAt, periodDurationMs)
    }
}
