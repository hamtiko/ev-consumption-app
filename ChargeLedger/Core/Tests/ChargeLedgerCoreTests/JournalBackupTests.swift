import Foundation
import XCTest
@testable import ChargeLedgerCore

final class JournalBackupTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000.125)
    private let month = ISO8601DateFormatter().date(from: "2026-07-01T12:00:00Z")!

    func testRoundTripRetainsRawPrecisionLinksPendingDataBrandsAndSettings() throws {
        let id = UUID(), sessionID = UUID()
        let record = BackupCheckpoint(id: id, date: date, recordedAt: date.addingTimeInterval(20),
            t1Text: "1234.567890123456789", t2Text: "2000.00", averageRateText: "49.125",
            t1RateText: "53.48", t2RateText: "43.48", useTariffRates: true,
            monthBoundary: month, closesCycle: true, tripBText: "432.10", battery: 100,
            linkedChargeID: sessionID, hasMeterReading: false, endedOutside: true,
            homeDataStatus: "pending", modifiedAt: date, revision: "revision")
        let session = BackupOutsideCharge(id: sessionID, date: date, energyText: "31.200", costText: "3600.00",
                                          location: "Station, \"North\"\nԵրևան", tripBText: "19.2", stationBrand: "EV \"Brand\"")
        let monthly = BackupMonthlyMileage(id: id, date: date, month: month, distanceText: "")
        let backup = JournalBackup(createdAt: date, checkpoints: [record], outsideCharges: [session],
                                   monthlyMileage: [monthly], meterSettings: BackupMeterSettings(useTariffRates: true))
        XCTAssertEqual(try JournalBackup.decode(backup.encoded()), backup)
    }

    func testSingleCounterAndConfirmedUnchangedHomeMetadataRoundTrip() throws {
        let record = BackupCheckpoint(id: UUID(), date: date, recordedAt: date, meterTotalText: "4470.26",
                                      endedOutside: true, homeDataStatus: "unchanged", homeDataAddedAt: date)
        let backup = JournalBackup(checkpoints: [record])
        XCTAssertEqual(try JournalBackup.decode(backup.encoded()).checkpoints, [record])
    }

    func testVersionTwoRetainsActualTripCountersAndCalculatedDistance() throws {
        let record = BackupCheckpoint(id: UUID(), date: date, recordedAt: date, closesCycle: true,
            tripBText: "533.4", tripBCounterText: "960.0", tripBPreviousCounterText: "426.6",
            tripBPreviousCheckpointID: UUID(), battery: 100)
        let backup = JournalBackup(checkpoints: [record])
        let decoded = try JournalBackup.decode(backup.encoded())
        XCTAssertEqual(decoded.version, 2); XCTAssertEqual(decoded.checkpoints, [record])
    }

    func testVersionOneBackupDoesNotGuessActualCarCounter() throws {
        var old = JournalBackup(checkpoints: [BackupCheckpoint(id: UUID(), date: date, recordedAt: date,
                                                               closesCycle: true, tripBText: "533.4", battery: 100)])
        old.version = 1
        let data = try old.encoded()
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("tripBCounterText"))
        let restored = try JournalBackup.decode(data)
        XCTAssertEqual(restored.version, 1)
        XCTAssertEqual(restored.checkpoints.first?.tripBText, "533.4")
        XCTAssertNil(restored.checkpoints.first?.tripBCounterText)
        XCTAssertNil(restored.checkpoints.first?.tripBPreviousCounterText)
    }

    func testInconsistentTripCounterMetadataIsRejected() throws {
        var record = BackupCheckpoint(id: UUID(), date: date, recordedAt: date, closesCycle: true,
            tripBText: "533.4", tripBCounterText: "960", tripBPreviousCounterText: "426.6",
            tripBPreviousCheckpointID: UUID(), battery: 100)
        XCTAssertNoThrow(try JournalBackup(checkpoints: [record]).encoded())
        record.tripBText = "600"
        XCTAssertThrowsError(try JournalBackup(checkpoints: [record]).encoded())
        record.tripBText = "533.4"; record.tripBPreviousCounterText = nil
        XCTAssertThrowsError(try JournalBackup(checkpoints: [record]).encoded())
        record.tripBPreviousCheckpointID = nil
        XCTAssertThrowsError(try JournalBackup(checkpoints: [record]).encoded())
    }

    func testUnknownAndExplicitZeroMonthlyMileageRemainDifferent() throws {
        let unknown = BackupMonthlyMileage(id: UUID(), date: date, month: month, distanceText: "")
        var zero = unknown; zero.id = UUID(); zero.distanceText = "0"
        let backup = JournalBackup(monthlyMileage: [unknown, zero])
        let result = try JournalBackup.decode(backup.encoded())
        XCTAssertEqual(result.monthlyMileage.map(\.distanceText), ["", "0"])
    }

    func testDuplicateIDsRejectedOnlyWithinTheirOwnRecordType() throws {
        let record = BackupCheckpoint(id: UUID(), date: date, recordedAt: date)
        XCTAssertThrowsError(try JournalBackup(checkpoints: [record, record]).encoded())
        XCTAssertNoThrow(try JournalBackup(checkpoints: [record],
            monthlyMileage: [BackupMonthlyMileage(id: record.id, date: date, month: month, distanceText: "")]).encoded())
    }

    func testFutureVersionHasUsefulErrorWithoutNeedingCurrentRecordLayout() {
        let data = Data(#"{"format":"charge-ledger-backup","version":99}"#.utf8)
        XCTAssertThrowsError(try JournalBackup.decode(data)) { error in
            XCTAssertTrue(error.localizedDescription.contains("different app version"))
        }
    }

    func testRejectsForeignDamagedAndOversizedFiles() {
        for data in [Data(), Data("spreadsheet,csv".utf8), Data(#"{"format":"other-app","version":1}"#.utf8),
                     Data(repeating: 32, count: 20 * 1024 * 1024 + 1)] {
            XCTAssertThrowsError(try JournalBackup.decode(data))
        }
    }

    func testRejectsInvalidValuesBeforeImport() throws {
        var record = BackupCheckpoint(id: UUID(), date: date, recordedAt: date)
        record.t1Text = "-1"
        XCTAssertThrowsError(try JournalBackup(checkpoints: [record]).encoded())
        record.t1Text = "0"; record.battery = 101
        XCTAssertThrowsError(try JournalBackup(checkpoints: [record]).encoded())
        record.battery = nil; record.homeDataStatus = "maybe"
        XCTAssertThrowsError(try JournalBackup(checkpoints: [record]).encoded())
        XCTAssertThrowsError(try JournalBackup(monthlyMileage: [
            BackupMonthlyMileage(id: UUID(), date: date, month: date, distanceText: "500")]).encoded())
    }

    func testRepeatedImportIsIdempotentAndKeepsUnrelatedEntries() throws {
        let session = BackupOutsideCharge(id: UUID(), date: date, energyText: "30", costText: "2000")
        let other = BackupOutsideCharge(id: UUID(), date: date, energyText: "20", costText: "0")
        let backup = JournalBackup(outsideCharges: [session])
        let first = try backup.merging(into: JournalBackup(outsideCharges: [other]))
        XCTAssertEqual(first.added, 1); XCTAssertEqual(first.updated, 0)
        XCTAssertEqual(first.journal.outsideCharges.count, 2)
        let second = try backup.merging(into: first.journal)
        XCTAssertEqual(second.added, 0); XCTAssertEqual(second.updated, 0); XCTAssertEqual(second.kept, 1)
        XCTAssertEqual(second.journal.outsideCharges, first.journal.outsideCharges)
    }

    func testMatchingEntryKeepsNewerEditAndDoesNotReplaceMeterDefaults() throws {
        let old = BackupOutsideCharge(id: UUID(), date: date, energyText: "30", costText: "2000", modifiedAt: date)
        var newer = old; newer.costText = "2500"; newer.modifiedAt = date.addingTimeInterval(10)
        let localSettings = BackupMeterSettings(averageRate: "52")
        let current = JournalBackup(outsideCharges: [newer], meterSettings: localSettings)
        let result = try JournalBackup(outsideCharges: [old], meterSettings: BackupMeterSettings()).merging(into: current)
        XCTAssertEqual(result.kept, 1); XCTAssertEqual(result.updated, 0)
        XCTAssertEqual(result.journal.outsideCharges, [newer])
        XCTAssertEqual(result.journal.meterSettings, localSettings)
        let update = try JournalBackup(outsideCharges: [newer]).merging(into: JournalBackup(outsideCharges: [old]))
        XCTAssertEqual(update.updated, 1)
        XCTAssertEqual(update.journal.outsideCharges, [newer])
    }

    func testSimultaneousEditOrderingDoesNotDependOnImportDirection() throws {
        let a = BackupOutsideCharge(id: UUID(), date: date, energyText: "10", costText: "100", modifiedAt: date, revision: "a")
        var b = a; b.costText = "200"; b.revision = "b"
        let first = try JournalBackup(outsideCharges: [a]).merging(into: JournalBackup(outsideCharges: [b]))
        let second = try JournalBackup(outsideCharges: [b]).merging(into: JournalBackup(outsideCharges: [a]))
        XCTAssertEqual(first.journal.outsideCharges, [b])
        XCTAssertEqual(second.journal.outsideCharges, [b])
    }

    func testSharedMonthlyAndMeterIdentityIsRestoredAsTwoLinkedRecords() throws {
        let id = UUID()
        let boundary = Ledger.monthCalendar.date(byAdding: .month, value: 1, to: month)!
        let backup = JournalBackup(checkpoints: [BackupCheckpoint(id: id, date: date, recordedAt: date, monthBoundary: boundary)],
            monthlyMileage: [BackupMonthlyMileage(id: id, date: date, month: month, distanceText: "1200")])
        let result = try backup.merging(into: JournalBackup())
        XCTAssertEqual(result.added, 2)
        XCTAssertEqual(result.journal.checkpoints.first?.id, result.journal.monthlyMileage.first?.id)
    }

    func testConflictingCountersOrMonthEntriesRejectTheWholeMerge() {
        let existing = BackupCheckpoint(id: UUID(), date: date, recordedAt: date, meterTotalText: "500")
        let conflict = BackupCheckpoint(id: UUID(), date: date.addingTimeInterval(100), recordedAt: date, meterTotalText: "400")
        XCTAssertThrowsError(try JournalBackup(checkpoints: [conflict]).merging(into: JournalBackup(checkpoints: [existing])))
        let current = JournalBackup(monthlyMileage: [BackupMonthlyMileage(id: UUID(), date: date, month: month, distanceText: "100")])
        let incoming = JournalBackup(monthlyMileage: [BackupMonthlyMileage(id: UUID(), date: date, month: month, distanceText: "200")])
        XCTAssertThrowsError(try incoming.merging(into: current))
        XCTAssertEqual(current.monthlyMileage.count, 1)
    }
}
