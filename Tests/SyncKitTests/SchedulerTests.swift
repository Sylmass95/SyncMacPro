import XCTest
@testable import SyncKit

final class SchedulerTests: XCTestCase {
    let paris: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()

    func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        paris.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func due(_ schedule: Schedule, after basis: Date?, now: Date? = nil) -> Date? {
        Scheduler.nextDue(for: schedule, after: basis, now: now ?? basis ?? Date(), calendar: paris)
    }

    func testManualAndWhenAvailableHaveNoCalendarDueDate() {
        XCTAssertNil(due(.manual, after: at(2026, 10, 12, 9)))
        XCTAssertNil(due(.whenAvailable, after: at(2026, 10, 12, 9)))
    }

    func testEveryMinutesRunsImmediatelyTheFirstTime() {
        let now = at(2026, 10, 12, 9)
        XCTAssertEqual(due(.everyMinutes(30), after: nil, now: now), now)
    }

    func testEveryMinutesAddsTheIntervalToTheLastStart() {
        let last = at(2026, 10, 12, 9)
        XCTAssertEqual(due(.everyMinutes(30), after: last), at(2026, 10, 12, 9, 30))
    }

    func testDailyTakesTodayIfTheTimeIsStillAhead() {
        XCTAssertEqual(due(.daily(hour: 3, minute: 0), after: at(2026, 10, 12, 1)), at(2026, 10, 12, 3))
    }

    func testDailyTakesTomorrowIfTheTimeHasPassed() {
        XCTAssertEqual(due(.daily(hour: 3, minute: 0), after: at(2026, 10, 12, 9)), at(2026, 10, 13, 3))
    }

    func testDailyIsStrictlyAfterTheBasis() {
        XCTAssertEqual(due(.daily(hour: 3, minute: 0), after: at(2026, 10, 12, 3)), at(2026, 10, 13, 3))
    }

    func testWeekdaysPicksTheEarliestSelectedDay() {
        // 2026-10-12 est un lundi ; Calendar : dimanche = 1, lundi = 2, vendredi = 6.
        let schedule = Schedule.weekdays(days: [2, 6], hour: 8, minute: 0)
        XCTAssertEqual(due(schedule, after: at(2026, 10, 12, 7)), at(2026, 10, 12, 8))
        XCTAssertEqual(due(schedule, after: at(2026, 10, 12, 9)), at(2026, 10, 16, 8))
    }

    func testWeekdaysWithNoDayNeverRuns() {
        XCTAssertNil(due(.weekdays(days: [], hour: 8, minute: 0), after: at(2026, 10, 12, 7)))
    }

    func testSpringForwardDoesNotSkipTheDailyRun() throws {
        // 2026-03-29 : à 02:00 il est 03:00 ; 02:30 n'existe pas ce jour-là.
        let schedule = Schedule.daily(hour: 2, minute: 30)
        let first = try XCTUnwrap(due(schedule, after: at(2026, 3, 28, 3)))
        XCTAssertEqual(paris.component(.day, from: first), 29)
        let second = try XCTUnwrap(due(schedule, after: first))
        XCTAssertEqual(second, at(2026, 3, 30, 2, 30))
    }

    func testFallBackDoesNotRunTheDailyTaskTwice() throws {
        // 2026-10-25 : 02:30 existe deux fois ; une seule exécution.
        let schedule = Schedule.daily(hour: 2, minute: 30)
        let first = try XCTUnwrap(due(schedule, after: at(2026, 10, 24, 12)))
        XCTAssertEqual(paris.component(.day, from: first), 25)
        let second = try XCTUnwrap(due(schedule, after: first))
        XCTAssertEqual(paris.component(.day, from: second), 26)
    }
}
