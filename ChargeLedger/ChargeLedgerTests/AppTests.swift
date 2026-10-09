import XCTest
import SwiftData
import UserNotifications
import ChargeLedgerCore
@testable import ChargeLedger

@MainActor
final class AppTests: XCTestCase {
    func testSwiftDataRoundTripRetainsPriceOverrideAndLink() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Checkpoint.self, OutsideCharge.self, MonthlyMileage.self, configurations: config)
        let context = ModelContext(container)
        let charge = Charge(date: .now, energy: 20, cost: 1500, tripB: Decimal(string: "125.5")!)
        let reading = Reading(date: charge.date, t1: 100, t2: 200, averageRate: 51,
                              closesCycle: true, tripB: 500, battery: 100)
        let checkpoint = Checkpoint(reading: reading, linkedChargeID: charge.id)
        context.insert(checkpoint); context.insert(OutsideCharge(charge: charge)); try context.save()
        let reloaded = try XCTUnwrap(context.fetch(FetchDescriptor<Checkpoint>()).first)
        XCTAssertEqual(reloaded.reading.averageRate, 51)
        XCTAssertEqual(reloaded.linkedChargeID, charge.id)
        XCTAssertEqual(reloaded.reading, reading)
        let reloadedCharge = try XCTUnwrap(context.fetch(FetchDescriptor<OutsideCharge>()).first)
        XCTAssertEqual(reloadedCharge.tripBText, "125.5")
        XCTAssertEqual(reloadedCharge.charge, charge)
        reloaded.update(with: Reading(id: reading.id, date: reading.date, t1: 100, t2: 200,
                                     averageRate: 55, closesCycle: true, tripB: 500, battery: 100))
        try context.save()
        XCTAssertEqual(reloaded.reading.averageRate, 55)
    }

    func testExportPreservesQuotesPricesAndLinkedSession() throws {
        let charge = Charge(date: .now, energy: Decimal(string: "12.6")!, cost: 0,
                            location: "Station, \"North\"", tripB: Decimal(string: "125.5")!)
        let checkpoint = Checkpoint(reading: Reading(date: charge.date, t1: 10, t2: 20, averageRate: 49), linkedChargeID: charge.id)
        let csv = CSVExport.make(readings: [checkpoint], charges: [OutsideCharge(charge: charge)])
        XCTAssertTrue(csv.contains("\"Station, \"\"North\"\"\""))
        XCTAssertTrue(csv.contains("\"49\""))
        XCTAssertTrue(csv.contains(charge.id.uuidString))
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}"))
        let chargeRow = try XCTUnwrap(csv.components(separatedBy: "\r\n").first { $0.hasPrefix("\"outside_charge\"") })
        XCTAssertEqual(chargeRow.components(separatedBy: ",")[10], "\"125.5\"")
    }

    func testMonthlyNotificationTriggerHasNextOccurrenceOnFirst() throws {
        var components = DateComponents()
        components.day = 1; components.hour = 9; components.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let next = try XCTUnwrap(trigger.nextTriggerDate())
        XCTAssertEqual(Calendar.current.component(.day, from: next), 1)
        XCTAssertEqual(Calendar.current.component(.hour, from: next), 9)
        XCTAssertEqual(Calendar.current.component(.minute, from: next), 0)
        XCTAssertTrue(trigger.repeats)
        XCTAssertNil(trigger.dateComponents.timeZone)
    }

    func testPendingHomeDataCanBeCompletedWithoutChangingOutsideSession() throws {
        let container = try ModelContainer(for: Checkpoint.self, OutsideCharge.self, MonthlyMileage.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let start = Reading(date: Date(timeIntervalSince1970: 1000), t1: 0, t2: 0,
                            closesCycle: true, isBaseline: true, battery: 100, meterTotal: 500)
        let pending = Reading(date: Date(timeIntervalSince1970: 2000), t1: 0, t2: 0,
                              closesCycle: true, tripB: 250, battery: 100, hasMeterReading: false)
        let charge = Charge(date: pending.date, energy: 30, cost: 1800)
        let checkpoint = Checkpoint(reading: pending, linkedChargeID: charge.id)
        checkpoint.endedOutside = true; checkpoint.homeDataStatus = "pending"
        context.insert(Checkpoint(reading: start)); context.insert(checkpoint)
        context.insert(OutsideCharge(charge: charge)); try context.save()
        let completed = try XCTUnwrap(Ledger.carryingForwardMeter(for: pending, readings: [start, pending]))
        checkpoint.update(with: completed); checkpoint.homeDataStatus = "unchanged"
        checkpoint.homeDataAddedAt = .now; try context.save()
        XCTAssertTrue(checkpoint.hasMeterReading)
        XCTAssertTrue(checkpoint.endedOutside)
        XCTAssertEqual(checkpoint.linkedChargeID, charge.id)
        XCTAssertEqual(checkpoint.homeDataStatus, "unchanged")
        XCTAssertEqual(try context.fetch(FetchDescriptor<OutsideCharge>()).first?.charge, charge)
        let csv = CSVExport.make(readings: [checkpoint], charges: [])
        XCTAssertTrue(csv.contains("\"unchanged\""))
        XCTAssertTrue(csv.contains("\"500\""))
    }

    func testLegacyMonthlyMileageConversionIsIdempotentAndKeepsMeterData() throws {
        let container = try ModelContainer(for: Checkpoint.self, OutsideCharge.self, MonthlyMileage.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let boundary = ISO8601DateFormatter().date(from: "2026-02-01T12:00:00Z")!
        let checkpoint = Checkpoint(reading: Reading(date: boundary, t1: 100, t2: 200,
                                                    monthBoundary: boundary, tripA: 2100))
        checkpoint.monthMileageMigrated = false
        context.insert(checkpoint); try context.save()
        try LegacyMileageMigration.run(in: context)
        try LegacyMileageMigration.run(in: context)
        let records = try context.fetch(FetchDescriptor<MonthlyMileage>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.distanceText, "2100")
        XCTAssertEqual(checkpoint.reading.total, 300)
        XCTAssertTrue(checkpoint.monthMileageMigrated)
        context.delete(try XCTUnwrap(records.first)); checkpoint.tripAText = nil; try context.save()
        try LegacyMileageMigration.run(in: context)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MonthlyMileage>()).isEmpty)
    }
}
