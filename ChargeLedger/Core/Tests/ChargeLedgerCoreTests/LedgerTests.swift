import XCTest
@testable import ChargeLedgerCore

final class LedgerTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text + "T09:00:00Z")!
    }
    private func d(_ text: String) -> Decimal { Decimal(string: text)! }

    func testJanuaryMatchesSpreadsheet() throws {
        let start = Reading(date: date("2026-01-01"), t1: d("184.77"), t2: d("367.16"),
                            monthBoundary: date("2026-01-01"), isBaseline: true)
        let end = Reading(date: date("2026-02-01"), t1: d("467.19"), t2: d("821.72"),
                          monthBoundary: date("2026-02-01"), tripA: 2183)
        let month = try XCTUnwrap(Ledger.months(readings: [start, end], charges: [], calendar: calendar).first)
        XCTAssertEqual(month.homeEnergy, d("736.98"))
        XCTAssertEqual(month.estimatedHomeCost, d("35006.55"))
        XCTAssertEqual(month.tariffComparisonCost, d("34868.0904"))
        XCTAssertEqual(Numbers.double(try XCTUnwrap(month.energyPer100KM)), 33.75996335, accuracy: 0.000001)
    }

    func testMonthlyReadingDoesNotCloseTripBCycle() throws {
        let start = Reading(date: date("2026-01-20"), t1: 100, t2: 200,
                            closesCycle: true, isBaseline: true, battery: 100)
        let boundary = Reading(date: date("2026-02-01"), t1: 120, t2: 230,
                               monthBoundary: date("2026-02-01"), tripA: 300, battery: 60)
        let end = Reading(date: date("2026-02-05"), t1: 140, t2: 260,
                          closesCycle: true, tripB: 500, battery: 100)
        let partial = Charge(date: date("2026-01-25"), energy: 10, cost: 1000)
        let full = Charge(date: end.date, energy: 20, cost: 2000)
        let after = Charge(date: date("2026-02-06"), energy: 50, cost: 5000)
        let cycles = Ledger.cycles(readings: [end, start, boundary], charges: [partial, full, after])
        XCTAssertEqual(cycles.count, 1)
        let cycle = try XCTUnwrap(cycles.first)
        XCTAssertEqual(cycle.distance, 500)
        XCTAssertEqual(cycle.homeEnergy, 100)
        XCTAssertEqual(cycle.outsideEnergy, 30)
        XCTAssertEqual(cycle.outsideCost, 3000)
        XCTAssertEqual(cycle.energyPer100KM, 26)
    }

    func testOutsideChargeAtBoundaryBelongsOnlyToEndingCycle() throws {
        let a = Reading(date: date("2026-01-01"), t1: 0, t2: 0, closesCycle: true, isBaseline: true, battery: 100)
        let b = Reading(date: date("2026-01-10"), t1: 0, t2: 0, closesCycle: true, tripB: 100, battery: 100)
        let c = Reading(date: date("2026-01-20"), t1: 0, t2: 0, closesCycle: true, tripB: 100, battery: 100)
        let charges = [Charge(date: a.date, energy: 99, cost: 999), Charge(date: b.date, energy: 20, cost: 200)]
        let cycles = Ledger.cycles(readings: [a, b, c], charges: charges)
        XCTAssertEqual(cycles[0].outsideEnergy, 20)
        XCTAssertEqual(cycles[1].outsideEnergy, 0)
    }

    func testEachRecordPriceAppliesToItsOwnMeterSegment() throws {
        let a = Reading(date: date("2026-01-01"), t1: 100, t2: 0, closesCycle: true, isBaseline: true, battery: 100)
        let b = Reading(date: date("2026-01-05"), t1: 150, t2: 0, averageRate: 40)
        let c = Reading(date: date("2026-01-10"), t1: 200, t2: 0, averageRate: 60,
                        closesCycle: true, tripB: 1000, battery: 100)
        let cycle = try XCTUnwrap(Ledger.cycles(readings: [a, b, c], charges: []).first)
        XCTAssertEqual(cycle.estimatedHomeCost, 5000)
    }

    func testTariffPricingCanBeChosenPerRecord() throws {
        let a = Reading(date: date("2026-01-01"), t1: 100, t2: 100, closesCycle: true, isBaseline: true, battery: 100)
        let b = Reading(date: date("2026-01-10"), t1: 110, t2: 120, averageRate: 99,
                        t1Rate: 5, t2Rate: 3, useTariffRates: true, closesCycle: true, tripB: 100, battery: 100)
        XCTAssertEqual(Ledger.cycles(readings: [a, b], charges: []).first?.estimatedHomeCost, 110)
    }

    func testMissingMonthlyBoundaryIsNotInvented() {
        let a = Reading(date: date("2026-01-01"), t1: 0, t2: 0, monthBoundary: date("2026-01-01"), isBaseline: true)
        let b = Reading(date: date("2026-03-01"), t1: 100, t2: 0, monthBoundary: date("2026-03-01"), tripA: 500)
        XCTAssertTrue(Ledger.months(readings: [a, b], charges: [], calendar: calendar).isEmpty)
    }

    func testLateMonthlyEntryUsesActualReadingTimes() throws {
        let a = Reading(date: date("2026-01-03"), t1: 0, t2: 0, monthBoundary: date("2026-01-01"), isBaseline: true)
        let b = Reading(date: date("2026-02-04"), t1: 100, t2: 0, monthBoundary: date("2026-02-01"), tripA: 500)
        let charge = Charge(date: date("2026-02-02"), energy: 10, cost: 100)
        let month = try XCTUnwrap(Ledger.months(readings: [a, b], charges: [charge], calendar: calendar).first)
        XCTAssertEqual(month.start, a.date)
        XCTAssertEqual(month.end, b.date)
        XCTAssertEqual(month.month, a.monthBoundary)
        XCTAssertEqual(month.outsideEnergy, 10)
    }

    func testWeightedConsumptionUsesTotalDistance() throws {
        let a = Reading(date: date("2026-01-01"), t1: 0, t2: 0, closesCycle: true, isBaseline: true, battery: 100)
        let b = Reading(date: date("2026-01-10"), t1: 50, t2: 0, closesCycle: true, tripB: 100, battery: 100)
        let c = Reading(date: date("2026-01-20"), t1: 140, t2: 0, closesCycle: true, tripB: 900, battery: 100)
        XCTAssertEqual(Ledger.weightedEfficiency(Ledger.cycles(readings: [a, b, c], charges: [])), 14)
    }

    func testMonthIdentifiersRemainConsecutiveAcrossTimeZoneChanges() {
        let firstMonth = ISO8601DateFormatter().date(from: "2026-03-01T12:00:00Z")!
        let nextMonth = ISO8601DateFormatter().date(from: "2026-04-01T12:00:00Z")!
        let a = Reading(date: date("2026-03-01"), t1: 0, t2: 0, monthBoundary: firstMonth, isBaseline: true)
        let b = Reading(date: date("2026-04-01"), t1: 100, t2: 0, monthBoundary: nextMonth, tripA: 500)
        XCTAssertEqual(Ledger.months(readings: [a, b], charges: []).count, 1)
        XCTAssertEqual(Ledger.monthCalendar.timeZone.secondsFromGMT(), 0)
    }

    func testZeroDistanceDoesNotDivideByZero() throws {
        let a = Reading(date: date("2026-01-01"), t1: 0, t2: 0, closesCycle: true, isBaseline: true, battery: 100)
        let b = Reading(date: date("2026-01-10"), t1: 10, t2: 0, closesCycle: true, tripB: 0, battery: 100)
        let summary = try XCTUnwrap(Ledger.cycles(readings: [a, b], charges: []).first)
        XCTAssertNil(summary.energyPer100KM)
        XCTAssertNil(summary.costPerKM)
    }

    func testBackdatedReadingChecksBothNeighbors() {
        let a = Reading(date: date("2026-01-01"), t1: 100, t2: 100)
        let c = Reading(date: date("2026-01-20"), t1: 200, t2: 200)
        XCTAssertNotNil(Ledger.validate(Reading(date: date("2026-01-10"), t1: 99, t2: 150), against: [a, c]))
        XCTAssertNotNil(Ledger.validate(Reading(date: date("2026-01-10"), t1: 150, t2: 201), against: [a, c]))
        XCTAssertNil(Ledger.validate(Reading(date: date("2026-01-10"), t1: 150, t2: 150), against: [a, c]))
    }

    func testDuplicateMonthsAndBadBatteryAreRejected() {
        let a = Reading(date: date("2026-01-01"), t1: 100, t2: 100, monthBoundary: date("2026-01-01"), isBaseline: true)
        let duplicate = Reading(date: date("2026-01-02"), t1: 101, t2: 100, monthBoundary: a.monthBoundary, tripA: 0)
        XCTAssertNotNil(Ledger.validate(duplicate, against: [a]))
        XCTAssertNotNil(Ledger.validate(Reading(date: date("2026-01-03"), t1: 101, t2: 100, battery: 101), against: [a]))
        XCTAssertNotNil(Ledger.validate(Reading(date: date("2026-01-03"), t1: 101, t2: 100, closesCycle: true, tripB: 10, battery: 90), against: [a]))
    }

    func testDecimalKeyboardInputIsStrictAndLocaleFriendly() {
        XCTAssertEqual(Numbers.parse(" 47,50 "), d("47.5"))
        XCTAssertEqual(Numbers.parse("0"), 0)
        for value in ["", "-1", "1,234.50", "1.2.3", "1e3", "NaN", "47 AMD", "12%"] {
            XCTAssertNil(Numbers.parse(value), "Unexpectedly accepted \(value)")
        }
    }
}
