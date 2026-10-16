import Foundation
import XCTest
import SwiftData
import ChargeLedgerCore
@testable import ChargeLedger

@MainActor
final class StorageTests: XCTestCase {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Checkpoint.self, OutsideCharge.self, MonthlyMileage.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    func testBackupRestoreKeepsPairedMonthlyReadingsAndIsIdempotent() throws {
        let context = ModelContext(try container())
        let id = UUID(), sessionID = UUID()
        let month = ISO8601DateFormatter().date(from: "2026-07-01T12:00:00Z")!
        let boundary = ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z")!
        let checkpoint = BackupCheckpoint(id: id, date: boundary, recordedAt: boundary,
            averageRateText: "49.123456789", monthBoundary: boundary, linkedChargeID: sessionID,
            meterTotalText: "1234.567890123456789", homeDataStatus: "entered", homeDataAddedAt: boundary)
        let backup = JournalBackup(checkpoints: [checkpoint],
            outsideCharges: [BackupOutsideCharge(id: sessionID, date: month, energyText: "31.200", costText: "0",
                                                location: "North, \"EV\"", tripBText: "125.5", stationBrand: "Brand")],
            monthlyMileage: [BackupMonthlyMileage(id: id, date: boundary, month: month, distanceText: "")])
        XCTAssertEqual(try BackupStore.restore(backup, in: context, restoreSettings: false).added, 3)
        XCTAssertEqual(try BackupStore.restore(backup, in: context, restoreSettings: false).added, 0)
        let restored = try BackupStore.snapshot(in: context)
        XCTAssertEqual(restored.checkpoints, backup.checkpoints)
        XCTAssertEqual(restored.monthlyMileage, backup.monthlyMileage)
        XCTAssertEqual(restored.outsideCharges, backup.outsideCharges)
    }

    func testConflictingImportDoesNotChangeExistingData() throws {
        let context = ModelContext(try container())
        let date = Date(timeIntervalSince1970: 1000)
        let checkpoint = Checkpoint(reading: Reading(date: date, t1: 0, t2: 0, meterTotal: 500))
        context.insert(checkpoint); try JournalStore.save(context)
        let before = try BackupStore.snapshot(in: context)
        let conflict = JournalBackup(checkpoints: [BackupCheckpoint(id: UUID(), date: date.addingTimeInterval(100),
                                                                   recordedAt: date, meterTotalText: "400")])
        XCTAssertThrowsError(try BackupStore.restore(conflict, in: context, restoreSettings: false))
        XCTAssertEqual(try BackupStore.snapshot(in: context).checkpoints, before.checkpoints)
        XCTAssertFalse(context.hasChanges)
    }

    func testSyncDuplicatesKeepLatestEditWithoutDeletingPairedMonth() throws {
        let context = ModelContext(try container())
        let date = Date(timeIntervalSince1970: 1000), id = UUID()
        let month = ISO8601DateFormatter().date(from: "2026-07-01T12:00:00Z")!
        let old = Checkpoint(reading: Reading(id: id, date: date, t1: 10, t2: 20, averageRate: 47))
        let latest = Checkpoint(reading: Reading(id: id, date: date, t1: 10, t2: 20, averageRate: 51))
        old.modifiedAt = date; latest.modifiedAt = date.addingTimeInterval(100)
        context.insert(old); context.insert(latest)
        context.insert(MonthlyMileage(record: MileageRecord(id: id, date: date, month: month, distance: 0, distanceKnown: false)))
        try context.save()
        XCTAssertEqual(SyncRecords.unique([old, latest]).first?.averageRateText, "51")
        try JournalStore.reconcile(context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Checkpoint>()).map(\.averageRateText), ["51"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<MonthlyMileage>()).map(\.id), [id])
    }

    func testSyncTieBreakIsStableAndLogicalDeleteRemovesEveryKnownReplica() throws {
        let context = ModelContext(try container()), id = UUID()
        let reading = Reading(id: id, date: .now, t1: 10, t2: 20)
        let a = Checkpoint(reading: reading), b = Checkpoint(reading: reading)
        XCTAssertNotEqual(a.instanceID, b.instanceID)
        a.instanceID = "a"; b.instanceID = "z"
        context.insert(a); context.insert(b); try context.save()
        XCTAssertEqual(SyncRecords.unique([a, b]).first?.instanceID, "z")
        XCTAssertEqual(SyncRecords.unique([b, a]).first?.instanceID, "z")
        try JournalStore.delete(a, in: context); try JournalStore.save(context)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Checkpoint>()).isEmpty)
    }

    func testConfigurationKeepsOriginalDefaultStoreURL() {
        let old = ModelConfiguration()
        let updated = ModelConfiguration(schema: Schema(versionedSchema: JournalSchema.self), cloudKitDatabase: .none)
        XCTAssertEqual(old.url, updated.url)
    }

    func testUpgradeFromUnversionedLocalSchemaPreservesAllRecordTypes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("default.store")
        let date = Date(timeIntervalSince1970: 1000), id = UUID(), chargeID = UUID()
        let month = ISO8601DateFormatter().date(from: "2026-07-01T12:00:00Z")!
        try autoreleasepool {
            // No versioned Schema: this reproduces how the pre-iCloud release opened its store.
            let schema = Schema([LegacyJournalSchema.Checkpoint.self, LegacyJournalSchema.OutsideCharge.self,
                                 LegacyJournalSchema.MonthlyMileage.self])
            let old = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
            let context = ModelContext(old)
            let checkpoint = LegacyJournalSchema.Checkpoint(reading: Reading(id: id, date: date, t1: 100, t2: 200,
                averageRate: 51, closesCycle: true, tripB: 500, battery: 100, hasMeterReading: false), linkedChargeID: chargeID)
            checkpoint.endedOutside = true; checkpoint.homeDataStatus = "pending"
            context.insert(checkpoint)
            context.insert(LegacyJournalSchema.OutsideCharge(charge: Charge(id: chargeID, date: date, energy: 30,
                cost: 2000, location: "North", tripB: 150, stationBrand: "Brand")))
            context.insert(LegacyJournalSchema.MonthlyMileage(record: MileageRecord(id: id, date: date, month: month, distance: 0, distanceKnown: false)))
            try context.save()
        }
        let schema = Schema(versionedSchema: JournalSchema.self)
        let upgraded = try ModelContainer(for: schema, migrationPlan: JournalMigration.self,
            configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        let context = ModelContext(upgraded)
        let checkpoint = try XCTUnwrap(context.fetch(FetchDescriptor<Checkpoint>()).first)
        XCTAssertEqual(checkpoint.id, id); XCTAssertEqual(checkpoint.linkedChargeID, chargeID)
        XCTAssertEqual(checkpoint.averageRateText, "51"); XCTAssertEqual(checkpoint.tripBText, "500")
        XCTAssertEqual(checkpoint.homeDataStatus, "pending"); XCTAssertFalse(checkpoint.hasMeterReading)
        let charge = try XCTUnwrap(context.fetch(FetchDescriptor<OutsideCharge>()).first)
        XCTAssertEqual(charge.id, chargeID); XCTAssertEqual(charge.stationBrand, "Brand"); XCTAssertEqual(charge.tripBText, "150")
        let mileage = try XCTUnwrap(context.fetch(FetchDescriptor<MonthlyMileage>()).first)
        XCTAssertEqual(mileage.id, id); XCTAssertEqual(mileage.distanceText, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: BackupStore.upgradeBackupURL.path))
    }
}
