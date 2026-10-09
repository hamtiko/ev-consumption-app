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

    func testMonthlyUtilityCostDoesNotRequireMileageOrIncludeOutsidePayment() throws {
        let start = Reading(date: date("2026-01-01"), t1: 0, t2: 0,
                            monthBoundary: date("2026-01-01"), meterTotal: 1000)
        let middle = Reading(date: date("2026-01-15"), t1: 0, t2: 0, averageRate: 50,
                             closesCycle: true, tripB: 300, battery: 100, meterTotal: 1100)
        let end = Reading(date: date("2026-02-01"), t1: 0, t2: 0, averageRate: 60,
                          monthBoundary: date("2026-02-01"), meterTotal: 1200)
        let monthly = MileageRecord(id: end.id, date: end.date, month: start.monthBoundary!, distance: 0, distanceKnown: false)
        let outside = Charge(date: date("2026-01-20"), energy: 20, cost: 3000)
        let report = try XCTUnwrap(Ledger.months(readings: [end, start, middle], charges: [outside],
                                               mileage: [monthly], sessionCalendar: calendar).first)
        XCTAssertTrue(report.homeEnergyKnown)
        XCTAssertFalse(report.distanceKnown)
        XCTAssertEqual(report.homeEnergy, 200)
        XCTAssertEqual(report.estimatedHomeCost, 11000)
        XCTAssertEqual(report.outsideCost, 3000)
        XCTAssertEqual(report.estimatedTotalCost, 14000)
        XCTAssertNil(report.energyPer100KM)
        XCTAssertNil(report.costPerKM)
        XCTAssertNil(Ledger.weightedEfficiency([report]))
    }

    func testMonthlyUtilityTariffsUseEachCounterIncreaseWithoutTripA() throws {
        let start = Reading(date: date("2026-01-01"), t1: 100, t2: 200,
                            useTariffRates: true, monthBoundary: date("2026-01-01"))
        let end = Reading(date: date("2026-02-01"), t1: 120, t2: 250, t1Rate: 60, t2Rate: 40,
                          useTariffRates: true, monthBoundary: date("2026-02-01"))
        let report = try XCTUnwrap(Ledger.months(readings: [start, end], charges: []).first)
        XCTAssertEqual(report.homeEnergy, 70)
        XCTAssertEqual(report.estimatedHomeCost, 3200)
        XCTAssertFalse(report.distanceKnown)
        XCTAssertTrue(Ledger.cycles(readings: [start, end], charges: []).isEmpty)
    }

    func testMonthlyAndCycleReadingsShareLatestKnownMeterForPrefill() {
        let cycle = Reading(date: date("2026-01-20"), t1: 0, t2: 0,
                            closesCycle: true, tripB: 300, battery: 100, meterTotal: 1000)
        let monthly = Reading(date: date("2026-02-01"), t1: 0, t2: 0,
                              monthBoundary: date("2026-02-01"), meterTotal: 1100)
        let pending = Reading(date: date("2026-02-03"), t1: 0, t2: 0, hasMeterReading: false)
        let nextCycle = Reading(date: date("2026-02-05"), t1: 0, t2: 0,
                                closesCycle: true, tripB: 400, battery: 100, meterTotal: 1200)
        let readings = [nextCycle, pending, monthly, cycle]
        XCTAssertEqual(Ledger.latestMeterReading(before: pending.date, readings: readings), monthly)
        XCTAssertEqual(Ledger.latestMeterReading(before: monthly.date, excludingID: monthly.id, readings: readings), cycle)
        XCTAssertEqual(Ledger.latestMeterReading(before: date("2026-02-10"), readings: readings), nextCycle)
        XCTAssertNil(Ledger.latestMeterReading(before: cycle.date, readings: readings))
    }

    func testMonthlyUtilityWithoutStartingBoundaryDoesNotInventCostOrDistance() throws {
        let end = Reading(date: date("2026-02-01"), t1: 0, t2: 0,
                          monthBoundary: date("2026-02-01"), meterTotal: 1200)
        let monthly = MileageRecord(id: end.id, date: end.date, month: date("2026-01-01"), distance: 0, distanceKnown: false)
        let report = try XCTUnwrap(Ledger.months(readings: [end], charges: [], mileage: [monthly], sessionCalendar: calendar).first)
        XCTAssertFalse(report.homeEnergyKnown)
        XCTAssertFalse(report.distanceKnown)
        XCTAssertNil(report.estimatedTotalCost)
        XCTAssertNil(report.costPerKM)
    }

    func testUnifiedCycleIncludesFinalOutsideChargeAndMonthlyPriceSegments() throws {
        let start = Reading(date: date("2026-01-20"), t1: 0, t2: 0, closesCycle: true,
                            isBaseline: true, battery: 100, meterTotal: 1000)
        let monthly = Reading(date: date("2026-02-01"), t1: 0, t2: 0, averageRate: 50,
                              monthBoundary: date("2026-02-01"), meterTotal: 1100)
        let end = Reading(date: date("2026-02-05"), t1: 0, t2: 0, averageRate: 60,
                          closesCycle: true, tripB: 500, battery: 100, meterTotal: 1120)
        let outside = Charge(date: end.date, energy: 30, cost: 3000)
        let report = try XCTUnwrap(Ledger.cycles(readings: [start, monthly, end], charges: [outside]).first)
        XCTAssertEqual(report.distance, 500)
        XCTAssertEqual(report.totalEnergy, 150)
        XCTAssertEqual(report.estimatedHomeCost, 6200)
        XCTAssertEqual(report.estimatedTotalCost, 9200)
        XCTAssertEqual(report.energyPer100KM, 30)
    }

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

    func testPartialChargeTripReadingDoesNotAddDistanceOrCloseCycle() throws {
        let a = Reading(date: date("2026-01-01"), t1: 0, t2: 0, closesCycle: true, isBaseline: true, battery: 100)
        let b = Reading(date: date("2026-01-10"), t1: 70, t2: 0, closesCycle: true, tripB: 500, battery: 100)
        let partial = Charge(date: date("2026-01-05"), energy: 30, cost: 1500, tripB: 240)
        XCTAssertEqual(partial.tripB, 240)
        XCTAssertTrue(Ledger.cycles(readings: [a], charges: [partial]).isEmpty)
        let cycles = Ledger.cycles(readings: [a, b], charges: [partial])
        XCTAssertEqual(cycles.count, 1)
        let cycle = try XCTUnwrap(cycles.first)
        XCTAssertEqual(cycle.distance, 500)
        XCTAssertEqual(cycle.totalEnergy, 100)
        XCTAssertEqual(cycle.energyPer100KM, 20)
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

    func testOutsideFullChargeHasPartialReportUntilHomeDataIsAdded() throws {
        let start = Reading(date: date("2026-01-01"), t1: 0, t2: 0, closesCycle: true,
                            isBaseline: true, battery: 100, meterTotal: 1000)
        let outside = Reading(date: date("2026-01-10"), t1: 0, t2: 0, closesCycle: true,
                              tripB: 500, battery: 100, hasMeterReading: false)
        let charge = Charge(date: outside.date, energy: 30, cost: 3000)
        XCTAssertNil(Ledger.validate(outside, against: [start]))
        let report = try XCTUnwrap(Ledger.cycles(readings: [start, outside], charges: [charge]).first)
        XCTAssertFalse(report.homeEnergyKnown)
        XCTAssertEqual(report.distance, 500)
        XCTAssertEqual(report.outsideEnergy, 30)
        XCTAssertEqual(report.outsideCost, 3000)
        XCTAssertNil(report.totalEnergy)
        XCTAssertNil(report.estimatedTotalCost)
        XCTAssertNil(report.energyPer100KM)
        XCTAssertEqual(report.missingHomeReadingIDs, [outside.id])
        XCTAssertNil(Ledger.weightedEfficiency([report]))
    }

    func testAddingHomeDataCompletesBothAdjacentCycles() throws {
        let start = Reading(date: date("2026-01-01"), t1: 0, t2: 0, closesCycle: true,
                            isBaseline: true, battery: 100, meterTotal: 1000)
        let pending = Reading(date: date("2026-01-10"), t1: 0, t2: 0, closesCycle: true,
                              tripB: 500, battery: 100, hasMeterReading: false)
        let end = Reading(date: date("2026-01-20"), t1: 0, t2: 0, closesCycle: true,
                          tripB: 700, battery: 100, meterTotal: 1150)
        let charges = [Charge(date: pending.date, energy: 30, cost: 3000),
                       Charge(date: date("2026-01-15"), energy: 20, cost: 1000)]
        let partial = Ledger.cycles(readings: [start, pending, end], charges: charges)
        XCTAssertTrue(partial.allSatisfy { !$0.homeEnergyKnown })
        let completed = Reading(id: pending.id, date: pending.date, t1: 0, t2: 0, closesCycle: true,
                                tripB: pending.tripB, battery: 100, meterTotal: 1100)
        XCTAssertNil(Ledger.validate(completed, against: [start, pending, end]))
        let reports = Ledger.cycles(readings: [start, completed, end], charges: charges)
        XCTAssertTrue(reports.allSatisfy(\.homeEnergyKnown))
        XCTAssertEqual(reports[0].totalEnergy, 130)
        XCTAssertEqual(reports[0].energyPer100KM, 26)
        XCTAssertEqual(reports[0].estimatedTotalCost, 7750)
        XCTAssertEqual(reports[1].totalEnergy, 70)
        XCTAssertEqual(reports[1].energyPer100KM, 10)
        XCTAssertTrue(reports.allSatisfy { $0.missingHomeReadingIDs.isEmpty })
    }

    func testNoHomeChargingCarriesForwardSingleOrTariffCounters() throws {
        let starts = [Reading(date: date("2026-01-01"), t1: 100, t2: 200, closesCycle: true, isBaseline: true, battery: 100),
                      Reading(date: date("2026-01-01"), t1: 0, t2: 0, closesCycle: true, isBaseline: true, battery: 100, meterTotal: 300)]
        for start in starts {
            let pending = Reading(date: date("2026-01-10"), t1: 0, t2: 0, closesCycle: true,
                                  tripB: 100, battery: 100, hasMeterReading: false)
            let completed = try XCTUnwrap(Ledger.carryingForwardMeter(for: pending, readings: [pending, start]))
            XCTAssertTrue(completed.hasMeterReading)
            XCTAssertEqual(completed.total, 300)
            XCTAssertEqual(completed.meterTotal, start.meterTotal)
            XCTAssertEqual(completed.id, pending.id)
            let report = try XCTUnwrap(Ledger.cycles(readings: [start, completed],
                charges: [Charge(date: pending.date, energy: 20, cost: 1000)]).first)
            XCTAssertEqual(report.homeEnergy, 0)
            XCTAssertEqual(report.totalEnergy, 20)
            XCTAssertEqual(report.energyPer100KM, 20)
            XCTAssertEqual(report.costPerKM, 10)
        }
    }

    func testCarryForwardNeverUsesFutureOrUnknownMeterValues() {
        let pending = Reading(date: date("2026-01-10"), t1: 0, t2: 0, hasMeterReading: false)
        let unknown = Reading(date: date("2026-01-01"), t1: 0, t2: 0, hasMeterReading: false)
        let future = Reading(date: date("2026-01-20"), t1: 100, t2: 100)
        XCTAssertNil(Ledger.carryingForwardMeter(for: pending, readings: [unknown, pending, future]))
    }

    func testNoHomeConfirmationCompletesAllPendingCheckpointsSinceLatestReading() throws {
        let a = Reading(date: date("2026-01-01"), t1: 0, t2: 0, closesCycle: true,
                        isBaseline: true, battery: 100, meterTotal: 1000)
        let b = Reading(date: date("2026-01-10"), t1: 0, t2: 0, closesCycle: true,
                        tripB: 300, battery: 100, hasMeterReading: false)
        let c = Reading(date: date("2026-01-20"), t1: 0, t2: 0, closesCycle: true,
                        tripB: 400, battery: 100, hasMeterReading: false)
        let completed = try XCTUnwrap(Ledger.confirmingNoHomeCharging(through: c, readings: [a, b, c]))
        XCTAssertEqual(completed.map(\.id), [b.id, c.id])
        let cycles = Ledger.cycles(readings: [a] + completed,
            charges: [Charge(date: b.date, energy: 20, cost: 1000), Charge(date: c.date, energy: 30, cost: 1500)])
        XCTAssertTrue(cycles.allSatisfy(\.homeEnergyKnown))
        XCTAssertTrue(cycles.allSatisfy { $0.homeEnergy == 0 })
        XCTAssertEqual(cycles.map(\.distance), [300, 400])
    }

    func testCompleteEnergyWindowSpansPendingOutsideCycleWithoutGuessingSplit() throws {
        let start = Reading(date: date("2026-01-01"), t1: 0, t2: 0, closesCycle: true,
                            isBaseline: true, battery: 100, meterTotal: 1000)
        let outside = Reading(date: date("2026-01-10"), t1: 0, t2: 0, closesCycle: true,
                              tripB: 500, battery: 100, hasMeterReading: false)
        let end = Reading(date: date("2026-01-20"), t1: 0, t2: 0, closesCycle: true,
                          tripB: 800, battery: 100, meterTotal: 1200)
        let charges = [Charge(date: outside.date, energy: 30, cost: 3000),
                       Charge(date: date("2026-01-15"), energy: 10, cost: 500)]
        let report = try XCTUnwrap(Ledger.measurements(readings: [start, outside, end], charges: charges).first)
        XCTAssertTrue(report.homeEnergyKnown)
        XCTAssertEqual(report.cycleCount, 2)
        XCTAssertEqual(report.distance, 1300)
        XCTAssertEqual(report.homeEnergy, 200)
        XCTAssertEqual(report.totalEnergy, 240)
        XCTAssertEqual(report.estimatedTotalCost, 13000)
    }

    func testMonthlyTripARequiresNoMeterOrCycleReset() throws {
        let month = ISO8601DateFormatter().date(from: "2026-02-01T12:00:00Z")!
        let mileage = MileageRecord(date: date("2026-03-01"), month: month, distance: 2100)
        let charges = [Charge(date: date("2026-02-15"), energy: 10, cost: 600),
                       Charge(date: date("2026-03-01"), energy: 20, cost: 1000)]
        let report = try XCTUnwrap(Ledger.months(readings: [], charges: charges, mileage: [mileage], sessionCalendar: calendar).first)
        XCTAssertEqual(report.distance, 2100)
        XCTAssertEqual(report.month, month)
        XCTAssertEqual(report.outsideEnergy, 10)
        XCTAssertEqual(report.outsideCost, 600)
        XCTAssertFalse(report.homeEnergyKnown)
        XCTAssertTrue(Ledger.cycles(readings: [], charges: charges).isEmpty)
    }

    func testChangingMeterFormatValidatesTotalAndSkipsPendingReadings() {
        let start = Reading(date: date("2026-01-01"), t1: 400, t2: 600)
        let pending = Reading(date: date("2026-01-05"), t1: 0, t2: 0, hasMeterReading: false)
        let end = Reading(date: date("2026-01-10"), t1: 0, t2: 0, meterTotal: 1100)
        XCTAssertNil(Ledger.validate(end, against: [start, pending]))
        XCTAssertNotNil(Ledger.validate(Reading(date: end.date, t1: 0, t2: 0, meterTotal: 999), against: [start, pending]))
        XCTAssertNil(Ledger.validate(Reading(date: date("2026-01-20"), t1: 450, t2: 700), against: [start, pending, end]))
    }

    func testDeferredOutsideSessionsAreIncludedAtCycleClose() throws {
        let a = Reading(date: date("2026-01-01"), t1: 0, t2: 0, closesCycle: true,
                        isBaseline: true, battery: 100, meterTotal: 1000)
        let b = Reading(date: date("2026-01-10"), t1: 0, t2: 0, closesCycle: true,
                        tripB: 500, battery: 100, meterTotal: 1100)
        let deferred = [Charge(date: date("2026-01-03"), energy: 10, cost: 500),
                        Charge(date: date("2026-01-07"), energy: 20, cost: 1000)]
        let current = Charge(date: b.date, energy: 30, cost: 3000)
        let report = try XCTUnwrap(Ledger.cycles(readings: [a, b], charges: deferred + [current]).first)
        XCTAssertEqual(report.outsideEnergy, 60)
        XCTAssertEqual(report.outsideCost, 4500)
        XCTAssertEqual(report.totalEnergy, 160)
    }
}
