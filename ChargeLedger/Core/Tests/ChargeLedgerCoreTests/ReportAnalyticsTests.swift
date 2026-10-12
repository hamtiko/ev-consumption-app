import XCTest
@testable import ChargeLedgerCore

final class ReportAnalyticsTests: XCTestCase {
    private var calendar: Calendar { Ledger.monthCalendar }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text + "T00:00:00Z")! }
    private func summary(distance: Decimal = 100, energy: Decimal = 20, homeCost: Decimal = 500,
                         outsideEnergy: Decimal = 0, outsideCost: Decimal = 0, known: Bool = true,
                         distanceKnown: Bool = true, month: Date? = nil) -> PeriodSummary {
        PeriodSummary(id: UUID(), start: date("2026-01-01"), end: date("2026-02-01"), month: month,
                      distance: distance, homeEnergy: energy, outsideEnergy: outsideEnergy,
                      estimatedHomeCost: homeCost, tariffComparisonCost: nil, outsideCost: outsideCost,
                      startBattery: 100, endBattery: 100, homeEnergyKnown: known, cycleCount: 1,
                      missingHomeReadingIDs: [], distanceKnown: distanceKnown)
    }

    func testCycleAverageIsWeightedWhileExtremaAreIndividualCycles() throws {
        let a = summary(distance: 100, energy: 20, homeCost: 500)
        let b = summary(distance: 900, energy: 90, homeCost: 900)
        let stats = try XCTUnwrap(ReportAnalytics.cycleStatistics([a, b]))
        XCTAssertEqual(stats.consumption.average, 11)
        XCTAssertEqual(stats.consumption.minimum, 10)
        XCTAssertEqual(stats.consumption.maximum, 20)
        XCTAssertEqual(stats.costPerKM.average, Decimal(string: "1.4"))
        XCTAssertEqual(stats.costPerKM.minimum, 1)
        XCTAssertEqual(stats.costPerKM.maximum, 5)
        XCTAssertEqual(stats.consumption.sampleCount, 2)
    }

    func testPendingUnknownDistanceAndZeroDistanceDoNotBiasAnyStatistic() throws {
        let complete = summary()
        let excluded = [summary(energy: 9999, homeCost: 99999, known: false),
                        summary(distance: 0, energy: 9999), summary(energy: 9999, distanceKnown: false)]
        let stats = try XCTUnwrap(ReportAnalytics.cycleStatistics(excluded + [complete]))
        XCTAssertEqual(stats.distance, 100)
        XCTAssertEqual(stats.totalEnergy, 20)
        XCTAssertEqual(stats.consumption.average, 20)
        XCTAssertEqual(stats.costPerKM.average, 5)
        XCTAssertEqual(stats.consumption.minimum, stats.consumption.maximum)
        XCTAssertEqual(ReportAnalytics.eligibleCycles(excluded + [complete]).map(\.id), [complete.id])
    }

    func testNoEligibleCyclesHaveNoStatistics() {
        XCTAssertNil(ReportAnalytics.cycleStatistics([]))
        XCTAssertNil(ReportAnalytics.cycleStatistics([summary(known: false), summary(distance: 0)]))
    }

    func testZeroEnergyAndFreeChargingRemainValidWithoutDividingByZero() throws {
        let stats = try XCTUnwrap(ReportAnalytics.cycleStatistics([summary(energy: 0, homeCost: 0)]))
        XCTAssertEqual(stats.consumption.average, 0)
        XCTAssertEqual(stats.costPerKM.minimum, 0)
        XCTAssertNil(stats.outsideEnergyShare)
        XCTAssertNil(stats.outsideCostShare)
        XCTAssertNil(stats.homePricePerKWh)
        XCTAssertNil(stats.outsidePricePerKWh)
    }

    func testSourceSharesAndPricesUseTotalsRatherThanSessionMeans() throws {
        let a = summary(energy: 30, homeCost: 1500, outsideEnergy: 10, outsideCost: 1000)
        let b = summary(energy: 50, homeCost: 2500, outsideEnergy: 10, outsideCost: 1000)
        let stats = try XCTUnwrap(ReportAnalytics.cycleStatistics([a, b]))
        XCTAssertEqual(stats.totalEnergy, 100)
        XCTAssertEqual(stats.outsideEnergyShare, 20)
        XCTAssertEqual(Numbers.double(try XCTUnwrap(stats.outsideCostShare)), 100.0 / 3, accuracy: 0.000001)
        XCTAssertEqual(stats.homePricePerKWh, 50)
        XCTAssertEqual(stats.outsidePricePerKWh, 100)
    }

    func testCompletingTemporaryHomeReadingAutomaticallyIncludesBothCycles() throws {
        let a = Reading(date: date("2026-01-01"), t1: 0, t2: 0, averageRate: 10,
                        closesCycle: true, isBaseline: true, battery: 100, meterTotal: 1000)
        let b = Reading(date: date("2026-01-10"), t1: 0, t2: 0, averageRate: 10,
                        closesCycle: true, tripB: 500, battery: 100, hasMeterReading: false)
        let c = Reading(date: date("2026-01-20"), t1: 0, t2: 0, averageRate: 10,
                        closesCycle: true, tripB: 500, battery: 100, meterTotal: 1100)
        let charges = [Charge(date: b.date, energy: 20, cost: 2000, stationBrand: "Acme")]
        XCTAssertNil(ReportAnalytics.cycleStatistics(Ledger.cycles(readings: [a, b, c], charges: charges)))
        let completed = Reading(id: b.id, date: b.date, t1: 0, t2: 0, averageRate: 10,
                                closesCycle: true, tripB: 500, battery: 100, meterTotal: 1050)
        let stats = try XCTUnwrap(ReportAnalytics.cycleStatistics(Ledger.cycles(readings: [a, completed, c], charges: charges)))
        XCTAssertEqual(stats.consumption.sampleCount, 2)
        XCTAssertEqual(stats.consumption.average, 12)
        XCTAssertEqual(stats.consumption.minimum, 10)
        XCTAssertEqual(stats.consumption.maximum, 14)
        XCTAssertEqual(stats.costPerKM.average, 3)
    }

    func testBrandGroupingNormalizesCaseAndWhitespaceWithWeightedPrices() throws {
        let charges = [Charge(date: date("2026-01-01"), energy: 10, cost: 100, stationBrand: "  Acme   Charge "),
                       Charge(date: date("2026-01-02"), energy: 30, cost: 900, stationBrand: "ACME\tCHARGE"),
                       Charge(date: date("2026-01-03"), energy: 10, cost: 0)]
        let brands = ReportAnalytics.brands(charges: charges.reversed())
        let acme = try XCTUnwrap(brands.first { $0.id == StationBrands.key("acme charge") })
        XCTAssertEqual(acme.name, "Acme Charge")
        XCTAssertEqual(acme.energy, 40)
        XCTAssertEqual(acme.cost, 1000)
        XCTAssertEqual(acme.sessions, 2)
        XCTAssertEqual(acme.pricePerKWh, 25)
        XCTAssertEqual(acme.energyShare, 80)
        XCTAssertEqual(brands.count, 2)
    }

    func testUnassignedBrandDoesNotInferLocationOrCollideWithNamedUnspecified() {
        let charges = [Charge(date: date("2026-01-01"), energy: 10, cost: 100, location: "Acme"),
                       Charge(date: date("2026-01-02"), energy: 10, cost: 100, stationBrand: "Unspecified"),
                       Charge(date: date("2026-01-03"), energy: 10, cost: 100, stationBrand: " \n ")]
        let brands = ReportAnalytics.brands(charges: charges)
        XCTAssertEqual(brands.count, 2)
        XCTAssertEqual(brands.first { $0.id == "unspecified" }?.sessions, 2)
        XCTAssertNotEqual(StationBrands.key(nil), StationBrands.key("Unspecified"))
    }

    func testBrandChoicesAreUniqueAndNewNamesArePreserved() {
        XCTAssertEqual(StationBrands.choices([nil, "Acme", " ACME ", "Beta", ""]), ["Acme", "Beta"])
        XCTAssertEqual(StationBrands.canonicalName(" acme ", choices: ["Acme"]), "Acme")
        XCTAssertEqual(StationBrands.canonicalName("New  Brand", choices: ["Acme"]), "New Brand")
        XCTAssertNil(StationBrands.canonicalName(" ", choices: ["Acme"]))
    }

    func testBrandZeroAndFreeEnergyNeverProducesInvalidPriceOrShare() {
        XCTAssertTrue(ReportAnalytics.brands(charges: []).isEmpty)
        let empty = ReportAnalytics.brands(charges: [Charge(date: date("2026-01-01"), energy: 0, cost: 0)]).first!
        XCTAssertNil(empty.pricePerKWh)
        XCTAssertNil(empty.energyShare)
        let free = ReportAnalytics.brands(charges: [Charge(date: date("2026-01-01"), energy: 20, cost: 0)]).first!
        XCTAssertEqual(free.pricePerKWh, 0)
        XCTAssertEqual(free.energyShare, 100)
    }

    func testHistoryUsesExactlyThreeCalendarMonthsAndExcludesFutureRecords() {
        let now = date("2026-10-12")
        XCTAssertEqual(ReportRange.threeMonths.start(through: now, calendar: calendar), date("2026-08-01"))
        XCTAssertTrue(ReportRange.threeMonths.includes(date("2026-08-01"), through: now, calendar: calendar))
        XCTAssertFalse(ReportRange.threeMonths.includes(date("2026-07-31"), through: now, calendar: calendar))
        XCTAssertFalse(ReportRange.all.includes(date("2026-10-13"), through: now, calendar: calendar))
        XCTAssertTrue(ReportRange.all.includes(date("2020-01-01"), through: now, calendar: calendar))
        XCTAssertEqual(ReportRange.sixMonths.start(through: now, calendar: calendar), date("2026-05-01"))
        XCTAssertEqual(ReportRange.twelveMonths.start(through: now, calendar: calendar), date("2025-11-01"))
    }

    func testYearToDateAndStableMonthIdentityUseLocalCalendar() {
        var local = calendar
        local.timeZone = TimeZone(secondsFromGMT: -7 * 3600)!
        let now = date("2026-10-12")
        XCTAssertTrue(ReportRange.threeMonths.includesMonth(date("2026-08-01"), through: now, calendar: local))
        XCTAssertFalse(ReportRange.threeMonths.includesMonth(date("2026-07-01"), through: now, calendar: local))
        let yearStart = date("2026-01-01").addingTimeInterval(7 * 3600)
        XCTAssertEqual(ReportRange.yearToDate.start(through: now, calendar: local), yearStart)
        XCTAssertFalse(ReportRange.yearToDate.includes(yearStart.addingTimeInterval(-1), through: now, calendar: local))
        XCTAssertTrue(ReportRange.yearToDate.includes(yearStart, through: now, calendar: local))
    }

    func testMonthlyCostChangeRequiresPreviousCalendarMonthWithKnownHomeCost() throws {
        let current = summary(homeCost: 1500, month: date("2026-03-01"))
        let previous = summary(homeCost: 1000, month: date("2026-02-01"))
        let change = try XCTUnwrap(ReportAnalytics.monthlyCostChange(for: current, reports: [previous, current]))
        XCTAssertEqual(change.amount, 500)
        XCTAssertEqual(change.percent, 50)
        XCTAssertNil(ReportAnalytics.monthlyCostChange(for: current, reports: [summary(month: date("2026-01-01"))]))
        XCTAssertNil(ReportAnalytics.monthlyCostChange(for: current, reports: [summary(known: false, month: previous.month)]))
        XCTAssertNil(ReportAnalytics.monthlyCostChange(for: summary(known: false, month: current.month), reports: [previous]))
    }

    func testMonthlyCostDropAndZeroBaselineAreReportedWithoutInvalidPercentages() throws {
        let previous = summary(homeCost: 1000, month: date("2026-02-01"))
        let current = summary(homeCost: 0, month: date("2026-03-01"))
        let drop = try XCTUnwrap(ReportAnalytics.monthlyCostChange(for: current, reports: [previous]))
        XCTAssertEqual(drop.amount, -1000)
        XCTAssertEqual(drop.percent, -100)
        let increase = try XCTUnwrap(ReportAnalytics.monthlyCostChange(for: summary(homeCost: 100, month: date("2026-04-01")), reports: [current]))
        XCTAssertEqual(increase.amount, 100)
        XCTAssertNil(increase.percent)
    }
}
