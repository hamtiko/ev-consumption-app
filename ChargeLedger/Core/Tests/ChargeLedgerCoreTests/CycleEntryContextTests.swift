import Foundation
import XCTest
@testable import ChargeLedgerCore

final class CycleEntryContextTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value + "T12:00:00Z")! }
    private func full(_ day: String, counter: Decimal, distance: Decimal? = nil, known: Bool = true) -> Reading {
        Reading(date: date(day), t1: 0, t2: 0, closesCycle: true, tripB: distance, battery: 100,
                hasMeterReading: known, meterTotal: counter)
    }

    func testContextUsesLastFullChargeInsteadOfMonthlyMeterAndKeepsEarlierCycleDetails() throws {
        let start = full("2026-10-12", counter: 1000)
        let end = full("2026-10-20", counter: 1100, distance: Decimal(string: "426.6"))
        let monthly = Reading(date: date("2026-10-22"), t1: 0, t2: 0, meterTotal: 1110)
        let context = CycleEntryContext(endingAt: date("2026-10-27"), readings: [monthly, end, start], charges: [])
        XCTAssertEqual(context.previousCheckpoint?.id, end.id)
        XCTAssertEqual(context.start, end.date)
        let summary = try XCTUnwrap(context.previousCycle)
        XCTAssertEqual(summary.start, start.date); XCTAssertEqual(summary.end, end.date)
        XCTAssertEqual(summary.distance, Decimal(string: "426.6"))
        XCTAssertEqual(summary.totalEnergy, 100)
    }

    func testSessionsUseActualChargingDatesAndExcludeStartButIncludeEnd() throws {
        let start = full("2026-07-12", counter: 1000)
        let previous = full("2026-07-25", counter: 1100, distance: 400)
        let current = date("2026-08-10")
        let atStart = Charge(date: previous.date, energy: 5, cost: 0)
        let july = Charge(date: date("2026-07-27"), energy: Decimal(string: "32.2")!, cost: 3600)
        let atEnd = Charge(date: current, energy: Decimal(string: "20.5")!, cost: 2000)
        let later = Charge(date: date("2026-08-11"), energy: 99, cost: 9999)
        let monthly = Reading(date: date("2026-08-01"), t1: 0, t2: 0, meterTotal: 1120)
        let context = CycleEntryContext(endingAt: current, readings: [start, previous, monthly],
                                       charges: [later, july, atEnd, atStart])
        XCTAssertEqual(context.outsideSessions.map(\.id), [july.id, atEnd.id])
        XCTAssertEqual(context.outsideEnergy, Decimal(string: "52.7")); XCTAssertEqual(context.outsideCost, 5600)
        XCTAssertEqual(context.previousCycleSessions.map(\.id), [atStart.id])
        XCTAssertFalse(context.contains(previous.date)); XCTAssertTrue(context.contains(current))
    }

    func testBackdatedEntryExcludesTheEditedCheckpointAndLaterCycles() {
        let first = full("2026-10-01", counter: 100)
        let previous = full("2026-10-10", counter: 200, distance: 300)
        let edited = full("2026-10-20", counter: 300, distance: 400)
        let future = full("2026-10-27", counter: 400, distance: 500)
        let context = CycleEntryContext(endingAt: date("2026-10-22"), excludingCheckpointID: edited.id,
                                       readings: [future, edited, previous, first], charges: [])
        XCTAssertEqual(context.previousCheckpoint?.id, previous.id)
        XCTAssertEqual(context.previousCycle?.id, previous.id)
        XCTAssertEqual(context.previousCycle?.distance, 300)
    }

    func testFirstRecordDoesNotInventCycleOrUseAFutureBaseline() {
        let future = Reading(date: date("2026-11-01"), t1: 0, t2: 0, isBaseline: true, meterTotal: 100)
        let before = Charge(date: date("2026-10-20"), energy: 10, cost: 500)
        let after = Charge(date: date("2026-11-02"), energy: 20, cost: 1000)
        let context = CycleEntryContext(endingAt: date("2026-10-27"), readings: [future], charges: [before, after])
        XCTAssertNil(context.start); XCTAssertNil(context.previousCycle); XCTAssertNil(context.previousCheckpoint)
        XCTAssertEqual(context.outsideSessions.map(\.id), [before.id])
    }

    func testOneEarlierCheckpointShowsReferenceWithoutInventingACompletedCycle() {
        let previous = full("2026-10-20", counter: 100, distance: 200)
        let context = CycleEntryContext(endingAt: date("2026-10-27"), readings: [previous], charges: [])
        XCTAssertEqual(context.previousCheckpoint?.id, previous.id)
        XCTAssertNil(context.previousCycle)
    }

    func testPendingPreviousCycleStillProvidesDistanceAndSavedSessions() throws {
        let start = full("2026-10-12", counter: 100)
        let previous = full("2026-10-20", counter: 0, distance: 400, known: false)
        let session = Charge(date: date("2026-10-15"), energy: 30, cost: 2000)
        let context = CycleEntryContext(endingAt: date("2026-10-27"), readings: [start, previous], charges: [session])
        let summary = try XCTUnwrap(context.previousCycle)
        XCTAssertFalse(summary.homeEnergyKnown); XCTAssertEqual(summary.distance, 400)
        XCTAssertEqual(context.previousCycleSessions.map(\.id), [session.id])
        XCTAssertTrue(context.outsideSessions.isEmpty)
    }

    func testReferenceMatchesExistingReportWithIntermediatePrices() throws {
        let start = full("2026-10-12", counter: 1000)
        let middle = Reading(date: date("2026-10-16"), t1: 0, t2: 0, averageRate: 50, meterTotal: 1050)
        let previous = full("2026-10-20", counter: 1100, distance: 400)
        let future = full("2026-10-29", counter: 1200, distance: 500)
        let session = Charge(date: date("2026-10-18"), energy: 30, cost: 2000)
        let readings = [start, middle, previous, future]
        let expected = try XCTUnwrap(Ledger.cycles(readings: readings, charges: [session]).first)
        let reference = try XCTUnwrap(CycleEntryContext(endingAt: date("2026-10-27"), readings: readings,
                                                       charges: [session]).previousCycle)
        XCTAssertEqual(reference.totalEnergy, expected.totalEnergy)
        XCTAssertEqual(reference.estimatedTotalCost, expected.estimatedTotalCost)
        XCTAssertEqual(reference.energyPer100KM, expected.energyPer100KM)
    }

    func testSavedEditedAndDraftSessionsAreIncludedOnceWithCurrentValues() {
        let saved = Charge(date: date("2026-10-24"), energy: 32, cost: 4000)
        let replacement = Charge(id: saved.id, date: saved.date, energy: Decimal(string: "32.2")!, cost: 3600)
        let draft = Charge(date: date("2026-10-26"), energy: Decimal(string: "20.5")!, cost: 2000)
        let combined = CycleEntryContext.combining(saved: [saved], replacingID: saved.id,
                                                  replacement: replacement, drafts: [draft, draft])
        let context = CycleEntryContext(endingAt: date("2026-10-27"),
            readings: [full("2026-10-20", counter: 100)], charges: combined)
        XCTAssertEqual(context.outsideSessions.count, 2)
        XCTAssertEqual(context.outsideEnergy, Decimal(string: "52.7"))
        XCTAssertEqual(context.outsideCost, 5600)
        XCTAssertTrue(CycleEntryContext.combining(saved: [saved], replacingID: saved.id).isEmpty)
    }

    func testCalculatorPreservesDecimalPrecisionAndCommaInput() throws {
        let result = try TripBCalculation(currentText: "960,05", previousText: "426.6")
        XCTAssertEqual(result.distance, Decimal(string: "533.45"))
        XCTAssertEqual(result.currentCounter, Decimal(string: "960.05"))
        XCTAssertEqual(result.previousCounter, Decimal(string: "426.6"))
    }

    func testRepeatedMissedResetsSubtractActualCounterInsteadOfLastCycleDistance() throws {
        let first = try TripBCalculation(currentText: "960", previousText: "426.6")
        let next = try TripBCalculation(currentCounter: 1200, previousCounter: first.currentCounter)
        XCTAssertEqual(first.distance, Decimal(string: "533.4"))
        XCTAssertEqual(next.distance, 240)
        XCTAssertNotEqual(next.distance, 1200 - first.distance)
    }

    func testZeroDistanceIsValidAndInvalidOrResetCountersAreRejected() throws {
        XCTAssertEqual(try TripBCalculation(currentText: "426.6", previousText: "426.6").distance, 0)
        for (current, previous) in [("", "100"), ("200", ""), ("bad", "100"), ("200", "-1"), ("50", "100")] {
            XCTAssertThrowsError(try TripBCalculation(currentText: current, previousText: previous))
        }
        XCTAssertThrowsError(try TripBCalculation(currentCounter: .nan, previousCounter: 0))
    }
}
