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

    func testCalculatedTripBCountersSurvivePersistenceBackupAndHomeDataCompletion() throws {
        let source = ModelContext(try container())
        let reading = Reading(date: Date(timeIntervalSince1970: 1000), t1: 0, t2: 0,
                              closesCycle: true, tripB: Decimal(string: "533.4")!, battery: 100, hasMeterReading: false)
        let checkpoint = Checkpoint(reading: reading)
        checkpoint.tripBCounterText = "960"; checkpoint.tripBPreviousCounterText = "426.6"
        checkpoint.tripBPreviousCheckpointID = UUID()
        source.insert(checkpoint); try JournalStore.save(source)
        let backup = try JournalBackup.decode(BackupStore.snapshot(in: source).encoded())
        let target = ModelContext(try container())
        _ = try BackupStore.restore(backup, in: target, restoreSettings: false)
        let stored = try XCTUnwrap(target.fetch(FetchDescriptor<Checkpoint>()).first)
        XCTAssertEqual(stored.tripBText, "533.4"); XCTAssertEqual(stored.tripBCounterText, "960")
        XCTAssertEqual(stored.tripBPreviousCounterText, "426.6")
        XCTAssertEqual(stored.tripBPreviousCheckpointID, checkpoint.tripBPreviousCheckpointID)
        stored.update(with: Reading(id: stored.id, date: stored.date, t1: 100, t2: 200,
                                    closesCycle: true, tripB: stored.reading.tripB, battery: 100))
        try JournalStore.save(target)
        XCTAssertEqual(stored.tripBCounterText, "960")
        XCTAssertEqual(stored.reading.tripB, Decimal(string: "533.4"))
        let row = try XCTUnwrap(CSVExport.make(readings: [stored], charges: []).components(separatedBy: "\r\n")
            .first { $0.hasPrefix("\"checkpoint\"") }).components(separatedBy: ",")
        XCTAssertEqual(row[27], "\"960\""); XCTAssertEqual(row[28], "\"426.6\"")
        XCTAssertEqual(row[29], "\"\(try XCTUnwrap(stored.tripBPreviousCheckpointID).uuidString)\"")
    }

    func testUpgradeFromCloudSchemaLeavesHistoricalRawCounterUnknown() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("default.store"), id = UUID(), sessionID = UUID()
        let date = Date(timeIntervalSince1970: 1000)
        try autoreleasepool {
            let schema = Schema(versionedSchema: CloudJournalSchemaV2.self)
            let old = try ModelContainer(for: schema,
                configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
            let context = ModelContext(old)
            let checkpoint = CloudJournalSchemaV2.Checkpoint(reading: Reading(id: id, date: date, t1: 100, t2: 200,
                averageRate: 51, closesCycle: true, tripB: Decimal(string: "533.4")!, battery: 100), linkedChargeID: sessionID)
            checkpoint.modifiedAt = date; checkpoint.revision = "existing-edit"; checkpoint.instanceID = "existing-replica"
            context.insert(checkpoint)
            context.insert(CloudJournalSchemaV2.OutsideCharge(charge: Charge(id: sessionID, date: date, energy: 30,
                                                                           cost: 2000, stationBrand: "Brand")))
            try context.save()
        }
        let schema = Schema(versionedSchema: JournalSchema.self)
        let current = try ModelContainer(for: schema, migrationPlan: JournalMigration.self,
            configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        let context = ModelContext(current)
        let checkpoint = try XCTUnwrap(context.fetch(FetchDescriptor<Checkpoint>()).first)
        XCTAssertEqual(checkpoint.id, id); XCTAssertEqual(checkpoint.tripBText, "533.4")
        XCTAssertNil(checkpoint.tripBCounterText); XCTAssertNil(checkpoint.tripBPreviousCounterText)
        XCTAssertNil(checkpoint.tripBPreviousCheckpointID)
        XCTAssertEqual(checkpoint.modifiedAt, date); XCTAssertEqual(checkpoint.revision, "existing-edit")
        XCTAssertEqual(checkpoint.instanceID, "existing-replica"); XCTAssertEqual(checkpoint.linkedChargeID, sessionID)
        XCTAssertEqual(try context.fetch(FetchDescriptor<OutsideCharge>()).first?.stationBrand, "Brand")
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
